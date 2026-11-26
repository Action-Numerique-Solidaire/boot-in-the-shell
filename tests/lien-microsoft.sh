#!/usr/bin/env bash
# lien-microsoft.py contre un faux site de Microsoft, servi en local : aucun
# appel à microsoft.com. Vérifie ce que le script lit de la page (édition,
# empreinte de la langue, message de refus), les deux appels à l'API dans
# l'ordre du navigateur (même session, Referer, langue), et ses codes de
# sortie : 0 lien obtenu, 3 refus de Microsoft, 2 autre échec.
#
# Le format réel des réponses de l'API n'est pas éprouvé ici : il ne l'est
# que par un vrai téléchargement (interface web, bouton « Télécharger » de
# Windows 11).
#
# Usage : tests/lien-microsoft.sh            (~2 s, python3 seulement)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIEN="$SCRIPT_DIR/../03 - prototype-generic/scripts/lien-microsoft.py"
T="$(mktemp -d)"
trap 'kill "${PID:-0}" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "ÉCHEC : $*" >&2; exit 1; }

SHA_FR=aa515279f02fb2b425eff341f0a1f158d61288c72cca5f9d87b79b5a23f7f918
install -d "$T/fr-fr"
cat > "$T/fr-fr/windows11.html" <<EOF
<input id="msg-01" type="hidden" value="Nous ne pouvons pas traiter votre demande pour le moment. Code 715-123130."/>
<select id="product-edition" aria-label="Sélectionner">
<option value="null" selected="selected">Sélectionnez Télécharger</option>
<option value="3813">Windows 11 (ISO édition multiple pour les appareils x64)</option>
</select>
<table><tbody><tr><th>Pays région</th><th>Code de hachage</th></tr>
<tr><td>Arabe 64-bit</td><td>A75AE3F36CB9FFFFEDCB2D7DED9CEF83FFB710EB1376610D2220684D987CB9A5</td></tr>
<tr><td>Français canadien 64-bit</td><td>F32E5538EE3F73206294378109501C9E2E2DA78DCDE66C43F4610B18CEEBC0A7</td></tr>
<tr><td>Fran&ccedil;ais 64-bit</td><td>${SHA_FR^^}</td></tr>
</tbody></table>
EOF
PAGE="file://$T/fr-fr/windows11.html"

# Faux API : contrôle ce que le navigateur enverrait, et répond selon le mode
# écrit dans $T/mode.
cat > "$T/faux.py" <<'EOF'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
racine = sys.argv[1]
sessions = set()
class G(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def repondre(self, corps, code=200):
        b = json.dumps(corps).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        mode = open(racine + "/mode").read().strip()
        with open(racine + "/appels", "a") as f: f.write(u.path + "\n")
        if u.path == "/tags":
            assert q.get("org_id") == "y6jn8c31", q
            sessions.add(q["session_id"]); return self.repondre({})
        assert q.get("sessionID") in sessions, "session non déclarée"
        assert q.get("Locale") == "fr-FR" and q.get("profile") == "606624d44113", q
        if u.path == "/api/getskuinformationbyproductedition":
            assert q.get("ProductEditionId") == "3813", q
            if mode == "refus-langues":
                return self.repondre({"Errors": [{"Key": "ErrorSettings.SentinelReject", "Value": "Sentinel marked this request as rejected."}]})
            return self.repondre({"Skus": [
                {"Id": "18001", "Language": "Arabic", "LocalizedLanguage": "Arabe"},
                {"Id": "18010", "Language": "French", "LocalizedLanguage": "Français"}]})
        if u.path == "/api/GetProductDownloadLinksBySku":
            assert q.get("SKU") == "18010", q
            assert self.headers.get("Referer", "").endswith("/fr-fr/windows11.html"), "Referer absent"
            if mode == "refus-lien":
                return self.repondre({"Errors": [{"Key": "ErrorSettings.SentinelReject", "Value": "715-123130"}]})
            if mode == "hors-microsoft":
                return self.repondre({"ProductDownloadOptions": [{"Uri": "https://exemple.org/Win11.iso", "DownloadType": 1}]})
            return self.repondre({"ProductDownloadOptions": [
                {"Uri": "https://software.download.prss.microsoft.com/dbazure/Win11_25H2_French_x64.iso?t=abc&e=1", "DownloadType": 1}]})
        self.repondre({"erreur": "inconnu"}, 404)
s = HTTPServer(("127.0.0.1", 0), G)
print(s.server_port, flush=True)
s.serve_forever()
EOF
echo ok > "$T/mode"
python3 -I "$T/faux.py" "$T" > "$T/port" 2>"$T/faux.err" &
PID=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
PORT="$(cat "$T/port")"
export BITS_MSDL_API="http://127.0.0.1:$PORT/api/" BITS_MSDL_TAGS="http://127.0.0.1:$PORT/tags"

essai() {  # essai <mode> <langue> [options] : sortie dans $T/out, code dans $rc
  echo "$1" > "$T/mode"; : > "$T/appels"
  local mode="$1"; shift
  set +e; python3 -I "$LIEN" "$PAGE" "$@" > "$T/out" 2> "$T/err"; rc=$?; set -e
  [[ ! -s "$T/faux.err" ]] || { cat "$T/faux.err"; fail "$mode : le faux serveur a refusé un appel"; }
}

essai ok Français --empreinte-seulement
[[ $rc -eq 0 && "$(cat "$T/out")" == "$SHA_FR" ]] || { cat "$T/err"; fail "empreinte seule"; }
[[ ! -s "$T/appels" ]] || fail "--empreinte-seulement a appelé l'API"
echo "OK : empreinte lue dans la page, sans appel à l'API"

essai ok Français
[[ $rc -eq 0 ]] || { cat "$T/err"; fail "lien : code $rc"; }
[[ "$(sed -n 1p "$T/out")" == "$SHA_FR" ]] || fail "lien : empreinte"
[[ "$(sed -n 2p "$T/out")" == https://software.download.prss.microsoft.com/dbazure/Win11_25H2_French_x64.iso\?t=abc\&e=1 ]] || fail "lien : $(sed -n 2p "$T/out")"
[[ "$(tr '\n' ' ' < "$T/appels")" == "/tags /api/getskuinformationbyproductedition /api/GetProductDownloadLinksBySku " ]] || fail "ordre des appels : $(cat "$T/appels")"
echo "OK : lien obtenu, appels dans l'ordre du navigateur"

for mode in refus-langues refus-lien; do
  essai "$mode" Français
  [[ $rc -eq 3 ]] || fail "$mode : code $rc au lieu de 3"
  grep -q "715-123130" "$T/err" || fail "$mode : message de refus absent ($(cat "$T/err"))"
done
echo "OK : refus de Microsoft rendu en code 3, avec son message"

essai hors-microsoft Français
[[ $rc -eq 2 ]] || fail "lien hors de microsoft.com accepté (code $rc)"
essai ok Klingon
if [[ $rc -ne 2 ]] || ! grep -q "Klingon 64-bit" "$T/err"; then fail "langue absente : code $rc"; fi
echo "OK : lien hors de microsoft.com et langue absente refusés (code 2)"
