#!/usr/bin/env bash
# Construit les paquets de Boot in the Shell, installables sur Debian et Ubuntu :
#
#   bits-pxe-server_<version>_all.deb   le serveur PXE et bitsctl
#   bits-web_<version>_all.deb          l'interface web
#
# Affiche le chemin de chaque paquet produit, un par ligne.
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
PKG_SRC="$SCRIPT_DIR/bits-pxe-server"

VERSION="${1:-0.1.0}"
OUT_DIR="${2:-$REPO_ROOT/out}"
PKG="bits-pxe-server"

# Une version Debian ne doit pas commencer par autre chose qu'un chiffre :
# on accepte donc « v1.2.3 » en entrée et on retire le v.
VERSION="${VERSION#v}"

[[ -d "$PROTO_SRC" ]] || { echo "ERREUR : introuvable : $PROTO_SRC" >&2; exit 1; }
[[ -d "$PKG_SRC" ]] || { echo "ERREUR : introuvable : $PKG_SRC" >&2; exit 1; }
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
  "$STAGE/usr/share/$PKG/config" \
  "$STAGE/usr/sbin" \
  "$STAGE/usr/lib/systemd/system" \
  "$STAGE/etc/$PKG" \
  "$STAGE/usr/share/doc/$PKG"

install -m 0755 "$PROTO_SRC/scripts/"*.sh "$PROTO_SRC/scripts/"*.py "$STAGE/usr/share/$PKG/scripts/"
install -m 0644 "$PROTO_SRC/scripts/lib/"*.sh  "$STAGE/usr/share/$PKG/scripts/lib/"
# Script embarqué dans iPXE, pour la compilation facultative (étape 50).
install -m 0644 "$PROTO_SRC/config/boot.ipxe"  "$STAGE/usr/share/$PKG/config/"

install -m 0755 "$PKG_SRC/bitsctl"               "$STAGE/usr/sbin/bitsctl"
install -m 0644 "$PKG_SRC/bits-dnsmasq.service"  "$STAGE/usr/lib/systemd/system/"
install -m 0644 "$PKG_SRC/bits-sync.service"     "$STAGE/usr/lib/systemd/system/"
install -m 0644 "$PKG_SRC/bits-lan.service"      "$STAGE/usr/lib/systemd/system/"
install -m 0644 "$PKG_SRC/bits-telechargement@.service" "$STAGE/usr/lib/systemd/system/"

# La configuration part dans /etc en conffiles : dpkg préservera les
# modifications de l'administrateur lors d'une mise à jour.
install -m 0644 "$PROTO_SRC/config/pxe.env.example"   "$STAGE/etc/$PKG/pxe.env"
install -m 0644 "$PROTO_SRC/config/media.conf.example" "$STAGE/etc/$PKG/media.conf"
# Catalogue de référence, hors /etc : mis à jour avec le paquet (voir bitsctl).
install -m 0644 "$PROTO_SRC/config/media.conf.example" "$STAGE/usr/share/$PKG/catalogue.conf"

install -m 0644 "$PROTO_SRC/README.md"   "$STAGE/usr/share/doc/$PKG/"
install -m 0644 "$PROTO_SRC/PLAYBOOK.md" "$STAGE/usr/share/doc/$PKG/"

# --- point d'entrée historique ---------------------------------------------------
# Conservé pour les installations existantes ; « bitsctl apply » fait la même
# chose, journalisé.
cat > "$STAGE/usr/sbin/bits-pxe-install" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
export PXE_CONFIG_FILE="${PXE_CONFIG_FILE:-/etc/bits-pxe-server/pxe.env}"
export PXE_MEDIA_FILE="${PXE_MEDIA_FILE:-/etc/bits-pxe-server/media.conf}"

case "${1:-}" in
  --prepare-data-disk)
    exec /usr/share/bits-pxe-server/scripts/install.sh --prepare-data-disk ;;
  ""|--reuse-data-disk)
    exec /usr/sbin/bitsctl apply ;;
  *)
    cat >&2 <<USAGE
Usage : sudo bits-pxe-install [--prepare-data-disk]

  sans option           équivaut à « bitsctl apply ».
  --prepare-data-disk   ATTENTION : efface entièrement le disque désigné par
                        PXE_DATA_DISK dans $PXE_CONFIG_FILE, puis publie.
USAGE
    exit 2 ;;
esac
WRAPPER
chmod 0755 "$STAGE/usr/sbin/bits-pxe-install"

# --- métadonnées -------------------------------------------------------------
# Dépendances : le socle seulement. Ce que demande un type de média (samba et
# wimtools pour Windows, parted pour un disque dédié) est en Suggests, et
# installé à la demande par l'étape 10 quand ce média est activé.
#
# dnsmasq-base et non dnsmasq : le binaire sans son service, qui est un
# serveur DNS. BITS lance sa propre instance (bits-dnsmasq.service, port=0).
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Action Numérique Solidaire <contact@actionnumeriquesolidaire.org>
Depends: bash (>= 5.0), systemd, python3, curl, ca-certificates, iproute2,
 util-linux, mount, dnsmasq-base, nginx, nfs-kernel-server, ipxe, unzip,
 nftables
