package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

const tmpDirName = ".lrc-tmp" // in EXPORT_DIR: uploads whose destination isn't known yet

// Temporary upload files are named .lrc-upload-*.part. They are created in the
// JPEG's own folder, so they get that folder's Synology ACL and the final rename
// is atomic; a dot name keeps them hidden from Finder and indexers.
const partPrefix = ".lrc-upload-"

// uploadError carries the HTTP status for a failed upload. 4xx means the request
// or this photo is the problem (the plugin leaves the photo alone until it's
// edited again); 5xx means the NAS has a problem that may pass (the plugin
// retries later).
type uploadError struct {
	code int
	err  error
}

func (e *uploadError) Error() string { return e.err.Error() }

func uploadErr(code int, err error) *uploadError { return &uploadError{code, err} }

// localErr classifies a failure of the NAS's own disk: full disk -> 507,
// anything else -> 500.
func localErr(err error) *uploadError {
	if errors.Is(err, syscall.ENOSPC) || errors.Is(err, syscall.EDQUOT) {
		return uploadErr(http.StatusInsufficientStorage, err)
	}
	if errors.Is(err, errNotFolder) {
		return uploadErr(http.StatusConflict, err)
	}
	return uploadErr(http.StatusInternalServerError, err)
}

// readErr classifies a failure to read the request.
func readErr(err error) *uploadError {
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		return uploadErr(http.StatusRequestEntityTooLarge, err)
	}
	return uploadErr(http.StatusBadRequest, err)
}

var errNotJPEG = errors.New("the file is not a JPEG")

