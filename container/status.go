package main

import (
	"html/template"
	"net/http"
	"time"
)

// The status page needs no token: it shows file names and activity, never the
// token or photos.
var statusTmpl = template.Must(template.New("status").Funcs(template.FuncMap{
	"ago": func(t time.Time) string {
		if t.IsZero() {
			return "never"
		}
		d := time.Since(t).Round(time.Second)
		switch {
		case d < time.Minute:
			return d.String() + " ago"
		case d < time.Hour:
			return d.Round(time.Minute).String() + " ago"
		case d < 48*time.Hour:
			return d.Round(time.Hour).String() + " ago"
		}
		return t.In(logLocation).Format("2006-01-02 15:04")
	},
	"when": func(t time.Time) string { return t.In(logLocation).Format("Jan 2 15:04:05") },
}).Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>NAS Publisher</title>
<style>
:root{--bg:#fafaf9;--fg:#1c1917;--muted:#78716c;--line:#e7e5e4;--ok:#15803d;--warn:#b45309;--err:#b91c1c}
@media (prefers-color-scheme: dark){:root{--bg:#1c1917;--fg:#f5f5f4;--muted:#a8a29e;--line:#44403c;--ok:#4ade80;--warn:#fbbf24;--err:#f87171}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:900px;padding:24px 16px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 8px}
.muted{color:var(--muted)}.ok{color:var(--ok)}.warn{color:var(--warn)}.error{color:var(--err)}
dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:0}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere}
table{border-collapse:collapse;width:100%;font-size:13px}td{border-top:1px solid var(--line);padding:5px 8px 5px 0;vertical-align:top;overflow-wrap:anywhere}
td:first-child{white-space:nowrap;color:var(--muted)}
</style></head><body>
<h1>NAS Publisher</h1>
<p class="muted">Lightroom Classic renders edited RAWs; this NAS files the JPEGs. Refreshes every 30 s.</p>
<dl>
<dt>Lightroom</dt><dd>{{if .Online}}<span class="ok">online</span>{{else}}<span class="muted">offline — nothing to do until it's back</span>{{end}}
 · last contact {{ago .LastSeen}}{{if .Host}} from {{.Host}}{{end}}{{if .PluginVersion}} (plugin {{.PluginVersion}}){{end}}</dd>
{{if .Catalog}}<dt>Catalog</dt><dd>{{.Catalog}}</dd>{{end}}
<dt>Published</dt><dd>{{.Published}} JPEGs</dd>
<dt>RAW folder</dt><dd>{{.SourceDir}}</dd>
<dt>JPEG folder</dt><dd>{{.ExportDir}}</dd>
<dt>Sidecar scan</dt><dd>{{if .Scan.Running}}running…{{else if .Scan.At.IsZero}}not yet (runs while Lightroom is online){{else}}{{ago .Scan.At}}: {{len .Scan.Items}} of {{.Scan.Raws}} RAWs have edited XMP sidecars{{end}}{{if .Scan.Err}} <span class="error">{{.Scan.Err}}</span>{{end}}</dd>
</dl>
<h2>Recent activity</h2>
{{if .Events}}<table>{{range .Events}}<tr><td>{{when .Time}}</td><td class="{{.Kind}}">{{.Kind}}</td><td>{{.ID}}{{if .Message}} <span class="muted">— {{.Message}}</span>{{end}}</td></tr>{{end}}</table>
{{else}}<p class="muted">Nothing yet.</p>{{end}}
<p class="muted">lrc-nas-publisher {{.Version}}</p>
</body></html>
`))

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	a.scanner.mu.Lock()
	scan := a.scanner.snap
	a.scanner.mu.Unlock()
	a.mu.Lock()
	events := make([]Event, 0, 60)
	for i := len(a.store.st.Events) - 1; i >= 0 && len(events) < 60; i-- {
		events = append(events, a.store.st.Events[i])
	}
	data := map[string]any{
		"Online": a.isOnline(time.Now()), "LastSeen": a.online.at, "Host": a.online.host,
		"PluginVersion": a.online.version, "Catalog": a.online.catalog,
		"Published": len(a.store.st.Photos), "SourceDir": a.cfg.SourceDir, "ExportDir": a.cfg.ExportDir,
		"Scan": scan, "Events": events, "Version": version,
	}
	a.mu.Unlock()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	statusTmpl.Execute(w, data)
}
