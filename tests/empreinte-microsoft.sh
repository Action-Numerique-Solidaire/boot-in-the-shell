#!/usr/bin/env bash
# empreinte-microsoft.py contre une copie locale de la page de Microsoft :
# aucun appel à microsoft.com. Vérifie la ligne choisie dans le tableau des
# empreintes (entités HTML comprises, sans confondre « Français » et
# « Français canadien ») et le code de sortie 2 pour une langue absente.
#
# Usage : tests/empreinte-microsoft.sh            (~1 s, python3 seulement)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMPREINTE="$SCRIPT_DIR/../03 - prototype-generic/scripts/empreinte-microsoft.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "ÉCHEC : $*" >&2; exit 1; }

SHA_FR=aa515279f02fb2b425eff341f0a1f158d61288c72cca5f9d87b79b5a23f7f918
install -d "$T/fr-fr"
cat > "$T/fr-fr/windows11.html" <<EOF
<table><tbody><tr><th>Pays région</th><th>Code de hachage</th></tr>
<tr><td>Arabe 64-bit</td><td>A75AE3F36CB9FFFFEDCB2D7DED9CEF83FFB710EB1376610D2220684D987CB9A5</td></tr>
<tr><td>Français canadien 64-bit</td><td>F32E5538EE3F73206294378109501C9E2E2DA78DCDE66C43F4610B18CEEBC0A7</td></tr>
<tr><td>Fran&ccedil;ais 64-bit</td><td>${SHA_FR^^}</td></tr>
</tbody></table>
EOF
PAGE="file://$T/fr-fr/windows11.html"

[[ "$(python3 -I "$EMPREINTE" "$PAGE" Français)" == "$SHA_FR" ]] || fail "empreinte de « Français 64-bit »"
echo "OK : empreinte lue dans la page"

set +e; python3 -I "$EMPREINTE" "$PAGE" Klingon > /dev/null 2> "$T/err"; rc=$?; set -e
if [[ $rc -ne 2 ]] || ! grep -q "Klingon 64-bit" "$T/err"; then fail "langue absente : code $rc"; fi
echo "OK : langue absente refusée (code 2)"
