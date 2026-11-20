#!/usr/bin/env bash
set -Eeuo pipefail

PROTO_ROOT=/opt/generic-pxe
STATE_LABEL=PXE_DATA
DATA_MOUNT=/srv/pxe-data
CONFIG_SUBDIR=boot-config

# --- 0. Mode non interactif piloté par la ligne de commande du noyau ----------
# Sans ce mode, l'assistant s'arrête au premier whiptail : aucun test
# automatisé ne peut aller au-delà, et un déploiement en série demande un
# opérateur devant chaque écran. Les paramètres sont lus sur /proc/cmdline
# parce que c'est le seul canal disponible avant tout système de fichiers
# inscriptible, et qu'il fonctionne aussi bien en PXE qu'en démarrage USB.
#
#   bits.auto                 active le mode non interactif
#   bits.data-disk=<chemin>   disque entier à EFFACER et préparer
#   bits.data-part=<chemin>   partition existante à réutiliser, rien n'est effacé
#                             (l'un des deux est obligatoire en mode auto)
#   bits.hostname=<nom>       nom du serveur
#   bits.iface=<ifname>       interface qui servira le PXE (si la machine en a plusieurs)
#   bits.gateway=<ip>         passerelle déclarée dans pxe.env
#   bits.dns=<ip>             DNS déclaré dans pxe.env
#   bits.media=none|<chemin>  catalogue de médias ; « none » n'en active aucun
AUTO=0
AUTO_DATA_DISK=""
AUTO_DATA_PART=""
AUTO_HOSTNAME=""
AUTO_IFACE=""
AUTO_GATEWAY=""
AUTO_DNS=""
AUTO_MEDIA=""
for arg in $(cat /proc/cmdline 2>/dev/null || true); do
  case "$arg" in
    bits.auto)          AUTO=1 ;;
    bits.data-disk=*)   AUTO_DATA_DISK="${arg#*=}" ;;
    bits.data-part=*)   AUTO_DATA_PART="${arg#*=}" ;;
    bits.hostname=*)    AUTO_HOSTNAME="${arg#*=}" ;;
    bits.iface=*)       AUTO_IFACE="${arg#*=}" ;;
    bits.gateway=*)     AUTO_GATEWAY="${arg#*=}" ;;
    bits.dns=*)         AUTO_DNS="${arg#*=}" ;;
    bits.media=*)       AUTO_MEDIA="${arg#*=}" ;;
  esac
done

# En mode auto, tout part sur /dev/console : avec console=ttyS0 c'est la ligne
# série, donc la seule chose qu'un test puisse lire. L'unité systemd écrit
# sinon sur /dev/tty1, invisible d'une VM sans écran.
if [[ $AUTO -eq 1 ]]; then
  exec >/dev/console 2>&1
fi

# Un échec doit être annoncé. Sans marqueur d'échec, un test ne distingue pas
# une panne d'une installation lente et attend son délai entier pour rien.
fail() {
  if [[ $AUTO -eq 1 ]]; then
    echo "BITS-PXE-FAILED $*"
  else
    whiptail --title "Serveur PXE — erreur" --msgbox "$*" 12 70 || true
  fi
  echo "ERREUR : $*" >&2
  exit 1
}
die() { fail "$@"; }
trap 'fail "interruption inattendue (ligne $LINENO)"' ERR

echo "== Assistant de démarrage du serveur PXE =="
[[ $AUTO -eq 1 ]] && echo "mode non interactif (bits.auto)"

# --- 1. Trouver où stocker les données du serveur PXE -------------------------
# Trois cas, dans cet ordre de priorité :
#
#   a. une partition déjà étiquetée PXE_DATA, OÙ QU'ELLE SOIT — y compris sur le
#      média de démarrage. C'est le cas de la clé USB fabriquée par
#      tools/creer-cle-usb.sh, dont la seconde partition porte déjà les médias :
#      rien n'est effacé, la configuration et le catalogue sont relus ;
#   b. bits.data-part=<partition>, pour désigner une partition existante ;
#   c. à défaut, un disque entier à préparer, média de démarrage exclu. C'est le
#      seul des trois cas qui efface quoi que ce soit.
live_source="$(findmnt -rn -o SOURCE /run/live/medium 2>/dev/null || findmnt -rn -o SOURCE /lib/live/mount/medium 2>/dev/null || true)"
live_disk=""
if [[ -n "$live_source" ]]; then
  live_parent="$(lsblk -no PKNAME "$live_source" 2>/dev/null || true)"
  [[ -n "$live_parent" ]] && live_disk="/dev/$live_parent"
