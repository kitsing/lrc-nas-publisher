package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Immich (optional: IMMICH_URL and IMMICH_API_KEY) can index EXPORT_DIR as an
// external library, but on its own it looks for new and changed files only once
// a night. So after JPEGs are written or removed, the service asks Immich to scan
// that library. Immich then imports new JPEGs, re-reads replaced ones and moves
// removed ones to its trash.
//
// Changes are batched: the scan is asked for once publishing has paused for
// immichQuiet, and at least every immichMaxWait during a long publish. Scanning
// a library of a few thousand JPEGs takes Immich seconds, so an extra scan costs
// little, while a missed one leaves Immich a day behind. Hence the scan asked
// for at start (it covers a change made just before a restart), the retries,
// and the one asked for on the way out. Other libraries can be large, so only
// one library is ever scanned: IMMICH_LIBRARY_ID, or else Immich's only one.
// An Immich setting or outage never stops publishing.

const (
	immichQuiet   = 30 * time.Second
	immichMaxWait = 3 * time.Minute
)

// Waits after failed attempts that may pass (no connection, 5xx); the last one
// repeats until Immich answers.
var immichRetries = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute}

// The wait after an error that needs a fix on Immich's side (a key's
// permissions, a missing library), unless a new change comes first.
const immichFixWait = 30 * time.Minute

var uuidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type Immich struct {
	base    string // IMMICH_URL without a trailing / or /api
	key     string
	library string // IMMICH_LIBRARY_ID; "" for Immich's only library
	client  *http.Client
	onError func(msg string) // logs a new error and shows it on the status page; called without mu held

	quiet, maxWait, fixWait, finalWait time.Duration // tests shorten these
	retries                            []time.Duration

	mu       sync.Mutex
	changes  int       // changes no accepted scan request covers yet
	first    time.Time // the first of them (or the last failed attempt)
	last     time.Time // the latest of them
	retryAt  time.Time // after a failure: not before this
	failures int       // failed attempts in a row that may pass by themselves
	status   immichStatus
	wake     chan struct{} // the loop rereads the schedule
	stop     chan struct{}
	done     chan struct{}
}

// immichStatus is what the status page shows. It never holds the API key.
type immichStatus struct {
	URL       string
	Libraries string    // the library Immich last agreed to scan, and its folders
	Asked     time.Time // when it last agreed
	Tried     time.Time // the last failed attempt
	Err       string    // why it failed; "" once an attempt works
	Due       time.Time // the next attempt; zero when nothing is waiting
}

// immichFixable marks an error that waiting won't fix (a wrong key, address or
// library, a missing permission): it is tried again at the next change, or
// after fixWait for a fix made in Immich.
type immichFixable struct{ error }

func fixablef(format string, args ...any) error {
	return immichFixable{fmt.Errorf(format, args...)}
}

