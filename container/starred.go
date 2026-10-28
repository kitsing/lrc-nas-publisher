package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"golang.org/x/text/unicode/norm"
)

// The starred folder (STARRED_DIR, "starred" by default) holds the JPEGs of the
// photos the plugin reports as starred, all in one folder so a gallery shows
// them as one album. Each is a hard link to the published JPEG: an ordinary file
// to every app, taking no extra space. Publishing a new version writes a new
// file, so the link is made again then. Where hard links aren't possible, a copy
// is made instead, stamped with the original's time so it isn't copied again.
//
// What the service put there is recorded in EXPORT_DIR/.lrc-starred.json, apart
// from state.json, so it survives losing state.json and a renamed or disabled
// starred folder. Each record has the file's inode (and size and time), and the
// service only removes or replaces a file that still matches it: a file someone
// else put there, or replaced, is left alone.

const (
	linkPrefix   = ".lrc-link-" // temporary names while a link is made
	starManifest = ".lrc-starred.json"
)

// linkFile makes a hard link; tests swap it out to exercise the copy fallback.
var linkFile = os.Link

type starEntry struct {
	Name  string    `json:"name"` // path relative to EXPORT_DIR
	Ino   uint64    `json:"ino"`
	Size  int64     `json:"size"`
	MTime time.Time `json:"mtime"`
	Copy  bool      `json:"copy,omitempty"` // a copy, not a hard link
}

type starManifestFile struct {
	Version int                   `json:"version"`
	Entries map[string]*starEntry `json:"entries"` // published id -> its file in the starred folder
}

// loadStarred reads the manifest and drops what no longer belongs: entries of a
// folder that was renamed, or of a feature that was turned off.
func (a *App) loadStarred() error {
	a.starred = map[string]*starEntry{}
	a.starErr = map[string]string{}
	b, err := os.ReadFile(filepath.Join(a.cfg.ExportDir, starManifest))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var m starManifestFile
	if err := json.Unmarshal(b, &m); err != nil {
		return fmt.Errorf("%s is damaged (%v); move it away to start over", starManifest, err)
	}
	for id, e := range m.Entries {
		if e != nil && e.Name != "" {
			a.starred[id] = e
		}
	}
	stale := 0
	for _, id := range sortedKeys(a.starred) {
		if !a.inStarredDir(a.starred[id].Name) {
			a.unstarLocked(id)
			stale++
		}
	}
	if stale > 0 {
		logf("INFO", "Removed %d starred links left from an earlier STARRED_DIR.", stale)
		return a.saveStarred()
	}
	return nil
}

