package main

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testImmichKey = "immich-key-Zx81"
	libExported   = "11111111-2222-4333-8444-555555555555"
	libOther      = "66666666-7777-4888-9999-aaaaaaaaaaaa"
)

var (
	exportedLib = immichLibrary{ID: libExported, Name: "exported_photos", ImportPaths: []string{"/mnt/exported_photos"}}
	otherLib    = immichLibrary{ID: libOther, Name: "phone", ImportPaths: []string{"/mnt/phone"}}
)

// fakeImmich answers the library endpoints like Immich v3.3.5 does.
type fakeImmich struct {
	t   *testing.T
	srv *httptest.Server

	mu          sync.Mutex
	libs        []immichLibrary
	codes       []int    // answers for the next library requests, in order; then 200/204
	location    string   // Location for a 3xx answer
	maintenance bool     // /api/server/config says maintenanceMode
	requests    []string // "METHOD path", every request
	scans       []string // library ids asked to scan, accepted
	badKeys     int      // requests without the right x-api-key
	hold        chan struct{}
	arrived     chan struct{}
}

func newFakeImmich(t *testing.T) *fakeImmich {
	f := &fakeImmich{t: t, libs: []immichLibrary{exportedLib}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeImmich) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests = append(f.requests, r.Method+" "+r.URL.Path)
	if r.Header.Get("x-api-key") != testImmichKey {
		f.badKeys++
	}
	if r.URL.Path == "/api/server/config" {
		maintenance := f.maintenance
		f.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"maintenanceMode": maintenance})
		return
	}
	code := 0
	if len(f.codes) > 0 {
		code, f.codes = f.codes[0], f.codes[1:]
	}
	libs := append([]immichLibrary(nil), f.libs...)
	hold, arrived, location := f.hold, f.arrived, f.location
	f.mu.Unlock()

	if code != 0 {
		if location != "" {
			w.Header().Set("Location", location)
		}
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(map[string]any{"message": "fake says no"})
		return
	}
	notFound := func() {
		w.WriteHeader(http.StatusBadRequest) // what v3.3.5 answers for an unknown library
		json.NewEncoder(w).Encode(map[string]any{"message": "Library not found"})
	}
	known := func(id string) (immichLibrary, bool) {
		for _, l := range libs {
			if l.ID == id {
				return l, true
			}
		}
		return immichLibrary{}, false
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/libraries":
		json.NewEncoder(w).Encode(libs)
	case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/api/libraries/"):
		if l, ok := known(strings.TrimPrefix(r.URL.Path, "/api/libraries/")); ok {
			json.NewEncoder(w).Encode(l)
		} else {
			notFound()
		}
	case r.Method == "POST" && strings.HasPrefix(r.URL.Path, "/api/libraries/") && strings.HasSuffix(r.URL.Path, "/scan"):
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/libraries/"), "/scan")
		if _, ok := known(id); !ok {
			notFound()
			return
		}
		if hold != nil {
			select {
			case arrived <- struct{}{}:
			default:
			}
			select {
			case <-hold:
			case <-r.Context().Done():
				return
			}
		}
		f.mu.Lock()
		f.scans = append(f.scans, id)
		f.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]any{"message": "Cannot " + r.Method + " " + r.URL.Path})
	}
}

func (f *fakeImmich) scanCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.scans)
}

func (f *fakeImmich) requestCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func (f *fakeImmich) answer(codes ...int) {
	f.mu.Lock()
	f.codes = append(f.codes, codes...)
	f.mu.Unlock()
}

// waitFor polls cond for up to 5 seconds.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

func (f *fakeImmich) waitScans(n int) {
	f.t.Helper()
	waitFor(f.t, "Immich scans", func() bool { return f.scanCount() >= n })
}

// captureLog sends the log to a buffer for the rest of the test; logged
// returns it.
func captureLog(t *testing.T) (logged func() string) {
	var buf bytes.Buffer
	logMu.Lock()
	prev := logOut
	logOut = &buf
	logMu.Unlock()
	t.Cleanup(func() {
		logMu.Lock()
		logOut = prev
		logMu.Unlock()
	})
	return func() string {
		logMu.Lock()
		defer logMu.Unlock()
		return buf.String()
	}
}

