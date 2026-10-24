#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

download_dir="$PXE_DATA_MOUNT/downloads"
mountpoint -q "$PXE_DATA_MOUNT" || die "$PXE_DATA_MOUNT n'est pas monté."
install -d -m 0755 "$download_dir"

while IFS='|' read -r enabled id type filename url sha label; do
  [[ "$enabled" == "yes" ]] || continue
  target="$download_dir/$filename"
  log "Téléchargement de $label"
  if [[ ! -f "$target" ]]; then
    curl --fail --location --continue-at - --output "$target.part" "$url"
    mv "$target.part" "$target"
  fi
  printf '%s  %s\n' "$sha" "$target" | sha256sum -c -
done < <(enabled_media)

echo "Tous les médias activés sont téléchargés et vérifiés."
