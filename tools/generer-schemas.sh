#!/usr/bin/env bash
# Dessine les schémas de la documentation : chaque docs/schemas/<nom>.mmd
# (Mermaid) donne docs/schemas/<nom>.svg, à côté.
#
# Les SVG sont commités et le README les affiche en images : GitHub dessine
# Mermaid dans un cadre de hauteur fixe qui coupe les grands schémas, et
# l'application mobile ou une copie hors de GitHub n'affichent que le code.
#
# Mermaid tourne dans Chrome ou Chromium sans fenêtre, chargé depuis jsDelivr
# (version épinglée) : il faut un navigateur et internet, pas Node.
#
# Usage : tools/generer-schemas.sh            (après modification d'un .mmd)
set -Eeuo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMAS="$RACINE/docs/schemas"
MERMAID_URL="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs"

die() { echo "ERREUR : $*" >&2; exit 1; }

navigateur=""
for candidat in google-chrome chromium chromium-browser; do
  command -v "$candidat" >/dev/null && { navigateur="$candidat"; break; }
done
[[ -n "$navigateur" ]] || die "Chrome ou Chromium introuvable."

travail="$(mktemp -d)"
trap 'rm -rf "$travail"' EXIT

# Une page qui dessine chaque source et range les SVG, en JSON, dans
# <pre id="resultat"> ; --dump-dom la relit une fois les rendus finis.
python3 -I - "$SCHEMAS" "$MERMAID_URL" "$travail/page.html" <<'EOF'
import html, json, pathlib, sys
schemas, url, page = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
sources = {p.stem: p.read_text() for p in sorted(schemas.glob("*.mmd"))}
if not sources:
    sys.exit(f"aucun .mmd dans {schemas}")
pathlib.Path(page).write_text(f"""<!doctype html><meta charset="utf-8">
<pre id="sources">{html.escape(json.dumps(sources))}</pre><pre id="resultat"></pre>
<script type="module">
import mermaid from "{url}";
// Libellés en texte SVG, pas en HTML : un <img> n'affiche pas toujours le
// HTML d'un SVG. Fond blanc : lisible aussi dans le thème sombre de GitHub.
mermaid.initialize({{startOnLoad: false, theme: "neutral", htmlLabels: false,
  flowchart: {{htmlLabels: false}}, fontFamily: "Helvetica, Arial, sans-serif"}});
const sources = JSON.parse(document.getElementById("sources").textContent);
const sortie = {{}};
for (const [nom, texte] of Object.entries(sources)) {{
  try {{
    const {{svg}} = await mermaid.render("schema-" + nom, texte);
    sortie[nom] = svg;
  }} catch (e) {{ sortie[nom] = "ERREUR " + e; }}
}}
document.getElementById("resultat").textContent = JSON.stringify(sortie);
</script>
""")
EOF

"$navigateur" --headless=new --disable-gpu --no-first-run --virtual-time-budget=30000 \
  --dump-dom "file://$travail/page.html" 2>/dev/null > "$travail/dom.html"

python3 -I - "$SCHEMAS" "$travail/dom.html" <<'EOF'
import html, json, pathlib, re, sys
import xml.etree.ElementTree as ET
schemas, dom = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text()
m = re.search(r'<pre id="resultat">(.*?)</pre>', dom, re.S)
if not m or not m.group(1):
    sys.exit("ERREUR : Mermaid n'a rien dessiné (internet, jsDelivr ?)")
erreurs = 0
for nom, svg in json.loads(html.unescape(m.group(1))).items():
    if svg.startswith("ERREUR"):
        print(f"ERREUR : {nom}.mmd : {svg[7:]}", file=sys.stderr)
        erreurs += 1
        continue
    # Taille fixe tirée du viewBox (Mermaid donne width="100%", sans hauteur,
    # ce qu'un <img> ne sait pas dimensionner) et fond blanc à la place du
    # max-width.
    l, h = re.search(r'viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"', svg).groups()
    svg = svg.replace('width="100%"', f'width="{round(float(l))}" height="{round(float(h))}"', 1)
    svg = re.sub(r'style="max-width: [\d.]+px;"', 'style="background-color: white"', svg, count=1)
    ET.fromstring(svg)  # XML bien formé, sinon un <img> n'affiche rien
    (schemas / f"{nom}.svg").write_text(svg + "\n")
    print(f"{nom}.svg")
sys.exit(1 if erreurs else 0)
EOF