// newImmichEnv starts the service with Immich pointed at a fake, and waits for
// the scan asked for at start. At the end it checks that the API key showed up
// nowhere: not in the log, the status page, the activity list or state.json.
func newImmichEnv(t *testing.T, quiet, maxWait time.Duration, tweak func(*Config)) (*env, *fakeImmich) {
	t.Helper()
	logged := captureLog(t)
	f := newFakeImmich(t)
	e := newEnv(t, func(c *Config) {
		c.ImmichURL, c.ImmichAPIKey = f.srv.URL, testImmichKey
		if tweak != nil {
			tweak(c)
		}
	})
	m := e.app.immich
	if m == nil {
		t.Fatalf("Immich is off: %s", e.app.immichOff)
	}
	m.quiet, m.maxWait, m.fixWait, m.retries = quiet, maxWait, time.Hour, []time.Duration{100 * time.Millisecond}
	t.Cleanup(func() {
		page := e.statusPage()
		e.app.mu.Lock()
		e.app.store.save()
		events := e.app.store.st.Events
		e.app.mu.Unlock()
		state, _ := os.ReadFile(filepath.Join(e.config, "state.json"))
		for where, text := range map[string]string{"log": logged(), "status page": page, "state.json": string(state)} {
			if strings.Contains(text, testImmichKey) {
				t.Errorf("the API key is in the %s", where)
			}
		}
		for _, ev := range events {
			if strings.Contains(ev.Message, testImmichKey) {
				t.Errorf("the API key is in an event: %v", ev)
			}
		}
	})
	m.start()
	t.Cleanup(func() { m.halt(2 * time.Second) })
	f.waitScans(1)
	return e, f
}

// setTimes changes the loop's timing while it runs.
func setTimes(m *Immich, quiet, fixWait time.Duration) {
	m.mu.Lock()
	m.quiet, m.fixWait = quiet, fixWait
	m.mu.Unlock()
	m.nudge()
}

func (e *env) statusPage() string {
	e.t.Helper()
	resp, err := http.Get(e.srv.URL + "/")
	must(e.t, err)
	defer resp.Body.Close()
	var b bytes.Buffer
	b.ReadFrom(resp.Body)
	return b.String()
}

func (e *env) events(kind, id string) []Event {
	e.app.mu.Lock()
	defer e.app.mu.Unlock()
	var out []Event
	for _, ev := range e.app.store.st.Events {
		if ev.Kind == kind && ev.ID == id {
			out = append(out, ev)
		}
	}
	return out
}

func waitErr(t *testing.T, m *Immich, want string) string {
	t.Helper()
	var got string
	waitFor(t, "an error about "+want, func() bool { got = m.snapshot().Err; return strings.Contains(got, want) })
	return got
}

func TestImmichAsksForOneScanPerBatchOfChanges(t *testing.T) {
	e, f := newImmichEnv(t, 50*time.Millisecond, time.Minute, nil)
	m := e.app.immich
	setTimes(m, time.Hour, time.Hour) // however slow the uploads, they are one batch
	for _, n := range []string{"A", "B", "C"} {
		e.touch("a/"+n+".RAF", []byte("raw"), 0)
		if code, _ := e.upload(map[string]string{"rel": "a/" + n + ".RAF"}, jpeg, testToken); code != 200 {
			t.Fatalf("upload %s: %d", n, code)
		}
	}
	if f.scanCount() != 1 {
		t.Fatal("a scan was asked for before publishing paused")
	}
	setTimes(m, 50*time.Millisecond, time.Hour)
	f.waitScans(2)
	time.Sleep(300 * time.Millisecond)
	if n := f.scanCount() - 1; n != 1 {
		t.Fatalf("%d scans for one batch of 3 uploads; want 1", n)
	}
	f.mu.Lock()
	scans, requests, badKeys := f.scans, f.requests, f.badKeys
	f.mu.Unlock()
	if scans[1] != libExported || badKeys != 0 {
		t.Fatalf("scans %v, requests without the key: %d", scans, badKeys)
	}
	if requests[len(requests)-2] != "GET /api/libraries" {
		t.Fatalf("without IMMICH_LIBRARY_ID it should list the libraries first: %v", requests)
	}
	if page := e.statusPage(); !strings.Contains(page, "asked to scan &#34;exported_photos&#34;") {
		t.Fatalf("status page: %s", page)
	}
}