Suggests: samba, wimtools, rsync, parted, e2fsprogs, wpasupplicant, iw
Homepage: https://github.com/Action-Numerique-Solidaire/boot-in-the-shell
Description: Serveur de démarrage PXE pour le reconditionnement de PC
 « Boot in the Shell » sert en PXE des images d'installation, de diagnostic
 et d'effacement (Ubuntu, Zorin OS, Killbit, Clonezilla…) aux postes à
 reconditionner, en BIOS et en UEFI.
 .
 Le réseau est lu sur l'interface active, rien n'est à configurer pour
 commencer. Choisir les images (« bitsctl media enable <id> »), puis
 « sudo bitsctl apply » : elles sont téléchargées, vérifiées et publiées, et
 la publication est rejouée à chaque démarrage.
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

# Installer le paquet n'active RIEN : répondre aux démarrages PXE d'un réseau
# est une décision, pas un effet de bord d'apt. Le serveur démarre à la
# première publication (bitsctl apply), et ensuite à chaque démarrage.
cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  install -d -m 0755 /var/lib/bits /var/log/bits /srv/bits-data
  # media.conf est un conffile, modifié dès qu'une image est activée : une
  # mise à jour ne le remplace pas. Killbit suivait la pré-release « latest »
  # (chaque commit) ; on le fait suivre la dernière version publiée.
  if [ -f /etc/bits-pxe-server/media.conf ]; then
    sed -i 's#/killbit-image/releases/download/latest/#/killbit-image/releases/latest/download/#g' /etc/bits-pxe-server/media.conf
  fi
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    # Mise à jour d'un serveur déjà en service : republier avec la nouvelle
    # version, en arrière-plan pour ne pas bloquer apt.
    if [ -n "$2" ] && systemctl is-enabled --quiet bits-sync.service 2>/dev/null; then
      systemctl start --no-block bits-sync.service || true
    fi
  fi
  if [ -z "$2" ]; then
    cat <<'MSG'

bits-pxe-server est installé. Le serveur PXE n'est PAS encore actif.

  sudo bitsctl media list              images disponibles
  sudo bitsctl media enable killbit    en activer une
  sudo bitsctl apply                   publier, et activer le serveur
  sudo bitsctl status                  état

MSG
  fi
fi
exit 0
POSTINST

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
if [ "$1" = "remove" ]; then
  # Mode passerelle : adresse du réseau PXE, NAT et routage retirés.
  /usr/share/bits-pxe-server/scripts/bits-passerelle.sh --retirer || true
  if [ -d /run/systemd/system ]; then
    systemctl disable --now bits-sync.service bits-dnsmasq.service bits-lan.service 2>/dev/null || true
  else
    systemctl disable bits-sync.service bits-dnsmasq.service bits-lan.service 2>/dev/null || true
  fi
fi
exit 0
PRERM

cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "purge" ]; then
  rm -rf /var/lib/bits /var/log/bits
  # Compléments de configuration hors conffile (mode écrit par la clé
  # d'installation) : dpkg ne les connaît pas.
  rm -rf /etc/bits-pxe-server/pxe.env.d
  rmdir /etc/bits-pxe-server 2>/dev/null || true
  echo "Les images téléchargées restent dans /srv/bits-data : à supprimer à la main si besoin."
fi
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload || true
fi
exit 0
POSTRM
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"

# --- construction ------------------------------------------------------------
install -d -m 0755 "$OUT_DIR"
DEB="$OUT_DIR/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null
echo "$DEB"

# =============================================================================
# bits-web : l'interface web. Paquet séparé : bits-pxe-server s'installe et se
# pilote sans elle (bitsctl), sur une machine qui a déjà un site web.
# =============================================================================
WEB="bits-web"
WEB_SRC="$SCRIPT_DIR/bits-web"
WSTAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$WSTAGE"' EXIT
chmod 0755 "$WSTAGE"

install -d -m 0755 \
  "$WSTAGE/DEBIAN" \
  "$WSTAGE/usr/share/$WEB" \
  "$WSTAGE/usr/lib/systemd/system" \
  "$WSTAGE/etc/nginx/sites-available" \
  "$WSTAGE/etc/issue.d" \
  "$WSTAGE/usr/share/doc/$WEB"
install -d -m 0750 "$WSTAGE/etc/sudoers.d"