func (a *App) saveStarred() error {
	a.starDirty = false
	path := filepath.Join(a.cfg.ExportDir, starManifest)
	if len(a.starred) == 0 {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	b, err := json.MarshalIndent(starManifestFile{Version: 1, Entries: a.starred}, "", " ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(a.cfg.ExportDir, fmt.Sprintf("%s%d.part", linkPrefix, time.Now().UnixNano()))
	if err := os.WriteFile(tmp, b, 0o666); err != nil {
		os.Remove(tmp)
		return err
	}
	a.own(tmp)
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// handleStarred takes the published ids that should be in the starred folder:
// {"ids":[...], "scope":[...]}. Ids in scope (every id the sender publishes) but
// not in ids lose their link; without scope, every id not in ids does. Ids the
// service didn't publish are ignored.
func (a *App) handleStarred(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs   []string  `json:"ids"`
		Scope *[]string `json:"scope"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad starred request: " + err.Error()})
		return
	}
	if a.cfg.StarredDir == "" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "disabled": true})
		return
	}
	want := cleanSet(req.IDs)
	var scope map[string]bool
	if req.Scope != nil {
		scope = cleanSet(*req.Scope)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	linked, unlinked, unknown, failed := 0, 0, 0, 0
	for _, id := range sortedKeys(a.starred) {
		_, published := a.store.st.Photos[id]
		if want[id] || (scope != nil && !scope[id] && published) {
			continue
		}
		if err := a.unstarLocked(id); err != nil {
			a.starFailure(id, fmt.Sprintf("removing it from %s: %v", a.cfg.StarredDir, err))
			failed++
		} else {
			unlinked++
		}
	}
	used := a.usedStarNames()
	for _, id := range sortedKeys(want) {
		if _, ok := a.store.st.Photos[id]; !ok {
			unknown++
			continue
		}
		changed, err := a.starLocked(id, used)
		switch {
		case err != nil:
			a.starFailure(id, fmt.Sprintf("adding it to %s: %v", a.cfg.StarredDir, err))
			failed++
		case changed:
			linked++
		}
	}
	if linked > 0 || unlinked > 0 {
		a.store.event("starred", "", "%d added to %s, %d removed", linked, a.cfg.StarredDir, unlinked)
	}
	if a.starDirty {
		if err := a.saveStarred(); err != nil {
			logf("ERROR", "saving %s: %v", starManifest, err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "starred": len(a.starred), "linked": linked, "unlinked": unlinked,
		"unknown": unknown, "failed": failed,
	})
}

// starFailure records a starred-folder problem as an event, but only when it is
// new for that id, so a resend every few minutes doesn't flood the history.
func (a *App) starFailure(id, msg string) {
	if a.starErr[id] == msg {
		return
	}
	a.starErr[id] = msg
	a.store.event("error", id, "%s", msg)
}

// starLocked makes sure the starred folder has this published JPEG, and reports
// whether anything changed. used holds the folder's names in use (see
// usedStarNames); it is updated. Callers hold a.mu.
func (a *App) starLocked(id string, used map[string]bool) (bool, error) {
	if a.cfg.StarredDir == "" {
		return false, nil
	}
	src := filepath.Join(a.cfg.ExportDir, filepath.FromSlash(id))
	srcInfo, err := os.Stat(src)
	if err != nil {
		return false, err
	}
	e := a.starred[id]
	if e != nil && !a.inStarredDir(e.Name) {
		a.unstarLocked(id)
		e = nil
	}
	if e != nil {
		dst := filepath.Join(a.cfg.ExportDir, filepath.FromSlash(e.Name))
		if fi, err := os.Lstat(dst); err == nil {
			if !a.ours(e, fi) {
				// Someone replaced it: leave their file, start over under a new name.
				delete(a.starred, id)
				a.starDirty = true
				e = nil
			} else if os.SameFile(fi, srcInfo) || (e.Copy && sameStamp(fi, srcInfo)) {
				delete(a.starErr, id)
				return false, nil
			}
		}
	}
	name := ""
	if e != nil {
		name = e.Name
	} else {
		name = a.starredName(id, used)
	}
	dst := filepath.Join(a.cfg.ExportDir, filepath.FromSlash(name))
	if err := a.mkdirs(filepath.Dir(dst)); err != nil {
		return false, err
	}
	tmp := filepath.Join(filepath.Dir(dst), fmt.Sprintf("%s%d.part", linkPrefix, time.Now().UnixNano()))
	isCopy := false
	if err := linkFile(src, tmp); err != nil {
		// No hard links here (another filesystem, or not allowed): copy instead.
		if err := copyFile(src, tmp); err != nil {
			os.Remove(tmp)
			return false, err
		}
		os.Chtimes(tmp, srcInfo.ModTime(), srcInfo.ModTime())
		a.own(tmp)
		isCopy = true
	}
	tmpInfo, err := os.Lstat(tmp)
	if err != nil {
		os.Remove(tmp)
		return false, err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp)
		return false, err
	}
	a.starred[id] = &starEntry{Name: name, Ino: inode(tmpInfo), Size: tmpInfo.Size(), MTime: tmpInfo.ModTime(), Copy: isCopy}
	used[starKey(name)] = true
	a.starDirty = true
	delete(a.starErr, id)
	return true, nil
}

// unstarLocked takes this id out of the starred folder. The file is removed only
// if it is still the one the service made. Callers hold a.mu.
func (a *App) unstarLocked(id string) error {
	e, ok := a.starred[id]
	if !ok {
		return nil
	}
	full := filepath.Join(a.cfg.ExportDir, filepath.FromSlash(e.Name))
	fi, err := os.Lstat(full)
	switch {
	case err == nil && a.ours(e, fi):
		if err := os.Remove(full); err != nil {
			return err
		}
	case err != nil && !errors.Is(err, os.ErrNotExist):
		return err
	}
	delete(a.starred, id)
	delete(a.starErr, id)
	a.starDirty = true
	return nil
}

// ours reports whether the file at a recorded name is still the one the service
// made: the same inode (a hard link keeps it even after the published JPEG is
// replaced), or for a copy, the same size and time.
func (a *App) ours(e *starEntry, fi os.FileInfo) bool {
	if !fi.Mode().IsRegular() {
		return false
	}
	if e.Ino != 0 && inode(fi) == e.Ino {
		return true
	}
	return e.Copy && fi.Size() == e.Size && fi.ModTime().Equal(e.MTime)
}

// usedStarNames is every name in the starred folder, recorded or on disk,
// compared without case or Unicode spelling (one file to a Mac).
func (a *App) usedStarNames() map[string]bool {
	used := map[string]bool{}
	for _, e := range a.starred {
		used[starKey(e.Name)] = true
	}
	entries, _ := os.ReadDir(filepath.Join(a.cfg.ExportDir, a.cfg.StarredDir))
	for _, en := range entries {
		used[starKey(path.Join(a.cfg.StarredDir, en.Name()))] = true
	}
	return used
}

func starKey(name string) string {
	return strings.ToLower(norm.NFC.String(name))
}

// starredName picks the file's name in the starred folder: the JPEG's own name,
// or, when that is taken, the name plus a short hash of the id.
func (a *App) starredName(id string, used map[string]bool) string {
	base := a.cfg.StarredDir
	file := path.Base(id)
	name := path.Join(base, file)
	if !used[starKey(name)] {
		return name
	}
	sum := sha1.Sum([]byte(id))
	ext := path.Ext(file)
	stem := strings.TrimSuffix(file, ext) + "-" + hex.EncodeToString(sum[:4])
	name = path.Join(base, stem+ext)
	for n := 2; used[starKey(name)]; n++ {
		name = path.Join(base, fmt.Sprintf("%s-%d%s", stem, n, ext))
	}
	return name
}

// inStarredDir reports whether a path relative to EXPORT_DIR lies in the starred
// folder, which published JPEGs must stay out of.
func (a *App) inStarredDir(rel string) bool {
	if a.cfg.StarredDir == "" {
		return false
	}
	return sameName(strings.SplitN(rel, "/", 2)[0], a.cfg.StarredDir)
}

// relinkStarred makes the starred folder follow a newly written JPEG. Callers
// hold a.mu.
func (a *App) relinkStarred(id string) {
	if _, err := a.starLocked(id, a.usedStarNames()); err != nil {
		a.starFailure(id, fmt.Sprintf("updating it in %s: %v", a.cfg.StarredDir, err))
	}
}

func (a *App) flushStarred() {
	if a.starDirty {
		if err := a.saveStarred(); err != nil {
			logf("ERROR", "saving %s: %v", starManifest, err)
		}
	}
}

func inode(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Ino)
	}
	return 0
}

func sameStamp(a, b os.FileInfo) bool {
	return a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}

func cleanSet(ids []string) map[string]bool {
	set := map[string]bool{}
	for _, id := range ids {
		if clean, err := cleanRel(id); err == nil {
			set[clean] = true
		}
	}
	return set
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
