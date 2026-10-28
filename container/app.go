package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type App struct {
	cfg      Config
	token    string
	uid, gid int // owner for new files and folders; -1 leaves it alone
	scanner  *Scanner

	mu        sync.Mutex // guards store, online and the starred records
	store     *Store
	starred   map[string]*starEntry // see starred.go
	starErr   map[string]string     // last starred-folder error per id, to log each only once
	starDirty bool
	online    struct {
		at      time.Time
		from    string // client address
		host    string // Mac's name, as the plugin reports it
		version string // plugin version
		catalog string
	}
}

func newApp(cfg Config) (*App, error) {
	for _, d := range []struct{ name, dir string }{{"SOURCE_DIR", cfg.SourceDir}, {"EXPORT_DIR", cfg.ExportDir}} {
		fi, err := os.Stat(d.dir)
		if err != nil || !fi.IsDir() {
			return nil, fmt.Errorf("%s %s is not a folder; check the volumes in compose.yaml", d.name, d.dir)
		}
	}
	probe, err := os.CreateTemp(cfg.ExportDir, ".lrc-write-test-*")
	if err != nil {
		return nil, fmt.Errorf("can't write to EXPORT_DIR %s: %v", cfg.ExportDir, err)
	}
	probe.Close()
	os.Remove(probe.Name())
	// Uploads cut off by a restart leave .part files behind.
	if n := removeParts(cfg.ExportDir); n > 0 {
		logf("INFO", "Removed %d unfinished uploads.", n)
	}
	if err := os.MkdirAll(cfg.ConfigDir, 0o755); err != nil {
		return nil, err
	}
	token, err := loadToken(cfg)
	if err != nil {
		return nil, err
	}
	store, err := openStore(filepath.Join(cfg.ConfigDir, "state.json"))
	if err != nil {
		return nil, err
	}
	a := &App{cfg: cfg, token: token, store: store, uid: -1, gid: -1,
		scanner: newScanner(cfg.SourceDir, cfg.Exclude)}
	// Files written by root in a Synology home folder would belong to root; give
	// them to whoever owns EXPORT_DIR (or PUID/PGID) so they behave like the
	// user's own files over SMB. Same for state.json and the config folder's owner.
	if os.Geteuid() == 0 {
		a.uid, a.gid = ownerOf(cfg.ExportDir)
		if cfg.OwnerUID >= 0 {
			a.uid = cfg.OwnerUID
		}
		if cfg.OwnerGID >= 0 {
			a.gid = cfg.OwnerGID
		}
		store.uid, store.gid = ownerOf(cfg.ConfigDir)
	}
	if err := store.ensureServerID(); err != nil {
		return nil, fmt.Errorf("saving state: %v", err)
	}
	if err := a.loadStarred(); err != nil {
		return nil, err
	}
	return a, nil
}

// removeParts deletes leftover temporary upload files anywhere in EXPORT_DIR.
func removeParts(root string) int {
	n := 0
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() && (strings.HasPrefix(d.Name(), partPrefix) || strings.HasPrefix(d.Name(), linkPrefix)) && strings.HasSuffix(d.Name(), ".part") {
			if os.Remove(p) == nil {
				n++
			}
		}
		return nil
	})
	return n
}

// ownerOf returns a folder's owner, or -1, -1 when it's root's or unknown.
func ownerOf(dir string) (int, int) {
	var st syscall.Stat_t
	if err := syscall.Stat(dir, &st); err == nil && st.Uid != 0 {
		return int(st.Uid), int(st.Gid)
	}
	return -1, -1
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": version})
	})
	mux.HandleFunc("GET /{$}", a.handleStatus)
	mux.HandleFunc("POST /api/hello", a.auth(a.handleHello))
	mux.HandleFunc("POST /api/photos", a.auth(a.handleUpload))
	mux.HandleFunc("POST /api/check", a.auth(a.handleCheck))
	mux.HandleFunc("POST /api/delete", a.auth(a.handleDelete))
	mux.HandleFunc("POST /api/starred", a.auth(a.handleStarred))
	mux.HandleFunc("GET /api/sidecars", a.auth(a.handleSidecars))
	return mux
}

// auth accepts "Authorization: Bearer <token>" (or "X-Token: <token>") and
// records the call as a sign of life from Lightroom.
func (a *App) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		if got == "" {
			got = strings.TrimSpace(r.Header.Get("X-Token"))
		}
		if subtle.ConstantTimeCompare([]byte(got), []byte(a.token)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "wrong or missing access token; copy it from the token file in the container's config folder"})
			return
		}
		now, from := time.Now(), clientAddr(r)
		a.mu.Lock()
		if !a.isOnline(now) {
			logf("INFO", "Lightroom is online (from %s).", from)
		}
		a.online.at, a.online.from = now, from
		a.mu.Unlock()
		next(w, r)
	}
}

func clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (a *App) isOnline(now time.Time) bool {
	return !a.online.at.IsZero() && now.Sub(a.online.at) < a.cfg.OnlineWindow
}

type helloRequest struct {
	Client   string `json:"client"`
	Version  string `json:"version"`
	Host     string `json:"host"`
	Catalog  string `json:"catalog"`
	Sidecars bool   `json:"sidecars"` // the plugin will ask for /api/sidecars
}

// handleHello is the plugin's heartbeat. When the plugin imports sidecar edits,
// it also starts a sidecar scan in the background if the last one is stale, so
// the answer is ready when asked.
func (a *App) handleHello(w http.ResponseWriter, r *http.Request) {
	var req helloRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad hello: " + err.Error()})
		return
	}
	a.mu.Lock()
	if a.online.host != req.Host || a.online.version != req.Version {
		logf("INFO", "Lightroom on %s, plugin %s, catalog %s", req.Host, req.Version, req.Catalog)
	}
	a.online.host, a.online.version, a.online.catalog = req.Host, req.Version, req.Catalog
	published, serverID := len(a.store.st.Photos), a.store.st.ServerID
	a.mu.Unlock()
	if req.Sidecars {
		a.scanner.kickIfStale(a.cfg.ScanInterval)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "server": "lrc-nas-publisher", "version": version, "serverId": serverID,
		"published": published, "sourceDir": a.cfg.SourceDir, "exportDir": a.cfg.ExportDir,
		"features": features,
	})
}

// features tells the plugin what this container understands, so a newer plugin
// can hold back requests an older container would misread. deleteIfSourceGone:
// /api/delete honours onlyIfSourceGone.
var features = []string{"deleteIfSourceGone"}

// handleSidecars lists RAWs whose XMP sidecar has Camera Raw settings. It waits
// up to a minute for a scan that is under way; the plugin asks again later if
// the answer says scanning.
func (a *App) handleSidecars(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Minute)
	defer cancel()
	snap := a.scanner.get(ctx, a.cfg.ScanInterval)
	resp := map[string]any{
		"ok": true, "scanning": snap.Running, "items": snap.Items, "raws": snap.Raws,
	}
	if !snap.At.IsZero() {
		resp["scannedAt"] = snap.At
	}
	if snap.Err != "" {
		resp["error"] = snap.Err
	}
	writeJSON(w, http.StatusOK, resp)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// fail logs the problem as an event (shown on the status page) and answers
// with it.
func (a *App) fail(w http.ResponseWriter, code int, id, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	a.mu.Lock()
	a.store.event("error", id, "%s", msg)
	a.mu.Unlock()
	writeJSON(w, code, map[string]any{"ok": false, "error": msg})
}
