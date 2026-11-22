#!/usr/bin/env bash
# Construit l'ISO d'amorçage de Boot in the Shell : le mini.iso officiel de
# Debian 13 (installation par le réseau, ~65 Mo) avec le preseed BITS.
#
# Gravée sur une clé USB, elle installe un Debian minimal sur le disque interne,
# ajoute le dépôt apt de BITS, installe bits-pxe-server et bits-web, ouvre SSH à
# root (mot de passe « admin ») et active les mises à jour automatiques. Au
# redémarrage, le serveur PXE répond, et la console affiche l'adresse de
# l'interface web et la commande SSH.
#
# Aucun paquet n'est embarqué : tout vient du réseau pendant l'installation.
#
# Usage : ./build-bootstrap-iso.sh <sortie.iso> [options]
#
#   --canal test|stable   dépôt BITS à utiliser (défaut : test, phase alpha)
#   --depot <url>         URL de base d'un autre dépôt apt plat
#   --test                variante pour les tests automatiques : l'entrée
#                         d'installation part seule après 1 s. Rien d'autre
#                         ne change. À ne PAS graver.
#   --console-serie       ajoute la console série, pour le seul contrôle
#                         d'amorçage de la CI (tests/boot-test.sh) : sur une
#                         ligne série l'installateur s'arrête sur le choix de
#                         la langue. À ne PAS graver.
#
# Variables : BITS_ISO_CACHE (cache du mini.iso, défaut ~/.cache/bits-iso).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBIAN_ARCHIVE=https://deb.debian.org/debian/dists/trixie
IMAGES="$DEBIAN_ARCHIVE/main/installer-amd64/current/images"
DEPOT_BASE=https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases/download
CACHE="${BITS_ISO_CACHE:-$HOME/.cache/bits-iso}"

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[iso %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

SORTIE="" CANAL=test DEPOT="" TEST=0 SERIE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --canal) CANAL="${2:?}"; shift 2 ;;
    --depot) DEPOT="${2:?}"; shift 2 ;;
    --test)  TEST=1; shift ;;
    --console-serie) SERIE=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "option inconnue : $1" ;;
    *)  [[ -z "$SORTIE" ]] || die "une seule sortie attendue"; SORTIE="$1"; shift ;;
  esac
done
[[ -n "$SORTIE" ]] || die "usage : $0 <sortie.iso> [--canal test|stable] [--depot <url>] [--test]"
case "$CANAL" in
  stable) DEPOT="${DEPOT:-$DEPOT_BASE/apt/}" ;;
  test)   DEPOT="${DEPOT:-$DEPOT_BASE/apt-test/}" ;;
  *)      die "canal inconnu : $CANAL" ;;
esac
[[ "$DEPOT" == */ ]] || DEPOT="$DEPOT/"
for c in curl xorriso cpio gzip sha256sum; do command -v "$c" >/dev/null || die "commande absente : $c"; done

# --- 1. mini.iso de Debian 13, vérifié ---------------------------------------------
install -d -m 0755 "$CACHE"
log "mini.iso de Debian 13"
curl -fsSL "$IMAGES/SHA256SUMS" -o "$CACHE/SHA256SUMS"
attendu="$(awk '$2 == "./netboot/mini.iso" { print $1 }' "$CACHE/SHA256SUMS")"
[[ "$attendu" =~ ^[0-9a-f]{64}$ ]] || die "netboot/mini.iso absent de $IMAGES/SHA256SUMS"

# Le SHA256SUMS des images est lui-même listé dans le Release signé de
# l'archive : on remonte la chaîne jusqu'à la clé de Debian quand le
# trousseau est disponible (paquet debian-archive-keyring).
trousseau=/usr/share/keyrings/debian-archive-keyring.gpg
verifie=0
if [[ -f "$trousseau" ]] && command -v gpgv >/dev/null; then
  curl -fsSL "$DEBIAN_ARCHIVE/InRelease" -o "$CACHE/InRelease"
  etat_sig="$(gpgv --status-fd 1 --keyring "$trousseau" "$CACHE/InRelease" 2>/dev/null || true)"
  # Mauvaise signature : arrêt. Clé inconnue : le trousseau de l'hôte est
  # antérieur aux clés de Debian 13 (cas d'un Ubuntu 24.04), la signature est
  # invérifiable ici, pas fausse.
  if grep -q "^\[GNUPG:\] BADSIG" <<<"$etat_sig"; then
    die "signature de InRelease INVALIDE"
  elif grep -q "^\[GNUPG:\] GOODSIG" <<<"$etat_sig"; then
    verifie=1
  else
    echo "  AVERTISSEMENT : trousseau Debian de l'hôte trop ancien pour Debian 13, signature non vérifiée (HTTPS seul)"
  fi
