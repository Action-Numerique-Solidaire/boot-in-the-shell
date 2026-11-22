#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${PXE_CONFIG_FILE:-$PROJECT_ROOT/config/pxe.env}"
MEDIA_FILE="${PXE_MEDIA_FILE:-$PROJECT_ROOT/config/media.conf}"

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
require_root() { [[ ${EUID} -eq 0 ]] || die "Cette commande doit être exécutée avec sudo."; }
require_command() { command -v "$1" >/dev/null || die "Commande absente : $1"; }

# Le réseau est celui que le système a déjà configuré : rien n'est écrit, tout
# est lu sur l'interface active. Chaque valeur peut être imposée dans pxe.env.
#
#   interface : celle de la route par défaut, sinon la première qui porte une
#               adresse IPv4 globale ;
#   adresse   : la première adresse IPv4 globale de cette interface ;
#   sous-réseau : déduit de l'adresse.
#
# L'ancien modèle exigeait une adresse statique écrite à la main, puis
# réécrivait Netplan pour l'imposer : sur une machine réelle, toute
# divergence entre le fichier et le réseau arrêtait l'installation.
derive_network() {
  if [[ -z "${PXE_INTERFACE:-}" ]]; then
    PXE_INTERFACE="$(ip -4 route show default 2>/dev/null \
      | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  fi
  if [[ -z "${PXE_INTERFACE:-}" ]]; then
    PXE_INTERFACE="$(ip -4 -o addr show scope global 2>/dev/null | awk '{ print $2; exit }')"
  fi
  [[ -n "${PXE_INTERFACE:-}" ]] || die "Aucune interface réseau ne porte d'adresse IPv4 : préciser PXE_INTERFACE."
  ip link show dev "$PXE_INTERFACE" >/dev/null 2>&1 || die "Interface inconnue : $PXE_INTERFACE"

  if [[ -z "${PXE_ADDRESS_CIDR:-}" ]]; then
    PXE_ADDRESS_CIDR="$(ip -4 -o addr show dev "$PXE_INTERFACE" scope global 2>/dev/null \
      | awk '{ print $4; exit }')"
  fi
  [[ -n "${PXE_ADDRESS_CIDR:-}" ]] || die "$PXE_INTERFACE n'a pas d'adresse IPv4 : préciser PXE_ADDRESS_CIDR."

  if [[ -z "${PXE_SUBNET_CIDR:-}" ]]; then
    PXE_SUBNET_CIDR="$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$PXE_ADDRESS_CIDR")"
  fi
  # shellcheck disable=SC2034  # lue par les scripts qui chargent ce fichier
  PXE_IP="${PXE_ADDRESS_CIDR%/*}"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Configuration absente : $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${PXE_DATA_MOUNT:?}" "${PXE_HTTP_ROOT:?}" "${PXE_TFTP_ROOT:?}" "${PXE_NFS_MOUNT_ROOT:?}"
  PXE_BUILD_ROOT="${PXE_BUILD_ROOT:-/var/cache/bits/build}"
  PXE_STATE_DIR="${PXE_STATE_DIR:-/var/lib/bits}"
  # Disque de données dédié : facultatif. Vide, les données vivent dans
  # PXE_DATA_MOUNT sur le système de fichiers racine.
  PXE_DATA_DISK="${PXE_DATA_DISK:-}"
  PXE_DATA_PARTITION="${PXE_DATA_PARTITION:-}"
  derive_network
}

# Le répertoire de données est-il prêt ? Avec un disque dédié, il doit être
# monté : écrire dans le point de montage vide remplirait la racine en silence.
require_data_dir() {
  if [[ -n "$PXE_DATA_DISK" ]]; then
    mountpoint -q "$PXE_DATA_MOUNT" || die "$PXE_DATA_MOUNT n'est pas monté (disque dédié $PXE_DATA_DISK)."
  fi
  install -d -m 0755 "$PXE_DATA_MOUNT" "$PXE_DATA_MOUNT/downloads"
}

# Toutes les lignes du catalogue, activées ou non.
catalogue_lines() {
  [[ -f "$MEDIA_FILE" ]] || die "Catalogue absent : $MEDIA_FILE"
  awk -F '|' 'NF >= 7 && $0 !~ /^[[:space:]]*#/ {print}' "$MEDIA_FILE"
}

enabled_media() {
  [[ -f "$MEDIA_FILE" ]] || die "Catalogue absent : $MEDIA_FILE"
  awk -F '|' 'NF >= 7 && $1 == "yes" && $0 !~ /^[[:space:]]*#/ {print}' "$MEDIA_FILE"
}

# Médias activés ET obtenus par 40-download-media.sh lors de cette
# publication. Un média activé mais écarté (téléchargement ou empreinte en
# échec) n'est ni publié ni contrôlé.
ready_media() {
  local ready_file="$PXE_STATE_DIR/media-prets"
  [[ -f "$ready_file" ]] || return 0
  enabled_media | awk -F '|' -v f="$ready_file" '
    BEGIN { while ((getline id < f) > 0) if (id != "") ok[id] = 1 }
    ($2 in ok) { print }'
}

safe_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Identifiant invalide : $1"; }