install -m 0755 "$WEB_SRC/bits-web.py"      "$WSTAGE/usr/share/$WEB/bits-web.py"
install -m 0644 "$WEB_SRC/index.html"       "$WSTAGE/usr/share/$WEB/index.html"
install -m 0644 "$WEB_SRC/bits-web.service" "$WSTAGE/usr/lib/systemd/system/"
install -m 0644 "$WEB_SRC/nginx-bits.conf"  "$WSTAGE/etc/nginx/sites-available/bits"
install -m 0644 "$WEB_SRC/bits.issue"       "$WSTAGE/etc/issue.d/bits.issue"
# sudo ignore un fichier de sudoers.d qui n'est pas en 0440 et root.
install -m 0440 "$WEB_SRC/sudoers"          "$WSTAGE/etc/sudoers.d/bits-web"

cat > "$WSTAGE/DEBIAN/control" <<CONTROL
Package: $WEB
Version: $VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Action Numérique Solidaire <contact@actionnumeriquesolidaire.org>
Depends: bits-pxe-server (= $VERSION), systemd, python3, nginx, sudo, iproute2
Homepage: https://github.com/Action-Numerique-Solidaire/boot-in-the-shell
Description: Interface web du serveur PXE Boot in the Shell
 Page web servie sur le port 80 du serveur PXE : liste des images que le
 serveur peut proposer (Ubuntu, Zorin OS, Killbit, Clonezilla…), activation
 ou désactivation de chacune, publication et journal en direct.
 .
 Le service tourne sans privilège ; sudo ne lui accorde que l'activation
 d'une image et le lancement de la publication. Il prend la place du site
 « default » de nginx, s'il n'a pas été modifié.
CONTROL

cat > "$WSTAGE/DEBIAN/conffiles" <<CONFFILES
/etc/nginx/sites-available/bits
/etc/sudoers.d/bits-web
/etc/issue.d/bits.issue
CONFFILES

# Installer l'interface, c'est vouloir la voir : contrairement au serveur PXE,
# elle est activée et démarrée tout de suite.
cat > "$WSTAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if ! getent passwd bits-web >/dev/null; then
    adduser --system --group --no-create-home --home /nonexistent \
      --gecos "Interface web de Boot in the Shell" bits-web >/dev/null
  fi
  install -d -m 0755 /var/lib/bits-web

  # Le site « default » de nginx écoute aussi en default_server sur le port
  # 80 : on ne le désactive que s'il est intact, et on le note pour le
  # réactiver à la désinstallation.
  # « Intact » : le lien pointe sur le fichier livré, et ce fichier a encore
  # l'empreinte que dpkg a enregistrée pour ce conffile.
  site_ok=1
  if [ -L /etc/nginx/sites-enabled/default ]; then
    cible="$(readlink -f /etc/nginx/sites-enabled/default)"
    attendu="$(dpkg-query -W -f='${Conffiles}\n' nginx-common nginx 2>/dev/null \
      | awk '$1 == "/etc/nginx/sites-available/default" { print $2; exit }')"
    actuel="$(md5sum /etc/nginx/sites-available/default 2>/dev/null | cut -d' ' -f1)"
    if [ "$cible" = /etc/nginx/sites-available/default ] && [ -n "$attendu" ] && [ "$attendu" = "$actuel" ]; then
      rm -f /etc/nginx/sites-enabled/default
      touch /var/lib/bits-web/default-desactive
    else
      site_ok=0
    fi
  fi
  if [ "$site_ok" = 1 ]; then
    ln -sfn /etc/nginx/sites-available/bits /etc/nginx/sites-enabled/bits
  else
    echo "bits-web : le site nginx « default » a été modifié, il est laissé en place."
    echo "           Activer l'interface à la main : /etc/nginx/sites-available/bits"
  fi

  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || systemctl restart nginx || true
    else
      echo "bits-web : nginx -t échoue, nginx n'est pas rechargé :"; nginx -t || true
    fi
    systemctl enable bits-web.service >/dev/null 2>&1 || true
    systemctl restart bits-web.service || true
  else
    systemctl enable bits-web.service >/dev/null 2>&1 || true
  fi
fi
exit 0
POSTINST

cat > "$WSTAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
if [ "$1" = "remove" ]; then
  if [ -d /run/systemd/system ]; then
    systemctl disable --now bits-web.service 2>/dev/null || true
  else
    systemctl disable bits-web.service 2>/dev/null || true
  fi
fi
exit 0
PRERM

cat > "$WSTAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  rm -f /etc/nginx/sites-enabled/bits
  if [ -e /var/lib/bits-web/default-desactive ] && [ -e /etc/nginx/sites-available/default ]; then
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /var/lib/bits-web/default-desactive
  fi
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  fi
fi
if [ "$1" = "purge" ]; then
  rm -rf /var/lib/bits-web
fi
exit 0
POSTRM
chmod 0755 "$WSTAGE/DEBIAN/postinst" "$WSTAGE/DEBIAN/prerm" "$WSTAGE/DEBIAN/postrm"

WDEB="$OUT_DIR/${WEB}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$WSTAGE" "$WDEB" >/dev/null
echo "$WDEB"
