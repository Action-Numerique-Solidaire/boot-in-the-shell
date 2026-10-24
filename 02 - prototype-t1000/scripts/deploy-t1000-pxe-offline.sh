#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="/srv/pxe-data"
IN_HTTP="$DATA_ROOT/incoming/http-root/pxe"
IN_PREPARED="$DATA_ROOT/incoming/srv-root/pxe/lubuntu-26.04-killbit"
HTTP_ROOT="/var/www/html/pxe"
ISO_ROOT="$DATA_ROOT/iso"
PREPARED_ROOT="$DATA_ROOT/prepared"
TFTP_ROOT="/srv/tftp"
CONFIG_STAGE="/home/user/t1000-pxe-config"
IPXE_BUILD="/home/user/build-source/ipxe/src"
BACKUP_DIR="/home/user/pxe-backups/pre-publication-$(date '+%Y%m%d-%H%M%S')"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

for required in \
  "$IN_HTTP" \
  "$IN_PREPARED" \
  "$CONFIG_STAGE/menu.ipxe" \
  "$CONFIG_STAGE/dnsmasq.conf" \
  "$CONFIG_STAGE/pxe.exports" \
  "$CONFIG_STAGE/start.ipxe" \
  "$IPXE_BUILD/bin/undionly.kpxe" \
  "$IPXE_BUILD/bin-x86_64-efi/snponly.efi"; do
  [[ -e "$required" ]] || { echo "Element requis absent : $required" >&2; exit 1; }
done

for service_name in dnsmasq nginx nfs-server; do
  if systemctl is-active --quiet "$service_name"; then
    echo "Refus : le service $service_name est deja actif." >&2
    exit 1
  fi
done

install -d -m 0755 "$BACKUP_DIR"
for source_file in /etc/fstab /etc/exports /etc/dnsmasq.conf /var/www/html/pxe/menu.ipxe; do
  if [[ -f "$source_file" ]]; then
    backup_name="$(printf '%s' "$source_file" | sed 's#^/##; s#/#__#g')"
    install -m 0600 "$source_file" "$BACKUP_DIR/$backup_name"
  fi
done

install -d -m 0755 "$ISO_ROOT" "$PREPARED_ROOT" "$HTTP_ROOT" "$TFTP_ROOT"

for iso_name in \
  Zorin-OS-18.1-Core-64-bit.iso \
  lubuntu-26.04-desktop-amd64.iso \
  lubuntu-26.04-killbit-amd64.iso \
  ubuntu-26.04-live-server-amd64.iso; do
  source_iso="$IN_HTTP/iso/$iso_name"
  target_iso="$ISO_ROOT/$iso_name"
  if [[ -f "$target_iso" ]]; then
    cmp -s "$source_iso" "$target_iso" || {
      echo "Refus : ISO deja presente mais differente : $target_iso" >&2
      exit 1
    }
  else
    mv "$source_iso" "$target_iso"
  fi
  chown root:root "$target_iso"
  chmod 0444 "$target_iso"
done

if [[ -d "$PREPARED_ROOT/lubuntu-26.04-killbit" ]]; then
  echo "Arborescence Killbit preparee deja presente."
else
  mv "$IN_PREPARED" "$PREPARED_ROOT/lubuntu-26.04-killbit"
fi
chown -R root:root "$PREPARED_ROOT/lubuntu-26.04-killbit"

tar -C "$IN_HTTP" --exclude='./iso' --exclude='./iso/*' -cf - . \
  | tar -C "$HTTP_ROOT" -xf -
install -m 0644 "$CONFIG_STAGE/menu.ipxe" "$HTTP_ROOT/menu.ipxe"
chown -R root:root "$HTTP_ROOT"

install -m 0644 "$CONFIG_STAGE/start.ipxe" "$TFTP_ROOT/start.ipxe"
install -m 0644 "$IPXE_BUILD/bin/undionly.kpxe" "$TFTP_ROOT/undionly.kpxe"
install -m 0644 "$IPXE_BUILD/bin-x86_64-efi/snponly.efi" "$TFTP_ROOT/snponly.efi"