fi

# Identifiant stable, ou chemin brut à défaut : fstab et pxe.env doivent
# survivre à un changement de nom de périphérique entre deux démarrages.
by_id_for() {
  local name="${1##*/}" found=""
  [[ -n "$name" ]] || return 0
  found="$(find /dev/disk/by-id -maxdepth 1 -lname "*/${name}" 2>/dev/null | sort | head -n1)"
  printf '%s' "${found:-$1}"
}

# Partition portant déjà l'étiquette, quelle que soit sa position et son disque.
trouver_partition_etiquetee() {
  local found
  found="$(blkid -L "$STATE_LABEL" 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    # Repli si le cache blkid est absent : lecture directe de la table.
    found="$(lsblk -prno NAME,LABEL 2>/dev/null \
      | awk -v l="$STATE_LABEL" '$2 == l {print $1; exit}')"
  fi
  printf '%s' "$found"
}

data_part=""
data_disk=""
prepare_needed=1

if [[ -n "$AUTO_DATA_PART" ]]; then
  data_part="$(readlink -f "$AUTO_DATA_PART" 2>/dev/null || true)"
  [[ -b "$data_part" ]] || fail "bits.data-part=$AUTO_DATA_PART ne désigne pas un périphérique bloc."
  prepare_needed=0
else
  existing="$(trouver_partition_etiquetee)"
  if [[ -n "$existing" && -b "$existing" ]]; then
    data_part="$existing"
    prepare_needed=0
  fi
fi

if [[ -n "$data_part" ]]; then
  parent="$(lsblk -no PKNAME "$data_part" 2>/dev/null | head -n1 || true)"
  [[ -n "$parent" ]] && data_disk="/dev/$parent"
elif [[ $AUTO -eq 1 ]]; then
  # Le mode auto ne devine JAMAIS quel disque effacer : --prepare-data-disk
  # efface entièrement sa cible, et un démarrage automatique sur une machine
  # garnie ne doit pas pouvoir détruire des données par défaut.
  [[ -n "$AUTO_DATA_DISK" ]] || fail "bits.auto exige bits.data-disk=<disque> ou bits.data-part=<partition> : le mode auto ne choisit pas seul le disque à effacer."
  data_disk="$(readlink -f "$AUTO_DATA_DISK" 2>/dev/null || true)"
  [[ -b "$data_disk" ]] || fail "bits.data-disk=$AUTO_DATA_DISK ne désigne pas un périphérique bloc."
  [[ "$data_disk" != "$live_disk" ]] || fail "bits.data-disk désigne le média de démarrage ($live_disk)."
else
  while read -r name type; do
    [[ "$type" == "disk" ]] || continue
    dev="/dev/$name"
    [[ "$dev" == "$live_disk" ]] && continue
    [[ -z "$data_disk" ]] && data_disk="$dev"
  done < <(lsblk -dn -o NAME,TYPE)
  [[ -n "$data_disk" ]] || die "Aucun disque local utilisable trouvé (en dehors du média de démarrage), et aucune partition $STATE_LABEL."
fi

data_disk_by_id="$(by_id_for "$data_disk")"

mounted_existing=0
if [[ $prepare_needed -eq 0 ]]; then
  install -d -m 0755 "$DATA_MOUNT"
  if mountpoint -q "$DATA_MOUNT" || mount "$data_part" "$DATA_MOUNT"; then
    mounted_existing=1
  else
    fail "La partition $STATE_LABEL ($data_part) existe mais ne se monte pas."
  fi
  data_part_by_id="$(by_id_for "$data_part")"
else
  # La partition sera créée en première position par 20-prepare-data-disk.sh.
  data_part_by_id="${data_disk_by_id}-part1"
fi

config_dir="$DATA_MOUNT/$CONFIG_SUBDIR"
persisted=0
if [[ $mounted_existing -eq 1 && -f "$config_dir/pxe.env" && -f "$config_dir/media.conf" ]]; then
  persisted=1
fi

