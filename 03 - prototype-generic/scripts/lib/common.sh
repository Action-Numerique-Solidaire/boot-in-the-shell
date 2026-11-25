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
#
# En mode passerelle, le serveur est au contraire le routeur d'un réseau PXE
# dédié : une interface filaire (PXE_LAN_INTERFACE) porte PXE_LAN_CIDR, sert
# le DHCP, le DNS et le PXE, et le trafic des postes sort par l'amont (la
# route par défaut, typiquement le Wi-Fi). Voir bits-passerelle.sh.
derive_network() {
  if [[ "$PXE_MODE" == passerelle ]]; then
    derive_network_passerelle
    return
  fi
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

# Interface de la route par défaut (vide sans route par défaut).
interface_amont() {
  ip -4 route show default 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

interface_sans_fil() { [[ -d "/sys/class/net/$1/wireless" || -d "/sys/class/net/$1/phy80211" ]]; }

# Première carte Ethernet physique (pas virtuelle, pas Wi-Fi) autre que $1.
premiere_filaire() {
  local chemin nom
  for chemin in /sys/class/net/*; do
    nom="${chemin##*/}"
    [[ "$nom" != "${1:-}" && -e "$chemin/device" && "$(cat "$chemin/type" 2>/dev/null)" == 1 ]] || continue
    interface_sans_fil "$nom" && continue
    echo "$nom"
    return 0
  done
  return 1
}

derive_network_passerelle() {
  PXE_LAN_CIDR="${PXE_LAN_CIDR:-192.168.42.1/24}"
  PXE_UPLINK_INTERFACE="${PXE_UPLINK_INTERFACE:-$(interface_amont)}"
  if [[ -z "${PXE_LAN_INTERFACE:-}" ]]; then
    PXE_LAN_INTERFACE="$(premiere_filaire "$PXE_UPLINK_INTERFACE")" \
      || die "Mode passerelle : aucune carte Ethernet pour le réseau PXE (préciser PXE_LAN_INTERFACE)."
  fi
  ip link show dev "$PXE_LAN_INTERFACE" >/dev/null 2>&1 || die "Interface inconnue : $PXE_LAN_INTERFACE"
  [[ "$PXE_LAN_INTERFACE" != "$PXE_UPLINK_INTERFACE" ]] \
    || die "Mode passerelle : $PXE_LAN_INTERFACE est à la fois l'amont (route par défaut) et le réseau PXE."
  PXE_INTERFACE="$PXE_LAN_INTERFACE"
  PXE_ADDRESS_CIDR="$PXE_LAN_CIDR"
  # Plage DHCP : de .100 à .250 d'un /24, ou les adresses suivant celle du
  # serveur jusqu'à l'avant-dernière du réseau.
  # shellcheck disable=SC2034  # lues par les scripts qui chargent ce fichier
  read -r PXE_SUBNET_CIDR PXE_DHCP_DEBUT PXE_DHCP_FIN PXE_NETMASK < <(python3 - "$PXE_LAN_CIDR" "${PXE_DHCP_RANGE:-}" <<'PY'
import ipaddress, sys
i = ipaddress.ip_interface(sys.argv[1])
n = i.network
if sys.argv[2]:
    debut, fin = (ipaddress.ip_address(x.strip()) for x in sys.argv[2].split(","))
elif n.prefixlen == 24:
    debut, fin = n.network_address + 100, n.network_address + 250
else:
    debut, fin = i.ip + 1, n.broadcast_address - 1
print(n, debut, fin, n.netmask)
PY
  ) || die "PXE_LAN_CIDR ou PXE_DHCP_RANGE invalide."
  # shellcheck disable=SC2034  # lue par les scripts qui chargent ce fichier
  PXE_IP="${PXE_LAN_CIDR%/*}"
}

# Fichier de configuration et ses compléments, sans rien déduire du réseau.
# Les compléments (pxe.env.d/*.env) sont hors conffile : la clé
# d'installation y écrit le mode passerelle sans provoquer de question de dpkg.
source_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Configuration absente : $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  local complement
  for complement in "$CONFIG_FILE.d"/*.env; do
    # shellcheck disable=SC1090
    if [[ -f "$complement" ]]; then source "$complement"; fi
  done
  PXE_MODE="${PXE_MODE:-proxy}"
  [[ "$PXE_MODE" =~ ^(proxy|passerelle)$ ]] || die "PXE_MODE invalide : $PXE_MODE (proxy ou passerelle)."
}

load_config() {
  source_config
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