func TestImmichNotAskedWhenNothingChanged(t *testing.T) {
	e, f := newImmichEnv(t, 100*time.Millisecond, time.Minute, func(c *Config) { c.StarredDir = "starred" })
	e.touch("a/X.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "a/X.RAF", "uuid": "u1", "fingerprint": "f1"}, jpeg, testToken)
	f.waitScans(2)

	if _, out := e.post("/api/check", map[string]any{"items": []map[string]string{{"key": "k", "rel": "a/X.RAF", "uuid": "u1", "fingerprint": "f1"}}}); !out["results"].(map[string]any)["k"].(map[string]any)["current"].(bool) {
		t.Fatalf("check: %v", out)
	}
	e.post("/api/starred", map[string]any{"ids": []string{"a/X.jpg"}})
	if !e.exists("starred/X.jpg") {
		t.Fatal("no starred link")
	}
	e.upload(map[string]string{"rel": "a/X.RAF"}, jpeg, "wrong-token")
	e.upload(map[string]string{"rel": "a/NOPE.RAF"}, jpeg, testToken)
	e.upload(map[string]string{"rel": "a/X.RAF"}, []byte("not a jpeg"), testToken)
	e.post("/api/delete", map[string]any{"ids": []string{"a/never-published.jpg"}})
	if _, out := e.post("/api/delete", map[string]any{"ids": []string{"a/X.jpg"}, "onlyIfSourceGone": true}); out["results"].(map[string]any)["a/X.jpg"] != "kept" {
		t.Fatalf("delete onlyIfSourceGone: %v", out)
	}
	time.Sleep(500 * time.Millisecond)
	if n := f.scanCount(); n != 2 {
		t.Fatalf("%d scans after requests that changed no JPEG; want none", n-2)
	}

	if _, out := e.post("/api/delete", map[string]any{"ids": []string{"a/X.jpg"}}); out["results"].(map[string]any)["a/X.jpg"] != "deleted" {
		t.Fatalf("delete: %v", out)
	}
	f.waitScans(3)
}

func TestImmichMaxWaitDuringSteadyChanges(t *testing.T) {
	e, f := newImmichEnv(t, 200*time.Millisecond, 400*time.Millisecond, nil)
	end := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(end) {
		e.app.immich.changed()
		time.Sleep(50 * time.Millisecond)
	}
	if n := f.scanCount() - 1; n < 2 {
		t.Fatalf("%d scans during 1.5 s of steady changes with a 400 ms limit; want at least 2", n)
	}
}

func TestImmichAsksAgainForAChangeDuringAScan(t *testing.T) {
	e, f := newImmichEnv(t, 100*time.Millisecond, time.Minute, nil)
	hold, arrived := make(chan struct{}), make(chan struct{}, 1)
	var once sync.Once
	release := func() { once.Do(func() { close(hold) }) }
	t.Cleanup(release) // runs before halt and the fake's Close, even if the test fails
	f.mu.Lock()
	f.hold, f.arrived = hold, arrived
	f.mu.Unlock()
	e.touch("a/A.RAF", []byte("raw"), 0)
	e.touch("a/B.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "a/A.RAF"}, jpeg, testToken)
	select {
	case <-arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("no scan request")
	}
	// Immich may already have looked at the folder: B needs another scan.
	e.upload(map[string]string{"rel": "a/B.RAF"}, jpeg, testToken)
	f.mu.Lock()
	f.hold = nil
	f.mu.Unlock()
	release()
	f.waitScans(3)
}

func TestImmichRetriesWhileImmichIsDown(t *testing.T) {
	e, f := newImmichEnv(t, 50*time.Millisecond, time.Minute, nil)
	f.answer(http.StatusServiceUnavailable, http.StatusBadGateway)
	e.touch("a/A.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "a/A.RAF"}, jpeg, testToken)
	f.waitScans(2)
	if got := len(e.events("error", "Immich")); got != 2 {
		t.Fatalf("%d error events for two different failures; want 2", got)
	}
	waitFor(t, "the error to clear", func() bool { return e.app.immich.snapshot().Err == "" })
	if page := e.statusPage(); !strings.Contains(page, "<dt>Immich</dt><dd>asked to scan") {
		t.Fatalf("status page after recovery: %s", page)
	}
}

// The retry schedule, with the real delays: 1, 5 and 30 minutes, then every 30
// minutes, and back to the start after a success.
func TestImmichRetrySchedule(t *testing.T) {
	logged := captureLog(t)
	f := newFakeImmich(t)
	m, err := newImmich(f.srv.URL, testImmichKey, "", nil)
	must(t, err)
	try := func() time.Duration {
		t.Helper()
		m.attempt(context.Background(), true)
		m.mu.Lock()
		defer m.mu.Unlock()
		due, pending := m.dueLocked()
		if !pending {
			t.Fatal("the changes were dropped")
		}
		return time.Until(due).Round(time.Minute)
	}
	for round := 0; round < 2; round++ {
		m.changed()
		f.answer(503, 503, 503, 503)
		for i, want := range []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 30 * time.Minute} {
			if got := try(); got != want {
				t.Fatalf("round %d, failure %d: next try in %v; want %v", round, i+1, got, want)
			}
		}
		m.changed() // a new change doesn't hurry a retry while Immich is down
		m.mu.Lock()
		due, _ := m.dueLocked()
		m.mu.Unlock()
		if time.Until(due) < 29*time.Minute {
			t.Fatalf("a new change moved the retry up to %v", time.Until(due))
		}
		m.attempt(context.Background(), true)
		if s := m.snapshot(); s.Err != "" || !s.Due.IsZero() || m.failures != 0 {
			t.Fatalf("after a success: %+v, %d failures", s, m.failures)
		}
	}
	if n := strings.Count(logged(), "503"); n != 8 {
		t.Fatalf("logged %d of 8 failures", n)
	}
}

func TestImmichFixableErrorsWaitForAChangeOrAFix(t *testing.T) {
	e, f := newImmichEnv(t, 50*time.Millisecond, time.Minute, nil)
	m := e.app.immich
	f.answer(http.StatusUnauthorized)
	e.touch("a/A.RAF", []byte("raw"), 0)
	e.touch("a/B.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "a/A.RAF"}, jpeg, testToken)
	waitErr(t, m, "doesn't accept the API key")
	before := f.requestCount()
	time.Sleep(500 * time.Millisecond) // several retry delays
	if f.requestCount() != before {
		t.Fatal("a wrong key was retried before the next change or fixWait")
	}
	if page := e.statusPage(); !strings.Contains(page, "doesn&#39;t accept the API key") || !strings.Contains(page, "next scan in") {
		t.Fatalf("status page: %s", page)
	}
	if got := e.events("error", "Immich"); len(got) != 1 || !strings.Contains(got[0].Message, "IMMICH_API_KEY") {
		t.Fatalf("events: %v", got)
	}

	// A new change tries again soon. Then the key's permissions are fixed in
	// Immich: that is picked up after fixWait, with no new change.
	setTimes(m, 50*time.Millisecond, 300*time.Millisecond)
	f.answer(http.StatusForbidden)
	e.upload(map[string]string{"rel": "a/B.RAF"}, jpeg, testToken)
	waitErr(t, m, "library.read and library.update")
	f.waitScans(2)
	waitFor(t, "the error to clear", func() bool { return m.snapshot().Err == "" })
}

func TestImmichErrorsSayWhatToFix(t *testing.T) {
	for _, c := range []struct {
		code int
		want string
	}{
		{http.StatusForbidden, "library.read and library.update"},
		{http.StatusNotFound, "is IMMICH_URL Immich's address"},
		{http.StatusTeapot, "answered 418 (fake says no)"},
	} {
		e, f := newImmichEnv(t, 20*time.Millisecond, time.Minute, nil)
		f.answer(c.code)
		e.app.immich.changed()
		waitErr(t, e.app.immich, c.want)
		before := f.requestCount()
		time.Sleep(300 * time.Millisecond)
		if f.requestCount() != before {
			t.Errorf("%d: retried without a change", c.code)
		}
	}
}

func TestImmichRedirectIsReportedNotFollowed(t *testing.T) {
	e, f := newImmichEnv(t, 20*time.Millisecond, time.Minute, nil)
	m := e.app.immich
	for i, nonce := range []string{"a1", "b2"} {
		f.mu.Lock()
		f.location = "https://team.cloudflareaccess.com/cdn-cgi/access/login/immich?kid=1&meta=" + nonce + strings.Repeat("x", 5000)
		f.mu.Unlock()
		f.answer(http.StatusFound)
		m.changed()
		waitFor(t, "the request", func() bool { return f.requestCount() >= 3+i })
		got := waitErr(t, m, "a redirect to https://team.cloudflareaccess.com: set IMMICH_URL")
		if len(got) > 400 {
			t.Fatalf("the whole Location went into the message: %d bytes", len(got))
		}
	}
	if n := len(e.events("error", "Immich")); n != 1 {
		t.Fatalf("%d events for the same redirect; want 1", n)
	}
	time.Sleep(300 * time.Millisecond) // past the retry delay: a redirect isn't retried
	if f.requestCount() != 4 {         // the scan at start, then one GET per change
		t.Fatalf("requests: %v", f.requests)
	}
}

func TestImmichMaintenanceModeIsRetried(t *testing.T) {
	e, f := newImmichEnv(t, 20*time.Millisecond, time.Minute, nil)
	f.mu.Lock()
	f.maintenance = true
	f.mu.Unlock()
	f.answer(http.StatusNotFound)
	e.app.immich.changed()
	waitErr(t, e.app.immich, "maintenance mode")
	f.mu.Lock()
	f.maintenance = false
	f.mu.Unlock()
	f.waitScans(2) // the 100 ms retry
}

func TestImmichCanNotConnect(t *testing.T) {
	logged := captureLog(t)
	f := newFakeImmich(t)
	addr := f.srv.URL
	f.srv.Close()
	m, err := newImmich(addr, testImmichKey, "", nil)
	must(t, err)
	m.changed()
	m.attempt(context.Background(), true)
	s := m.snapshot()
	if !strings.Contains(s.Err, "can't reach Immich at "+addr) || s.Due.IsZero() || m.failures != 1 {
		t.Fatalf("after a refused connection: %+v, %d failures", s, m.failures)
	}
	if strings.Contains(logged(), testImmichKey) {
		t.Fatal("the key is in the log")
	}

	// The causes that waiting won't fix get their own advice.
	notFound := func(name string) error {
		return &url.Error{Op: "Get", URL: "x", Err: &net.OpError{Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: name, IsNotFound: true}}}
	}
	for _, c := range []struct {
		base string
		err  error
		want string
	}{
		{"http://host.docker.internal:2283", notFound("host.docker.internal"), "add extra_hosts"},
		{"http://Host.Docker.Internal:2283", notFound("Host.Docker.Internal"), "add extra_hosts"},
		{"http://macmini.local:2283", notFound("macmini.local"), "use Immich's IP address"},
		{"http://nas.lan:2283", notFound("nas.lan"), "can't find nas.lan"},
		{"https://nas.lan:5001", &url.Error{Op: "Get", URL: "x", Err: x509.UnknownAuthorityError{}}, "plain http"},
		{"https://nas.lan:2283", &url.Error{Op: "Get", URL: "x", Err: errors.New("http: server gave HTTP response to HTTPS client")}, "use http://"},
	} {
		m.base = c.base
		if err := m.connErr(c.err); !errors.As(err, new(immichFixable)) || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v; want a fixable error saying %q", c.base, err, c.want)
		}
	}

	// A connection Immich drops (say while it restarts) is worth waiting for, and
	// reads the same every time though the local port differs.
	m.base = "http://nas.lan:2283"
	reset := func(port int) error {
		return &url.Error{Op: "Get", URL: "x", Err: &net.OpError{Op: "read", Net: "tcp",
			Source: &net.TCPAddr{IP: net.IPv4(172, 20, 0, 2), Port: port}, Addr: &net.TCPAddr{IP: net.IPv4(172, 17, 0, 1), Port: 2283},
			Err: errors.New("connection reset by peer")}}
	}
	a, b := m.connErr(reset(41234)), m.connErr(reset(50000))
	if errors.As(a, new(immichFixable)) || a.Error() != b.Error() || !strings.Contains(a.Error(), "closed the connection") {
		t.Errorf("connection reset: %v / %v", a, b)
	}
}

func TestImmichLibraries(t *testing.T) {
	// One library: it's the one.
	e, f := newImmichEnv(t, 20*time.Millisecond, time.Minute, nil)
	waitFor(t, "the status", func() bool { return e.app.immich.snapshot().Libraries == `"exported_photos" (/mnt/exported_photos)` })

	// Several: scanning them all could crawl a large unrelated one every few
	// minutes, so it asks which.
	f.mu.Lock()
	f.libs = []immichLibrary{exportedLib, otherLib}
	f.mu.Unlock()
	e.app.immich.changed()
	got := waitErr(t, e.app.immich, "Set IMMICH_LIBRARY_ID")
	if !strings.Contains(got, `"phone" (/mnt/phone), id `+libOther) || f.scanCount() != 1 {
		t.Fatalf("%q, %d scans", got, f.scanCount())
	}

	// None.
	f.mu.Lock()
	f.libs = nil
	f.mu.Unlock()
	e.app.immich.changed()
	waitErr(t, e.app.immich, "no external libraries")

	// IMMICH_LIBRARY_ID picks one; the URL may end in /api/.
	f2 := newFakeImmich(t)
	f2.libs = []immichLibrary{exportedLib, otherLib}
	e2 := newEnv(t, func(c *Config) {
		c.ImmichURL, c.ImmichAPIKey, c.ImmichLibrary = f2.srv.URL+"/api/", testImmichKey, libOther
	})
	e2.app.immich.quiet = 20 * time.Millisecond
	e2.app.immich.start()
	t.Cleanup(func() { e2.app.immich.halt(2 * time.Second) })
	f2.waitScans(1)
	f2.mu.Lock()
	if len(f2.scans) != 1 || f2.scans[0] != libOther || f2.requests[0] != "GET /api/libraries/"+libOther {
		t.Fatalf("with IMMICH_LIBRARY_ID: requests %v, scans %v", f2.requests, f2.scans)
	}
	f2.mu.Unlock()

	// An id Immich doesn't have: it answers 400.
	f3 := newFakeImmich(t)
	m, err := newImmich(f3.srv.URL, testImmichKey, "99999999-8888-4777-8666-555555555555", nil)
	must(t, err)
	m.changed()
	m.attempt(context.Background(), true)
	if s := m.snapshot(); !strings.Contains(s.Err, "answered 400 (Library not found): is IMMICH_LIBRARY_ID the id") || m.failures != 0 || time.Until(s.Due) < 29*time.Minute {
		t.Fatalf("unknown library: %+v, %d failures; want a fixable error, tried again in 30 min", s, m.failures)
	}
}

func TestImmichHaltAsksForTheScanStillWaiting(t *testing.T) {
	e, f := newImmichEnv(t, 50*time.Millisecond, time.Minute, nil)
	m := e.app.immich
	setTimes(m, time.Hour, time.Hour)
	m.changed()
	m.halt(2 * time.Second)
	if n := f.scanCount(); n != 2 {
		t.Fatalf("%d scans after halt; want the waiting one asked for", n-1)
	}
	m.halt(time.Second) // a second halt is harmless
}

func TestImmichHaltWithNothingWaitingAsksForNothing(t *testing.T) {
	e, f := newImmichEnv(t, 20*time.Millisecond, time.Minute, nil)
	before := f.requestCount()
	e.app.immich.halt(2 * time.Second)
	if f.requestCount() != before {
		t.Fatal("halt asked for a scan with nothing waiting")
	}
}

// hungImmich accepts connections and never answers.
func hungImmich(t *testing.T) (addr string, accepted chan struct{}) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	must(t, err)
	accepted = make(chan struct{}, 10)
	var mu sync.Mutex
	var conns []net.Conn
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, c)
			mu.Unlock()
			accepted <- struct{}{}
		}
	}()
	t.Cleanup(func() {
		l.Close()
		mu.Lock()
		for _, c := range conns {
			c.Close()
		}
		mu.Unlock()
	})
	return "http://" + l.Addr().String(), accepted
}

