#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root

export DEBIAN_FRONTEND=noninteractive

PAQUETS=(
  curl ca-certificates gnupg git build-essential liblzma-dev
  dnsmasq nginx nfs-kernel-server samba wimtools unzip rsync
  squashfs-tools parted e2fsprogs util-linux iproute2
)

# L'ISO live embarque déjà tous ces paquets, précisément pour qu'une clé USB
# fonctionne sans internet. Lancer apt sans réseau échouait alors sur
# « apt-get update », et set -e interrompait toute l'installation : le serveur
# PXE ne montait jamais hors ligne. On ne sollicite apt que s'il manque
# réellement quelque chose.
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
  apt-get install -y "${manquants[@]}"
fi

systemctl disable --now dnsmasq nginx nfs-server smbd nmbd 2>/dev/null || true
echo "Prérequis en place. Les services PXE restent arrêtés."