install -d -m 0755 "$HTTP_ROOT/iso" /srv/pxe

append_fstab_line() {
  local line="$1"
  grep -Fqx "$line" /etc/fstab || printf '%s\n' "$line" >> /etc/fstab
}

append_fstab_line "$ISO_ROOT $HTTP_ROOT/iso none bind,x-systemd.requires-mounts-for=$DATA_ROOT 0 0"
append_fstab_line "$PREPARED_ROOT /srv/pxe none bind,x-systemd.requires-mounts-for=$DATA_ROOT 0 0"
append_fstab_line "$HTTP_ROOT/iso/lubuntu-26.04-desktop-amd64.iso /mnt/lubuntu-26.04 iso9660 loop,ro,nofail 0 0"
append_fstab_line "$HTTP_ROOT/iso/Zorin-OS-18.1-Core-64-bit.iso /mnt/zorin-18.1 iso9660 loop,ro,nofail 0 0"
append_fstab_line "$HTTP_ROOT/iso/lubuntu-26.04-killbit-amd64.iso /mnt/lubuntu-26.04-killbit iso9660 loop,ro,nofail 0 0"
append_fstab_line "$HTTP_ROOT/iso/ubuntu-26.04-live-server-amd64.iso /mnt/ubuntu-server-26.04 iso9660 loop,ro,nofail 0 0"

install -d -m 0755 \
  /mnt/lubuntu-26.04 \
  /mnt/zorin-18.1 \
  /mnt/lubuntu-26.04-killbit \
  /mnt/ubuntu-server-26.04

systemctl daemon-reload
mountpoint -q "$HTTP_ROOT/iso" || mount "$HTTP_ROOT/iso"
mountpoint -q /srv/pxe || mount /srv/pxe
for mount_point in \
  /mnt/lubuntu-26.04 \
  /mnt/zorin-18.1 \
  /mnt/lubuntu-26.04-killbit \
  /mnt/ubuntu-server-26.04; do
  mountpoint -q "$mount_point" || mount "$mount_point"
done

install -d -m 0755 /etc/exports.d
install -m 0644 "$CONFIG_STAGE/pxe.exports" /etc/exports.d/pxe.exports
install -m 0644 "$CONFIG_STAGE/dnsmasq.conf" /etc/dnsmasq.conf

dnsmasq --test
nginx -t

for expected_file in \
  "$HTTP_ROOT/lubuntu-26.04/vmlinuz" \
  "$HTTP_ROOT/lubuntu-26.04/initrd" \
  "$HTTP_ROOT/lubuntu-26.04-killbit/vmlinuz" \
  "$HTTP_ROOT/lubuntu-26.04-killbit/initrd" \
  "$HTTP_ROOT/zorin-18.1/vmlinuz" \
  "$HTTP_ROOT/zorin-18.1/initrd.zstd" \
  "$HTTP_ROOT/ubuntu-server-26.04/vmlinuz" \
  "$HTTP_ROOT/ubuntu-server-26.04/initrd"; do
  [[ -s "$expected_file" ]] || { echo "Fichier de boot absent : $expected_file" >&2; exit 1; }
done

if grep -R -a -F "192.168.0.100" \
  /etc/dnsmasq.conf \
  "$HTTP_ROOT/menu.ipxe" \
  "$TFTP_ROOT/start.ipxe" \
  "$TFTP_ROOT/undionly.kpxe" \
  "$TFTP_ROOT/snponly.efi" >/dev/null; then
  echo "Refus : ancienne adresse .100 encore presente dans la publication." >&2
  exit 1
fi

systemctl disable dnsmasq nginx nfs-server >/dev/null 2>&1 || true
chown -R user:user /home/user/pxe-backups

echo
echo "Publication PXE preparee et validee hors ligne."
echo "Les services dnsmasq, nginx et NFS restent arretes et desactives."
echo "Sauvegarde : $BACKUP_DIR"
echo "Arrete le T800 avant l'activation du T1000."