fi
if (( verifie )); then
  sums="$(awk '/^SHA256:/ { s = 1; next } /^[A-Za-z]/ { s = 0 } s && $3 == "main/installer-amd64/current/images/SHA256SUMS" { print $1; exit }' "$CACHE/InRelease")"
  [[ -n "$sums" ]] || die "SHA256SUMS des images absent de InRelease"
  echo "$sums  $CACHE/SHA256SUMS" | sha256sum -c --status - || die "SHA256SUMS des images ne correspond pas à InRelease"
  echo "  chaîne vérifiée jusqu'à la signature de l'archive Debian"
elif [[ ! -f "$trousseau" ]]; then
  echo "  AVERTISSEMENT : trousseau Debian absent, signature de l'archive non vérifiée (HTTPS seul)"
fi

if [[ ! -f "$CACHE/mini.iso" ]] || ! echo "$attendu  $CACHE/mini.iso" | sha256sum -c --status -; then
  curl -fsSL "$IMAGES/netboot/mini.iso" -o "$CACHE/mini.iso.part"
  echo "$attendu  $CACHE/mini.iso.part" | sha256sum -c --status - || die "empreinte de mini.iso incorrecte"
  mv -f "$CACHE/mini.iso.part" "$CACHE/mini.iso"
fi
echo "  mini.iso vérifié ($(du -h "$CACHE/mini.iso" | cut -f1))"

# --- 2. preseed ajouté à l'initrd ----------------------------------------------------
TRAVAIL="$(mktemp -d)"
trap 'rm -rf "$TRAVAIL"' EXIT
install -d -m 0755 "$TRAVAIL/racine/bits"
# /preseed.cfg est chargé par l'installateur pour toute entrée du menu
# (S30initrd-preseed) ; il n'inclut bits/preseed.cfg que sur bits=installer.
install -m 0644 "$SCRIPT_DIR/preseed/racine.cfg"        "$TRAVAIL/racine/preseed.cfg"
install -m 0644 "$SCRIPT_DIR/preseed/preseed.cfg"       "$TRAVAIL/racine/bits/"
install -m 0755 "$SCRIPT_DIR/preseed/choisir-disque.sh" "$TRAVAIL/racine/bits/"
install -m 0755 "$SCRIPT_DIR/preseed/late.sh"           "$TRAVAIL/racine/bits/"
printf "BITS_DEPOT='deb [trusted=yes] %s ./'\n" "$DEPOT" > "$TRAVAIL/racine/bits/bits.conf"

log "Preseed (dépôt : $DEPOT)"
xorriso -osirrox on -indev "$CACHE/mini.iso" -extract /initrd.gz "$TRAVAIL/initrd.gz" >/dev/null 2>&1
chmod u+w "$TRAVAIL/initrd.gz"
# Le noyau accepte plusieurs archives cpio compressées mises bout à bout :
# l'initrd d'origine reste intact, /bits y est simplement ajouté.
(cd "$TRAVAIL/racine" && find preseed.cfg bits -print | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) \
  | gzip -9 -n >> "$TRAVAIL/initrd.gz"

# --- 3. menus d'amorçage ---------------------------------------------------------------
# Aucun choix par défaut ni délai : l'installation EFFACE le disque interne.
# Une clé restée branchée sur une machine qui redémarre attend qu'on choisisse,
# au lieu de réinstaller. Seule l'entrée BITS passe bits=installer.
params_bits="bits=installer priority=critical locale=fr_FR.UTF-8 keymap=fr"
params_fin="quiet"
delai_grub="set timeout=-1"
delai_syslinux="timeout 0"
defaut_syslinux=""
if (( TEST )); then
  # Seul le délai change. Pas de console série : sur une ligne série,
  # l'installateur ne propose que les langues affichables en ASCII, ignore la
  # langue préréglée et pose la question — la variante de test ne serait plus
  # la même installation que la vraie.
  delai_grub="set timeout=1
