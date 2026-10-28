# lrc-nas-publisher (the NAS side)

A small HTTP service in Docker. It receives the JPEGs that the **NAS Publisher** Lightroom Classic
plugin renders from edited RAWs, and files them in an export folder, in the same folders as the
RAWs:

    /source/DCIM/100_FUJI/DSCF4742.RAF   (your RAWs, mounted read-only)
    /export/DCIM/100_FUJI/DSCF4742.jpg   (the published JPEG)

- **Idle without Lightroom:** only Lightroom can render Lightroom edits faithfully (nothing on
  Linux reproduces Camera Raw). So when the Mac is off or Lightroom is closed, the service just
  waits: it reads nothing and writes nothing.
- **XMP sidecars:** while Lightroom is online, and if the plugin's sidecar option is on, it lists
  RAWs whose `.xmp` sidecar holds Camera Raw edits. The plugin adds the ones the catalog lacks.
- **Safe writes:** a JPEG is received into a hidden `.lrc-upload-*.part` file in its own folder
  and renamed into place, so a half-written file is never visible. New files and folders get the
  export folder's owner. The service never `chmod`s, so Synology ACLs keep working.
- **Never touches other files:** it overwrites or deletes only JPEGs it recorded writing. If a file
  it didn't write is already at a JPEG's path (say an earlier manual export), the new JPEG gets a
  suffix instead (`-raf`, `-nef`, …).
- **Unchanged photos aren't re-sent:** each JPEG's edit fingerprint is stored. When Lightroom
  flags a photo as modified but nothing changed, the plugin skips rendering and uploading it.
- **A starred album:** `/export/starred/` holds every published photo rated at or above the
  plugin's *Starred folder* setting (1 star by default), in one flat folder that galleries show as
  one album. Each file there is a hard link to the published JPEG: an ordinary file to every app,
  using no extra space. Rating changes in Lightroom show up within about 30 seconds, with no
  re-rendering; a republished photo's link follows the new version. Where hard links aren't
  possible, copies are made instead. What the service put in that folder is recorded in
  `/export/.lrc-starred.json` (by inode), so it survives a lost `state.json`, and files someone
  else put there or replaced are never touched. Name clashes get a short suffix
  (`DSCF0001-1a2b3c4d.jpg`).

## Set it up on a Synology (DSM 7.2+, Container Manager)

1. **Copy this folder** to the NAS, e.g. `docker/projects/lrc-nas-publisher`, and create an empty
   `config` folder inside it in File Station. It is then yours: the token the service writes there
   on first start stays readable over SMB.
2. **Edit `compose.yaml`:** the two paths marked *CHANGE ME* (your RAW folder and the export folder,
   which must exist), and `TZ`.
3. **Create the project:** Container Manager → **Project → Create**. Use the name
   `lrc-nas-publisher` and that folder as the path. Choose *Use existing docker-compose.yml*,
   then **Next** and **Done**. The build takes a few minutes; Synology's builder is slow on
   steps like `HEALTHCHECK`, which is normal. Over SSH instead:
   `cd /volume1/docker/projects/lrc-nas-publisher && sudo docker compose up -d --build`
4. **Check it:** open `http://<your-nas>:8765/`. The status page should say *Lightroom offline*.
   If it doesn't load and the DSM firewall is on, allow TCP port 8765 from your LAN
   (**Control Panel → Security → Firewall → Edit Rules**).
5. **Set up the plugin** in Lightroom (see `../plugin/README.md`). It reads the token from
   `config/token` over the mounted `docker` share. If your Mac doesn't mount that share, show the
   token with Container Manager → **Container** → `lrc-nas-publisher` → **Terminal** →
   `lrc-nas-publisher token`, and paste it into the plugin's settings.

Any other Docker host works the same: mount your RAW folder at `/source` (read-only) and the
export folder at `/export`, and publish port 8765.

**Logs:** Container Manager → **Container** → `lrc-nas-publisher` → **Log**. The status page shows
the same activity, plus whether Lightroom is online.

## Settings (environment variables in compose.yaml)

| Variable | Default | Meaning |
|---|---|---|
| `TZ` | `UTC` | Time zone for log and status times. |
| `SCAN_INTERVAL_MINUTES` | `10` | How stale the sidecar scan may get while Lightroom is online. |
| `ONLINE_WINDOW_MINUTES` | `3` | How long after Lightroom's last contact it still counts as online. |
| `MAX_UPLOAD_MB` | `1024` | Largest JPEG accepted. |
| `REQUIRE_SOURCE` | `true` | Refuse JPEGs whose RAW isn't under `/source`. This catches a wrong "RAW folder on this Mac" setting in the plugin. |
| `EXCLUDE` | `@*,#recycle,#snapshot,.*,*.lrlibrary,*.lrdata,*.photoslibrary,*.lrcat-data` | Names skipped by the sidecar scan. |
| `STARRED_DIR` | `starred` | Folder in `/export` for starred photos; `off` turns it off. Renaming or turning it off removes the links the service made in the old folder at the next start. A RAW folder with the same name is refused. |
| `PUID` / `PGID` | owner of `/export` | Owner given to new JPEGs and folders. |
| `TOKEN` | contents of `/config/token` | Access token. If neither is set, a token is created in `/config/token`. |

## How it works

| Request | Purpose |
|---|---|
| `POST /api/hello` | Plugin heartbeat. Lightroom counts as online for `ONLINE_WINDOW_MINUTES` afterwards. Answers with the version, server id and `features` this container understands. |
| `POST /api/photos` | One rendered JPEG (multipart). Answers with its id, its path under `/export`, which Lightroom stores. |
| `POST /api/check` | Which photos are already published with the same edit fingerprint (skipped), and which RAWs the service can't find. |
| `POST /api/delete` | Remove JPEGs by id, when photos leave the published collection. With `onlyIfSourceGone` (photos Lightroom shows outside the RAW folder), a JPEG goes only once its RAW has left `/source`; otherwise, or if `/source` can't be read, the answer is `kept`. |
| `POST /api/starred` | The starred ids (and the sender's scope: every id it publishes); the starred folder follows. |
| `GET /api/sidecars` | RAWs with edited `.xmp` sidecars. Scans `/source` only while Lightroom is online. |
| `GET /` | Status page (no token needed; shows file names, never photos or the token). |

Every `/api` request needs `Authorization: Bearer <token>`. `config/state.json` records what's
published and holds a server id. If it's lost, the service starts with a new id. The plugin
notices that and publishes everything again, taking over the JPEGs Lightroom wrote before at the
same paths, so nothing duplicates.

Upload errors say whose problem it is. A 4xx answer means the photo or the plugin's settings (not
a JPEG, a RAW the service can't find, a file in the way of a folder), and the plugin leaves that
photo until it's edited again. A 5xx answer means the NAS (507 = disk full), and the plugin
retries after 1, 5, 30 and then every 120 minutes.

**Name clashes:** a virtual copy becomes `NAME-<copy name>.jpg`. Two RAWs with the same name in
one folder (say `DSCF0001.RAF` and `DSCF0001.NEF`) become `DSCF0001.jpg` and `DSCF0001-nef.jpg`.
The same goes for names that differ only in case or Unicode spelling (one file to a Mac), and for
two virtual copies with the same copy name.

## Development

`go test ./...` covers uploads, replacement, moves, deletes, name clashes, files it didn't write,
state loss, error codes, Unicode (NFD/NFC) names, the fingerprint check and the sidecar scan.
`golang.org/x/text` is vendored (`go mod vendor`), so building the image downloads only the base
images.
