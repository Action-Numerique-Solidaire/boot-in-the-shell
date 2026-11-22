#!/usr/bin/env bash
# Construit un dépôt apt « plat » à partir de paquets .deb.
#
# Usage : ./packaging/build-apt-repo.sh <répertoire-de-sortie> <canal> <paquet.deb>...
#
#   canal : stable (tags v*) ou test (tags test-*). Il devient le champ Suite
#           du fichier Release, sur lequel unattended-upgrades fait son filtre.
#
# « Plat » : tous les fichiers au même niveau, sans arborescence dists/ ni
# pool/. C'est ce qui permet de servir le dépôt depuis les fichiers d'une
# release GitHub, qui n'acceptent pas de sous-répertoire. apt demande alors
# <base>/./Release, <base>/./Packages.gz…, chemins que GitHub sert tels quels.
#
# Ligne côté client :
#   deb [trusted=yes] https://github.com/<org>/<dépôt>/releases/download/apt/ ./
#
# Signature : si BITS_APT_GPG_KEY contient une clé privée GPG armurée (sans
# phrase de passe), Release est signé (InRelease et Release.gpg) et la clé
# publique est écrite en bits-archive-keyring.gpg. Sans elle, le dépôt n'est
# pas signé ; il reste servi en HTTPS.
set -Eeuo pipefail

die() { echo "ERREUR : $*" >&2; exit 1; }

[[ $# -ge 3 ]] || die "usage : $0 <répertoire-de-sortie> <stable|test> <paquet.deb>..."
OUT="$1"; CANAL="$2"; shift 2
[[ "$CANAL" =~ ^(stable|test)$ ]] || die "canal inconnu : $CANAL (attendu stable ou test)"
command -v apt-ftparchive >/dev/null || die "apt-ftparchive absent (paquet apt-utils)"

# Le répertoire est vidé avant écriture : il doit donc être neuf, ou n'avoir
# été produit que par ce script. On refuse tout le reste plutôt que d'effacer
# un répertoire de travail désigné par erreur.
if [[ -e "$OUT" ]]; then
  [[ -d "$OUT" ]] || die "$OUT existe et n'est pas un répertoire"
  if [[ -n "$(ls -A "$OUT")" && ! -f "$OUT/Release" ]]; then
    die "$OUT n'est pas vide et ne contient pas de dépôt : refus de l'écraser"
  fi
  find "$OUT" -mindepth 1 -maxdepth 1 -type f -delete
fi
install -d -m 0755 "$OUT"

for deb in "$@"; do
  [[ -f "$deb" && "$deb" == *.deb ]] || die "paquet introuvable : $deb"
  dpkg-deb --info "$deb" >/dev/null || die "paquet illisible : $deb"
  install -m 0644 "$deb" "$OUT/"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$OUT"
apt-ftparchive packages . > Packages
# -n : pas de nom ni d'horodatage dans l'en-tête gzip, pour que deux
# constructions des mêmes paquets donnent le même Packages.gz.
gzip -9 -n -k -f Packages

# Release est écrit hors du répertoire puis déplacé : écrit en place, il
# s'inclurait lui-même, vide, dans la liste des empreintes.
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=BITS \
  -o APT::FTPArchive::Release::Label="Boot in the Shell" \
  -o APT::FTPArchive::Release::Suite="$CANAL" \
  -o APT::FTPArchive::Release::Codename="$CANAL" \
  -o APT::FTPArchive::Release::Architectures="all amd64 arm64" \
  -o APT::FTPArchive::Release::Description="Paquets du serveur PXE Boot in the Shell (canal $CANAL)" \
  release . > "$TMP/Release"
mv "$TMP/Release" Release

if [[ -n "${BITS_APT_GPG_KEY:-}" ]]; then
  command -v gpg >/dev/null || die "gpg absent : impossible de signer"
  export GNUPGHOME="$TMP/gnupg"
  install -d -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --import <<<"$BITS_APT_GPG_KEY"
  fpr="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ {print $10; exit}')"
  [[ -n "$fpr" ]] || die "BITS_APT_GPG_KEY ne contient pas de clé privée"
  gpg --batch --yes --pinentry-mode loopback --local-user "$fpr" \
    --clearsign --output InRelease Release
  gpg --batch --yes --pinentry-mode loopback --local-user "$fpr" \
    --armor --detach-sign --output Release.gpg Release
  gpg --batch --export "$fpr" > bits-archive-keyring.gpg
  echo "Dépôt signé par $fpr" >&2
else
  echo "Dépôt non signé (BITS_APT_GPG_KEY absent)" >&2
fi

ls -1