// newImmich checks the Immich settings. It returns nil, nil when they are unset.
// Errors never quote the settings: a misplaced key would end up on the status
// page, which needs no token.
func newImmich(rawURL, key, library string, onError func(string)) (*Immich, error) {
	rawURL, key, library = strings.TrimSpace(rawURL), strings.TrimSpace(key), strings.TrimSpace(library)
	if rawURL == "" {
		if key != "" || library != "" {
			return nil, errors.New("IMMICH_API_KEY or IMMICH_LIBRARY_ID is set but IMMICH_URL isn't")
		}
		return nil, nil
	}
	u, err := url.Parse(rawURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, errors.New("IMMICH_URL isn't a web address like http://host.docker.internal:2283")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("IMMICH_URL has a user name, password, ?query or #fragment in it; give only Immich's address, like http://host.docker.internal:2283, and the key as IMMICH_API_KEY")
	}
	base := strings.TrimSuffix(strings.TrimRight(u.Scheme+"://"+u.Host+u.EscapedPath(), "/"), "/api")
	if key == "" {
		return nil, errors.New("IMMICH_URL is set but IMMICH_API_KEY is empty: create a key in Immich under Account Settings → API Keys")
	}
	if strings.ContainsFunc(key, func(r rune) bool { return r <= ' ' || r == 0x7f }) {
		return nil, errors.New("IMMICH_API_KEY has spaces or control characters in it; paste the key again")
	}
	if library != "" && !uuidRE.MatchString(library) {
		return nil, errors.New("IMMICH_LIBRARY_ID isn't a library id (like 0f5a1d6e-…); leave it unset if Immich has only one library")
	}
	if onError == nil {
		onError = func(msg string) { logf("WARNING", "Immich: %s", msg) }
	}
	return &Immich{
		base: base, key: key, library: library, onError: onError,
		client: &http.Client{
			Timeout: 30 * time.Second,
			// A redirect means a login page or a wrong address, not Immich.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		quiet: immichQuiet, maxWait: immichMaxWait, fixWait: immichFixWait, finalWait: 5 * time.Second,
		retries: immichRetries,
		status:  immichStatus{URL: base},
		wake:    make(chan struct{}, 1),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}, nil
}

// start runs the loop that asks for scans, beginning with one.
func (m *Immich) start() {
	if m == nil {
		return
	}
	which := "its only library"
	if m.library != "" {
		which = "library " + m.library
	}
	logf("INFO", "Immich at %s: will ask it to scan %s after JPEGs change.", m.base, which)
	m.changed()
	go m.run()
}

// halt asks for a scan still waiting, and stops the loop. It gives up after
// timeout.
func (m *Immich) halt(timeout time.Duration) {
	if m == nil {
		return
	}
	select {
	case <-m.stop:
	default:
		close(m.stop)
	}
	select {
	case <-m.done:
	case <-time.After(timeout):
	}
}

// changed records that a JPEG under EXPORT_DIR was written or removed. Callers
// may hold App.mu.
func (m *Immich) changed() {
	if m == nil {
		return
	}
	m.mu.Lock()
	now := time.Now()
	if m.changes == 0 {
		m.first = now
	}
	m.changes++
	m.last = now
	if m.failures == 0 {
		// After an error that needs a fix, a new change is a new chance; after
		// one that may pass, the retry schedule stands.
		m.retryAt = time.Time{}
	}
	m.mu.Unlock()
	m.nudge()
}

func (m *Immich) nudge() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

// dueLocked is when to ask next: once changes have paused for quiet, or maxWait
// after the first, but not before a retry is due. Callers hold mu.
func (m *Immich) dueLocked() (time.Time, bool) {
	if m.changes == 0 {
		return time.Time{}, false
	}
	due := m.last.Add(m.quiet)
	if limit := m.first.Add(m.maxWait); limit.Before(due) {
		due = limit
	}
	if due.Before(m.retryAt) {
		due = m.retryAt
	}
	return due, true
}

func (m *Immich) run() {
	defer close(m.done)
	for {
		m.mu.Lock()
		due, pending := m.dueLocked()
		m.mu.Unlock()
		var fire <-chan time.Time
		var timer *time.Timer
		if pending {
			timer = time.NewTimer(time.Until(due))
			fire = timer.C
		}
		select {
		case <-m.stop:
			if timer != nil {
				timer.Stop()
			}
			ctx, cancel := context.WithTimeout(context.Background(), m.finalWait)
			m.attempt(ctx, true)
			cancel()
			return
		case <-m.wake:
		case <-fire:
			m.attempt(context.Background(), false)
		}
		if timer != nil {
			timer.Stop()
		}
	}
}

// attempt asks Immich to scan, if it's time (or now, if final).
func (m *Immich) attempt(ctx context.Context, final bool) {
	m.mu.Lock()
	due, pending := m.dueLocked()
	if !pending || (!final && time.Now().Before(due)) {
		m.mu.Unlock()
		return
	}
	n := m.changes
	m.changes = 0
	m.mu.Unlock()

	name, err := m.scan(ctx)

	m.mu.Lock()
	now := time.Now()
	if err == nil {
		m.failures, m.retryAt = 0, time.Time{}
		m.status.Libraries, m.status.Asked, m.status.Err = name, now, ""
		m.mu.Unlock()
		logf("INFO", "Asked Immich to scan %s.", name)
		return
	}
	msg := err.Error()
	repeated := msg == m.status.Err
	m.status.Tried, m.status.Err = now, msg
	// Put the changes back and try again later.
	if m.changes == 0 {
		m.first = now
	}
	m.changes += n
	if m.last.Before(now) {
		m.last = now
	}
	var fixable immichFixable
	if errors.As(err, &fixable) {
		m.failures, m.retryAt = 0, now.Add(m.fixWait)
	} else {
		m.failures++
		m.retryAt = now.Add(m.retries[min(m.failures, len(m.retries))-1])
	}
	m.mu.Unlock()
	if repeated {
		logf("WARNING", "Immich: %s", msg)
	} else {
		m.onError(msg)
	}
}

type immichLibrary struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	ImportPaths []string `json:"importPaths"`
}

