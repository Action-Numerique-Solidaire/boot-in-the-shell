#!/usr/bin/env bash
# Construit bits-pxe-server_<version>_all.deb : les scripts du prototype
# générique, installables sur un serveur Debian/Ubuntu.
#
# Usage : ./packaging/build-deb.sh [version] [repertoire-de-sortie]
#
# Volontairement en dpkg-deb seul, sans debhelper : le paquet ne contient que
# des scripts shell et de la configuration, et ça le rend constructible sur
# n'importe quelle machine (ou runner CI) sans chaîne de packaging complète.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROTO_SRC="$REPO_ROOT/03 - prototype-generic"

VERSION="${1:-0.1.0}"
OUT_DIR="${2:-$REPO_ROOT/out}"
PKG="bits-pxe-server"

# Une version Debian ne doit pas commencer par autre chose qu'un chiffre :
# on accepte donc « v1.2.3 » en entrée et on retire le v.
VERSION="${VERSION#v}"

[[ -d "$PROTO_SRC" ]] || { echo "ERREUR : introuvable : $PROTO_SRC" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "ERREUR : dpkg-deb absent" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# mktemp crée en 0700 : sans ça, la racine du paquet porterait des droits
# restrictifs et lintian le signalerait (dir-or-file-in-... / unusual-mode).
chmod 0755 "$STAGE"

# --- arborescence ------------------------------------------------------------
install -d -m 0755 \
  "$STAGE/DEBIAN" \
  "$STAGE/usr/share/$PKG/scripts/lib" \
  "$STAGE/usr/sbin" \
  "$STAGE/etc/$PKG" \
  "$STAGE/usr/share/doc/$PKG"

install -m 0755 "$PROTO_SRC/scripts/"*.sh      "$STAGE/usr/share/$PKG/scripts/"
install -m 0644 "$PROTO_SRC/scripts/lib/"*.sh  "$STAGE/usr/share/$PKG/scripts/lib/"

# La configuration part dans /etc en conffiles : dpkg préservera les
# modifications de l'administrateur lors d'une mise à jour.
install -m 0644 "$PROTO_SRC/config/pxe.env.example"   "$STAGE/etc/$PKG/pxe.env"
install -m 0644 "$PROTO_SRC/config/media.conf.example" "$STAGE/etc/$PKG/media.conf"

install -m 0644 "$PROTO_SRC/README.md"   "$STAGE/usr/share/doc/$PKG/"
install -m 0644 "$PROTO_SRC/PLAYBOOK.md" "$STAGE/usr/share/doc/$PKG/"

# --- point d'entrée ----------------------------------------------------------
# lib/common.sh honore PXE_CONFIG_FILE et PXE_MEDIA_FILE : aucun script du
# prototype n'a besoin d'être modifié pour être empaqueté.
cat > "$STAGE/usr/sbin/bits-pxe-install" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
export PXE_CONFIG_FILE="${PXE_CONFIG_FILE:-/etc/bits-pxe-server/pxe.env}"
export PXE_MEDIA_FILE="${PXE_MEDIA_FILE:-/etc/bits-pxe-server/media.conf}"

if [[ $# -eq 0 ]]; then
  cat >&2 <<USAGE
Usage : sudo bits-pxe-install --prepare-data-disk | --reuse-data-disk

  --prepare-data-disk   ATTENTION : efface entièrement le disque désigné par
                        PXE_DATA_DISK dans $PXE_CONFIG_FILE.
  --reuse-data-disk     Réutilise un disque de données déjà préparé.

Configurer $PXE_CONFIG_FILE avant la première exécution.
USAGE
  exit 2
fi

exec /usr/share/bits-pxe-server/scripts/install.sh "$@"
WRAPPER
chmod 0755 "$STAGE/usr/sbin/bits-pxe-install"

# --- métadonnées -------------------------------------------------------------
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Action Numérique Solidaire <contact@actionnumeriquesolidaire.org>
Depends: bash (>= 5.0), curl, ca-certificates, gnupg, git, build-essential,
 liblzma-dev, dnsmasq, nginx, nfs-kernel-server, samba, wimtools, unzip,
 rsync, squashfs-tools, parted, e2fsprogs, util-linux, iproute2
Homepage: https://github.com/Action-Numerique-Solidaire/boot-in-the-shell
Description: Serveur de démarrage PXE pour le reconditionnement de PC
 « Boot in the Shell » déploie un serveur PXE complet permettant de démarrer
 des ISO de diagnostic matériel et de masteriser des postes à reconditionner
 (installation d'OS, clonage Clonezilla).
 .
 Le paquet installe les scripts du pipeline générique et le point d'entrée
 bits-pxe-install. Configurer /etc/bits-pxe-server/pxe.env, puis lancer
 « sudo bits-pxe-install --prepare-data-disk ».
 .
 dnsmasq est utilisé en ProxyDHCP uniquement, afin de coexister avec le
 serveur DHCP existant du réseau : ce paquet ne distribue jamais d'adresses.
CONTROL

# Les fichiers de /etc sont déclarés conffiles pour ne pas écraser une
# configuration en place lors d'une mise à jour.
cat > "$STAGE/DEBIAN/conffiles" <<CONFFILES
/etc/$PKG/pxe.env
/etc/$PKG/media.conf
CONFFILES

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  chmod 0600 /etc/bits-pxe-server/pxe.env || true
  cat <<'MSG'

bits-pxe-server est installé.

  1. Éditer /etc/bits-pxe-server/pxe.env (interface, adresses, disque de données).
     PXE_DATA_DISK doit être un identifiant stable /dev/disk/by-id/...
  2. Choisir les médias dans /etc/bits-pxe-server/media.conf.
  3. Lancer : sudo bits-pxe-install --prepare-data-disk

MSG
fi
exit 0
POSTINST
chmod 0755 "$STAGE/DEBIAN/postinst"

# --- construction ------------------------------------------------------------
install -d -m 0755 "$OUT_DIR"
DEB="$OUT_DIR/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null
echo "$DEB"