// A hung Immich must not hold up the container's stop.
func TestImmichHaltGivesUpOnAHungImmich(t *testing.T) {
	captureLog(t)
	t.Run("an attempt under way", func(t *testing.T) {
		addr, accepted := hungImmich(t)
		m, err := newImmich(addr, testImmichKey, "", nil)
		must(t, err)
		m.quiet = 0
		m.start()
		<-accepted
		start := time.Now()
		m.halt(300 * time.Millisecond)
		if took := time.Since(start); took > time.Second {
			t.Fatalf("halt took %v; want its 300 ms limit", took)
		}
	})
	t.Run("the scan on the way out", func(t *testing.T) {
		addr, accepted := hungImmich(t)
		m, err := newImmich(addr, testImmichKey, "", nil)
		must(t, err)
		m.quiet, m.finalWait = time.Hour, 200*time.Millisecond
		m.start()
		m.halt(5 * time.Second)
		select {
		case <-accepted:
		default:
			t.Fatal("no scan asked for on the way out")
		}
		select {
		case <-m.done:
		default:
			t.Fatal("the last attempt outlived finalWait")
		}
	})
}

// Which errors are worth waiting for (tried again on the 1/5/30-minute
// schedule) and which need a fix (tried again at the next change, or after
// fixWait).
func TestImmichErrorKinds(t *testing.T) {
	captureLog(t)
	f := newFakeImmich(t)
	for _, c := range []struct {
		code        int
		maintenance bool
		transient   bool
	}{
		{http.StatusFound, false, false},
		{http.StatusOK, false, false}, // not what Immich answers
		{http.StatusBadRequest, false, false},
		{http.StatusUnauthorized, false, false},
		{http.StatusForbidden, false, false},
		{http.StatusNotFound, false, false},
		{http.StatusNotFound, true, true},
		{http.StatusRequestTimeout, false, true},
		{http.StatusTeapot, false, false},
		{http.StatusTooManyRequests, false, true},
		{http.StatusInternalServerError, false, true},
		{http.StatusServiceUnavailable, false, true},
	} {
		m, err := newImmich(f.srv.URL, testImmichKey, "", nil)
		must(t, err)
		f.mu.Lock()
		f.maintenance = c.maintenance
		f.mu.Unlock()
		f.answer(c.code)
		m.changed()
		m.attempt(context.Background(), true)
		s := m.snapshot()
		wait := time.Until(s.Due).Round(time.Minute)
		if s.Err == "" || (c.transient && (m.failures != 1 || wait != time.Minute)) || (!c.transient && (m.failures != 0 || wait != 30*time.Minute)) {
			t.Errorf("%d (maintenance %v): %q, %d failures, next try in %v; want transient=%v", c.code, c.maintenance, s.Err, m.failures, wait, c.transient)
		}
	}
	f.mu.Lock()
	f.maintenance = false
	f.mu.Unlock()
	for _, libs := range [][]immichLibrary{nil, {exportedLib, otherLib}} {
		f.mu.Lock()
		f.libs = libs
		f.mu.Unlock()
		m, err := newImmich(f.srv.URL, testImmichKey, "", nil)
		must(t, err)
		m.changed()
		m.attempt(context.Background(), true)
		if s := m.snapshot(); s.Err == "" || m.failures != 0 || time.Until(s.Due) < 29*time.Minute {
			t.Errorf("%d libraries: %+v, %d failures; want a fixable error", len(libs), s, m.failures)
		}
	}
}