// describe names a library and its folders as Immich sees them, so a wrong
// pick shows: "exported_photos" (/mnt/exported_photos).
func (l immichLibrary) describe() string {
	name := l.ID
	if l.Name != "" {
		name = fmt.Sprintf("%q", l.Name)
	}
	if len(l.ImportPaths) == 0 {
		return name + " (no folders)"
	}
	return name + " (" + strings.Join(l.ImportPaths, ", ") + ")"
}

// scan asks Immich to scan the library and describes it.
func (m *Immich) scan(ctx context.Context) (string, error) {
	var lib immichLibrary
	if m.library != "" {
		if err := m.call(ctx, http.MethodGet, "/api/libraries/"+m.library, &lib); err != nil {
			return "", err
		}
	} else {
		var libs []immichLibrary
		if err := m.call(ctx, http.MethodGet, "/api/libraries", &libs); err != nil {
			return "", err
		}
		switch len(libs) {
		case 0:
			return "", fixablef("Immich has no external libraries yet; add one for the JPEG folder (Administration → External Libraries)")
		case 1:
			lib = libs[0]
		default:
			// Scanning them all would also crawl libraries that may be large and
			// have nothing to do with these JPEGs, every few minutes.
			list := make([]string, 0, len(libs))
			for _, l := range libs {
				list = append(list, fmt.Sprintf("%s, id %s", l.describe(), l.ID))
			}
			return "", fixablef("Immich has %d libraries: %s. Set IMMICH_LIBRARY_ID to the id of the one for the JPEG folder", len(libs), strings.Join(list, "; "))
		}
	}
	if !uuidRE.MatchString(lib.ID) {
		return "", fixablef("Immich listed a library without a valid id; is IMMICH_URL Immich's address?")
	}
	if err := m.call(ctx, http.MethodPost, "/api/libraries/"+lib.ID+"/scan", nil); err != nil {
		return "", err
	}
	return lib.describe(), nil
}

// call makes one request to Immich and decodes its JSON answer into out.
func (m *Immich) call(ctx context.Context, method, path string, out any) error {
	resp, body, err := m.do(ctx, method, path)
	if err != nil {
		return m.connErr(err)
	}
	code := resp.StatusCode
	what := fmt.Sprintf("%s %s answered %d", method, path, code)
	if why := immichMessage(body); why != "" {
		what += " (" + why + ")"
	}
	switch {
	case code >= 200 && code < 300:
		if out != nil {
			if err := json.Unmarshal(body, out); err != nil {
				return fixablef("%s %s didn't answer like Immich does; is IMMICH_URL Immich's address?", method, path)
			}
		}
		return nil
	case code >= 300 && code < 400:
		to := "elsewhere"
		if l, err := url.Parse(resp.Header.Get("Location")); err == nil && l.Host != "" {
			to = l.Scheme + "://" + l.Host // not the rest: a login page's address changes every time
		}
		return fixablef("%s %s answered %d, a redirect to %s: set IMMICH_URL to Immich's own address on the network (like http://host.docker.internal:2283), not one behind a login", method, path, code, to)
	case code == http.StatusUnauthorized:
		return fixablef("%s: Immich doesn't accept the API key; check IMMICH_API_KEY", what)
	case code == http.StatusForbidden:
		return fixablef("%s: the API key needs the library.read and library.update permissions, and must be an admin's", what)
	case code == http.StatusNotFound:
		if m.inMaintenance(ctx) {
			return errors.New("Immich is in maintenance mode")
		}
		if m.library != "" {
			return fixablef("%s: is IMMICH_LIBRARY_ID right, and IMMICH_URL Immich's address?", what)
		}
		return fixablef("%s: is IMMICH_URL Immich's address?", what)
	case code == http.StatusBadRequest && m.library != "":
		return fixablef("%s: is IMMICH_LIBRARY_ID the id of one of Immich's external libraries?", what)
	case code == http.StatusRequestTimeout || code == http.StatusTooManyRequests || code >= 500:
		return errors.New(what)
	}
	return fixablef("%s", what)
}

