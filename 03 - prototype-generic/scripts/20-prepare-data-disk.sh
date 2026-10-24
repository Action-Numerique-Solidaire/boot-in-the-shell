#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

[[ ${1:-} == "ERASE-PXE-DATA" ]] || die "Usage : sudo $0 ERASE-PXE-DATA"
[[ -b "$PXE_DATA_DISK" ]] || die "Disque absent : $PXE_DATA_DISK"
disk_real="$(readlink -f "$PXE_DATA_DISK")"
root_source="$(findmnt -n -o SOURCE /)"
root_parent="$(lsblk -ndo PKNAME "$root_source" 2>/dev/null || true)"
[[ "$disk_real" != "$root_source" && "$disk_real" != "/dev/$root_parent" ]] || die "Refus : le disque cible porte le système racine."
if lsblk -nrpo MOUNTPOINT "$disk_real" | grep -q '/'; then
  lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$disk_real" >&2
  die "Une partition du disque cible est montée."
fi

log "EFFACEMENT et formatage de $PXE_DATA_DISK"
wipefs --all "$disk_real"
parted --script "$disk_real" mklabel gpt
parted --script "$disk_real" mkpart primary ext4 1MiB 100%
partprobe "$disk_real"
udevadm settle
[[ -b "$PXE_DATA_PARTITION" ]] || die "Partition attendue absente : $PXE_DATA_PARTITION"
mkfs.ext4 -F -L PXE_DATA "$PXE_DATA_PARTITION"
uuid="$(blkid -s UUID -o value "$PXE_DATA_PARTITION")"
install -d -m 0755 "$PXE_DATA_MOUNT"
line="UUID=$uuid $PXE_DATA_MOUNT ext4 defaults,nofail 0 2"
grep -Fqx "$line" /etc/fstab || printf '%s\n' "$line" >> /etc/fstab
systemctl daemon-reload
mount "$PXE_DATA_MOUNT"
install -d -m 0755 "$PXE_DATA_MOUNT"/{downloads,iso,live,windows,clonezilla,clonezilla-images}
echo "Disque de données prêt sous $PXE_DATA_MOUNT."
