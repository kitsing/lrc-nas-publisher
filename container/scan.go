package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/text/unicode/norm"
)

// RAW formats whose edits Lightroom keeps in a .xmp sidecar. DNG is missing on
// purpose: Lightroom writes a DNG's edits into the DNG itself and ignores
// sidecars next to it.
var rawExts = map[string]bool{
	".raf": true, ".nef": true, ".nrw": true, ".cr2": true, ".cr3": true, ".crw": true,
	".arw": true, ".srf": true, ".sr2": true, ".orf": true, ".rw2": true, ".raw": true,
	".rwl": true, ".pef": true, ".srw": true, ".x3f": true, ".3fr": true, ".fff": true,
	".iiq": true, ".erf": true, ".mef": true, ".mos": true, ".mrw": true, ".dcr": true,
	".kdc": true, ".gpr": true,
}

// A sidecar with Camera Raw settings says crs:HasSettings="True" (attribute
// form, what Lightroom writes) or <crs:HasSettings>True</crs:HasSettings>.
var hasSettingsRE = regexp.MustCompile(`crs:HasSettings\s*=\s*["']True["']|<crs:HasSettings>\s*True\s*</crs:HasSettings>`)

// Sidecars changed this recently may still be being written.
const sidecarSettle = 30 * time.Second

type SidecarItem struct {
	Rel      string    `json:"rel"`              // the RAW, relative to SOURCE_DIR
	RelNFD   string    `json:"relNFD,omitempty"` // Rel in decomposed Unicode, if different: how macOS may spell it
	Sidecar  string    `json:"sidecar"`          // its .xmp
	Modified time.Time `json:"modified"`
	Version  string    `json:"version"` // changes whenever the sidecar does; independent of time zones
}

type ScanSnapshot struct {
	At      time.Time
	Took    time.Duration
	Running bool
	Items   []SidecarItem
	Raws    int
	Err     string
}

type sidecarInfo struct {
	size        int64
	mod         time.Time
	hasSettings bool
}

// Scanner walks SOURCE_DIR for RAWs with edited XMP sidecars. It runs only
// when asked, and the plugin asks only while Lightroom is running.
type Scanner struct {
	root    string
	exclude []string

	mu      sync.Mutex
	snap    ScanSnapshot
	done    chan struct{} // closed when the running scan ends
	cache   map[string]sidecarInfo
	nowFunc func() time.Time
}

func newScanner(root string, exclude []string) *Scanner {
	return &Scanner{root: root, exclude: exclude, cache: map[string]sidecarInfo{}, nowFunc: time.Now}
}

// kickIfStale starts a scan in the background unless a recent one exists or
// one is running.
func (s *Scanner) kickIfStale(maxAge time.Duration) <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done != nil {
		return s.done
	}
	if !s.snap.At.IsZero() && s.nowFunc().Sub(s.snap.At) < maxAge {
		closed := make(chan struct{})
		close(closed)
		return closed
	}
	done := make(chan struct{})
	s.done = done
	s.snap.Running = true
	go s.run(done)
	return done
}

// get returns the latest results, scanning first if they are stale and
// waiting for the scan until ctx ends.
func (s *Scanner) get(ctx context.Context, maxAge time.Duration) ScanSnapshot {
	done := s.kickIfStale(maxAge)
	select {
	case <-done:
	case <-ctx.Done():
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	snap := s.snap
	snap.Items = append([]SidecarItem(nil), s.snap.Items...)
	return snap
}

func (s *Scanner) run(done chan struct{}) {
	start := s.nowFunc()
	var items []SidecarItem
	raws := 0
	seen := map[string]bool{}
	err := s.scanDir(s.root, "", &items, &raws, seen)
	s.mu.Lock()
	for p := range s.cache {
		if !seen[p] {
			delete(s.cache, p)
		}
	}
	s.snap = ScanSnapshot{At: s.nowFunc(), Took: s.nowFunc().Sub(start), Items: items, Raws: raws}
	if err != nil {
		s.snap.Err = err.Error()
		logf("WARNING", "Sidecar scan: %v", err)
	} else {
		logf("INFO", "Sidecar scan: %d RAWs, %d with edited sidecars (%s).", raws, len(items), s.snap.Took.Round(time.Millisecond))
	}
	s.done = nil
	s.mu.Unlock()
	close(done)
}

func (s *Scanner) scanDir(dir, rel string, items *[]SidecarItem, raws *int, seen map[string]bool) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	xmps := map[string]os.DirEntry{}
	for _, e := range entries {
		if !e.IsDir() && strings.EqualFold(path.Ext(e.Name()), ".xmp") {
			xmps[strings.ToLower(strings.TrimSuffix(e.Name(), path.Ext(e.Name())))] = e
		}
	}
	for _, e := range entries {
		name := e.Name()
		if excluded(name, s.exclude) {
			continue
		}
		childRel := path.Join(rel, name)
		if e.IsDir() {
			if err := s.scanDir(filepath.Join(dir, name), childRel, items, raws, seen); err != nil {
				logf("WARNING", "Sidecar scan: skipping %s: %v", childRel, err)
			}
			continue
		}
		if !e.Type().IsRegular() || !rawExts[strings.ToLower(path.Ext(name))] {
			continue
		}
		*raws++
		x, ok := xmps[strings.ToLower(strings.TrimSuffix(name, path.Ext(name)))]
		if !ok {
			continue
		}
		info, err := x.Info()
		if err != nil || s.nowFunc().Sub(info.ModTime()) < sidecarSettle {
			continue
		}
		sidecar := filepath.Join(dir, x.Name())
		seen[sidecar] = true
		if s.hasSettings(sidecar, info) {
			item := SidecarItem{Rel: childRel, Sidecar: path.Join(rel, x.Name()), Modified: info.ModTime(),
				Version: fmt.Sprintf("%d-%d", info.ModTime().UnixNano(), info.Size())}
			if nfd := norm.NFD.String(childRel); nfd != childRel {
				item.RelNFD = nfd
			}
			*items = append(*items, item)
		}
	}
	return nil
}

// hasSettings reports whether the sidecar holds Camera Raw settings; unchanged
// sidecars are not read again.
func (s *Scanner) hasSettings(p string, info os.FileInfo) bool {
	s.mu.Lock()
	c, ok := s.cache[p]
	s.mu.Unlock()
	if ok && c.size == info.Size() && c.mod.Equal(info.ModTime()) {
		return c.hasSettings
	}
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	b, err := io.ReadAll(io.LimitReader(f, 16<<20))
	f.Close()
	if err != nil {
		return false
	}
	has := hasSettingsRE.Match(b)
	s.mu.Lock()
	s.cache[p] = sidecarInfo{size: info.Size(), mod: info.ModTime(), hasSettings: has}
	s.mu.Unlock()
	return has
}

// excluded matches a file or folder name against EXCLUDE patterns, ignoring
// case.
func excluded(name string, patterns []string) bool {
	lower := strings.ToLower(name)
	for _, p := range patterns {
		if ok, _ := path.Match(strings.ToLower(p), lower); ok {
			return true
		}
	}
	return false
}
