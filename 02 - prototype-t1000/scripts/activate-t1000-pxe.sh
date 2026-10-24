#!/usr/bin/env bash
set -Eeuo pipefail

OLD_SERVER_IP="192.168.0.100"
INTERFACE_NAME="enp0s31f6"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

mode="${1:-activate}"
[[ "$mode" == "activate" || "$mode" == "status" ]] || {
  echo "Usage : sudo $0 [activate|status]" >&2
  exit 2
}

active_cidr="$(ip -4 -o addr show dev "$INTERFACE_NAME" scope global | awk 'NR == 1 { print $4 }')"
[[ -n "$active_cidr" ]] || {
  echo "Refus : aucune adresse IPv4 active sur $INTERFACE_NAME." >&2
  exit 1
}
active_ip="${active_cidr%/*}"

check_pxe() {
  local mount_point service_name

  for mount_point in \
    /srv/pxe-data \
    /var/www/html/pxe/iso \
    /srv/pxe \
    /mnt/lubuntu-26.04 \
    /mnt/zorin-18.1 \
    /mnt/lubuntu-26.04-killbit \
    /mnt/ubuntu-server-26.04; do
    mountpoint -q "$mount_point" || {
      echo "Refus : montage absent : $mount_point" >&2
      exit 1
    }
  done

  if command -v ufw >/dev/null && ufw status | grep -Fq "Status: active"; then
    echo "Refus : UFW est actif. Les regles PXE/NFS doivent etre validees." >&2
    exit 1
  fi

  dnsmasq --test
  nginx -t

  for service_name in dnsmasq nginx nfs-server; do
    systemctl is-active --quiet "$service_name" || {
      echo "Echec : service inactif : $service_name" >&2
      exit 1
    }
  done

  if grep -Fq "item windows11 " /var/www/html/pxe/menu.ipxe; then
    systemctl is-active --quiet smbd || {
      echo "Echec : service inactif : smbd" >&2
      exit 1
    }
    testparm -s /etc/samba/smb.conf >/dev/null
    curl -fsSI "http://127.0.0.1/pxe/windows11/wimboot" >/dev/null
    curl -fsSI "http://127.0.0.1/pxe/windows11/media/sources/boot.wim" >/dev/null
  fi

  if grep -Fq "item clonezilla " /var/www/html/pxe/menu.ipxe; then
    curl -fsSI "http://127.0.0.1/pxe/clonezilla-3.3.3-37/vmlinuz" >/dev/null
    curl -fsSI "http://127.0.0.1/pxe/clonezilla-3.3.3-37/initrd.img" >/dev/null
    curl -fsSI "http://127.0.0.1/pxe/clonezilla-3.3.3-37/filesystem.squashfs" >/dev/null
    if grep -Fq "/srv/pxe-data/clonezilla-images" /etc/exports.d/pxe.exports; then
      showmount -e localhost | grep -F "/srv/pxe-data/clonezilla-images" >/dev/null
    fi
  fi

  curl -fsS "http://127.0.0.1/pxe/menu.ipxe" | grep -F "menu Serveur PXE T1000" >/dev/null
  curl -fsS "http://127.0.0.1/pxe/menu.ipxe" | grep -F "$active_ip" >/dev/null
  curl -fsSI "http://127.0.0.1/pxe/lubuntu-26.04/vmlinuz" >/dev/null
  curl -fsSI "http://127.0.0.1/pxe/lubuntu-26.04-killbit/vmlinuz" >/dev/null
  curl -fsSI "http://127.0.0.1/pxe/zorin-18.1/vmlinuz" >/dev/null
  curl -fsSI "http://127.0.0.1/pxe/ubuntu-server-26.04/vmlinuz" >/dev/null
  showmount -e localhost | grep -F "/mnt/ubuntu-server-26.04" >/dev/null
  showmount -e localhost | grep -F "/srv/pxe/lubuntu-26.04-killbit" >/dev/null
}

if [[ "$mode" == "activate" ]]; then
  if ping -c 2 -W 1 "$OLD_SERVER_IP" >/dev/null 2>&1; then
    echo "Refus : le T800 ($OLD_SERVER_IP) repond encore. Eteins-le avant activation." >&2
    exit 1
  fi

  exportfs -ra
  systemctl enable --now nginx
  systemctl enable --now nfs-server
  systemctl enable --now dnsmasq
fi

check_pxe

echo
if [[ "$mode" == "status" ]]; then
  echo "T1000 PXE valide sur $active_cidr."
else
  echo "T1000 PXE active avec succes sur $active_ip."
fi
echo "Les services dnsmasq, nginx et NFS sont actifs et persistants."
if grep -Fq "item windows11 " /var/www/html/pxe/menu.ipxe; then
  echo "Windows 11 : wimboot, WinPE et Samba sont disponibles."
fi
if grep -Fq "item clonezilla " /var/www/html/pxe/menu.ipxe; then
  echo "Clonezilla : noyau, initrd et squashfs sont disponibles."
  if grep -Fq "/srv/pxe-data/clonezilla-images" /etc/exports.d/pxe.exports; then
    echo "Clonezilla : depot NFS d'images disponible en lecture/ecriture."
  fi
fi
