#!/usr/bin/env bash
# Attend une route par défaut (l'accès à internet), 120 s au plus.
#
# Lancé avant la publication du démarrage (bits-sync.service). network-online
# ne suffit pas : avec ifupdown, l'interface que l'installateur Debian déclare
# en « allow-hotplug » n'est pas attendue, et la publication partait avant le
# bail DHCP — le serveur PXE restait alors arrêté.
#
# Une route par défaut et non une simple adresse : en mode passerelle,
# l'adresse du réseau PXE est posée dès le démarrage (bits-lan.service), bien
# avant que le Wi-Fi ne soit associé.
#
# Rend toujours 0 : la publication se fait quand même, avec les images déjà
# téléchargées.
set -uo pipefail
delai="${1:-120}"
for ((i = 0; i < delai; i++)); do
  if ip -4 route show default 2>/dev/null | grep -q .; then
    (( i > 0 )) && echo "Route par défaut obtenue après ${i}s."
    exit 0
  fi
  sleep 1
done
echo "Aucune route par défaut après ${delai}s : publication sans accès à internet."
exit 0
