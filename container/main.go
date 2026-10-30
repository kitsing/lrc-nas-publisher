// Command lrc-nas-publisher is the NAS half of "NAS Publisher": it receives the
// JPEGs that the Lightroom Classic plugin renders from edited RAW files and files
// them under EXPORT_DIR, mirroring the RAW's folder under SOURCE_DIR.
//
// Lightroom does the rendering (nothing else can render its edits faithfully), so
// while Lightroom is not running this service only waits. It also scans SOURCE_DIR
// for RAWs whose XMP sidecars carry Camera Raw edits, so that the plugin can add
// those photos to the catalog and publish them too; that scan runs only while
// Lightroom is online.
//
//	lrc-nas-publisher [serve]   run the HTTP service (the container default)
//	lrc-nas-publisher token     print the access token the plugin needs
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata" // TZ works even without the OS time zone database
)

const version = "1.2.0"

var logLocation = time.UTC
var logMu sync.Mutex
var logOut io.Writer = os.Stderr // tests read what's logged

func logf(level, format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()
	fmt.Fprintf(logOut, "%s %s %s\n", time.Now().In(logLocation).Format("2006-01-02 15:04:05"), level, fmt.Sprintf(format, args...))
}

type Config struct {
	SourceDir      string        // SOURCE_DIR: the RAW tree, read-only
	ExportDir      string        // EXPORT_DIR: where JPEGs go, mirroring SOURCE_DIR
	ConfigDir      string        // CONFIG_DIR: state.json and token
	Listen         string        // LISTEN
	Token          string        // TOKEN, else CONFIG_DIR/token (created on first start)
	ScanInterval   time.Duration // SCAN_INTERVAL_MINUTES: how stale the sidecar scan may get while Lightroom is online
	OnlineWindow   time.Duration // ONLINE_WINDOW_MINUTES: Lightroom counts as online this long after its last contact
	MaxUploadBytes int64         // MAX_UPLOAD_MB
	RequireSource  bool          // REQUIRE_SOURCE: refuse JPEGs whose RAW isn't under SOURCE_DIR
	Exclude        []string      // EXCLUDE: name patterns skipped by the sidecar scan
	StarredDir     string        // STARRED_DIR: folder in EXPORT_DIR for starred photos; "" when off
	OwnerUID       int           // PUID: owner for new files and folders (default: owner of EXPORT_DIR)
	OwnerGID       int           // PGID
	ImmichURL      string        // IMMICH_URL: ask this Immich to scan after JPEGs change; "" when off (see immich.go)
	ImmichAPIKey   string        // IMMICH_API_KEY
	ImmichLibrary  string        // IMMICH_LIBRARY_ID: the library to scan; "" for Immich's only one
}

