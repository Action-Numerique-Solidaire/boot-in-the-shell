#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

require_command curl
require_command exportfs
require_command systemctl

dnsmasq_file="$PXE_STATE_DIR/dnsmasq.conf"
[[ -f "$dnsmasq_file" ]] || die "Configuration dnsmasq absente : $dnsmasq_file (étape 60)."
grep -Fqx "dhcp-range=${PXE_SUBNET_CIDR%/*},proxy" "$dnsmasq_file" || \
  die "La plage ProxyDHCP ne correspond pas à $PXE_SUBNET_CIDR."

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  die "UFW est actif. Ouvrir explicitement les flux PXE/NFS/Samba nécessaires avant l'activation."
fi

dnsmasq --test --conf-file="$dnsmasq_file"
nginx -t
exportfs -ra

services=(nginx nfs-server bits-dnsmasq)
if grep -q '^\[pxe_' /etc/samba/bits-shares.conf 2>/dev/null; then
  testparm -s >/dev/null
  services+=(smbd)
fi
systemctl enable --quiet "${services[@]}"
# restart et non start : la configuration vient d'être réécrite, et un
# dnsmasq déjà lancé garderait l'ancienne adresse ou l'ancienne interface.
systemctl restart "${services[@]}"

for service in "${services[@]}"; do
  systemctl is-active --quiet "$service" || die "Service inactif : $service"
  systemctl is-enabled --quiet "$service" || die "Service non persistant : $service"
done

curl --fail --silent --show-error "http://$PXE_IP/pxe/menu.ipxe" >/dev/null
[[ -s "$PXE_TFTP_ROOT/undionly.kpxe" && -s "$PXE_TFTP_ROOT/snponly.efi" ]] || \
  die "Chargeurs TFTP absents."
# Le menu doit aussi être joignable en TFTP : c'est par là que passe un client
# dont la ROM est déjà iPXE.
[[ -s "$PXE_TFTP_ROOT/menu.ipxe" ]] || die "Menu iPXE absent du répertoire TFTP."

while IFS='|' read -r _ id type _ _ _ label; do
  case "$type" in
    casper-iso)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/vmlinuz" -o /dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/initrd" -o /dev/null
      mountpoint -q "$PXE_NFS_MOUNT_ROOT/$id" || die "Montage NFS absent pour $label."
      ;;
    debian-live-iso)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/vmlinuz" -o /dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/initrd.img" -o /dev/null
      mountpoint -q "$PXE_NFS_MOUNT_ROOT/$id" || die "Montage NFS absent pour $label."
      ;;
    clonezilla-zip)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/vmlinuz" -o /dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/initrd.img" -o /dev/null
      curl --fail --silent --show-error -I "http://$PXE_IP/pxe/$id/filesystem.squashfs" -o /dev/null
      ;;
    windows-iso)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/wimboot" -o /dev/null
      curl --fail --silent --show-error -I "http://$PXE_IP/pxe/$id/media/sources/boot.wim" -o /dev/null
      ;;
  esac
done < <(ready_media)

echo "Serveur PXE actif et contrôlé : $PXE_IP sur $PXE_INTERFACE ($PXE_SUBNET_CIDR)."
