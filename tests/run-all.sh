#!/usr/bin/env bash
# Porte d'entrée unique des tests : la même commande pour un contributeur et
# pour la CI.
#
# Ce que chaque niveau prouve, et ce qu'il coûte :
#
#   1. amorçage BIOS  — l'ISO démarre vraiment sur un firmware legacy
#   2. amorçage UEFI  — ... et sur un firmware récent (Secure Boot désactivé)
#   3. bout en bout   — le serveur s'installe seul et des clients démarrent
#                       dessus. Demande root, libvirt et un accès réseau
#                       sortant ; se compte en dizaines de minutes avec KVM.
#
# Un niveau qui ne peut pas tourner est annoncé IGNORÉ, jamais réussi : un test
# sauté qui compte comme vert est précisément le défaut qui a laissé passer une
# release sans ISO.
#
# Usage : tests/run-all.sh <image.iso>
#         sudo tests/run-all.sh <image.iso>     # ajoute le bout en bout
set -Eeuo pipefail

ISO="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$ISO" ]]; then
  cat >&2 <<USAGE
Usage : tests/run-all.sh <image.iso>

Construire l'ISO au préalable :
  cd "04 - live-iso" && sudo ./build-iso.sh /srv/bits-test/boot-in-the-shell-live.iso

Ou récupérer celle de la dernière release :
  https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases
USAGE
  exit 2
fi
[[ -f "$ISO" ]] || { echo "ERREUR : ISO introuvable : $ISO" >&2; exit 2; }

results=()
rc=0

run() {
  local label="$1"; shift
  echo
  echo "================================================================"
  echo "  $label"
  echo "================================================================"
  if "$@"; then
    results+=("OK      $label")
  else
    results+=("ÉCHEC   $label")
    rc=1
  fi
}

run "1. amorçage BIOS" "$SCRIPT_DIR/boot-test.sh" "$ISO" bios
run "2. amorçage UEFI" "$SCRIPT_DIR/boot-test.sh" "$ISO" uefi

# --- 3. bout en bout : seulement si la machine peut le faire ------------------
skip_reason=""
[[ ${EUID} -eq 0 ]] || skip_reason="demande root (relancer avec sudo)"
if [[ -z "$skip_reason" ]] && ! command -v virsh >/dev/null; then
  skip_reason="virsh absent (paquets libvirt-clients libvirt-daemon-system)"
fi
if [[ -z "$skip_reason" ]] && ! virsh -c qemu:///system version >/dev/null 2>&1; then
  skip_reason="libvirt injoignable (systemctl start libvirtd)"
fi

if [[ -n "$skip_reason" ]]; then
  echo
  echo "================================================================"
  echo "  3. bout en bout PXE — IGNORÉ : $skip_reason"
  echo "================================================================"
  results+=("IGNORÉ  3. bout en bout PXE — $skip_reason")
else
  run "3. bout en bout PXE (serveur + clients BIOS et UEFI)" \
    "$SCRIPT_DIR/e2e-pxe.sh" "$ISO"
fi

echo
echo "================================================================"
echo "  Récapitulatif"
echo "================================================================"
printf '  %s\n' "${results[@]}"
echo
exit "$rc"