// handleUpload takes one rendered JPEG as multipart/form-data:
//
//	rel         the RAW's path relative to the photo folder, with "/" separators
//	variant     the virtual copy name ("" for the master photo)
//	previousId  the id Lightroom recorded the last time it published this photo
//	fingerprint, uuid   kept for matching later uploads and checks
//	file        the JPEG (sent last by the plugin)
//
// It answers {"ok":true,"id":...}; the id is the JPEG's path relative to
// EXPORT_DIR, and the plugin records it in Lightroom.
func (a *App) handleUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, a.cfg.MaxUploadBytes)
	mr, err := r.MultipartReader()
	if err != nil {
		a.fail(w, http.StatusBadRequest, "", "expected a multipart upload: %v", err)
		return
	}
	fields := map[string]string{}
	var tmp, source string
	var size int64
	defer func() {
		if tmp != "" {
			os.Remove(tmp)
		}
	}()
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			ue := readErr(err)
			a.fail(w, ue.code, "", "reading the upload: %v", err)
			return
		}
		if part.FormName() == "file" || part.FileName() != "" {
			if tmp != "" {
				part.Close()
				a.fail(w, http.StatusBadRequest, "", "an upload carries one file")
				return
			}
			dir := filepath.Join(a.cfg.ExportDir, tmpDirName)
			if _, ok := fields["rel"]; ok {
				var ue *uploadError
				if source, ue = a.resolveUploadSource(fields["rel"]); ue != nil {
					io.Copy(io.Discard, part) // read it all, so the client sees the answer
					part.Close()
					a.fail(w, ue.code, fields["rel"], "%v", ue.err)
					return
				}
				dir = filepath.Join(a.cfg.ExportDir, filepath.FromSlash(path.Dir(source)))
			}
			var ue *uploadError
			tmp, size, ue = a.receive(part, dir)
			part.Close()
			if ue != nil {
				a.fail(w, ue.code, fields["rel"], "receiving the JPEG: %v", ue.err)
				return
			}
			continue
		}
		b, err := io.ReadAll(io.LimitReader(part, 64<<10))
		part.Close()
		if err != nil {
			ue := readErr(err)
			a.fail(w, ue.code, "", "reading the upload: %v", err)
			return
		}
		fields[part.FormName()] = string(b)
	}
	if tmp == "" {
		a.fail(w, http.StatusBadRequest, fields["rel"], "the upload has no file")
		return
	}
	if source == "" {
		var ue *uploadError
		if source, ue = a.resolveUploadSource(fields["rel"]); ue != nil {
			a.fail(w, ue.code, fields["rel"], "%v", ue.err)
			return
		}
	}
	variant := norm.NFC.String(strings.TrimSpace(fields["variant"]))
	uuid := strings.TrimSpace(fields["uuid"])
	previousID := strings.TrimSpace(fields["previousId"])

	a.mu.Lock()
	defer a.mu.Unlock()
	id := a.targetID(source, variant, uuid, previousID)
	dst := filepath.Join(a.cfg.ExportDir, filepath.FromSlash(id))
	if err := a.mkdirs(filepath.Dir(dst)); err != nil {
		ue := localErr(err)
		a.store.event("error", id, "creating its folder: %v", err)
		writeJSON(w, ue.code, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	replaced := false
	if fi, err := os.Lstat(dst); err == nil {
		if !fi.Mode().IsRegular() {
			a.store.event("error", id, "something other than a file is in the way")
			writeJSON(w, http.StatusConflict, map[string]any{"ok": false, "error": id + " exists and is not a file"})
			return
		}
		replaced = true
	}
	// No chmod: on Synology that would replace the folder's inherited ACL with Unix permissions.
	a.own(tmp)
	if err := os.Rename(tmp, dst); err != nil {
		a.store.event("error", id, "moving the JPEG into place: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	tmp = ""
	syncDir(filepath.Dir(dst))
	a.store.st.Photos[id] = &Published{
		Source: source, Variant: variant, UUID: uuid, Fingerprint: strings.TrimSpace(fields["fingerprint"]),
		Bytes: size, PublishedAt: time.Now(),
	}
	kind := "published"
	if replaced {
		kind = "updated"
	}
	a.store.event(kind, id, "from %s (%s)", source, humanBytes(size))
	// The photo was published under another name before (it moved to another
	// folder in Lightroom, or its virtual copy was renamed): remove the old JPEG,
	// if this service wrote it for this same photo. A starred photo stays starred.
	_, starred := a.starred[id]
	if prev, err := cleanRel(previousID); err == nil && prev != id {
		if p, known := a.store.st.Photos[prev]; known && (p.UUID == "" || uuid == "" || p.UUID == uuid) {
			if _, ok := a.starred[prev]; ok {
				starred = true
			}
			if _, err := a.deleteLocked(prev, "replaced by "+id); err != nil {
				a.store.event("error", prev, "removing the old JPEG: %v", err)
			}
		}
	}
	// A new version is a new file: link the starred folder's copy to it again.
	if starred {
		a.relinkStarred(id)
	}
	a.flushStarred()
	if err := a.store.save(); err != nil {
		logf("ERROR", "saving state: %v", err)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id, "bytes": size, "replaced": replaced})
}

// resolveUploadSource checks rel and finds its RAW under SOURCE_DIR, spelled as
// on disk.
func (a *App) resolveUploadSource(rel string) (string, *uploadError) {
	source, err := cleanRel(rel)
	if err != nil {
		return "", uploadErr(http.StatusBadRequest, fmt.Errorf("rel: %v", err))
	}
	if a.inStarredDir(source) {
		return "", uploadErr(http.StatusConflict, fmt.Errorf(
			"%s is in a RAW folder named like the starred folder (STARRED_DIR=%s); rename one of them", source, a.cfg.StarredDir))
	}
	if onDisk, ok := resolveSource(a.cfg.SourceDir, source); ok {
		return onDisk, nil
	}
	if a.cfg.RequireSource {
		return "", uploadErr(http.StatusUnprocessableEntity, fmt.Errorf(
			"%s is not in the NAS photo folder. Check that the plugin's RAW folder setting is the Mac path of SOURCE_DIR", source))
	}
	return norm.NFC.String(source), nil
}

// receive streams the file part into a hidden temporary file in dir and returns
// its path; it never holds the whole JPEG in memory.
func (a *App) receive(part io.Reader, dir string) (string, int64, *uploadError) {
	if err := a.mkdirs(dir); err != nil {
		return "", 0, localErr(err)
	}
	br := bufio.NewReaderSize(part, 64<<10)
	head, err := br.Peek(3)
	if err != nil && len(head) < 3 {
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			return "", 0, uploadErr(http.StatusUnsupportedMediaType, errNotJPEG)
		}
		return "", 0, readErr(err)
	}
	if !bytes.Equal(head, []byte{0xFF, 0xD8, 0xFF}) {
		return "", 0, uploadErr(http.StatusUnsupportedMediaType, errNotJPEG)
	}
	// Mode 0666 like any new file (umask and the folder's ACL decide); os.CreateTemp's 0600
	// would make the JPEG private.
	var f *os.File
	for i := 0; i < 100; i++ {
		f, err = os.OpenFile(filepath.Join(dir, fmt.Sprintf("%s%d-%d.part", partPrefix, time.Now().UnixNano(), i)),
			os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
		if !errors.Is(err, os.ErrExist) {
			break
		}
	}
	if err != nil {
		return "", 0, localErr(err)
	}
	fw := &errWriter{w: f}
	n, err := io.Copy(fw, br)
	var ue *uploadError
	switch {
	case fw.err != nil:
		ue = localErr(fw.err)
	case err != nil:
		ue = readErr(err)
	}
	if ue == nil {
		if err := f.Sync(); err != nil {
			ue = localErr(err)
		}
	}
	if err := f.Close(); err != nil && ue == nil {
		ue = localErr(err)
	}
	if ue != nil {
		os.Remove(f.Name())
		return "", 0, ue
	}
	return f.Name(), n, nil
}

// errWriter remembers write errors, to tell the NAS's disk failing from the
// request failing.
type errWriter struct {
	w   io.Writer
	err error
}

func (e *errWriter) Write(p []byte) (int, error) {
	n, err := e.w.Write(p)
	if err != nil && e.err == nil {
		e.err = err
	}
	return n, err
}

type checkItem struct {
	Key         string `json:"key"`
	Rel         string `json:"rel"`
	Variant     string `json:"variant"`
	UUID        string `json:"uuid"`
	Fingerprint string `json:"fingerprint"`
}

type checkResult struct {
	ID      string `json:"id,omitempty"`
	Current bool   `json:"current"`
	Found   bool   `json:"found"` // the RAW is under SOURCE_DIR (always true with REQUIRE_SOURCE=false)
}

// handleCheck tells the plugin, before it renders anything, which photos are
// already published with the same fingerprint (Lightroom flags photos as
// modified now and then without a real change, and a new catalog or publish
// service starts with every photo unpublished), and which RAWs the NAS can't
// find (a wrong "RAW folder" setting).
func (a *App) handleCheck(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Items []checkItem `json:"items"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad check request: " + err.Error()})
		return
	}
	results := map[string]checkResult{}
	for _, it := range req.Items {
		source, err := cleanRel(it.Rel)
		if err != nil {
			results[it.Key] = checkResult{}
			continue
		}
		res := checkResult{Found: !a.cfg.RequireSource}
		if onDisk, ok := resolveSource(a.cfg.SourceDir, source); ok {
			source, res.Found = onDisk, true
		} else {
			source = norm.NFC.String(source)
		}
		variant := norm.NFC.String(strings.TrimSpace(it.Variant))
		a.mu.Lock()
		id, ok := a.store.idFor(source, variant, strings.TrimSpace(it.UUID))
		var p Published
		if ok {
			p = *a.store.st.Photos[id]
		}
		a.mu.Unlock()
		if ok {
			res.ID = id
			if fp := strings.TrimSpace(it.Fingerprint); fp != "" && fp == p.Fingerprint {
				fi, err := os.Stat(filepath.Join(a.cfg.ExportDir, filepath.FromSlash(id)))
				res.Current = err == nil && fi.Mode().IsRegular() && fi.Size() == p.Bytes
			}
		}
		results[it.Key] = res
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "results": results})
}

type deleteRequest struct {
	IDs    []string `json:"ids"`
	Reason string   `json:"reason"`
	// OnlyIfSourceGone: delete a JPEG only once its RAW has left SOURCE_DIR.
	// The plugin asks this for photos Lightroom shows outside the NAS photo
	// folder. If the Mac's view is wrong (the share came back under another
	// name, or the "RAW folder" setting doesn't match Lightroom's folders), the
	// RAWs are all still here, and their JPEGs must stay.
	OnlyIfSourceGone bool `json:"onlyIfSourceGone"`
}

// movedOutReason is the reason plugins send for a photo Lightroom shows outside
// the NAS photo folder.
const movedOutReason = "moved out of the NAS photo folder in Lightroom"

// handleDelete removes published JPEGs by id. Each id's result is "deleted",
// "missing" (already gone), "unknown" (not a JPEG this service wrote, so it is
// left alone), "kept" (onlyIfSourceGone, and the RAW is still in SOURCE_DIR or
// SOURCE_DIR can't be read), or an error message. The first three are final.
func (a *App) handleDelete(w http.ResponseWriter, r *http.Request) {
	var req deleteRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad delete request: " + err.Error()})
		return
	}
	why := strings.TrimSpace(req.Reason)
	if why == "" {
		why = "removed in Lightroom"
	}
	if why == movedOutReason {
		// The 1.1.0 plugin's moved-out deletes don't ask for the source check, but need it.
		req.OnlyIfSourceGone = true
	}
	results := map[string]string{}
	a.mu.Lock()
	defer a.mu.Unlock()
	// Fail closed: with SOURCE_DIR unreadable or empty, every RAW counts as still there.
	sourceOK := !req.OnlyIfSourceGone || dirHasEntries(a.cfg.SourceDir)
	kept := 0
	for _, id := range req.IDs {
		if req.OnlyIfSourceGone && (!sourceOK || a.sourceStillThere(id)) {
			results[id] = "kept"
			kept++
			continue
		}
		res, err := a.deleteLocked(id, why)
		if err != nil {
			a.store.event("error", id, "deleting: %v", err)
			res = "error: " + err.Error()
		}
		results[id] = res
	}
	if kept > 0 {
		logf("INFO", "kept %d JPEGs asked to go as %q: their RAWs are still in %s (or it can't be read)", kept, why, a.cfg.SourceDir)
	}
	a.flushStarred()
	if err := a.store.save(); err != nil {
		logf("ERROR", "saving state: %v", err)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "results": results})
}

// sourceStillThere reports whether the RAW a published JPEG was made from is
// still in SOURCE_DIR. Callers hold a.mu.
func (a *App) sourceStillThere(id string) bool {
	clean, err := cleanRel(id)
	if err != nil {
		return false
	}
	p, ok := a.store.st.Photos[clean]
	if !ok || p.Source == "" {
		return false
	}
	_, found := resolveSource(a.cfg.SourceDir, p.Source)
	return found
}

// dirHasEntries reports whether dir can be read and isn't empty.
func dirHasEntries(dir string) bool {
	f, err := os.Open(dir)
	if err != nil {
		return false
	}
	defer f.Close()
	names, _ := f.Readdirnames(1)
	return len(names) > 0
}

// deleteLocked removes the JPEG with this id and forgets it, but only a JPEG
// this service recorded writing: anything else in EXPORT_DIR is left alone.
// Callers hold a.mu.
func (a *App) deleteLocked(id, why string) (string, error) {
	clean, err := cleanRel(id)
	if err != nil {
		return "unknown", nil
	}
	id = clean
	if _, ok := a.store.st.Photos[id]; !ok {
		return "unknown", nil
	}
	full := filepath.Join(a.cfg.ExportDir, filepath.FromSlash(id))
	fi, err := os.Lstat(full)
	switch {
	case errors.Is(err, os.ErrNotExist):
		a.unstarLocked(id)
		delete(a.store.st.Photos, id)
		return "missing", nil
	case err != nil:
		return "", err
	case !fi.Mode().IsRegular():
		delete(a.store.st.Photos, id)
		return "unknown", nil
	}
	if err := os.Remove(full); err != nil {
		return "", err
	}
	if err := a.unstarLocked(id); err != nil {
		a.starFailure(id, fmt.Sprintf("removing it from %s: %v", a.cfg.StarredDir, err))
	}
	delete(a.store.st.Photos, id)
	a.store.event("deleted", id, "%s", why)
	a.removeEmptyDirs(filepath.Dir(full))
	return "deleted", nil
}

// owns reports whether a published record belongs to this photo. A RAW has one
// JPEG per copy name; virtual copies (which may share a copy name) are also told
// apart by their Lightroom uuid.
func owns(p *Published, source, variant, uuid string) bool {
	if p.Source != source || p.Variant != variant {
		return false
	}
	return variant == "" || p.UUID == "" || uuid == "" || p.UUID == uuid
}

// targetID picks the JPEG's path: the same as last time if this photo was
// published before, else <folder>/<name>[-<copy>].jpg, falling back to
// <name>-<ext>.jpg when that name is taken: by another photo (say DSCF0001.NEF
// next to DSCF0001.RAF), by one differing only in case or Unicode spelling (the
// same file for a Mac), or by a file this service didn't write. An unrecorded
// file at previousId is Lightroom's own earlier upload (the service's state was
// lost) and is taken over. Callers hold a.mu.
func (a *App) targetID(source, variant, uuid, previousID string) string {
	if p, ok := a.store.st.Photos[previousID]; ok && owns(p, source, variant, uuid) {
		return previousID
	}
	if id, ok := a.store.idFor(source, variant, uuid); ok {
		return id
	}
	for n := 0; ; n++ {
		id := outputID(source, variant, n)
		if p, ok := a.store.st.Photos[id]; ok {
			if owns(p, source, variant, uuid) {
				return id
			}
			continue
		}
		if a.store.foldTaken(id) {
			continue
		}
		if _, err := os.Lstat(filepath.Join(a.cfg.ExportDir, filepath.FromSlash(id))); err == nil && id != previousID {
			continue
		}
		return id
	}
}

func outputID(source, variant string, n int) string {
	dir, file := path.Split(source)
	ext := path.Ext(file)
	base := strings.TrimSuffix(file, ext)
	if variant != "" {
		base += "-" + safeName(variant)
	}
	tag := strings.ToLower(strings.TrimPrefix(ext, "."))
	if tag == "" {
		tag = "raw"
	}
	switch {
	case n == 1:
		base += "-" + tag
	case n > 1:
		base += fmt.Sprintf("-%s-%d", tag, n)
	}
	return dir + base + ".jpg"
}

// safeName makes a virtual copy name usable in a file name.
func safeName(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '/' || r == '\\' || r == ':' || unicode.IsControl(r):
			b.WriteRune('_')
		default:
			b.WriteRune(r)
		}
	}
	out := strings.Trim(b.String(), " .")
	if rs := []rune(out); len(rs) > 80 {
		out = string(rs[:80])
	}
	if out == "" {
		out = "copy"
	}
	return out
}

// cleanRel checks a path relative to SOURCE_DIR or EXPORT_DIR: "/"-separated,
// not absolute, no "..".
func cleanRel(p string) (string, error) {
	if strings.TrimSpace(p) == "" {
		return "", errors.New("empty path")
	}
	if strings.ContainsRune(p, 0) || strings.HasPrefix(p, "/") {
		return "", fmt.Errorf("%q is not a relative path", p)
	}
	for _, el := range strings.Split(p, "/") {
		if el == ".." {
			return "", fmt.Errorf("%q leaves its folder", p)
		}
	}
	c := path.Clean(p)
	if c == "." {
		return "", fmt.Errorf("%q is not a file", p)
	}
	return c, nil
}

// resolveSource finds rel under root and returns it spelled as on disk.
// Lightroom sees the share through macOS, which ignores case and may spell
// accented names in decomposed Unicode (NFD) where the NAS stores composed
// (NFC); each level falls back to a match that ignores both.
func resolveSource(root, rel string) (string, bool) {
	if fi, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); err == nil && fi.Mode().IsRegular() {
		return rel, true
	}
	dir := root
	parts := strings.Split(rel, "/")
	for i, p := range parts {
		name := ""
		if _, err := os.Lstat(filepath.Join(dir, p)); err == nil {
			name = p
		} else {
			entries, err := os.ReadDir(dir)
			if err != nil {
				return "", false
			}
			for _, e := range entries {
				if sameName(e.Name(), p) {
					name = e.Name()
					break
				}
			}
		}
		if name == "" {
			return "", false
		}
		parts[i] = name
		dir = filepath.Join(dir, name)
	}
	if fi, err := os.Stat(dir); err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	return strings.Join(parts, "/"), true
}

var errNotFolder = errors.New("exists and is not a folder")

func sameName(a, b string) bool {
	return strings.EqualFold(norm.NFC.String(a), norm.NFC.String(b))
}

// syncDir flushes a folder's entries, so a renamed-in JPEG survives a power cut.
func syncDir(dir string) {
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
}

// mkdirs creates dir and any missing parents inside EXPORT_DIR, giving each new
// folder the export folder's owner.
func (a *App) mkdirs(dir string) error {
	rel, err := filepath.Rel(a.cfg.ExportDir, dir)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("%s is outside EXPORT_DIR", dir)
	}
	cur := a.cfg.ExportDir
	for _, p := range strings.Split(rel, string(filepath.Separator)) {
		if p == "." || p == "" {
			continue
		}
		cur = filepath.Join(cur, p)
		err := os.Mkdir(cur, 0o777)
		switch {
		case err == nil:
			a.own(cur)
		case errors.Is(err, os.ErrExist):
			if fi, err := os.Stat(cur); err != nil || !fi.IsDir() {
				return fmt.Errorf("%s: %w", cur, errNotFolder)
			}
		default:
			return err
		}
	}
	return nil
}

// removeEmptyDirs removes dir and its parents up to EXPORT_DIR while they are
// empty.
func (a *App) removeEmptyDirs(dir string) {
	for {
		rel, err := filepath.Rel(a.cfg.ExportDir, dir)
		if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, "..") {
			return
		}
		if os.Remove(dir) != nil {
			return
		}
		dir = filepath.Dir(dir)
	}
}

func (a *App) own(p string) {
	if a.uid < 0 && a.gid < 0 {
		return
	}
	if err := os.Lchown(p, a.uid, a.gid); err != nil {
		logf("WARNING", "Can't give %s to %d:%d: %v", p, a.uid, a.gid, err)
	}
}

func humanBytes(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d bytes", n)
}
