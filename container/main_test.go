package main

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testToken = "secret-token"

var jpeg = append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, bytes.Repeat([]byte("x"), 5000)...)

type env struct {
	t      *testing.T
	app    *App
	srv    *httptest.Server
	source string
	export string
	config string
}

func newEnv(t *testing.T, tweak func(*Config)) *env {
	t.Helper()
	root := t.TempDir()
	e := &env{t: t, source: filepath.Join(root, "source"), export: filepath.Join(root, "export"), config: filepath.Join(root, "config")}
	for _, d := range []string{e.source, e.export, e.config} {
		must(t, os.MkdirAll(d, 0o755))
	}
	cfg := Config{
		SourceDir: e.source, ExportDir: e.export, ConfigDir: e.config, Token: testToken,
		ScanInterval: time.Minute, OnlineWindow: time.Minute, MaxUploadBytes: 1 << 20,
		RequireSource: true, Exclude: splitList("@*,#recycle,#snapshot,.*,*.lrlibrary,*.lrdata"),
		OwnerUID: -1, OwnerGID: -1,
	}
	if tweak != nil {
		tweak(&cfg)
	}
	app, err := newApp(cfg)
	must(t, err)
	app.uid, app.gid = -1, -1 // tests may run as root; don't chown
	e.app = app
	e.srv = httptest.NewServer(app.routes())
	t.Cleanup(e.srv.Close)
	return e
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (e *env) touch(rel string, body []byte, age time.Duration) {
	e.t.Helper()
	p := filepath.Join(e.source, filepath.FromSlash(rel))
	must(e.t, os.MkdirAll(filepath.Dir(p), 0o755))
	must(e.t, os.WriteFile(p, body, 0o644))
	if age > 0 {
		old := time.Now().Add(-age)
		must(e.t, os.Chtimes(p, old, old))
	}
}

func (e *env) upload(fields map[string]string, file []byte, token string) (int, map[string]any) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		must(e.t, mw.WriteField(k, v))
	}
	if file != nil {
		fw, err := mw.CreateFormFile("file", "photo.jpg")
		must(e.t, err)
		fw.Write(file)
	}
	must(e.t, mw.Close())
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/photos", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+token)
	return e.do(req)
}

func (e *env) post(path string, body any) (int, map[string]any) {
	e.t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", e.srv.URL+path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+testToken)
	return e.do(req)
}

