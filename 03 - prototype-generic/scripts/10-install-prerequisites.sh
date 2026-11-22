#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

export DEBIAN_FRONTEND=noninteractive

# Le socle (dnsmasq-base, nginx, nfs-kernel-server, ipxe…) est tiré par les
# dépendances du paquet bits-pxe-server. Ne reste ici que ce qu'un type de
# média demande en plus, installé seulement si un tel média est activé : un
# serveur qui ne sert pas Windows n'a besoin ni de samba ni de wimtools.
PAQUETS=(curl ca-certificates python3 iproute2 util-linux unzip nginx nfs-kernel-server)
if enabled_media | awk -F '|' '$3 == "windows-iso" { found = 1 } END { exit !found }'; then
  PAQUETS+=(samba wimtools rsync)
fi
[[ -n "$PXE_DATA_DISK" ]] && PAQUETS+=(parted e2fsprogs)
command -v dnsmasq >/dev/null || PAQUETS+=(dnsmasq-base)

# On ne sollicite apt que s'il manque réellement quelque chose : sans réseau,
# « apt-get update » échouerait et interromprait une installation complète.
manquants=()
for paquet in "${PAQUETS[@]}"; do
  dpkg-query -W -f='${Status}' "$paquet" 2>/dev/null | grep -q "^install ok installed$" \
    || manquants+=("$paquet")
done

if [[ ${#manquants[@]} -eq 0 ]]; then
  echo "Prérequis déjà présents, apt n'est pas sollicité (${#PAQUETS[@]} paquets)."
else
  echo "Paquets manquants : ${manquants[*]}"
  apt-get update || die "Dépôts injoignables et ${#manquants[@]} paquet(s) manquant(s) : ${manquants[*]}"
  apt-get install -y --no-install-recommends "${manquants[@]}"
fi

# Le service dnsmasq du système (paquet « dnsmasq », s'il est installé) est un
# serveur DNS ; BITS a sa propre instance, bits-dnsmasq.service, sans DNS.
# Les deux à la fois se disputeraient les ports DHCP et TFTP.
if systemctl is-active --quiet dnsmasq.service 2>/dev/null; then
  die "dnsmasq.service est actif : il entrerait en conflit avec bits-dnsmasq.service. L'arrêter (systemctl disable --now dnsmasq) ou le désinstaller."
fi
echo "Prérequis en place."