func TestImmichSettings(t *testing.T) {
	good := []struct{ url, want string }{
		{"http://host.docker.internal:2283", "http://host.docker.internal:2283"},
		{" http://10.0.0.86:2283/ ", "http://10.0.0.86:2283"},
		{"http://nas:2283/api/", "http://nas:2283"},
		{"http://[fd00::86]:2283", "http://[fd00::86]:2283"},
		{"https://photos.example.com/immich", "https://photos.example.com/immich"},
	}
	for _, g := range good {
		m, err := newImmich(g.url, testImmichKey, "", nil)
		if err != nil || m == nil || m.base != g.want {
			t.Errorf("IMMICH_URL=%q: %v, %v; want base %q", g.url, m, err, g.want)
		}
	}
	if m, err := newImmich("", "", "", nil); m != nil || err != nil {
		t.Errorf("unset: %v, %v", m, err)
	}
	if _, err := newImmich("http://nas:2283", testImmichKey, " "+libExported+" ", nil); err != nil {
		t.Errorf("library id: %v", err)
	}
	// Errors never repeat the settings: a misplaced key would be on the status page.
	bad := []struct{ url, key, lib, want, secret string }{
		{"nas:2283", testImmichKey, "", "IMMICH_URL isn't a web address", ""},
		{"ftp://nas", testImmichKey, "", "IMMICH_URL isn't a web address", ""},
		{testImmichKey, testImmichKey, "", "IMMICH_URL isn't a web address", testImmichKey},
		{"http://", testImmichKey, "", "IMMICH_URL isn't a web address", ""},
		{"http://me:pw-Q93@nas:2283", testImmichKey, "", "user name, password", "pw-Q93"},
		{"http://nas:2283/?apiKey=K-7731", testImmichKey, "", "?query", "K-7731"},
		{"http://nas:2283", "", "", "IMMICH_API_KEY is empty", ""},
		{"http://nas:2283", "two words-Q5", "", "IMMICH_API_KEY has spaces", "words-Q5"},
		{"", testImmichKey, "", "IMMICH_URL isn't", testImmichKey},
		{"", "", libExported, "IMMICH_URL isn't", ""},
		{"http://nas:2283", testImmichKey, testImmichKey, "IMMICH_LIBRARY_ID isn't a library id", testImmichKey},
	}
	for _, b := range bad {
		_, err := newImmich(b.url, b.key, b.lib, nil)
		if err == nil || !strings.Contains(err.Error(), b.want) {
			t.Errorf("%q %q %q: %v; want an error about %s", b.url, b.key, b.lib, err, b.want)
		} else if b.secret != "" && strings.Contains(err.Error(), b.secret) {
			t.Errorf("the error repeats a setting: %v", err)
		}
	}
}

func TestWrongImmichSettingDoesNotStopPublishing(t *testing.T) {
	e := newEnv(t, func(c *Config) { c.ImmichURL = "http://nas:2283" })
	if e.app.immich != nil {
		t.Fatal("Immich on without a key")
	}
	e.app.immich.start() // nil: does nothing
	e.touch("a/X.RAF", []byte("raw"), 0)
	if code, _ := e.upload(map[string]string{"rel": "a/X.RAF"}, jpeg, testToken); code != 200 {
		t.Fatalf("upload: %d", code)
	}
	if page := e.statusPage(); !strings.Contains(page, "off: IMMICH_URL is set but IMMICH_API_KEY is empty") {
		t.Fatalf("status page: %s", page)
	}
	e.app.immich.halt(time.Second)
}
