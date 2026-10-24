#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${PXE_CONFIG_FILE:-$PROJECT_ROOT/config/pxe.env}"
MEDIA_FILE="${PXE_MEDIA_FILE:-$PROJECT_ROOT/config/media.conf}"

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
require_root() { [[ ${EUID} -eq 0 ]] || die "Cette commande doit être exécutée avec sudo."; }
require_command() { command -v "$1" >/dev/null || die "Commande absente : $1"; }

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Configuration absente : $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${PXE_HOSTNAME:?}" "${PXE_INTERFACE:?}" "${PXE_ADDRESS_CIDR:?}"
  : "${PXE_GATEWAY:?}" "${PXE_DNS:?}" "${PXE_SUBNET_CIDR:?}"
  : "${PXE_DATA_DISK:?}" "${PXE_DATA_PARTITION:?}" "${PXE_DATA_MOUNT:?}"
  : "${PXE_HTTP_ROOT:?}" "${PXE_TFTP_ROOT:?}" "${PXE_NFS_MOUNT_ROOT:?}" "${PXE_BUILD_ROOT:?}"
  PXE_IP="${PXE_ADDRESS_CIDR%/*}"
}

enabled_media() {
  [[ -f "$MEDIA_FILE" ]] || die "Catalogue absent : $MEDIA_FILE"
  awk -F '|' 'NF >= 7 && $1 == "yes" && $0 !~ /^[[:space:]]*#/ {print}' "$MEDIA_FILE"
}

safe_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Identifiant invalide : $1"; }
