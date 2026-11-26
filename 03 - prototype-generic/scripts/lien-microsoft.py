#!/usr/bin/python3 -I
"""Lien de téléchargement et empreinte d'une ISO Windows, demandés à Microsoft.

    lien-microsoft.py <page> <langue> [--empreinte-seulement]

<page>    page de téléchargement, par exemple
          https://www.microsoft.com/fr-fr/software-download/windows11
<langue>  langue telle que la page l'écrit, par exemple « Français »

Affiche l'empreinte SHA-256 sur la première ligne, puis le lien sur la
seconde. Sort avec :
    0  empreinte (et lien) obtenus ;
    3  Microsoft a refusé de fournir le lien : son message est affiché ;
    2  autre échec (page changée, réseau, langue absente).

Microsoft ne publie pas d'adresse fixe pour ses ISO : la page de
téléchargement en fabrique une, valable 24 h, par deux appels à
software-download-connector/api/ (langues de l'édition, puis lien pour la
langue choisie). On refait ces deux appels, comme le navigateur.

L'empreinte, elle, vient du tableau « Valeurs de hachage des fichiers ISO
pour chaque langue » de la page publique (ligne « <langue> 64-bit ») : elle
ne dépend pas de l'API, et --empreinte-seulement ne fait aucun appel à l'API.
C'est ce que l'interface web utilise pour savoir si une nouvelle version est
sortie.

Microsoft refuse parfois ces appels (« Certains utilisateurs, entités et
emplacements ne sont pas autorisés », code 715-123130). Le secours est alors
de coller un lien obtenu dans un navigateur (bitsctl media download
--arriere-plan <id> --lien <url>).

BITS_MSDL_API et BITS_MSDL_TAGS remplacent les adresses de l'API pour les
tests.
"""

import html
import os
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

API = "https://www.microsoft.com/software-download-connector/api/"
TAGS = "https://vlscppe.microsoft.com/tags"
# Valeurs fixes du script de la page de téléchargement.
PROFIL = "606624d44113"
ORG_ID = "y6jn8c31"
NAVIGATEUR = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
HOTE_RE = re.compile(r"^https://[A-Za-z0-9.-]+\.microsoft\.com/[!-~]+$")


class Refus(Exception):
    pass


def lire(url, referer=None, accept_language=None):
    req = urllib.request.Request(url, headers={"User-Agent": NAVIGATEUR, "Accept": "*/*"})
    if referer:
        req.add_header("Referer", referer)
    if accept_language:
        req.add_header("Accept-Language", accept_language)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read(4 * 1024 * 1024).decode("utf-8", "replace")


def texte(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", fragment))).strip()


def locale_de(page):
    """fr-fr dans l'adresse de la page → fr-FR pour l'API."""
    m = re.search(r"/([a-z]{2})-([a-z]{2})/", urllib.parse.urlsplit(page).path)
    return f"{m.group(1)}-{m.group(2).upper()}" if m else "en-US"


def empreinte(source, langue):
    voulue = f"{langue} 64-bit".casefold()
    for nom, sha in re.findall(r"<td[^>]*>(.*?)</td>\s*<td[^>]*>\s*([0-9A-Fa-f]{64})\s*</td>", source, re.S):
        if texte(nom).casefold() == voulue:
            return sha.lower()
    raise ValueError(f"ligne « {langue} 64-bit » absente du tableau des empreintes de la page")


def edition(source):
    m = re.search(r'<select[^>]*id="product-edition".*?</select>', source, re.S)
    if not m:
        raise ValueError("liste des éditions absente de la page")
    ids = re.findall(r'<option value="(\d+)"', m.group(0))
    if not ids:
        raise ValueError("aucune édition dans la page")
    return ids[0]


def message_refus(source):
    m = re.search(r'<input id="msg-01" type="hidden" value="([^"]*)"', source)
    return texte(m.group(1)) if m else "Microsoft refuse de fournir le lien (715-123130)."


def erreurs(reponse, source):
    """Les deux appels rendent {"Errors": [...]} en cas de refus."""
    errs = reponse.get("Errors") if isinstance(reponse, dict) else None
    if errs:
        details = "; ".join(str(e.get("Value") or e.get("Key") or e) if isinstance(e, dict) else str(e) for e in errs)
        raise Refus(f"{message_refus(source)} [{details}]")


def lien(page, source, langue, api, tags):
    locale = locale_de(page)
    session = str(uuid.uuid4())
    # Le navigateur déclare la session ici avant tout appel ; sans cela, les
    # appels suivants sont refusés.
    try:
        lire(f"{tags}?org_id={ORG_ID}&session_id={session}", referer=page)
    except (OSError, urllib.error.URLError):
        pass
    commun = f"profile={PROFIL}&friendlyFileName=undefined&Locale={locale}&sessionID={session}"
    try:
        skus = json.loads(lire(f"{api}getskuinformationbyproductedition?{commun}"
                               f"&ProductEditionId={edition(source)}&SKU=undefined", referer=page))
    except ValueError as e:
        raise ValueError(f"réponse illisible de l'API (langues) : {e}")
    erreurs(skus, source)
    voulue = langue.casefold()
    sku = next((s for s in skus.get("Skus", [])
                if voulue in (str(s.get("LocalizedLanguage", "")).casefold(), str(s.get("Language", "")).casefold())),
               None)
    if not sku:
        dispo = ", ".join(str(s.get("LocalizedLanguage") or s.get("Language")) for s in skus.get("Skus", []))
        raise ValueError(f"langue « {langue} » absente de la réponse de Microsoft ({dispo or 'aucune langue'})")
    try:
        liens = json.loads(lire(f"{api}GetProductDownloadLinksBySku?{commun}"
                                f"&productEditionId=undefined&SKU={urllib.parse.quote(str(sku['Id']))}", referer=page))
    except ValueError as e:
        raise ValueError(f"réponse illisible de l'API (lien) : {e}")
    erreurs(liens, source)
    uris = [o.get("Uri", "") for o in liens.get("ProductDownloadOptions", []) if isinstance(o, dict)]
    uris = [u for u in uris if HOTE_RE.match(u)]
    # Une ISO 64 bits par langue pour Windows 11 ; on préfère x64 si d'autres
    # architectures venaient à apparaître.
    choix = [u for u in uris if "x64" in u.lower()] or uris
    if not choix:
        raise ValueError("aucun lien https://….microsoft.com/ dans la réponse de Microsoft")
    return choix[0]


def main():
    args = sys.argv[1:]
    seulement = "--empreinte-seulement" in args
    args = [a for a in args if a != "--empreinte-seulement"]
    if len(args) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    page, langue = args
    if not page.startswith(("https://", "file:///")):
        print("page attendue en https:// (ou file:/// pour les tests)", file=sys.stderr)
        return 2
    api = os.environ.get("BITS_MSDL_API", API)
    tags = os.environ.get("BITS_MSDL_TAGS", TAGS)
    try:
        source = lire(page, accept_language=locale_de(page))
        sha = empreinte(source, langue)
        if seulement:
            print(sha)
            return 0
        url = lien(page, source, langue, api, tags)
    except Refus as e:
        print(f"Microsoft a refusé : {e}", file=sys.stderr)
        return 3
    except urllib.error.HTTPError as e:
        print(f"{e.url} : HTTP {e.code}", file=sys.stderr)
        return 3 if e.code in (403, 429) else 2
    except (OSError, ValueError, KeyError) as e:
        print(f"échec : {e}", file=sys.stderr)
        return 2
    print(sha)
    print(url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
