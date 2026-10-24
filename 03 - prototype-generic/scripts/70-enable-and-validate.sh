#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

require_command curl
require_command exportfs
require_command systemctl

ip -4 -o addr show dev "$PXE_INTERFACE" | grep -Fq " $PXE_ADDRESS_CIDR " || \
  die "$PXE_ADDRESS_CIDR n'est pas active sur $PXE_INTERFACE."

network_address="$(python3 - "$PXE_SUBNET_CIDR" <<'PY'
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=True).network_address)
PY
)"
grep -Fqx "dhcp-range=$network_address,proxy" /etc/dnsmasq.d/generic-pxe.conf || \
  die "La plage ProxyDHCP ne correspond pas à $PXE_SUBNET_CIDR."

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  die "UFW est actif. Ouvrir explicitement les flux PXE/NFS/Samba nécessaires avant l'activation."
fi

dnsmasq --test
nginx -t
exportfs -ra

services=(nginx nfs-server dnsmasq)
if grep -q '^\[pxe_' /etc/samba/generic-pxe-shares.conf 2>/dev/null; then
  testparm -s >/dev/null
  services+=(smbd)
fi
systemctl enable --now "${services[@]}"

for service in "${services[@]}"; do
  systemctl is-active --quiet "$service" || die "Service inactif : $service"
  systemctl is-enabled --quiet "$service" || die "Service non persistant : $service"
done

curl --fail --silent --show-error "http://$PXE_IP/pxe/menu.ipxe" >/dev/null
[[ -s "$PXE_TFTP_ROOT/undionly.kpxe" && -s "$PXE_TFTP_ROOT/snponly.efi" ]] || \
  die "Chargeurs TFTP absents."

while IFS='|' read -r enabled id type filename url sha label; do
  [[ "$enabled" == yes ]] || continue
  case "$type" in
    casper-iso)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/vmlinuz" >/dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/initrd" >/dev/null
      mountpoint -q "$PXE_NFS_MOUNT_ROOT/$id" || die "Montage NFS absent pour $label."
      ;;
    clonezilla-zip)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/vmlinuz" >/dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/initrd.img" >/dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/filesystem.squashfs" >/dev/null
      ;;
    windows-iso)
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/wimboot" >/dev/null
      curl --fail --silent --show-error "http://$PXE_IP/pxe/$id/media/sources/boot.wim" >/dev/null
      ;;
  esac
done < <(enabled_media)

echo "Serveur PXE actif et contrôlé sur $PXE_ADDRESS_CIDR."
echo "Un démarrage physique BIOS et UEFI reste le contrôle final obligatoire."
