#!/usr/bin/env bash
# Compile les deux chargeurs iPXE (BIOS et UEFI) une fois pour toutes.
#
# Sert à fabriquer une clé USB qui fonctionne SANS INTERNET : sans chargeurs
# pré-compilés, l'étape 50 du pipeline clone iPXE depuis GitHub et le compile
# sur la machine qui démarre, ce qui est impossible hors ligne et long partout.
#
# Le script embarqué ne fige aucune adresse (voir config/boot.ipxe), donc ces
# chargeurs valent pour n'importe quel serveur.
#
# Usage : tools/construire-ipxe.sh <repertoire-de-sortie>
set -Eeuo pipefail

OUT="${1:?Usage: tools/construire-ipxe.sh <repertoire-de-sortie>}"
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO="$RACINE/03 - prototype-generic"
BOOT_IPXE="$PROTO/config/boot.ipxe"

# Épinglés sur les mêmes valeurs que l'assistant de démarrage.
IPXE_GIT_URL="${IPXE_GIT_URL:-https://github.com/ipxe/ipxe.git}"
IPXE_GIT_COMMIT="${IPXE_GIT_COMMIT:-45af75d2af3b85af51bc0d16af5df30abff1935b}"
WORK="${IPXE_WORK:-/srv/ipxe-build}"

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ -f "$BOOT_IPXE" ]] || die "Script embarqué introuvable : $BOOT_IPXE"
for cmd in git make gcc; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd (paquet : git ou build-essential)"
done
# zbin, utilitaire interne d'iPXE, inclut <lzma.h>. Sans l'en-tête, la
# compilation échoue tard et de façon peu lisible : « fatal error: lzma.h: No
# such file or directory » au milieu d'une sortie de make parallèle.
[[ -f /usr/include/lzma.h ]] \
  || die "En-tête lzma.h absent. Corriger avec : sudo apt-get install -y liblzma-dev"

src="$WORK/ipxe"
install -d -m 0755 "$WORK" "$OUT"
if [[ ! -d "$src/.git" ]]; then
  log "Clonage d'iPXE"
  git clone "$IPXE_GIT_URL" "$src"
fi
git -C "$src" fetch --all --tags
git -C "$src" checkout --detach "$IPXE_GIT_COMMIT"

# make découpe la valeur de EMBED sur les espaces. Le dépôt contenant un
# répertoire « 03 - prototype-generic », passer le chemin du script tel quel
# donne « No rule to make target '.../03' ». On le recopie donc sous un chemin
# sans espace avant de le donner à make.
embed="$WORK/boot.ipxe"
install -m 0644 "$BOOT_IPXE" "$embed"
[[ "$embed" != *[[:space:]]* ]] || die "Le chemin de travail contient un espace : $embed"

log "Compilation (commit $IPXE_GIT_COMMIT)"
make -C "$src/src" clean >/dev/null
make -C "$src/src" -j"$(nproc)" bin/undionly.kpxe EMBED="$embed"
make -C "$src/src" -j"$(nproc)" bin-x86_64-efi/snponly.efi EMBED="$embed"

install -m 0644 "$src/src/bin/undionly.kpxe" "$OUT/undionly.kpxe"
install -m 0644 "$src/src/bin-x86_64-efi/snponly.efi" "$OUT/snponly.efi"

# Contrôle : le chargeur doit réellement porter l'URL de repli, sinon il a été
# compilé sans le script embarqué et ne chaînera rien.
# Sans « -q » et avec une redirection : grep -q sort a la premiere
# correspondance, strings recoit alors SIGPIPE et rend 141, et « set -o
# pipefail » transforme ce succes en echec. Le defaut est non deterministe,
# selon que strings a fini d'ecrire ou non.
# shellcheck disable=SC2016  # ${next-server} est la chaîne littérale cherchée
if ! strings "$OUT/snponly.efi" | grep -F 'http://${next-server}/pxe/menu.ipxe' >/dev/null; then
  die "Le chargeur UEFI n'embarque pas le script attendu."
fi

printf '%s  %s\n' "$IPXE_GIT_COMMIT" "commit iPXE" > "$OUT/VERSION"
log "Chargeurs prêts dans $OUT"
ls -l "$OUT"