set default=0"
  delai_syslinux="timeout 10"
  defaut_syslinux="  menu default"
fi
(( SERIE )) && params_fin="quiet console=tty0 console=ttyS0,115200n8"

cat > "$TRAVAIL/isolinux.cfg" <<EOF
# Écrit par build-bootstrap-iso.sh (Boot in the Shell)
path
ui vesamenu.c32
include stdmenu.cfg
menu title Boot in the Shell - installation du serveur PXE
$delai_syslinux

label bits
  menu label ^Installer le serveur BITS (EFFACE le disque interne)
$defaut_syslinux
  kernel linux
  append vga=788 initrd=initrd.gz $params_bits --- $params_fin

label manuel
  menu label Installation Debian ^manuelle (sans BITS, sans effacement automatique)
  kernel linux
  append vga=788 initrd=initrd.gz --- quiet

label local
  menu label Demarrer sur le ^disque local
  localboot 0x80
EOF

cat > "$TRAVAIL/grub.cfg" <<EOF
# Écrit par build-bootstrap-iso.sh (Boot in the Shell)
if [ x\$feature_default_font_path = xy ] ; then
   font=unicode
else
   font=\$prefix/font.pf2
fi
if loadfont \$font ; then
  set gfxmode=800x600
  set gfxpayload=keep
  insmod efi_gop
  insmod efi_uga
  insmod video_bochs
  insmod video_cirrus
  insmod gfxterm
  terminal_output gfxterm
fi
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue
$delai_grub

menuentry 'Installer le serveur BITS (EFFACE le disque interne)' {
    set background_color=black
    linux    /linux $params_bits vga=788 --- $params_fin
    initrd   /initrd.gz
}
menuentry 'Installation Debian manuelle (sans BITS, sans effacement automatique)' {
    set background_color=black
    linux    /linux vga=788 --- quiet
    initrd   /initrd.gz
}
menuentry 'Démarrer sur le disque local' {
    exit
}
EOF

# --- 4. nouvelle ISO, structure d'amorçage d'origine rejouée ----------------------------
# « -boot_image any replay » reprend tel quel le catalogue El Torito (BIOS et
# UEFI) et la zone système hybride du mini.iso : rien n'est reconstruit à la
# main, contrairement à l'ISO live dont l'amorçage UEFI avait cassé.
log "Construction de $SORTIE"
install -d -m 0755 "$(dirname "$SORTIE")"
rm -f "$SORTIE"
if ! xorriso -indev "$CACHE/mini.iso" -outdev "$SORTIE" \
  -map "$TRAVAIL/initrd.gz" /initrd.gz \
  -map "$TRAVAIL/isolinux.cfg" /isolinux.cfg \
  -map "$TRAVAIL/grub.cfg" /boot/grub/grub.cfg \
  -boot_image any replay > "$TRAVAIL/xorriso.log" 2>&1; then
  tail -15 "$TRAVAIL/xorriso.log" >&2
  die "xorriso a échoué"
fi

# Les deux modes d'amorçage doivent être déclarés.
el="$(xorriso -indev "$SORTIE" -report_el_torito plain 2>/dev/null | grep 'El Torito boot img' || true)"
grep -q BIOS <<<"$el" || die "entrée El Torito BIOS absente de $SORTIE"
grep -q UEFI <<<"$el" || die "entrée El Torito UEFI absente de $SORTIE"
(( TEST )) && echo "  VARIANTE DE TEST : installation automatique après 1 s, à ne pas graver"
(( SERIE )) && echo "  VARIANTE DE TEST : console série, à ne pas graver"
sha256sum "$SORTIE" | sed 's|  .*/|  |' > "$SORTIE.sha256"
echo "  $SORTIE : $(du -h "$SORTIE" | cut -f1), BIOS et UEFI, canal $CANAL"
