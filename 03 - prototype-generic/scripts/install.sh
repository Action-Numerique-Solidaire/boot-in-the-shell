#!/usr/bin/env bash
# Enchaînement complet depuis le dépôt, sans le paquet. Le paquet passe par
# « bitsctl apply », qui joue les mêmes étapes et les journalise.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
mode="${1:-}"

case "$mode" in
  ""|--reuse-data-disk)
    "$script_dir/00-validate-config.sh"
    "$script_dir/10-install-prerequisites.sh"
    ;;
  --prepare-data-disk)
    "$script_dir/00-validate-config.sh"
    "$script_dir/10-install-prerequisites.sh"
    "$script_dir/20-prepare-data-disk.sh" ERASE-PXE-DATA
    ;;
  *)
    echo "Usage : sudo $0 [--prepare-data-disk]" >&2
    echo "ATTENTION : --prepare-data-disk efface entièrement PXE_DATA_DISK." >&2
    exit 2
    ;;
esac

"$script_dir/30-configure-network.sh"
"$script_dir/40-download-media.sh"
"$script_dir/50-build-ipxe.sh"
"$script_dir/60-publish-media.sh"
"$script_dir/70-enable-and-validate.sh"

echo "Installation terminée. Effectuer maintenant un démarrage PXE réel."
