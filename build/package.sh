#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:?repo root required}"
DEST="${2:?destination directory required}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/netbird" "$WORKDIR/on_boot.d" "$DEST"
for file in manage.sh common.sh netbird-env netbird-install.service netbird-install.timer on-boot.sh; do
  cp "$SOURCE/package/$file" "$WORKDIR/netbird/$file"
done
cp "$SOURCE/LICENSE" "$WORKDIR/netbird/LICENSE"
cp "$SOURCE/package/on-boot.sh" "$WORKDIR/on_boot.d/20-netbird.sh"
chmod 0755 "$WORKDIR/netbird/manage.sh" "$WORKDIR/netbird/on-boot.sh" "$WORKDIR/on_boot.d/20-netbird.sh"

tar czf "$DEST/netbird-unifi.tgz" -C "$WORKDIR" netbird on_boot.d --owner=0 --group=0
(cd "$DEST" && sha256sum netbird-unifi.tgz >netbird-unifi.tgz.sha256)
