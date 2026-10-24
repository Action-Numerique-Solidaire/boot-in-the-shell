#!/usr/bin/env bash
set -Eeuo pipefail

PROTO_ROOT=/opt/generic-pxe
STATE_LABEL=PXE_DATA
DATA_MOUNT=/srv/pxe-data
CONFIG_SUBDIR=boot-config

die() { whiptail --title "Serveur PXE — erreur" --msgbox "$*" 12 70 || true; echo "ERREUR : $*" >&2; exit 1; }

echo "== Assistant de démarrage du serveur PXE =="

# --- 1. Identifier le disque de données local (hors média de démarrage live) ---
live_source="$(findmnt -rn -o SOURCE /run/live/medium 2>/dev/null || findmnt -rn -o SOURCE /lib/live/mount/medium 2>/dev/null || true)"
live_disk=""
if [[ -n "$live_source" ]]; then
  live_parent="$(lsblk -no PKNAME "$live_source" 2>/dev/null || true)"
  [[ -n "$live_parent" ]] && live_disk="/dev/$live_parent"
fi

data_disk=""
preferred_disk=""
while read -r name type; do
  [[ "$type" == "disk" ]] || continue
  dev="/dev/$name"
  [[ "$dev" == "$live_disk" ]] && continue
  [[ -z "$data_disk" ]] && data_disk="$dev"
  part_name="$(lsblk -rno NAME "$dev" | sed -n '2p')"
  if [[ -n "$part_name" ]] && [[ "$(lsblk -no LABEL "/dev/$part_name" 2>/dev/null || true)" == "$STATE_LABEL" ]]; then
    preferred_disk="$dev"
  fi
done < <(lsblk -dn -o NAME,TYPE)

[[ -n "$preferred_disk" ]] && data_disk="$preferred_disk"
[[ -n "$data_disk" ]] || die "Aucun disque local utilisable trouvé (en dehors du média de démarrage)."

data_disk_name="${data_disk##*/}"
data_disk_by_id="$(find /dev/disk/by-id -maxdepth 1 -lname "*/${data_disk_name}" 2>/dev/null | sort | head -n1 || true)"
[[ -n "$data_disk_by_id" ]] || die "Pas d'identifiant stable /dev/disk/by-id/ pour $data_disk. Impossible de continuer."

part_name="$(lsblk -rno NAME "$data_disk" | sed -n '2p')"
prepare_needed=1
mounted_existing=0
if [[ -n "$part_name" ]] && [[ "$(lsblk -no LABEL "/dev/$part_name" 2>/dev/null || true)" == "$STATE_LABEL" ]]; then
  prepare_needed=0
  install -d -m 0755 "$DATA_MOUNT"
  if mount "/dev/$part_name" "$DATA_MOUNT"; then
    mounted_existing=1
  else
    echo "Montage de /dev/$part_name impossible, nouvelle préparation forcée." >&2
    prepare_needed=1
  fi
fi

config_dir="$DATA_MOUNT/$CONFIG_SUBDIR"
persisted=0
if [[ $mounted_existing -eq 1 && -f "$config_dir/pxe.env" && -f "$config_dir/media.conf" ]]; then
  persisted=1
fi

# --- 2. Construire la proposition de configuration (persistée ou par défaut) ---
if [[ $persisted -eq 1 ]]; then
  # shellcheck disable=SC1090
  source "$config_dir/pxe.env"
else
  iface="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [[ -n "$iface" ]] || iface="$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}')"
  [[ -n "$iface" ]] || die "Impossible de détecter une interface réseau active."
  cidr="$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4; exit}')"
  [[ -n "$cidr" ]] || die "Interface $iface sans adresse IPv4. Branche le câble réseau puis relance."
  gw="$(ip -o -4 route show to default dev "$iface" | awk '{print $3; exit}')"
  dns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
  [[ -n "$dns" ]] || dns="$gw"
  subnet="$(python3 - "$cidr" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  PXE_HOSTNAME="pxe-server"
  PXE_INTERFACE="$iface"
  PXE_ADDRESS_CIDR="$cidr"
  PXE_GATEWAY="$gw"
  PXE_DNS="$dns"
  PXE_SUBNET_CIDR="$subnet"
fi

PXE_DATA_DISK="$data_disk_by_id"
PXE_DATA_PARTITION="${data_disk_by_id}-part1"
PXE_DATA_MOUNT="$DATA_MOUNT"
PXE_HTTP_ROOT="/var/www/html/pxe"
PXE_TFTP_ROOT="/srv/tftp"
PXE_NFS_MOUNT_ROOT="/mnt/pxe-media"
# Sur le live, / est un overlay en RAM : cloner et compiler iPXE dans /opt
# remplirait la mémoire de la machine. On construit sur le disque de
# données, ce qui évite aussi de tout recompiler à chaque démarrage.
PXE_BUILD_ROOT="$DATA_MOUNT/build"
PXE_MANAGE_NETWORK="no"
WIMBOOT_URL="https://github.com/ipxe/wimboot/releases/download/v2.9.0/wimboot"
WIMBOOT_SHA256="5f067ccdc4d084d5bf77b6c853bd0f8402dfc2b4cd1b103d358993ae97fae8e3"
IPXE_GIT_URL="https://github.com/ipxe/ipxe.git"
IPXE_GIT_COMMIT="45af75d2af3b85af51bc0d16af5df30abff1935b"