func (m *Immich) do(ctx context.Context, method, path string) (*http.Response, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, m.base+path, nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("x-api-key", m.key)
	req.Header.Set("Accept", "application/json")
	resp, err := m.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp, body, nil
}

// inMaintenance reports whether Immich answers that it is in maintenance mode,
// in which only a few of its endpoints answer and the rest say 404.
func (m *Immich) inMaintenance(ctx context.Context) bool {
	resp, body, err := m.do(ctx, http.MethodGet, "/api/server/config")
	if err != nil || resp.StatusCode != http.StatusOK {
		return false
	}
	var cfg struct {
		MaintenanceMode bool `json:"maintenanceMode"`
	}
	return json.Unmarshal(body, &cfg) == nil && cfg.MaintenanceMode
}

// connErr explains a request that got no answer.
func (m *Immich) connErr(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err // the message names the address already
	}
	var op *net.OpError
	if errors.As(err, &op) && op.Source != nil {
		// The local port differs every time; without it a repeated failure reads the same.
		c := *op
		c.Source = nil
		err = &c
	}
	host := m.base
	if u, perr := url.Parse(m.base); perr == nil {
		host = u.Hostname()
	}
	var dns *net.DNSError
	var unknownCA x509.UnknownAuthorityError
	var wrongHost x509.HostnameError
	var invalid x509.CertificateInvalidError
	var verify *tls.CertificateVerificationError
	switch {
	case errors.As(err, &dns) && dns.IsNotFound && strings.EqualFold(host, "host.docker.internal"):
		return fixablef("can't find host.docker.internal (%v): add extra_hosts with host.docker.internal:host-gateway to this service in compose.yaml", err)
	case errors.As(err, &dns) && dns.IsNotFound && strings.HasSuffix(strings.ToLower(host), ".local"):
		return fixablef("can't find %s: containers can't look up .local names; use Immich's IP address in IMMICH_URL", host)
	case errors.As(err, &dns) && dns.IsNotFound:
		return fixablef("can't find %s (%v); is the name in IMMICH_URL right?", host, err)
	case errors.As(err, &unknownCA) || errors.As(err, &wrongHost) || errors.As(err, &invalid) || errors.As(err, &verify):
		return fixablef("Immich's https certificate isn't trusted (%v); use its plain http address on your network, like http://host.docker.internal:2283", err)
	case strings.Contains(err.Error(), "server gave HTTP response to HTTPS client"):
		return fixablef("IMMICH_URL starts with https://, but Immich answers plain http there; use http://")
	case op != nil && op.Op == "dial":
		return fmt.Errorf("can't reach Immich at %s (%v); is it running, and does the NAS firewall let this container reach that port?", m.base, err)
	}
	return fmt.Errorf("Immich at %s closed the connection (%v); it may be starting or restarting", m.base, err)
}

// immichMessage picks the message out of an Immich error answer.
func immichMessage(body []byte) string {
	var e struct {
		Message any `json:"message"`
	}
	if json.Unmarshal(body, &e) != nil || e.Message == nil {
		return ""
	}
	var msg string
	switch v := e.Message.(type) {
	case string:
		msg = v
	case []any: // a list of validation errors
		parts := make([]string, 0, len(v))
		for _, p := range v {
			parts = append(parts, fmt.Sprint(p))
		}
		msg = strings.Join(parts, "; ")
	default:
		msg = fmt.Sprint(v)
	}
	if r := []rune(msg); len(r) > 200 {
		msg = string(r[:200]) + "…"
	}
	return msg
}

func (m *Immich) snapshot() *immichStatus {
	if m == nil {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.status
	s.Due, _ = m.dueLocked()
	return &s
}
