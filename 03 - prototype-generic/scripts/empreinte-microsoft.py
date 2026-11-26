#!/usr/bin/python3 -I
"""Empreinte SHA-256 d'une ISO Windows, lue sur la page de Microsoft.

    empreinte-microsoft.py <page> <langue>

<page>    page de téléchargement, par exemple
          https://www.microsoft.com/fr-fr/software-download/windows11
<langue>  langue telle que la page l'écrit, par exemple « Français »

Affiche l'empreinte, lue dans le tableau « Valeurs de hachage des fichiers
ISO pour chaque langue » de la page (ligne « <langue> 64-bit »). Sort avec 0,
ou 2 en cas d'échec (page changée, réseau, langue absente).

Microsoft ne publie pas d'adresse fixe pour ses ISO, seulement des liens
valables 24 h fabriqués par sa page de téléchargement, et refuse de les
fournir à un programme (« Sentinel », code 715-123130). Le lien est donc
obtenu dans un navigateur et collé dans l'interface web (bitsctl media
download --arriere-plan <id> --lien <url>) ; ce script ne sert qu'à vérifier
l'ISO et à savoir si une nouvelle version est sortie.
"""

import html
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

NAVIGATEUR = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"


def lire(url, accept_language=None):
    req = urllib.request.Request(url, headers={"User-Agent": NAVIGATEUR, "Accept": "*/*"})
    if accept_language:
        req.add_header("Accept-Language", accept_language)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read(4 * 1024 * 1024).decode("utf-8", "replace")


def texte(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", fragment))).strip()


def langue_de(page):
    """fr-fr dans l'adresse de la page → fr-FR."""
    m = re.search(r"/([a-z]{2})-([a-z]{2})/", urllib.parse.urlsplit(page).path)
    return f"{m.group(1)}-{m.group(2).upper()}" if m else "en-US"


def empreinte(source, langue):
    voulue = f"{langue} 64-bit".casefold()
    for nom, sha in re.findall(r"<td[^>]*>(.*?)</td>\s*<td[^>]*>\s*([0-9A-Fa-f]{64})\s*</td>", source, re.S):
        if texte(nom).casefold() == voulue:
            return sha.lower()
    raise ValueError(f"ligne « {langue} 64-bit » absente du tableau des empreintes de la page")


def main():
    args = sys.argv[1:]
    if len(args) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    page, langue = args
    if not page.startswith(("https://", "file:///")):
        print("page attendue en https:// (ou file:/// pour les tests)", file=sys.stderr)
        return 2
    try:
        print(empreinte(lire(page, accept_language=langue_de(page)), langue))
    except urllib.error.HTTPError as e:
        print(f"{e.url} : HTTP {e.code}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as e:
        print(f"échec : {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
