# NAS Publisher (Lightroom Classic plugin)

A publish service that renders your edited RAWs and hands the JPEGs to the `lrc-nas-publisher`
container on the NAS. While Lightroom runs, it publishes by itself. You never press Export or
Publish.

Requirements: Lightroom Classic on macOS (developed on 15.6, SDK 10 or later; Windows is untested
and its paths aren't handled), with the RAWs on the NAS mounted over SMB, and the container
running on the NAS (see `../container/README.md`).

## Install

1. Copy `NASPublisher.lrplugin` to `~/Library/Application Support/Adobe/Lightroom/Modules/`, or
   add it in **File → Plug-in Manager → Add**.
2. Restart Lightroom, or click **Reload Plug-in** in the Plug-in Manager.
3. In the **Publish Services** panel (Library, left side), click **Set Up…** next to
   **NAS Publisher**, or **+ → Go to Publishing Manager**, then fill in:
   - **NAS service:** `http://<your-nas>:8765`, e.g. `http://nas.local:8765`
   - **Access token:** leave it empty if the Mac mounts the NAS's `docker` share; the plugin then
     reads the container's token from `/Volumes/docker/projects/lrc-nas-publisher/config/token`
     (or `/Volumes/docker/lrc-nas-publisher/config/token`,
     `/Volumes/home/lrc-nas-publisher/config/token`). Otherwise paste the token.
   - **RAW folder on this Mac:** the container's `/source` folder as the Mac sees it, e.g.
     `/Volumes/photo/RAW`
   - **Publish automatically:** on. The defaults are full-size sRGB JPEG at quality 90, and you
     can change them in the usual File Settings, Image Sizing, Output Sharpening and Metadata
     sections.

   Click **Test Connection**, then **Save**. If macOS asks whether Lightroom may find devices on
   your local network, allow it.

## What happens then

- Within 30 seconds the service gets an **Edited RAWs** smart collection: Raw or DNG photos that
  have adjustments or a crop. You can edit its rules, for example to add *Pick Flag is Flagged*.
  Photos outside the RAW folder are listed there but never published.
- About a minute after your last edit to a photo (**settle** time), the plugin publishes it:
  Lightroom renders it, and the container saves it as
  `<export folder>/<same folders>/<name>.jpg`. If you keep editing without a pause, it publishes
  after 10 minutes anyway.
- Edit a published photo and it is published again. Reset it, so that it leaves the smart
  collection, and its JPEG is deleted.
- **Hand-picked** is an ordinary collection for photos you want on the NAS without editing them.
- **Starred folder:** published photos rated at or above the service's *Starred folder* setting
  (1 star by default; *Off* turns it off) also appear in `starred/` on the NAS, as one album.
  Changing a rating updates it within about 30 seconds without re-rendering anything. Only
  published photos (edited or hand-picked) count, and only while auto-publish is on.
- Every 10 minutes, while you aren't editing, the plugin asks the NAS for RAWs whose `.xmp`
  sidecar has edits. It adds the ones your catalog lacks to the catalog, and to the **Added by NAS
  Publisher** collection, and Lightroom applies their sidecar edits. Each sidecar version is added
  once: remove such a photo from the catalog and it stays out until its sidecar changes. Turn this
  off with **Add RAWs that have edits in XMP sidecars** in the service settings.
- When the NAS isn't mounted or the container doesn't answer, nothing happens and nothing pops up.
  Photos wait in the queue.

**Library → Plug-in Extras → NAS Publisher: Status…** shows what the plugin is doing.
**…: Publish Now** publishes everything pending right away. The log is
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/NASPublisher.log`. The container's status page is
`http://<your-nas>:8765/`.

## Notes

- Automatic publishes never show dialogs. A photo that fails because of itself (an unreadable
  file, a RAW the NAS can't find) is skipped until you edit it again. One that fails because of
  the NAS (a full disk) is retried after 1, 5, 30 and then every 120 minutes. Status counts both.
  A manual Publish click or **Publish Now** tells you what went wrong.
- Before uploading, the plugin checks that the original is still there and that the JPEG has the
  original's size. If the share dropped mid-publish, Lightroom would otherwise quietly render from
  the smart preview (about 2560 px); such a render is thrown away and the photo waits.
- If the NAS can't find the RAWs (the **RAW folder on this Mac** setting doesn't match the
  container's folder), nothing is rendered and Status says so.
- Lightroom sometimes marks photos as *Modified* without a real change. The container remembers
  each JPEG's edit fingerprint, so such photos leave the queue without being rendered or uploaded
  again.
- Moving a RAW to another folder in Lightroom republishes it at the new path and removes the old
  JPEG. Moving it out of the RAW folder removes its JPEG. Renaming a virtual copy renames its JPEG.
- Removing a published photo from the catalog: Lightroom asks whether to delete it from the
  service too.
- HDR edits are published as SDR JPEGs unless you turn on **HDR Output** (and **Maximize
  Compatibility**) under File Settings in the service settings. That writes JPEGs with an HDR gain
  map: HDR-capable viewers show HDR, others the SDR image. Changing it republishes every photo.

## Development

The plugin is plain Lua 5.1. `tests/run_harness.sh` runs it on a fake Lightroom SDK
(`tests/fake_lrsdk.lua`) against the real container in Docker: 23 scenarios covering settling,
republishing, removals, the NAS going away, wrong settings, smart-preview renders, sidecar
imports, Unicode paths, and plugin reloads (including one mid-publish). The fake follows the documented SDK behavior; where the
real SDK surprised us (`exportSession:photosToExport()` returns an iterator), the fake was fixed
to match. `tests/*_test.lua` are unit tests (`lua5.1 tests/json_test.lua NASPublisher.lrplugin`).