# --- 2. Construire la proposition de configuration (persistée ou par défaut) ---
if [[ $persisted -eq 1 ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$config_dir/pxe.env"
else
  if [[ -n "$AUTO_IFACE" ]]; then
    iface="$AUTO_IFACE"
    ip link show "$iface" >/dev/null 2>&1 || fail "bits.iface=$iface : interface inconnue."
  else
    iface="$(ip -o -4 route show to default | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || iface="$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}')"
  fi
  [[ -n "$iface" ]] || die "Impossible de détecter une interface réseau active."
  cidr="$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4; exit}')"
  [[ -n "$cidr" ]] || die "Interface $iface sans adresse IPv4. Branche le câble réseau puis relance."
  gw="$(ip -o -4 route show to default dev "$iface" | awk '{print $3; exit}')"
  # Repli : une interface dédiée au PXE peut ne pas porter la route par défaut.
  [[ -n "$gw" ]] || gw="$(ip -o -4 route show to default | awk '{print $3; exit}')"
  [[ -n "$AUTO_GATEWAY" ]] && gw="$AUTO_GATEWAY"
  if [[ -z "$gw" ]]; then
    # Pas de routeur sur ce réseau. Ce n'est pas une erreur : servir du PXE ne
    # demande aucune route par défaut, et un atelier avec un simple commutateur
    # est un cas valable. On enregistre l'adresse du serveur lui-même, parce que
    # pxe.env exige une valeur, et on le dit explicitement plutôt que d'inventer
    # une passerelle en silence.
    gw="${cidr%/*}"
    echo "Aucune passerelle détectée sur $iface : le serveur n'aura pas de route par défaut."
    echo "La valeur enregistrée est sa propre adresse ($gw). Préciser bits.gateway=<ip> si un routeur existe."
  fi
  dns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
  [[ -n "$dns" ]] || dns="$gw"
  [[ -n "$AUTO_DNS" ]] && dns="$AUTO_DNS"
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
[[ -n "$AUTO_HOSTNAME" ]] && PXE_HOSTNAME="$AUTO_HOSTNAME"

PXE_DATA_DISK="$data_disk_by_id"
PXE_DATA_PARTITION="$data_part_by_id"
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
Stockage données  : $([[ $prepare_needed -eq 1 ]] && echo "$data_disk (SERA EFFACÉ et préparé)" || echo "$data_part (déjà préparé, conservé)")
Source            : $([[ $persisted -eq 1 ]] && echo 'configuration précédente retrouvée sur le disque' || echo 'valeurs détectées automatiquement (DHCP)')"

if [[ $AUTO -eq 1 ]]; then
  echo "$summary"
  use_defaults=1
elif whiptail --title "Serveur PXE — configuration par défaut" --yesno "$summary

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

if [[ "$AUTO_MEDIA" == "none" ]]; then
  # Catalogue sans aucune ligne active : le serveur s'installe et se valide
  # sans télécharger les 6 à 8 Go de médias du catalogue d'exemple. Utile pour
  # un test, et pour déployer un serveur dont les médias seront ajoutés après.
  printf '# Catalogue vide (bits.media=none) : aucun média activé.\n' \
    > "$PROTO_ROOT/config/media.conf"
elif [[ -n "$AUTO_MEDIA" ]]; then
  [[ -f "$AUTO_MEDIA" ]] || fail "bits.media=$AUTO_MEDIA : fichier introuvable."
  cp -a "$AUTO_MEDIA" "$PROTO_ROOT/config/media.conf"
elif [[ -f "$config_dir/media.conf" ]]; then
  # Indépendant de pxe.env : une clé USB livre son catalogue sans pouvoir
  # livrer pxe.env, qui dépend du réseau de la machine où elle démarre.
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

if [[ $AUTO -eq 1 ]]; then
  # Marqueur de succès en dernier : un test qui le voit sait que le pipeline
  # entier est passé, services activés et contrôles de l'étape 70 compris.
  trap - ERR
  echo "Serveur PXE prêt sur $PXE_ADDRESS_CIDR."
  echo "BITS-PXE-READY $PXE_ADDRESS_CIDR"
  exit 0
fi

whiptail --title "Serveur PXE" --msgbox "Serveur PXE actif sur $PXE_ADDRESS_CIDR.

La configuration a été enregistrée sur $data_disk et sera reproposée par défaut au prochain démarrage." 12 70 || true

echo "Serveur PXE prêt sur $PXE_ADDRESS_CIDR."