func loadConfig() (Config, error) {
	cfg := Config{
		SourceDir:      envOr("SOURCE_DIR", "/source"),
		ExportDir:      envOr("EXPORT_DIR", "/export"),
		ConfigDir:      envOr("CONFIG_DIR", "/config"),
		Listen:         envOr("LISTEN", ":8765"),
		Token:          strings.TrimSpace(os.Getenv("TOKEN")),
		ImmichURL:      os.Getenv("IMMICH_URL"),
		ImmichAPIKey:   os.Getenv("IMMICH_API_KEY"),
		ImmichLibrary:  os.Getenv("IMMICH_LIBRARY_ID"),
		RequireSource:  true,
		StarredDir:     "starred",
		Exclude:        splitList(envOr("EXCLUDE", "@*,#recycle,#snapshot,.*,*.lrlibrary,*.lrdata,*.photoslibrary,*.lrcat-data")),
		OwnerUID:       -1,
		OwnerGID:       -1,
		ScanInterval:   10 * time.Minute,
		OnlineWindow:   3 * time.Minute,
		MaxUploadBytes: 1024 << 20,
	}
	var err error
	if cfg.ScanInterval, err = envMinutes("SCAN_INTERVAL_MINUTES", cfg.ScanInterval); err != nil {
		return cfg, err
	}
	if cfg.OnlineWindow, err = envMinutes("ONLINE_WINDOW_MINUTES", cfg.OnlineWindow); err != nil {
		return cfg, err
	}
	if v := os.Getenv("MAX_UPLOAD_MB"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			return cfg, fmt.Errorf("MAX_UPLOAD_MB=%q: want a positive number", v)
		}
		cfg.MaxUploadBytes = n << 20
	}
	if v := os.Getenv("REQUIRE_SOURCE"); v != "" {
		if cfg.RequireSource, err = strconv.ParseBool(v); err != nil {
			return cfg, fmt.Errorf("REQUIRE_SOURCE=%q: want true or false", v)
		}
	}
	if v, ok := os.LookupEnv("STARRED_DIR"); ok {
		v = strings.TrimSpace(v)
		switch {
		case v == "" || strings.EqualFold(v, "off") || strings.EqualFold(v, "none"):
			cfg.StarredDir = ""
		case strings.ContainsAny(v, "/\\") || strings.HasPrefix(v, ".") || v == "..":
			return cfg, fmt.Errorf("STARRED_DIR=%q: want a plain folder name", v)
		default:
			cfg.StarredDir = v
		}
	}
	for _, e := range []struct {
		name string
		dst  *int
	}{{"PUID", &cfg.OwnerUID}, {"PGID", &cfg.OwnerGID}} {
		if v := os.Getenv(e.name); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 0 {
				return cfg, fmt.Errorf("%s=%q: want a number", e.name, v)
			}
			*e.dst = n
		}
	}
	return cfg, nil
}

func envOr(name, def string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return def
}

func envMinutes(name string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil || n <= 0 {
		return def, fmt.Errorf("%s=%q: want a positive number of minutes", name, v)
	}
	return time.Duration(n * float64(time.Minute)), nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// loadToken returns TOKEN, else the token saved in CONFIG_DIR/token, creating
// one there on first start.
func loadToken(cfg Config) (string, error) {
	if cfg.Token != "" {
		return cfg.Token, nil
	}
	path := filepath.Join(cfg.ConfigDir, "token")
	if b, err := os.ReadFile(path); err == nil {
		if t := strings.TrimSpace(string(b)); t != "" {
			return t, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	t := hex.EncodeToString(buf)
	if err := os.WriteFile(path, []byte(t+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("saving a new token: %w", err)
	}
	if os.Geteuid() == 0 {
		// Readable by whoever owns the config folder (you, over SMB), not only root.
		if uid, gid := ownerOf(cfg.ConfigDir); uid >= 0 {
			os.Lchown(path, uid, gid)
		}
	}
	logf("INFO", "Created a new access token in %s; enter it in the Lightroom plugin's settings.", path)
	return t, nil
}

const usage = `lrc-nas-publisher [serve]   run the HTTP service (default)
lrc-nas-publisher token     print the access token the Lightroom plugin needs
`

func main() {
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	if tz := os.Getenv("TZ"); tz != "" {
		if loc, err := time.LoadLocation(tz); err == nil {
			logLocation = loc
		}
	}
	cfg, err := loadConfig()
	if err != nil {
		logf("ERROR", "%v", err)
		os.Exit(2)
	}
	switch command {
	case "serve":
	case "token":
		t, err := loadToken(cfg)
		if err != nil {
			logf("ERROR", "%v", err)
			os.Exit(1)
		}
		fmt.Println(t)
		return
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	app, err := newApp(cfg)
	if err != nil {
		logf("ERROR", "%v", err)
		os.Exit(1)
	}
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           app.routes(),
		ReadHeaderTimeout: 30 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		<-ctx.Done()
		// Let an upload or delete in progress finish (compose gives us a minute).
		shutdown, cancel := context.WithTimeout(context.Background(), 50*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
		app.immich.halt(6 * time.Second) // asks Immich for a scan still waiting
	}()
	logf("INFO", "lrc-nas-publisher %s listening on %s; RAWs in %s, JPEGs to %s", version, cfg.Listen, cfg.SourceDir, cfg.ExportDir)
	app.immich.start()
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logf("ERROR", "%v", err)
		os.Exit(1)
	}
	<-drained
	logf("INFO", "Stopped.")
}
