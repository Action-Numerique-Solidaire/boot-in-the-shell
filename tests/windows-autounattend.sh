#!/usr/bin/env bash
# windows-autounattend.sh : fichier de réponses de l'installation automatique
# de Windows 11. Vérifie, pour l'UEFI et le BIOS : XML bien formé, langue,
# édition, partition d'installation, compte local, commandes de moins de 260
# caractères (limite de RunSynchronous), script de nommage présent ; et le
# refus d'arguments invalides. Ne remplace pas une installation réelle.
#
# Usage : tests/windows-autounattend.sh            (~1 s, python3 seulement)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/../03 - prototype-generic/scripts/windows-autounattend.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "ÉCHEC : $*" >&2; exit 1; }

for plateforme in efi pcbios; do
  "$GEN" "$plateforme" ANS > "$T/$plateforme.xml"
  python3 -I - "$T/$plateforme.xml" "$plateforme" <<'EOF' || fail "$plateforme : contenu"
import sys, xml.etree.ElementTree as ET
U = "{urn:schemas-microsoft-com:unattend}"
racine = ET.parse(sys.argv[1]).getroot()
plateforme = sys.argv[2]
def tout(nom): return [e.text or "" for e in racine.iter(U + nom)]
assert set(tout("UILanguage")) == {"fr-FR"}, tout("UILanguage")
assert set(tout("InputLocale")) == {"040c:0000040c"}
assert tout("TimeZone") == ["Romance Standard Time"]
assert "Windows 11 Home" in tout("Value"), "édition"
assert tout("WillWipeDisk") == ["true"]
types = tout("Type")
attendu = {"efi": (["EFI", "MSR", "Primary"], "3"), "pcbios": (["Primary", "Primary"], "2")}[plateforme]
assert types == attendu[0], types
installe = racine.find(f".//{U}InstallTo/{U}PartitionID").text
assert installe == attendu[1], installe
assert tout("Name") == ["Utilisateur"] and tout("Group") == ["Administrators"]
assert tout("HideOnlineAccountScreens") == ["true"]
for chemin in tout("Path"):
    assert len(chemin) < 260, f"commande de {len(chemin)} caractères : {chemin[:60]}…"
nommage = racine.find("{urn:bits-pxe-server:autounattend}BITS/{urn:bits-pxe-server:autounattend}Nommage").text
assert "'ANS-'" in nommage and "Length - 11" in nommage, nommage
assert racine.find(f".//{U}ComputerName") is None, "ComputerName fixe"
EOF
done
echo "OK : fichiers de réponses UEFI et BIOS"

for args in "" "uefi" "efi ANS-1" "efi TROPLONG"; do
  # shellcheck disable=SC2086
  if "$GEN" $args > /dev/null 2>&1; then fail "arguments acceptés : « $args »"; fi
done
echo "OK : arguments invalides refusés"
