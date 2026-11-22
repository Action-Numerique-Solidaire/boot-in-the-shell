#!/usr/bin/env bash
# Porte d'entrée unique des tests : la même commande pour un contributeur et
# pour la CI. Chaque élément est éprouvé seul, du plus rapide au plus lent :
#
#   1. paquets installés par apt dans un Debian 13 vierge   docker          ~40 s
#   2. dépôt apt lu par apt                                 docker          ~12 s
#   3. ISO d'amorçage : démarrage BIOS et UEFI              qemu            ~20 s
#   4. paquets de bout en bout (clients PXE, interface web) root, libvirt   ~3 min
#   5. ISO d'amorçage : installation complète, UEFI et BIOS root, libvirt   ~20 min
#
# Le niveau 5 ne tourne qu'avec --complet. Un niveau qui ne peut pas tourner
# est annoncé IGNORÉ, jamais réussi : un test sauté qui compte comme vert est
# précisément le défaut qui a laissé publier une release sans ISO.
#
# Usage : tests/run-all.sh                      # niveaux 1 à 3
#         sudo tests/run-all.sh                 # niveaux 1 à 4
#         sudo tests/run-all.sh --complet       # niveaux 1 à 5
#         tests/run-all.sh --iso-live <image>   # ancienne ISO live (obsolète)
#
# Options : --killbit <image.iso>  copie locale de Killbit pour le niveau 4
#           --travail <répertoire> où construire (défaut : répertoire temporaire)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPLET=0 KILLBIT="" TRAVAIL="" ISO_LIVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --complet)  COMPLET=1; shift ;;
    --killbit)  KILLBIT="${2:?}"; shift 2 ;;
    --travail)  TRAVAIL="${2:?}"; shift 2 ;;
    --iso-live) ISO_LIVE="${2:?}"; shift 2 ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done

results=()
rc=0

run() {
  local label="$1"; shift
  echo
  echo "================================================================"
  echo "  $label"
  echo "================================================================"
  local code=0
  "$@" || code=$?
  case $code in
    0)  results+=("OK      $label") ;;
    77) results+=("IGNORÉ  $label — un contrôle n'a pas pu tourner") ;;
    *)  results+=("ÉCHEC   $label"); rc=1 ;;
  esac
}

ignore() {
  echo
  echo "================================================================"
  echo "  $1 — IGNORÉ : $2"
  echo "================================================================"
  results+=("IGNORÉ  $1 — $2")
}

recapitulatif() {
  echo
  echo "================================================================"
  echo "  Récapitulatif"
  echo "================================================================"
  printf '  %s\n' "${results[@]}"
  echo
  exit "$rc"
}

# --- ancienne ISO live --------------------------------------------------------------
if [[ -n "$ISO_LIVE" ]]; then
  [[ -f "$ISO_LIVE" ]] || { echo "ERREUR : ISO introuvable : $ISO_LIVE" >&2; exit 2; }
  run "ISO live : amorçage BIOS" "$SCRIPT_DIR/boot-test.sh" "$ISO_LIVE" bios
  run "ISO live : amorçage UEFI" "$SCRIPT_DIR/boot-test.sh" "$ISO_LIVE" uefi
  if [[ ${EUID} -eq 0 ]] && command -v virsh >/dev/null && virsh -c qemu:///system version >/dev/null 2>&1; then
    run "ISO live : bout en bout PXE" "$SCRIPT_DIR/e2e-pxe.sh" "$ISO_LIVE"
  else
    ignore "ISO live : bout en bout PXE" "demande root et libvirt"
  fi
  recapitulatif
fi

# --- construction -------------------------------------------------------------------
if [[ -z "$TRAVAIL" ]]; then
  TRAVAIL="$(mktemp -d)"
  trap 'rm -rf "$TRAVAIL"' EXIT
fi
install -d "$TRAVAIL"
echo "Construction dans $TRAVAIL"
"$REPO/packaging/build-deb.sh" "0.0.0+essai$(date +%Y%m%d%H%M)" "$TRAVAIL/debs" >/dev/null
SERVEUR=("$TRAVAIL"/debs/bits-pxe-server_*.deb)
WEB=("$TRAVAIL"/debs/bits-web_*.deb)
echo "  paquets : $(basename "${SERVEUR[0]}"), $(basename "${WEB[0]}")"

