package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
)

// Published is one JPEG this service wrote. Its id (the key in State.Photos) is
// the JPEG's path relative to EXPORT_DIR; the plugin stores it in Lightroom as
// the photo's remote id.
type Published struct {
	Source      string    `json:"source"`            // RAW path relative to SOURCE_DIR
	Variant     string    `json:"variant,omitempty"` // virtual copy name; "" for the master photo
	Fingerprint string    `json:"fingerprint,omitempty"`
	UUID        string    `json:"uuid,omitempty"` // Lightroom's id for the photo
	Bytes       int64     `json:"bytes"`
	PublishedAt time.Time `json:"publishedAt"`
}

type Event struct {
	Time    time.Time `json:"time"`
	Kind    string    `json:"kind"` // published, replaced, deleted, error
	ID      string    `json:"id,omitempty"`
	Message string    `json:"message,omitempty"`
}

type State struct {
	Version  int                   `json:"version"`
	ServerID string                `json:"serverId"` // new with every fresh state.json; tells the plugin to republish everything
	Photos   map[string]*Published `json:"photos"`
	Events   []Event               `json:"events"`
}

const maxEvents = 300

// Store keeps State in CONFIG_DIR/state.json. Callers hold App.mu.
type Store struct {
	path     string
	st       State
	uid, gid int // owner for state.json; -1 leaves it alone
}

func openStore(path string) (*Store, error) {
	s := &Store{path: path, st: State{Version: 1, Photos: map[string]*Published{}}, uid: -1, gid: -1}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &s.st); err != nil {
		return nil, fmt.Errorf("%s is damaged (%v); move it away to start over", path, err)
	}
	if s.st.Photos == nil {
		s.st.Photos = map[string]*Published{}
	}
	return s, nil
}

// ensureServerID gives a fresh state its id and saves it.
func (s *Store) ensureServerID() error {
	if s.st.ServerID != "" {
		return nil
	}
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return err
	}
	s.st.ServerID = hex.EncodeToString(buf)
	return s.save()
}

// save writes the state to a temporary file and renames it over state.json, so
// a crash never leaves a half-written file.
func (s *Store) save() error {
	b, err := json.MarshalIndent(&s.st, "", " ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".state-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if s.uid >= 0 || s.gid >= 0 {
		os.Lchown(tmp.Name(), s.uid, s.gid)
	}
	return os.Rename(tmp.Name(), s.path)
}

func (s *Store) event(kind, id, format string, args ...any) {
	e := Event{Time: time.Now(), Kind: kind, ID: id, Message: fmt.Sprintf(format, args...)}
	s.st.Events = append(s.st.Events, e)
	if n := len(s.st.Events); n > maxEvents {
		s.st.Events = append([]Event(nil), s.st.Events[n-maxEvents:]...)
	}
	level := "INFO"
	if kind == "error" {
		level = "WARNING"
	}
	if id != "" {
		logf(level, "%s %s: %s", kind, id, e.Message)
	} else {
		logf(level, "%s: %s", kind, e.Message)
	}
}

// idFor returns the id under which this photo is already published, if any.
func (s *Store) idFor(source, variant, uuid string) (string, bool) {
	for id, p := range s.st.Photos {
		if owns(p, source, variant, uuid) {
			return id, true
		}
	}
	return "", false
}

// foldTaken reports whether a recorded id other than id itself differs from it
// only in case or Unicode spelling: on a Mac both would be the same file.
func (s *Store) foldTaken(id string) bool {
	key := strings.ToLower(norm.NFC.String(id))
	for other := range s.st.Photos {
		if other != id && strings.ToLower(norm.NFC.String(other)) == key {
			return true
		}
	}
	return false
}
