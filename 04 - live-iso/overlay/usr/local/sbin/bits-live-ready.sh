#!/usr/bin/env bash
# Annonce sur la console que le système live a réellement atteint un état
# utilisable, et résume ce que la machine voit.
#
# Ce marqueur existe parce qu'une ISO peut contenir tous les bons fichiers et
# paniquer au démarrage. Aucune vérification de contenu ne distingue un noyau
# qui panique d'un démarrage lent : il faut que le système dise lui-même qu'il
# est arrivé. C'est ce que `tests/boot-test.sh` attend.
#
# Il s'exécute AVANT l'assistant : l'assistant est interactif et ne rend la main
# qu'une fois le serveur PXE installé, donc un marqueur posé après lui ne
# prouverait plus que le démarrage.
set -Eeuo pipefail

MARKER="BITS-LIVE-READY"

echo "== Boot in the Shell -- système live =="
echo "noyau   : $(uname -r)"
echo "hôte    : $(cat /etc/hostname 2>/dev/null || echo inconnu)"

echo "réseau  :"
ip -4 -o addr show scope global 2>/dev/null | awk '{printf "          %s %s\n", $2, $4}' \
  || echo "          aucune adresse IPv4"

echo "disques :"
lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3 == "disk" {printf "          %s\n", $0}' \
  || echo "          aucun disque détecté"

# Le marqueur en dernier : un test qui le voit sait que tout ce qui précède a
# été produit par un système vivant.
echo "$MARKER"
