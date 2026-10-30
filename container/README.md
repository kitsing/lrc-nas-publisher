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
- **Immich (optional):** if [Immich](https://immich.app) indexes the export folder as an external
  library, the service asks it to scan after JPEGs are published or removed, so they show up in
  Immich within a minute instead of after its nightly scan. See [Immich](#immich-optional).

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
| `IMMICH_URL` | unset (off) | Immich's address, e.g. `http://host.docker.internal:2283`. See [Immich](#immich-optional). |
| `IMMICH_API_KEY` | unset | An Immich admin's API key with the `library.read` and `library.update` permissions. |
| `IMMICH_LIBRARY_ID` | unset (Immich's only library) | The Immich library to scan, when it has more than one. |

## Immich (optional)

[Immich](https://immich.app) can show the export folder as an *external library*, mounted
read-only; it then indexes the JPEGs where they are. On its own, Immich looks for new and changed
files only once a night. With these settings the service asks Immich to scan that library once
publishing pauses for 30 seconds (and every 3 minutes during a long publish). Immich then imports
new JPEGs, re-reads replaced ones (the photo keeps its favorites and albums) and moves removed ones
to its trash.

1. **Give Immich the export folder,** if it doesn't have it yet. In Immich's `compose.yaml`, mount
   the folder read-only on `immich-server`, e.g.
   `- /volume1/photo/exported:/mnt/exported_photos:ro`. Then, as the admin, add it under
   **Administration → External Libraries → Create Library**, with the folder `/mnt/exported_photos`
   and the exclusion pattern `/mnt/exported_photos/starred/**` (see *The starred folder* below).
2. **Create an API key in Immich,** signed in as the admin: **Account Settings → API Keys → New
   API Key**. Name it `NAS Publisher` and give it only the `library.read` and `library.update`
   permissions. Immich shows the key once, so copy it before closing the window.
3. **Turn the settings on in this service's `compose.yaml`:** uncomment the two `extra_hosts` lines
   and the `IMMICH_URL` and `IMMICH_API_KEY` lines, and paste the key between the quotes. They
   then read:

   ```yaml
       extra_hosts:
         - host.docker.internal:host-gateway
   ```

   ```yaml
         IMMICH_URL: http://host.docker.internal:2283
         IMMICH_API_KEY: "the key you copied"
   ```

   `host.docker.internal` is the NAS itself, as the container sees it. For Immich on another
   machine, use that machine's IP address instead (containers can't look up `.local` names).
   Don't use an address behind a login, such as a Cloudflare Access domain, or Immich's https
   address with a self-signed certificate; the status page says so if you do.
4. **If Immich has more than one external library,** also uncomment `IMMICH_LIBRARY_ID` and set it
   to the export folder's library. The status page lists each library's id when it's needed; it's
   also the last part of the library page's address under **Administration → External Libraries**.
   Only that library is scanned, so large unrelated ones aren't crawled every few minutes.
5. **Build** the project again. The service asks Immich for a scan at start, so within about 30
   seconds the status page's *Immich* line should say
   `asked to scan "…" (/mnt/exported_photos)`, naming the export folder's library.

**When something's wrong,** the status page's *Immich* line says what, and so does the log. Nothing
is lost: the JPEGs wait for the next scan that works, and Immich's own nightly scan catches up on
anything missed. An Immich problem never stops publishing.
- **Immich down, restarting or in maintenance mode** (or a wrong port, which looks the same): tried
  again after 1, 5 and 30 minutes, then every 30 minutes.
- **A wrong key, permission, library, host name or address:** tried again at the next publish, or
  after 30 minutes if you fix it in Immich.

**Can't reach Immich?**
- *can't find host.docker.internal:* the `extra_hosts` lines are missing.
- *can't reach Immich:* is it running, on that port? If DSM's firewall is on, it may block
  containers from the NAS's own ports. In **Container Manager → Network**, look up the subnet of
  `lrc-nas-publisher_default` (for example `172.20.0.0/16`), then in **Control Panel → Security →
  Firewall → Edit Rules** allow TCP port 2283 from that subnet.

**The starred folder** holds second copies (hard links) of published JPEGs, so have Immich skip it,
or it shows every starred photo twice. Anchor the exclusion pattern to the path you gave Immich, as
in step 1, and use your `STARRED_DIR` name if you changed it. The shorter `**/starred/**` works
too, but it also skips every deeper folder called `starred`, in any letter case (Immich ignores
case), such as a RAW folder `Trips/Starred`. Changes in the starred folder don't ask for a scan.

**Ratings:** Immich reads a photo's stars from its JPEG, as last published, and shows them once
**Star rating** is on under **Account Settings → Features**. The JPEG carries the rating unless the
publish service's **Metadata** is set to *Copyright Only*. Changing only the rating in Lightroom
updates the starred folder without re-rendering the photo, so Immich shows the new rating once the
photo is next edited and republished.

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
state loss, error codes, Unicode (NFD/NFC) names, the fingerprint check, the sidecar scan and the
Immich scan requests (against a fake Immich).
`golang.org/x/text` is vendored (`go mod vendor`), so building the image downloads only the base
images.