# --- 1 et 2 : conteneurs -----------------------------------------------------------------
docker_ok=""
if ! command -v docker >/dev/null; then
  docker_ok="docker absent"
elif ! docker info >/dev/null 2>&1; then
  docker_ok="docker injoignable (service arrêté, ou utilisateur hors du groupe docker)"
fi
if [[ -z "$docker_ok" ]]; then
  run "1. paquets installés par apt (Debian 13)" "$SCRIPT_DIR/paquet-deb.sh" "${SERVEUR[0]}" "${WEB[0]}"
  # shellcheck disable=SC2317  # appelée par run
  depot() {
    "$REPO/packaging/build-apt-repo.sh" "$TRAVAIL/apt" test "$TRAVAIL"/debs/*.deb >/dev/null \
      && "$SCRIPT_DIR/depot-apt.sh" "$TRAVAIL/apt"
  }
  run "2. dépôt apt" depot
else
  ignore "1. paquets installés par apt (Debian 13)" "$docker_ok"
  ignore "2. dépôt apt" "$docker_ok"
fi

# --- 3 : démarrage de l'ISO d'amorçage --------------------------------------------------
iso_ok=""
for c in qemu-system-x86_64 xorriso cpio; do command -v "$c" >/dev/null || iso_ok="$c absent"; done
if [[ -z "$iso_ok" ]]; then
  if "$REPO/05 - bootstrap-iso/build-bootstrap-iso.sh" "$TRAVAIL/amorcage-serie.iso" --test --console-serie >/dev/null 2>&1; then
    for mode in bios uefi; do
      run "3. ISO d'amorçage : démarrage $mode" env BITS_BOOT_MARKER='1\*installer' \
        "$SCRIPT_DIR/boot-test.sh" "$TRAVAIL/amorcage-serie.iso" "$mode" 600 disque
    done
  else
    results+=("ÉCHEC   3. ISO d'amorçage : construction"); rc=1
  fi
else
  ignore "3. ISO d'amorçage : démarrage" "$iso_ok"
fi

# --- 4 et 5 : labo libvirt -----------------------------------------------------------------
labo_ok=""
[[ ${EUID} -eq 0 ]] || labo_ok="demande root (relancer avec sudo)"
if [[ -z "$labo_ok" ]] && ! command -v virsh >/dev/null; then
  labo_ok="virsh absent (libvirt-clients libvirt-daemon-system)"
fi
if [[ -z "$labo_ok" ]] && ! virsh -c qemu:///system version >/dev/null 2>&1; then
  labo_ok="libvirt injoignable (systemctl start libvirtd)"
fi
if [[ -z "$labo_ok" ]]; then
  run "4. paquets de bout en bout (clients PXE BIOS et UEFI)" \
    "$SCRIPT_DIR/e2e-paquet.sh" "${SERVEUR[0]}" "${WEB[0]}" ${KILLBIT:+"$KILLBIT"}
else
  ignore "4. paquets de bout en bout" "$labo_ok"
fi

if (( ! COMPLET )); then
  ignore "5. ISO d'amorçage : installation complète" "seulement avec --complet (~20 min)"
elif [[ -n "$labo_ok" ]]; then
  ignore "5. ISO d'amorçage : installation complète" "$labo_ok"
else
  # L'installation tire les paquets du dépôt GitHub du canal test : elle
  # éprouve ce qui est PUBLIÉ, pas les paquets construits ci-dessus.
  "$REPO/05 - bootstrap-iso/build-bootstrap-iso.sh" "$TRAVAIL/amorcage-test.iso" --test >/dev/null
  run "5. ISO d'amorçage : installation complète (UEFI et BIOS)" \
    "$SCRIPT_DIR/e2e-iso.sh" "$TRAVAIL/amorcage-test.iso" uefi bios
fi

recapitulatif
