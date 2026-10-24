#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"
EXPECTED_MODEL="TOSHIBA MQ04ABF1"
EXPECTED_SERIAL="Y7I7P5KTT"
MOUNT_POINT="/srv/pxe-data"
CONFIRMATION="ERASE-T1000-SDA"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

if [[ ${1:-} != "$CONFIRMATION" ]]; then
  echo "Confirmation absente. Usage : sudo $0 $CONFIRMATION" >&2
  exit 2
fi

for command_name in lsblk blockdev wipefs parted partprobe udevadm mkfs.ext4 blkid findmnt mount systemctl; do
  command -v "$command_name" >/dev/null || {
    echo "Commande requise absente : $command_name" >&2
    exit 1
  }
done

[[ -b "$TARGET_DISK" ]] || { echo "$TARGET_DISK absent" >&2; exit 1; }

actual_model="$(lsblk -dn -o MODEL "$TARGET_DISK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
actual_serial="$(lsblk -dn -o SERIAL "$TARGET_DISK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
actual_size="$(blockdev --getsize64 "$TARGET_DISK")"

[[ "$actual_model" == "$EXPECTED_MODEL" ]] || {
  echo "Refus : modele inattendu ($actual_model)." >&2
  exit 1
}
[[ "$actual_serial" == "$EXPECTED_SERIAL" ]] || {
  echo "Refus : numero de serie inattendu ($actual_serial)." >&2
  exit 1
}
(( actual_size >= 900000000000 && actual_size <= 1100000000000 )) || {
  echo "Refus : taille inattendue ($actual_size octets)." >&2
  exit 1
}

if lsblk -nrpo MOUNTPOINT "$TARGET_DISK" | grep -q '/'; then
  echo "Refus : un systeme de fichiers de $TARGET_DISK est monte." >&2
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$TARGET_DISK" >&2
  exit 1
fi

if findmnt -rn -S "$TARGET_DISK" >/dev/null || findmnt -rn -S "$TARGET_PARTITION" >/dev/null; then
  echo "Refus : le disque ou sa partition est utilise par un montage." >&2
  exit 1
fi

echo "Cible validee : $TARGET_DISK | $actual_model | $actual_serial | $actual_size octets"
echo "Creation d'une partition GPT ext4 PXE_DATA..."

wipefs --all "$TARGET_DISK"
parted --script "$TARGET_DISK" mklabel gpt
parted --script "$TARGET_DISK" mkpart primary ext4 1MiB 100%
partprobe "$TARGET_DISK"
udevadm settle
mkfs.ext4 -F -L PXE_DATA "$TARGET_PARTITION"

uuid="$(blkid -s UUID -o value "$TARGET_PARTITION")"
[[ -n "$uuid" ]] || { echo "UUID introuvable apres formatage." >&2; exit 1; }

install -d -m 0755 "$MOUNT_POINT"
fstab_line="UUID=$uuid $MOUNT_POINT ext4 defaults,nofail 0 2"
grep -Fqx "$fstab_line" /etc/fstab || printf '%s\n' "$fstab_line" >> /etc/fstab
systemctl daemon-reload
mount "$MOUNT_POINT"

install -d -m 0755 \
  "$MOUNT_POINT/iso" \
  "$MOUNT_POINT/live" \
  "$MOUNT_POINT/prepared"
install -d -o user -g user -m 0755 "$MOUNT_POINT/incoming"

echo
echo "SSD PXE prepare avec succes."
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$TARGET_DISK"
df -hT "$MOUNT_POINT"
