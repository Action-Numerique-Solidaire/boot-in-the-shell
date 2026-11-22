#!/usr/bin/env bash
# Attend qu'une interface porte une adresse IPv4 globale, 120 s au plus.
#
# Lancé avant la publication du démarrage (bits-sync.service). network-online
# ne suffit pas : avec ifupdown, l'interface que l'installateur Debian déclare
# en « allow-hotplug » n'est pas attendue, et la publication partait avant le
# bail DHCP — le serveur PXE restait alors arrêté.
#
# Rend toujours 0 : sans adresse au bout du délai, c'est la publication qui
# échoue, avec un message explicite.
set -uo pipefail
delai="${1:-120}"
for ((i = 0; i < delai; i++)); do
  if ip -4 -o addr show scope global 2>/dev/null | grep -q .; then
    (( i > 0 )) && echo "Adresse IPv4 obtenue après ${i}s."
    exit 0
  fi
  sleep 1
done
echo "Aucune adresse IPv4 après ${delai}s."
exit 0
