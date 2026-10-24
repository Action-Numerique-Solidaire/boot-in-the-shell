#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

if [[ "${PXE_MANAGE_NETWORK:-no}" != "yes" ]]; then
  ip -4 -o addr show dev "$PXE_INTERFACE" | grep -Fq " $PXE_ADDRESS_CIDR " || \
    die "$PXE_ADDRESS_CIDR doit déjà être active sur $PXE_INTERFACE."
  echo "Réseau déjà configuré."
  exit 0
fi

target=/etc/netplan/90-generic-pxe.yaml
backup=/var/backups/generic-pxe-netplan-$(date '+%Y%m%d-%H%M%S')
install -d -m 0700 "$backup"
cp -a /etc/netplan/. "$backup/"
cat > "$target" <<EOF
network:
  version: 2
  ethernets:
    $PXE_INTERFACE:
      dhcp4: false
      addresses: [$PXE_ADDRESS_CIDR]
      routes:
        - to: default
          via: $PXE_GATEWAY
      nameservers:
        addresses: [$PXE_DNS]
EOF
chmod 0600 "$target"
netplan generate
echo "Netplan va appliquer $PXE_ADDRESS_CIDR sur $PXE_INTERFACE."
echo "Confirmer dans l'écran netplan try, sinon la configuration sera annulée automatiquement."
netplan try --timeout 120
ip -4 -o addr show dev "$PXE_INTERFACE" | grep -Fq " $PXE_ADDRESS_CIDR " || die "Adresse attendue inactive."
echo "Réseau configuré. Sauvegarde : $backup"