func (e *env) do(req *http.Request) (int, map[string]any) {
	e.t.Helper()
	resp, err := http.DefaultClient.Do(req)
	must(e.t, err)
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (e *env) exists(rel string) bool {
	_, err := os.Stat(filepath.Join(e.export, filepath.FromSlash(rel)))
	return err == nil
}

func TestCleanRel(t *testing.T) {
	for in, want := range map[string]string{
		"a/b.RAF": "a/b.RAF", "a//b.RAF": "a/b.RAF", "./a/b.RAF": "a/b.RAF", "Photo Booth 圖庫/x.NEF": "Photo Booth 圖庫/x.NEF",
	} {
		got, err := cleanRel(in)
		if err != nil || got != want {
			t.Errorf("cleanRel(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", " ", "/etc/passwd", "../x.jpg", "a/../../x.jpg", "a/../b.jpg", ".", "a\x00b"} {
		if got, err := cleanRel(in); err == nil {
			t.Errorf("cleanRel(%q) = %q; want an error", in, got)
		}
	}
}

func TestOutputID(t *testing.T) {
	cases := []struct {
		source, variant string
		n               int
		want            string
	}{
		{"DCIM/100_FUJI/DSCF0001.RAF", "", 0, "DCIM/100_FUJI/DSCF0001.jpg"},
		{"DCIM/100_FUJI/DSCF0001.RAF", "Copy 1", 0, "DCIM/100_FUJI/DSCF0001-Copy 1.jpg"},
		{"DCIM/100_FUJI/DSCF0001.NEF", "", 1, "DCIM/100_FUJI/DSCF0001-nef.jpg"},
		{"DCIM/100_FUJI/DSCF0001.NEF", "", 2, "DCIM/100_FUJI/DSCF0001-nef-2.jpg"},
		{"top.RAF", "a/b:c", 0, "top-a_b_c.jpg"},
		{"x/noext", "", 1, "x/noext-raw.jpg"},
	}
	for _, c := range cases {
		if got := outputID(c.source, c.variant, c.n); got != c.want {
			t.Errorf("outputID(%q, %q, %d) = %q; want %q", c.source, c.variant, c.n, got, c.want)
		}
	}
	if got := safeName(" .. "); got != "copy" {
		t.Errorf("safeName(blank) = %q", got)
	}
}

func TestUploadMirrorsFolderAndReplaces(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("DCIM/100_FUJI/DSCF0001.RAF", []byte("raw"), 0)
	code, out := e.upload(map[string]string{"rel": "DCIM/100_FUJI/DSCF0001.RAF", "uuid": "u1", "fingerprint": "1"}, jpeg, testToken)
	if code != 200 || out["id"] != "DCIM/100_FUJI/DSCF0001.jpg" || out["replaced"] != false {
		t.Fatalf("first upload: %d %v", code, out)
	}
	got, err := os.ReadFile(filepath.Join(e.export, "DCIM/100_FUJI/DSCF0001.jpg"))
	if err != nil || !bytes.Equal(got, jpeg) {
		t.Fatalf("published file wrong: %v", err)
	}
	newer := append(append([]byte{}, jpeg...), 'y')
	code, out = e.upload(map[string]string{"rel": "DCIM/100_FUJI/DSCF0001.RAF", "uuid": "u1", "fingerprint": "2", "previousId": "DCIM/100_FUJI/DSCF0001.jpg"}, newer, testToken)
	if code != 200 || out["id"] != "DCIM/100_FUJI/DSCF0001.jpg" || out["replaced"] != true {
		t.Fatalf("second upload: %d %v", code, out)
	}
	got, _ = os.ReadFile(filepath.Join(e.export, "DCIM/100_FUJI/DSCF0001.jpg"))
	if !bytes.Equal(got, newer) {
		t.Fatal("replacement not written")
	}
	// State survives a restart.
	s, err := openStore(filepath.Join(e.config, "state.json"))
	must(t, err)
	if p := s.st.Photos["DCIM/100_FUJI/DSCF0001.jpg"]; p == nil || p.Fingerprint != "2" || p.Source != "DCIM/100_FUJI/DSCF0001.RAF" {
		t.Fatalf("state: %+v", s.st.Photos)
	}
	// No temporary files left behind.
	if parts, _ := filepath.Glob(filepath.Join(e.export, tmpDirName, "*")); len(parts) != 0 {
		t.Fatalf("leftover temp files: %v", parts)
	}
}

func TestUploadResolvesCaseAndRejectsUnknownSource(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("DCIM/100_FUJI/DSCF0001.RAF", []byte("raw"), 0)
	// The NAS's btrfs is case-sensitive; a Mac's disk usually isn't, and there
	// any spelling already finds the file.
	_, err := os.Stat(filepath.Join(e.source, "dcim/100_fuji/dscf0001.raf"))
	caseSensitive := err != nil
	code, out := e.upload(map[string]string{"rel": "dcim/100_fuji/dscf0001.raf"}, jpeg, testToken)
	if code != 200 || (caseSensitive && out["id"] != "DCIM/100_FUJI/DSCF0001.jpg") {
		t.Fatalf("case-insensitive upload: %d %v", code, out)
	}
	code, out = e.upload(map[string]string{"rel": "My Raw Photos/DCIM/100_FUJI/DSCF0001.RAF"}, jpeg, testToken)
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown source: %d %v", code, out)
	}
	code, _ = e.upload(map[string]string{"rel": "../source/DCIM/100_FUJI/DSCF0001.RAF"}, jpeg, testToken)
	if code != http.StatusBadRequest {
		t.Fatalf("traversal: %d", code)
	}
}

func TestUploadMatchesDecomposedUnicodeAndWritesReadableFiles(t *testing.T) {
	e := newEnv(t, nil)
	composed := "Caf\u00e9 \u5716\u5eab/DSCF0001.RAF"    // as the NAS stores it (NFC)
	decomposed := "Cafe\u0301 \u5716\u5eab/DSCF0001.RAF" // as macOS may report it (NFD)
	e.touch(composed, []byte("raw"), 0)
	// A Mac's APFS finds either spelling by itself; the NAS's btrfs does not.
	_, err := os.Stat(filepath.Join(e.source, decomposed))
	exact := err != nil
	code, out := e.upload(map[string]string{"rel": decomposed}, jpeg, testToken)
	if code != 200 || (exact && out["id"] != "Caf\u00e9 \u5716\u5eab/DSCF0001.jpg") {
		t.Fatalf("NFD upload: %d %v", code, out)
	}
	fi, err := os.Stat(filepath.Join(e.export, filepath.FromSlash(out["id"].(string))))
	must(t, err)
	if fi.Mode().Perm()&0o044 == 0 {
		t.Fatalf("published JPEG is private: %v", fi.Mode())
	}
}

func TestUploadRejectsBadRequests(t *testing.T) {
	e := newEnv(t, func(c *Config) { c.MaxUploadBytes = 4096 })
	e.touch("a/X.RAF", []byte("raw"), 0)
	if code, _ := e.upload(map[string]string{"rel": "a/X.RAF"}, jpeg[:1000], "wrong"); code != http.StatusUnauthorized {
		t.Fatalf("wrong token: %d", code)
	}
	if code, _ := e.upload(map[string]string{"rel": "a/X.RAF"}, []byte("not a jpeg"), testToken); code != http.StatusUnsupportedMediaType {
		t.Fatalf("not a JPEG: %d", code)
	}
	if code, _ := e.upload(map[string]string{"rel": "a/X.RAF"}, jpeg, testToken); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("too big: %d", code)
	}
	if code, _ := e.upload(map[string]string{"rel": "a/X.RAF"}, nil, testToken); code != http.StatusBadRequest {
		t.Fatalf("no file: %d", code)
	}
	if e.exists("a/X.jpg") {
		t.Fatal("a rejected upload was published")
	}
}

func TestNameCollisionsAndVirtualCopies(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/DSCF0002.RAF", []byte("raw"), 0)
	e.touch("d/DSCF0002.NEF", []byte("raw"), 0)
	_, a := e.upload(map[string]string{"rel": "d/DSCF0002.RAF", "uuid": "u-raf"}, jpeg, testToken)
	_, b := e.upload(map[string]string{"rel": "d/DSCF0002.NEF", "uuid": "u-nef"}, jpeg, testToken)
	_, c := e.upload(map[string]string{"rel": "d/DSCF0002.RAF", "uuid": "u-vc", "variant": "Copy 1"}, jpeg, testToken)
	_, a2 := e.upload(map[string]string{"rel": "d/DSCF0002.RAF", "uuid": "u-raf"}, jpeg, testToken)
	if a["id"] != "d/DSCF0002.jpg" || b["id"] != "d/DSCF0002-nef.jpg" || c["id"] != "d/DSCF0002-Copy 1.jpg" || a2["id"] != "d/DSCF0002.jpg" {
		t.Fatalf("ids: %v %v %v %v", a["id"], b["id"], c["id"], a2["id"])
	}
}

func TestMovedPhotoReplacesOldJPEG(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("old/DSCF0003.RAF", []byte("raw"), 0)
	_, first := e.upload(map[string]string{"rel": "old/DSCF0003.RAF", "uuid": "u3"}, jpeg, testToken)
	must(t, os.MkdirAll(filepath.Join(e.source, "new"), 0o755))
	must(t, os.Rename(filepath.Join(e.source, "old/DSCF0003.RAF"), filepath.Join(e.source, "new/DSCF0003.RAF")))
	code, second := e.upload(map[string]string{"rel": "new/DSCF0003.RAF", "uuid": "u3", "previousId": first["id"].(string)}, jpeg, testToken)
	if code != 200 || second["id"] != "new/DSCF0003.jpg" {
		t.Fatalf("moved upload: %d %v", code, second)
	}
	if e.exists("old/DSCF0003.jpg") || e.exists("old") {
		t.Fatal("old JPEG or its empty folder is still there")
	}
	// A previousId now owned by another photo is left alone.
	e.touch("new/DSCF0004.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "new/DSCF0004.RAF", "uuid": "u4", "previousId": "new/DSCF0003.jpg"}, jpeg, testToken)
	if !e.exists("new/DSCF0003.jpg") {
		t.Fatal("another photo's JPEG was removed")
	}
}

func TestCheck(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/A.RAF", []byte("raw"), 0)
	e.touch("d/B.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "d/A.RAF", "fingerprint": "fp1"}, jpeg, testToken)
	e.upload(map[string]string{"rel": "d/A.RAF", "variant": "Copy 1", "fingerprint": "fp2"}, jpeg, testToken)
	items := []map[string]string{
		{"key": "1", "rel": "d/A.RAF", "fingerprint": "fp1"},
		{"key": "2", "rel": "d/A.RAF", "fingerprint": "changed"},
		{"key": "3", "rel": "d/A.RAF", "variant": "Copy 1", "fingerprint": "fp2"},
		{"key": "4", "rel": "d/B.RAF", "fingerprint": "fp1"},
		{"key": "5", "rel": "../x", "fingerprint": "fp1"},
		{"key": "6", "rel": "d/A.RAF", "fingerprint": ""},
	}
	code, out := e.post("/api/check", map[string]any{"items": items})
	if code != 200 {
		t.Fatalf("check: %d %v", code, out)
	}
	res := out["results"].(map[string]any)
	want := map[string]string{"1": "d/A.jpg true", "2": "d/A.jpg false", "3": "d/A-Copy 1.jpg true", "4": " false", "5": " false", "6": "d/A.jpg false"}
	for k, w := range want {
		r := res[k].(map[string]any)
		id, _ := r["id"].(string)
		if got := id + " " + map[bool]string{true: "true", false: "false"}[r["current"].(bool)]; got != w {
			t.Errorf("item %s = %q; want %q", k, got, w)
		}
	}
	// A JPEG changed on disk behind the service's back is not current.
	must(t, os.WriteFile(filepath.Join(e.export, "d/A.jpg"), []byte("edited elsewhere"), 0o644))
	_, out = e.post("/api/check", map[string]any{"items": items[:1]})
	if out["results"].(map[string]any)["1"].(map[string]any)["current"] != false {
		t.Fatal("a modified JPEG still counts as current")
	}
}

func TestDelete(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/A.RAF", []byte("raw"), 0)
	e.touch("d/B.RAF", []byte("raw"), 0)
	e.upload(map[string]string{"rel": "d/A.RAF"}, jpeg, testToken)
	e.upload(map[string]string{"rel": "d/B.RAF"}, jpeg, testToken)
	must(t, os.WriteFile(filepath.Join(e.export, "keep.txt"), []byte("mine"), 0o644))
	code, out := e.post("/api/delete", map[string]any{"ids": []string{"d/A.jpg", "d/gone.jpg", "../export/keep.txt", "keep.txt"}})
	if code != 200 {
		t.Fatalf("delete: %d %v", code, out)
	}
	res := out["results"].(map[string]any)
	if res["d/A.jpg"] != "deleted" || res["d/gone.jpg"] != "unknown" ||
		res["../export/keep.txt"] != "unknown" || res["keep.txt"] != "unknown" {
		t.Fatalf("results: %v", res)
	}
	if e.exists("d/A.jpg") || !e.exists("d/B.jpg") || !e.exists("keep.txt") {
		t.Fatal("wrong files deleted")
	}
	e.post("/api/delete", map[string]any{"ids": []string{"d/B.jpg"}})
	if e.exists("d") {
		t.Fatal("empty folder not removed")
	}
	if !e.exists(".") {
		t.Fatal("export folder itself was removed")
	}
}

func TestSidecarScan(t *testing.T) {
	e := newEnv(t, nil)
	edited := []byte(`<x:xmpmeta><rdf:Description crs:Version="17.0" crs:HasSettings="True" crs:Exposure2012="+0.50"/></x:xmpmeta>`)
	plain := []byte(`<x:xmpmeta><rdf:Description xmp:Rating="3" crs:HasSettings="False"/></x:xmpmeta>`)
	old := time.Hour
	e.touch("DCIM/100_FUJI/DSCF0001.RAF", []byte("raw"), old)
	e.touch("DCIM/100_FUJI/DSCF0001.xmp", edited, old) // counts
	e.touch("DCIM/100_FUJI/DSCF0002.RAF", []byte("raw"), old)
	e.touch("DCIM/100_FUJI/DSCF0002.XMP", plain, old) // no settings
	e.touch("DCIM/100_FUJI/DSCF0003.RAF", []byte("raw"), old)
	e.touch("DCIM/100_FUJI/DSCF0004.RAF", []byte("raw"), old)
	e.touch("DCIM/100_FUJI/DSCF0004.xmp", edited, 0) // too new
	e.touch("DCIM/100_FUJI/DSCF0005.dng", []byte("raw"), old)
	e.touch("DCIM/100_FUJI/DSCF0005.xmp", edited, old) // DNGs keep their own settings
	e.touch("DCIM/100_FUJI/@eaDir/DSCF0006.RAF", []byte("raw"), old)
	e.touch("DCIM/100_FUJI/@eaDir/DSCF0006.xmp", edited, old)
	e.touch("Pictures/Lightroom Library.lrlibrary/x/IMG.CR3", []byte("raw"), old)
	e.touch("Pictures/Lightroom Library.lrlibrary/x/IMG.xmp", edited, old)
	e.touch("Photo Booth 圖庫/IMG_1.nef", []byte("raw"), old)
	e.touch("Photo Booth 圖庫/IMG_1.xmp", edited, old) // counts
	e.touch("Caf\u00e9/IMG_2.cr3", []byte("raw"), old)
	e.touch("Caf\u00e9/IMG_2.xmp", edited, old) // counts, with its NFD spelling

	code, out := e.post("/api/hello", map[string]string{"client": "test", "version": "0", "host": "mac"})
	if code != 200 || out["ok"] != true {
		t.Fatalf("hello: %d %v", code, out)
	}
	sid, _ := out["serverId"].(string)
	if len(sid) != 16 {
		t.Fatalf("serverId = %q", sid)
	}
	if s, _ := openStore(filepath.Join(e.config, "state.json")); s.st.ServerID != sid {
		t.Fatalf("serverId not saved: %q", s.st.ServerID)
	}
	req, _ := http.NewRequest("GET", e.srv.URL+"/api/sidecars", nil)
	req.Header.Set("X-Token", testToken)
	code, out = e.do(req)
	if code != 200 {
		t.Fatalf("sidecars: %d %v", code, out)
	}
	var rels []string
	for _, it := range out["items"].([]any) {
		m := it.(map[string]any)
		rels = append(rels, m["rel"].(string))
		if nfd, _ := m["relNFD"].(string); m["rel"] == "Caf\u00e9/IMG_2.cr3" && nfd != "Cafe\u0301/IMG_2.cr3" {
			t.Errorf("relNFD = %q", nfd)
		} else if m["rel"] != "Caf\u00e9/IMG_2.cr3" && nfd != "" {
			t.Errorf("unneeded relNFD %q for %v", nfd, m["rel"])
		}
	}
	want := []string{"Caf\u00e9/IMG_2.cr3", "DCIM/100_FUJI/DSCF0001.RAF", "Photo Booth 圖庫/IMG_1.nef"}
	if strings.Join(rels, "|") != strings.Join(want, "|") {
		t.Fatalf("sidecar items = %v; want %v", rels, want)
	}
	if out["raws"].(float64) != 6 {
		t.Fatalf("raws = %v; want 6", out["raws"])
	}
	// A fresh scan is reused; a new sidecar shows up after the interval.
	e.touch("DCIM/100_FUJI/DSCF0003.xmp", edited, old)
	snap := e.app.scanner.get(context.Background(), time.Hour)
	if len(snap.Items) != 3 {
		t.Fatalf("cached scan changed: %v", snap.Items)
	}
	snap = e.app.scanner.get(context.Background(), time.Nanosecond)
	if len(snap.Items) != 4 {
		t.Fatalf("rescan missed the new sidecar: %v", snap.Items)
	}
}

func TestStatusPageAndOnline(t *testing.T) {
	e := newEnv(t, nil)
	resp, err := http.Get(e.srv.URL + "/")
	must(t, err)
	var b bytes.Buffer
	b.ReadFrom(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(b.String(), "offline") {
		t.Fatalf("status page: %d", resp.StatusCode)
	}
	e.post("/api/hello", map[string]string{"client": "test", "version": "9.9", "host": "MacBook Air"})
	resp, _ = http.Get(e.srv.URL + "/")
	b.Reset()
	b.ReadFrom(resp.Body)
	resp.Body.Close()
	if !strings.Contains(b.String(), ">online<") || !strings.Contains(b.String(), "MacBook Air") {
		t.Fatal("status page doesn't show Lightroom online")
	}
	if resp, _ := http.Get(e.srv.URL + "/api/sidecars"); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("api without token: %d", resp.StatusCode)
	}
}

func TestTokenFileCreatedOnce(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{ConfigDir: dir}
	a, err := loadToken(cfg)
	must(t, err)
	b, err := loadToken(cfg)
	must(t, err)
	if a == "" || a != b {
		t.Fatalf("tokens %q %q", a, b)
	}
	if fi, _ := os.Stat(filepath.Join(dir, "token")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("token file mode %v", fi.Mode())
	}
}

func TestNeverOverwritesOrDeletesFilesItDidNotWrite(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/DSCF4742.RAF", []byte("raw"), 0)
	must(t, os.MkdirAll(filepath.Join(e.export, "d"), 0o755))
	mine := []byte("the user's own export")
	must(t, os.WriteFile(filepath.Join(e.export, "d/DSCF4742.jpg"), mine, 0o644))
	_, out := e.upload(map[string]string{"rel": "d/DSCF4742.RAF", "uuid": "u1"}, jpeg, testToken)
	if out["id"] != "d/DSCF4742-raf.jpg" {
		t.Fatalf("id = %v; want the -raf name next to the user's file", out["id"])
	}
	if got, _ := os.ReadFile(filepath.Join(e.export, "d/DSCF4742.jpg")); !bytes.Equal(got, mine) {
		t.Fatal("the user's file was overwritten")
	}
	// A previousId pointing at the user's file must not delete it either.
	e.upload(map[string]string{"rel": "d/DSCF4742.RAF", "uuid": "u1", "previousId": "d/DSCF4742.jpg"}, jpeg, testToken)
	if !e.exists("d/DSCF4742.jpg") {
		t.Fatal("previousId cleanup deleted a file the service didn't write")
	}
}

func TestStateLossTakesOverOwnFilesWithoutMixingThemUp(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/IMG.RAF", []byte("raw"), 0)
	e.touch("d/IMG.NEF", []byte("raw"), 0)
	_, a := e.upload(map[string]string{"rel": "d/IMG.RAF", "uuid": "ua"}, jpeg, testToken)
	_, b := e.upload(map[string]string{"rel": "d/IMG.NEF", "uuid": "ub"}, jpeg, testToken)
	if a["id"] != "d/IMG.jpg" || b["id"] != "d/IMG-nef.jpg" {
		t.Fatalf("ids %v %v", a["id"], b["id"])
	}
	// state.json is lost; Lightroom republishes both, the NEF first, with their old ids.
	e.app.mu.Lock()
	e.app.store.st.Photos = map[string]*Published{}
	e.app.mu.Unlock()
	nef := append(append([]byte{}, jpeg...), 'N')
	raf := append(append([]byte{}, jpeg...), 'R')
	_, b2 := e.upload(map[string]string{"rel": "d/IMG.NEF", "uuid": "ub", "previousId": "d/IMG-nef.jpg"}, nef, testToken)
	_, a2 := e.upload(map[string]string{"rel": "d/IMG.RAF", "uuid": "ua", "previousId": "d/IMG.jpg"}, raf, testToken)
	if a2["id"] != "d/IMG.jpg" || b2["id"] != "d/IMG-nef.jpg" {
		t.Fatalf("after state loss: %v %v", a2["id"], b2["id"])
	}
	gotA, _ := os.ReadFile(filepath.Join(e.export, "d/IMG.jpg"))
	gotB, _ := os.ReadFile(filepath.Join(e.export, "d/IMG-nef.jpg"))
	if !bytes.Equal(gotA, raf) || !bytes.Equal(gotB, nef) {
		t.Fatal("JPEGs were mixed up")
	}
}

func TestVirtualCopiesWithTheSameNameAndCaseClashes(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/A.RAF", []byte("raw"), 0)
	e.touch("d/IMG_0001.CR2", []byte("raw"), 0)
	e.touch("d/img_0001.dng", []byte("raw"), 0)
	_, v1 := e.upload(map[string]string{"rel": "d/A.RAF", "uuid": "vc1", "variant": "BW"}, jpeg, testToken)
	_, v2 := e.upload(map[string]string{"rel": "d/A.RAF", "uuid": "vc2", "variant": "BW"}, jpeg, testToken)
	_, v1b := e.upload(map[string]string{"rel": "d/A.RAF", "uuid": "vc1", "variant": "BW"}, jpeg, testToken)
	if v1["id"] != "d/A-BW.jpg" || v2["id"] != "d/A-BW-raf.jpg" || v1b["id"] != "d/A-BW.jpg" {
		t.Fatalf("copies: %v %v %v", v1["id"], v2["id"], v1b["id"])
	}
	_, c1 := e.upload(map[string]string{"rel": "d/IMG_0001.CR2", "uuid": "c1"}, jpeg, testToken)
	_, c2 := e.upload(map[string]string{"rel": "d/img_0001.dng", "uuid": "c2"}, jpeg, testToken)
	if c1["id"] == "" || c2["id"] == "" || strings.EqualFold(c1["id"].(string), c2["id"].(string)) {
		t.Fatalf("case clash: %v %v", c1["id"], c2["id"])
	}
}

func TestErrorCodesTellPhotoProblemsFromNASProblems(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/sub/X.RAF", []byte("raw"), 0)
	must(t, os.MkdirAll(filepath.Join(e.export, "d"), 0o755))
	must(t, os.WriteFile(filepath.Join(e.export, "d/sub"), []byte("a file where a folder goes"), 0o644))
	if code, out := e.upload(map[string]string{"rel": "d/sub/X.RAF"}, jpeg, testToken); code != http.StatusConflict {
		t.Fatalf("file in the way of a folder: %d %v", code, out)
	}
	// A wrong RAW folder is refused before anything is written, and the check says so.
	if code, _ := e.upload(map[string]string{"rel": "My Raw Photos/d/sub/X.RAF"}, jpeg, testToken); code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown source: %d", code)
	}
	_, out := e.post("/api/check", map[string]any{"items": []map[string]string{
		{"key": "a", "rel": "My Raw Photos/d/sub/X.RAF"}, {"key": "b", "rel": "d/sub/X.RAF"}}})
	res := out["results"].(map[string]any)
	if res["a"].(map[string]any)["found"] != false || res["b"].(map[string]any)["found"] != true {
		t.Fatalf("found flags: %v", res)
	}
	if parts := removeParts(e.export); parts != 0 {
		t.Fatalf("%d temporary files left behind", parts)
	}
}

func TestHelloScansOnlyWhenAsked(t *testing.T) {
	e := newEnv(t, nil)
	e.touch("d/A.RAF", []byte("raw"), time.Hour)
	e.touch("d/A.xmp", []byte(`crs:HasSettings="True"`), time.Hour)
	scanState := func() (bool, bool) {
		e.app.scanner.mu.Lock()
		defer e.app.scanner.mu.Unlock()
		return !e.app.scanner.snap.At.IsZero(), e.app.scanner.done != nil
	}
	e.post("/api/hello", map[string]any{"client": "test", "sidecars": false})
	time.Sleep(100 * time.Millisecond)
	if done, running := scanState(); done || running {
		t.Fatal("hello without sidecars started a scan")
	}
	e.post("/api/hello", map[string]any{"client": "test", "sidecars": true})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if done, _ := scanState(); done {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("hello with sidecars didn't scan")
		}
		time.Sleep(20 * time.Millisecond)
	}
	req, _ := http.NewRequest("GET", e.srv.URL+"/api/sidecars", nil)
	req.Header.Set("X-Token", testToken)
	_, out := e.do(req)
	items := out["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["version"] == "" {
		t.Fatalf("sidecar items: %v", items)
	}
}