# --- 3. Proposer la configuration, accepter ou modifier via whiptail ---
summary="Interface réseau : $PXE_INTERFACE
Adresse IP fixe   : $PXE_ADDRESS_CIDR
Passerelle        : $PXE_GATEWAY
DNS               : $PXE_DNS
Sous-réseau PXE   : $PXE_SUBNET_CIDR
Disque de données : $data_disk $([[ $prepare_needed -eq 1 ]] && echo '(sera effacé et préparé)' || echo '(déjà préparé, conservé)')
Source            : $([[ $persisted -eq 1 ]] && echo 'configuration précédente retrouvée sur le disque' || echo 'valeurs détectées automatiquement (DHCP)')"

if whiptail --title "Serveur PXE — configuration par défaut" --yesno "$summary

Utiliser cette configuration ?" 20 76; then
  use_defaults=1
else
  use_defaults=0
fi

if [[ $use_defaults -eq 0 ]]; then
  PXE_HOSTNAME="$(whiptail --inputbox "Nom du serveur" 10 60 "$PXE_HOSTNAME" 3>&1 1>&2 2>&3)"
  PXE_INTERFACE="$(whiptail --inputbox "Interface réseau" 10 60 "$PXE_INTERFACE" 3>&1 1>&2 2>&3)"
  PXE_ADDRESS_CIDR="$(whiptail --inputbox "Adresse IP fixe (CIDR, ex: 192.168.1.15/24)" 10 60 "$PXE_ADDRESS_CIDR" 3>&1 1>&2 2>&3)"
  PXE_GATEWAY="$(whiptail --inputbox "Passerelle" 10 60 "$PXE_GATEWAY" 3>&1 1>&2 2>&3)"
  PXE_DNS="$(whiptail --inputbox "DNS" 10 60 "$PXE_DNS" 3>&1 1>&2 2>&3)"
  PXE_SUBNET_CIDR="$(whiptail --inputbox "Sous-réseau PXE (ex: 192.168.1.0/24)" 10 60 "$PXE_SUBNET_CIDR" 3>&1 1>&2 2>&3)"
fi

# --- 4. Écrire la configuration et lancer le pipeline d'installation ---
cat > "$PROTO_ROOT/config/pxe.env" <<EOF
PXE_HOSTNAME=$PXE_HOSTNAME
PXE_INTERFACE=$PXE_INTERFACE
PXE_ADDRESS_CIDR=$PXE_ADDRESS_CIDR
PXE_GATEWAY=$PXE_GATEWAY
PXE_DNS=$PXE_DNS
PXE_SUBNET_CIDR=$PXE_SUBNET_CIDR

PXE_DATA_DISK=$PXE_DATA_DISK
PXE_DATA_PARTITION=$PXE_DATA_PARTITION
PXE_DATA_MOUNT=$PXE_DATA_MOUNT

PXE_HTTP_ROOT=$PXE_HTTP_ROOT
PXE_TFTP_ROOT=$PXE_TFTP_ROOT
PXE_NFS_MOUNT_ROOT=$PXE_NFS_MOUNT_ROOT
PXE_BUILD_ROOT=$PXE_BUILD_ROOT

PXE_MANAGE_NETWORK=$PXE_MANAGE_NETWORK

WIMBOOT_URL=$WIMBOOT_URL
WIMBOOT_SHA256=$WIMBOOT_SHA256

IPXE_GIT_URL=$IPXE_GIT_URL
IPXE_GIT_COMMIT=$IPXE_GIT_COMMIT
EOF

if [[ $persisted -eq 1 && -f "$config_dir/media.conf" ]]; then
  cp -a "$config_dir/media.conf" "$PROTO_ROOT/config/media.conf"
else
  cp -a "$PROTO_ROOT/config/media.conf.example" "$PROTO_ROOT/config/media.conf"
fi

cd "$PROTO_ROOT"
if [[ $prepare_needed -eq 1 ]]; then
  ./scripts/install.sh --prepare-data-disk
else
  ./scripts/install.sh --reuse-data-disk
fi

install -d -m 0755 "$config_dir"
cp -a "$PROTO_ROOT/config/pxe.env" "$PROTO_ROOT/config/media.conf" "$config_dir/"

whiptail --title "Serveur PXE" --msgbox "Serveur PXE actif sur $PXE_ADDRESS_CIDR.

La configuration a été enregistrée sur $data_disk et sera reproposée par défaut au prochain démarrage." 12 70 || true

echo "Serveur PXE prêt sur $PXE_ADDRESS_CIDR."
