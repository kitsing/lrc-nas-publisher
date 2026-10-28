#!/bin/sh
# Runs tests/harness.lua: the plugin's Lua on a fake Lightroom SDK, against a real
# lrc-nas-publisher container. Needs docker (with colima, a bind-mounted folder must be under $HOME).
#
#   tests/run_harness.sh                 all scenarios
#   ONLY=2,3 tests/run_harness.sh        some of them (later ones build on 2)
#   VERBOSE=1 tests/run_harness.sh       with HTTP/SDK traces, the plugin's log and the container's
#   IMAGE=local/lrc-nas-publisher:test   the container image (build it from container/ first)
#   NAS_FS=bind                          put /nas in $HOME/.lrc-harness/run-* instead of a docker
#                                        volume. Note: on macOS that folder is case- and Unicode-
#                                        normalization-insensitive, unlike a NAS's ext4/btrfs, so the
#                                        NFD scenario can't show what happens on a real NAS.
#   KEEP=1                               keep the volume / folder for a look afterwards
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(dirname "$HERE")
IMAGE=${IMAGE:-local/lrc-nas-publisher:test}
ID=$$
NET="lrc-harness-net-$ID"
NAS="lrc-harness-nas-$ID"
TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
if [ "${NAS_FS:-volume}" = bind ]; then
	WORK="$HOME/.lrc-harness/run-$ID"
	mkdir -p "$WORK"
	MOUNT="$WORK"
else
	WORK="lrc-harness-vol-$ID"
	docker volume create "$WORK" >/dev/null
	MOUNT="$WORK"
fi

cleanup() {
	docker rm -f "$NAS" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	if [ "${KEEP:-}" = 1 ]; then
		echo "kept: $WORK"
	elif [ "${NAS_FS:-volume}" = bind ]; then
		# Files the containers wrote may belong to root inside the VM.
		docker run --rm -v "$HOME/.lrc-harness":/w alpine:3.24 rm -rf "/w/run-$ID" >/dev/null 2>&1 || rm -rf "$WORK"
	else
		docker volume rm "$WORK" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT INT TERM

docker run --rm -v "$MOUNT":/nas alpine:3.24 mkdir -p /nas/source /nas/export /nas/config
docker network create "$NET" >/dev/null
# The same folders at the same paths in both containers: the plugin's "RAW folder on this Mac"
# is /nas/source, which is also the container's SOURCE_DIR.
docker run -d --name "$NAS" --network "$NET" \
	-e TOKEN="$TOKEN" -e SOURCE_DIR=/nas/source -e EXPORT_DIR=/nas/export -e CONFIG_DIR=/nas/config \
	-e SCAN_INTERVAL_MINUTES=0.05 \
	-v "$MOUNT":/nas "$IMAGE" >/dev/null

set +e
docker run --rm --network "$NET" \
	-e NAS_URL="http://$NAS:8765" -e NAS_TOKEN="$TOKEN" -e NAS_CONTAINER="$NAS" -e NAS_ROOT=/nas \
	-e VERBOSE="${VERBOSE:-}" -e ONLY="${ONLY:-}" \
	-v "$MOUNT":/nas -v "$PLUGIN_ROOT":/p:ro -v /var/run/docker.sock:/var/run/docker.sock \
	alpine:3.24 sh -c 'apk add -q lua5.1 curl >/dev/null && lua5.1 /p/tests/harness.lua /p/NASPublisher.lrplugin'
STATUS=$?
set -e
if [ "${VERBOSE:-}" = 1 ]; then
	echo "--- container log"
	docker logs "$NAS" 2>&1 | tail -200
fi
exit $STATUS
