#!/usr/bin/env bash
# Construit une ISO live bootable hybride BIOS (isolinux) + UEFI (GRUB) qui
# embarque le serveur PXE
# générique (03 - prototype-generic) et un assistant de configuration au
# démarrage. À exécuter avec sudo sur un hôte Ubuntu/Debian.
#
# Usage : sudo ./build-iso.sh [chemin-de-sortie.iso]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTO_SRC="$SCRIPT_DIR/../03 - prototype-generic"
OVERLAY_SRC="$SCRIPT_DIR/overlay"

WORK_ROOT="${PXE_ISO_WORK:-/srv/pxe-iso-build}"
CHROOT="$WORK_ROOT/chroot"
ISO_STAGE="$WORK_ROOT/iso"
BOOTSTRAP_CACHE="${PXE_ISO_BOOTSTRAP_CACHE:-/srv/pxe-live-build/cache/bootstrap}"
DISTRO="noble"
MIRROR="http://archive.ubuntu.com/ubuntu"
OUTPUT_ISO="${1:-$WORK_ROOT/boot-in-the-shell-live.iso}"
VOLID="BITS-LIVE"

PACKAGES=(
  openssh-server curl ca-certificates gnupg git
  build-essential liblzma-dev
  dnsmasq nginx nfs-kernel-server samba wimtools unzip rsync
  squashfs-tools parted e2fsprogs util-linux iproute2
  whiptail python3 net-tools
  isolinux syslinux-common
  grub-efi-amd64-bin grub-common mtools dosfstools
  linux-image-generic
  live-boot live-config live-config-systemd
)

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { echo "ERREUR : $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Ce script doit être exécuté avec sudo."
[[ -d "$PROTO_SRC" ]] || die "Introuvable : $PROTO_SRC"

for cmd in debootstrap mksquashfs xorriso; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd"
done

mounted=()
cleanup() {
  local m
  for ((i=${#mounted[@]}-1; i>=0; i--)); do
    m="${mounted[i]}"
    mountpoint -q "$m" && umount "$m" 2>/dev/null || true
  done
}
trap cleanup EXIT

bind_mount() {
  local target="$1"
  shift
  mount "$@" "$target"
  mounted+=("$target")
}

# --- 1. Préparer le chroot de base -----------------------------------------
install -d -m 0755 "$WORK_ROOT"
if [[ -d "$CHROOT" ]]; then
  log "Chroot existant réutilisé : $CHROOT (supprimer $WORK_ROOT pour repartir de zéro)"
elif [[ -d "$BOOTSTRAP_CACHE" ]]; then
  log "Copie du cache debootstrap existant ($BOOTSTRAP_CACHE)"
  install -d -m 0755 "$CHROOT"
  cp -a "$BOOTSTRAP_CACHE/." "$CHROOT/"
else
  log "Debootstrap complet de $DISTRO (pas de cache trouvé, ça va prendre quelques minutes)"
  debootstrap --arch=amd64 "$DISTRO" "$CHROOT" "$MIRROR"
fi

# --- 2. Monter les systèmes de fichiers virtuels ----------------------------
bind_mount "$CHROOT/dev" --bind /dev
bind_mount "$CHROOT/dev/pts" --bind /dev/pts
bind_mount "$CHROOT/proc" -t proc proc
bind_mount "$CHROOT/sys" -t sysfs sysfs
install -m 0644 /etc/resolv.conf "$CHROOT/etc/resolv.conf"

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $DISTRO main restricted universe multiverse
deb $MIRROR $DISTRO-updates main restricted universe multiverse
deb $MIRROR $DISTRO-security main restricted universe multiverse
EOF

cat > "$CHROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$CHROOT/usr/sbin/policy-rc.d"

in_chroot() { chroot "$CHROOT" /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

# --- 3. Paquets --------------------------------------------------------------
log "apt-get update"
in_chroot apt-get update

# dpkg s'auto-met-à-jour parfois de façon instable au milieu d'une grosse
# transaction dans ce genre d'environnement hors ligne/chrooté : le mettre à
# jour seul en premier évite une course sur start-stop-daemon.
log "Mise à jour préventive de dpkg"
in_chroot apt-get install --only-upgrade -y dpkg

log "Mise à niveau du système de base"
in_chroot apt-get upgrade -y

log "Installation des paquets : ${PACKAGES[*]}"
in_chroot apt-get install -y "${PACKAGES[@]}"

# live-boot doit être présent AVANT la génération de l'initramfs pour que ses
# hooks y soient inclus ; on régénère explicitement par sécurité, peu importe
# l'ordre choisi par apt pendant la transaction ci-dessus.
log "Régénération de l'initramfs avec le support live-boot"
in_chroot update-initramfs -u -k all

# --- 4. Contenu embarqué -----------------------------------------------------
log "Copie du serveur PXE générique et de l'assistant de démarrage"
install -d -m 0755 "$CHROOT/opt"
rm -rf "$CHROOT/opt/generic-pxe"
cp -a "$PROTO_SRC" "$CHROOT/opt/generic-pxe"
chown -R root:root "$CHROOT/opt/generic-pxe"
chmod +x "$CHROOT/opt/generic-pxe/scripts/"*.sh

cp -a "$OVERLAY_SRC/." "$CHROOT/"
# cp -a conserve l'UID du dépôt (1000) : sans ce chown, l'assistant lancé en
# root au démarrage appartiendrait dans l'image à un utilisateur non privilégié.
while IFS= read -r -d '' rel; do
  chown root:root "$CHROOT/$rel"
done < <(cd "$OVERLAY_SRC" && find . -mindepth 1 -printf '%P\0')
chmod +x "$CHROOT/usr/local/sbin/generic-pxe-wizard.sh"
install -d -m 0755 "$CHROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/generic-pxe-wizard.service \
  "$CHROOT/etc/systemd/system/multi-user.target.wants/generic-pxe-wizard.service"

# live-config ne configure pas le réseau (aucun composant DHCP dans
# /lib/live/config) et /etc/netplan est vide dans un chroot debootstrap : sans
# networkd+resolved activés et sans le netplan DHCP de l'overlay, le live
# démarre sans adresse IP et l'assistant s'arrête sur « Impossible de détecter
# une interface réseau active ».
log "Activation de systemd-networkd et systemd-resolved"
in_chroot systemctl enable systemd-networkd.service systemd-resolved.service

echo "pxe-live" > "$CHROOT/etc/hostname"

# --- 4bis. Chargeur UEFI (GRUB) ------------------------------------------------
# Construit DANS le chroot : l'hôte n'a besoin que de xorriso. Le .EFI embarque
# un grub.cfg minimal qui retrouve l'ISO par son label et charge le vrai menu.
log "Construction du chargeur UEFI (GRUB x86_64-efi)"
cat > "$CHROOT/tmp/grub-embed.cfg" <<EOF
search --no-floppy --set=root --label $VOLID
set prefix=(\$root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

in_chroot /bin/bash -c '
  set -Eeuo pipefail
  grub-mkstandalone -O x86_64-efi -o /tmp/BOOTX64.EFI \
    --locales= --themes= --fonts= \
    "boot/grub/grub.cfg=/tmp/grub-embed.cfg"
  # image FAT dimensionnée sur le binaire + marge
  kb=$(( ($(stat -c %s /tmp/BOOTX64.EFI) / 1024) + 512 ))
  mkfs.vfat -n BITSEFI -C /tmp/efi.img "$kb" >/dev/null
  mmd   -i /tmp/efi.img ::/EFI ::/EFI/BOOT
  mcopy -i /tmp/efi.img /tmp/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
'

# Sortir les artefacts du chroot pour qu'ils n'alourdissent pas le squashfs.
install -m 0644 "$CHROOT/tmp/efi.img" "$WORK_ROOT/efi.img"
rm -f "$CHROOT/tmp/efi.img" "$CHROOT/tmp/BOOTX64.EFI" "$CHROOT/tmp/grub-embed.cfg"
log "efi.img prêt ($(du -h "$WORK_ROOT/efi.img" | cut -f1))"

# --- 5. Nettoyage -------------------------------------------------------------
log "Nettoyage du cache apt"
in_chroot apt-get clean
rm -f "$CHROOT/usr/sbin/policy-rc.d"
# Le resolv.conf du build est une copie de celui de l'hôte : inutile dans
# l'image. Le supprimer sans rien mettre à la place laissait le live sans
# aucune résolution DNS (téléchargement des médias et clone iPXE impossibles).
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"

cleanup
trap - EXIT

# --- 6. Extraction noyau/initrd -----------------------------------------------
log "Extraction du noyau et de l'initrd"
install -d -m 0755 "$ISO_STAGE/live" "$ISO_STAGE/isolinux" "$ISO_STAGE/boot/grub"
kernel="$(find "$CHROOT/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
initrd="$(find "$CHROOT/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -n1)"
[[ -n "$kernel" && -n "$initrd" ]] || die "Noyau ou initrd introuvable dans $CHROOT/boot"
install -m 0644 "$kernel" "$ISO_STAGE/live/vmlinuz"
install -m 0644 "$initrd" "$ISO_STAGE/live/initrd.img"

# --- 7. Squashfs ---------------------------------------------------------------
log "Construction de filesystem.squashfs (peut prendre plusieurs minutes)"
rm -f "$ISO_STAGE/live/filesystem.squashfs"
mksquashfs "$CHROOT" "$ISO_STAGE/live/filesystem.squashfs" \
  -comp xz -noappend -wildcards \
  -e "boot/vmlinuz-*" -e "boot/initrd.img-*"

# --- 8. isolinux -----------------------------------------------------------------
log "Préparation du chargeur isolinux"
install -m 0644 "$CHROOT/usr/lib/ISOLINUX/isolinux.bin" "$ISO_STAGE/isolinux/isolinux.bin"
cp -a "$CHROOT/usr/lib/syslinux/modules/bios/"*.c32 "$ISO_STAGE/isolinux/" 2>/dev/null || true

cat > "$ISO_STAGE/isolinux/isolinux.cfg" <<EOF
DEFAULT live
PROMPT 0
TIMEOUT 50

LABEL live
  MENU LABEL Boot in the Shell -- serveur PXE
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet
EOF

# --- 8bis. Menu GRUB (UEFI) ----------------------------------------------------
log "Préparation du menu GRUB (UEFI)"
install -m 0644 "$WORK_ROOT/efi.img" "$ISO_STAGE/boot/grub/efi.img"
cat > "$ISO_STAGE/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "Boot in the Shell -- serveur PXE" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd.img
}
EOF

# --- 9. Assemblage de l'ISO -------------------------------------------------------
log "Construction de l'ISO"
install -d -m 0755 "$(dirname "$OUTPUT_ISO")"
rm -f "$OUTPUT_ISO"
# Deux entrées El Torito : BIOS (isolinux) puis UEFI (efi.img). -isohybrid-mbr
# et -isohybrid-gpt-basdat rendent l'ISO dd-able sur clé USB dans les deux modes
# et remplacent l'ancien appel à isohybrid.
xorriso -as mkisofs \
  -r -V "$VOLID" -J -l \
  -isohybrid-mbr "$CHROOT/usr/lib/ISOLINUX/isohdpfx.bin" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$OUTPUT_ISO" "$ISO_STAGE"

sha256sum "$OUTPUT_ISO" | tee "${OUTPUT_ISO}.sha256"

log "Terminé : $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "Pour écrire sur une clé USB :"
echo "  sudo dd if=\"$OUTPUT_ISO\" of=/dev/sdX bs=4M status=progress conv=fsync"
