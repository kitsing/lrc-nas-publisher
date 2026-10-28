# NAS Publisher for Lightroom Classic

Keep a folder of JPEGs on your NAS in step with your Lightroom Classic edits, without ever pressing
Export. Your RAWs live on the NAS; you edit them in Lightroom on your Mac. About a minute after you
stop editing a photo, its JPEG appears on the NAS, in the same folders as the RAW. Edit it again
and the JPEG is replaced; reset it and the JPEG goes away.

    Lightroom Classic (Mac) ──renders──▶ plugin ──HTTP──▶ lrc-nas-publisher (Docker on the NAS)
       edits RAWs in                                       files JPEGs in
       /volume1/photo/RAW/2026/Trip/DSCF0001.RAF            /volume1/photo/exported/2026/Trip/DSCF0001.jpg

## Why it's built this way

Only Adobe's Camera Raw engine renders Lightroom edits faithfully. Nothing on Linux reproduces it
(darktable reads a small part of Lightroom's XMP: no white balance, tone sliders, profiles or
masks). So **Lightroom renders, and the NAS publishes**:

- **`plugin/NASPublisher.lrplugin`**: a Lightroom Classic publish service with an "Edited RAWs"
  smart collection, plus a background loop that publishes once edits settle. It runs only while
  Lightroom is open; nothing happens otherwise.
- **`container/`**: a small Go service (Docker) on the NAS that receives each JPEG and writes it
  atomically into the export folder. It remembers what it published and never touches files it
  didn't write. It also finds RAWs whose XMP sidecars carry edits so the plugin can add them to
  the catalog.

The export folder can then feed whatever comes next: Synology Photos, an album sync, a backup.

## Features

- Publishes automatically while Lightroom runs, about a minute after the last edit to a photo
  (configurable). It publishes anyway after 10 minutes of continuous editing.
- Mirrors the RAW folder tree. Virtual copies, name clashes (`DSCF0001.RAF` + `DSCF0001.NEF`) and
  Unicode/case differences between macOS and the NAS are handled.
- Removes the JPEG when a photo's edits are reset, it's moved out of the RAW folder or it leaves the
  collection. Republishes at the new path when the RAW moves.
- Skips photos Lightroom flags as modified without a real change, using an edit fingerprint.
- Never publishes a low-resolution smart-preview render if the share drops mid-publish.
- Optionally adds RAWs with edited `.xmp` sidecars that aren't in the catalog yet, so edits made
  elsewhere get published too.
- No dialogs during automatic publishes. Problems show in **Library → Plug-in Extras → NAS
  Publisher: Status…**, in the plugin log, and on the container's status page.

## Set up

1. **NAS:** run the container. See [`container/README.md`](container/README.md) (Synology
   Container Manager or any Docker host).
2. **Mac:** install the plugin and set up the publish service. See
   [`plugin/README.md`](plugin/README.md).

Requirements: Lightroom Classic on macOS (developed on 15.6), the NAS's RAW folder mounted on the
Mac over SMB, and Docker on the NAS. Windows is untested and its paths aren't handled.

## Tests

- `cd container && go test ./...`: the service.
- `sh plugin/tests/run_harness.sh`: the plugin's Lua on a fake Lightroom SDK, against the real
  container in Docker (21 scenarios).
- `plugin/tests/*_test.lua`: unit tests, run with Lua 5.1.

CI runs all three on every push.

## Prior art

[crowlKats/lightroom-catalog-publisher](https://github.com/crowlKats/lightroom-catalog-publisher)
showed the background auto-publish loop with an edit-settling delay. That repo has no license, so
no code was taken from it, only the idea. Jeffrey Friedl's Folder Publisher and Bag-o-Goodies
("Publish Continuously") cover parts of this as closed-source plugins.

## License

[MIT](LICENSE)
