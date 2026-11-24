#!/usr/bin/python3 -I
"""Interface web de Boot in the Shell.

Liste les images que le serveur PXE peut proposer, permet d'en activer ou
d'en désactiver, et lance la publication (« bitsctl apply ») en suivant son
journal en direct.

Le service tourne sans privilège (utilisateur bits-web). Il lit l'état dans
les fichiers de bits-pxe-server et ne passe par sudo que pour trois commandes,
les seules que /etc/sudoers.d/bits-web lui accorde :

    bitsctl media enable <id>
    bitsctl media disable <id>
    bitsctl media download --arriere-plan <id>     (télécharger sans publier)
    systemctl start --no-block bits-sync.service   (publier)

La publication passe par bits-sync.service, la même unité qu'au démarrage,
et non par un processus fils : elle tourne ainsi dans sa propre unité, et un
redémarrage du service web (mise à jour automatique, par exemple) n'interrompt
pas un téléchargement de plusieurs gigaoctets.

Écoute sur 127.0.0.1:8080 ; nginx le publie sur le port 80.

Bibliothèque standard seulement : rien à installer en plus de python3.
"""

import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, urlsplit

MEDIA_FILE = os.environ.get("BITS_MEDIA_FILE", "/etc/bits-pxe-server/media.conf")
CATALOGUE = os.environ.get("BITS_CATALOGUE", "/usr/share/bits-pxe-server/catalogue.conf")
STATE_DIR = os.environ.get("BITS_STATE_DIR", "/var/lib/bits")
LOG_DIR = os.environ.get("BITS_LOG_DIR", "/var/log/bits")
DATA_DIR = os.environ.get("BITS_DATA_DIR", "/srv/bits-data")
LOCK = os.environ.get("BITS_LOCK", "/run/bits-apply.lock")
BITSCTL = shlex.split(os.environ.get("BITS_BITSCTL", "sudo -n /usr/sbin/bitsctl"))
APPLIQUER = shlex.split(os.environ.get("BITS_APPLIQUER", "sudo -n /usr/bin/systemctl start --no-block bits-sync.service"))
STATIC_DIR = os.environ.get("BITS_WEB_STATIC", os.path.dirname(os.path.abspath(__file__)))
ADDR = os.environ.get("BITS_WEB_ADDR", "127.0.0.1")
PORT = int(os.environ.get("BITS_WEB_PORT", "8080"))

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
# En-tête exigé sur toute requête qui modifie quelque chose. Un site tiers ne
# peut pas l'ajouter sans requête de contrôle CORS, que ce service ne valide
# jamais : une page malveillante ouverte sur le réseau ne peut donc ni activer
# une image ni lancer de publication à la place de l'utilisateur.
CSRF_HEADER = "X-BITS-Requete"

_apply_lock = threading.Lock()


# --- lecture de l'état -----------------------------------------------------------

def lire_catalogue():
    """Lignes du catalogue local, puis celles du catalogue de référence dont
    l'identifiant n'y figure pas (montrées désactivées)."""
    medias, vus = [], set()
    for chemin, local in ((MEDIA_FILE, True), (CATALOGUE, False)):
        try:
            with open(chemin, encoding="utf-8") as f:
                lignes = f.read().splitlines()
        except OSError:
            continue
        for ligne in lignes:
            if not ligne.strip() or ligne.lstrip().startswith("#"):
                continue
            champs = ligne.split("|")
            if len(champs) < 7 or not ID_RE.match(champs[1]) or champs[1] in vus:
                continue
            vus.add(champs[1])
            medias.append({
                "id": champs[1],
                "type": champs[2],
                "fichier": champs[3],
                "url": champs[4],
                "empreinte": champs[5],
                "libelle": "|".join(champs[6:]),
                "active": local and champs[0] == "yes",
                # Une URL à renseigner : l'image ne peut pas être activée telle quelle.
                "disponible": "REPLACE_" not in champs[4] and "REPLACE_" not in champs[5],
            })
    return medias


def lire_ids(nom):
    try:
        with open(os.path.join(STATE_DIR, nom), encoding="utf-8") as f:
            return {l.strip() for l in f if l.strip()}
    except OSError:
        return set()


def lire_texte(chemin):
    try:
        with open(chemin, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def versions_publiees():
    """{id: empreinte} des médias servis, écrit par « bitsctl apply »."""
    versions = {}
    try:
        with open(os.path.join(STATE_DIR, "versions-publiees"), encoding="utf-8") as f:
            for l in f:
                champs = l.split()
                if len(champs) == 2:
                    versions[champs[0]] = champs[1]
    except OSError:
        pass
    return versions


# --- dernière version disponible ---------------------------------------------------

SHA_RE = re.compile(r"^[0-9a-f]{64}$")
CACHE_VERSIONS = 600          # secondes : une vérification par image toutes les 10 min au plus
_versions = {}                # id -> (instant, résultat)
_versions_lock = threading.Lock()


def empreinte_distante(media):
    """Empreinte de la version publiée en amont. Une image à nom fixe
    (Killbit, « latest ») publie un fichier d'empreinte à côté d'elle
    (sha256sums:<url>) : il change à chaque version. Une empreinte écrite dans
    le catalogue, elle, ne change qu'avec une mise à jour du paquet."""
    source = media["empreinte"]
    if not source.startswith("sha256sums:"):
        return source.lower(), False
    url = source[len("sha256sums:"):]
    # file:/// : catalogue local et tests, comme pour 40-download-media.sh.
    if not url.startswith(("https://", "file:///")):
        raise ValueError("URL d'empreinte ni https:// ni file:///")
    with urllib.request.urlopen(url, timeout=20) as r:
        texte = r.read(1024 * 1024).decode("utf-8", "replace")
    # Même règle que 40-download-media.sh : on compare le nom de base, le
    # fichier de Killbit porte le chemin du runner qui l'a produit.
    nom = os.path.basename(urlsplit(media["url"]).path)
    for ligne in texte.splitlines():
        champs = ligne.split(None, 1)
        if len(champs) == 2 and os.path.basename(champs[1].strip().lstrip("*")) == nom:
            return champs[0].lower(), True
    raise ValueError(f"{nom} absent du fichier d'empreintes")


def derniere_version(media, forcer=False):
    with _versions_lock:
        cache = _versions.get(media["id"])
        if cache and not forcer and time.time() - cache[0] < CACHE_VERSIONS:
            return cache[1]
    try:
        sha, flottante = empreinte_distante(media)
        if not SHA_RE.match(sha):
            raise ValueError("empreinte invalide")
        resultat = {"empreinte": sha, "flottante": flottante, "erreur": None}
    except (OSError, ValueError) as e:
        resultat = {"empreinte": None, "flottante": None, "erreur": str(e)}
    resultat["verifie_le"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with _versions_lock:
        _versions[media["id"]] = (time.time(), resultat)
    return resultat


def taille(chemin):
    try:
        return os.path.getsize(chemin)
    except OSError:
        return None


def publication_en_cours():
    """Vrai si une publication tient le verrou de bitsctl, qu'elle ait été
    lancée d'ici ou par bits-sync.service au démarrage."""
    try:
        fd = os.open(LOCK, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def reseau():
    """Interface et adresse servies : celles de la dernière publication si
    elle a eu lieu, sinon celles de la route par défaut."""
    interface = None
    try:
        with open(os.path.join(STATE_DIR, "dnsmasq.conf"), encoding="utf-8") as f:
            for l in f:
                if l.startswith("interface="):
                    interface = l.split("=", 1)[1].strip()
    except OSError:
        pass
    try:
        if not interface:
            routes = json.loads(subprocess.run(["ip", "-j", "-4", "route", "show", "default"],
                                               capture_output=True, text=True, timeout=5).stdout or "[]")
            interface = routes[0]["dev"] if routes else None
        if interface:
            addrs = json.loads(subprocess.run(["ip", "-j", "-4", "addr", "show", "dev", interface, "scope", "global"],
                                              capture_output=True, text=True, timeout=5).stdout or "[]")
            for a in addrs:
                for info in a.get("addr_info", []):
                    return {"interface": interface, "adresse": f"{info['local']}/{info['prefixlen']}", "ip": info["local"]}
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        pass
    return {"interface": interface, "adresse": None, "ip": None}


def operation_en_cours():
    """Nature de l'opération en cours, d'après le dernier journal ouvert :
    publication, ou téléchargement d'une image (et laquelle)."""
    if not publication_en_cours():
        return None
    nom = os.path.basename(os.path.realpath(os.path.join(LOG_DIR, "derniere.log")))
    m = re.match(r"telechargement-([a-z0-9][a-z0-9._-]*)-\d{8}-\d{6}\.log$", nom)
    if m:
        return {"type": "téléchargement", "id": m.group(1)}
    return {"type": "publication", "id": None}


def derniere_publication():
    lien = os.path.join(LOG_DIR, "apply-latest.log")
    try:
        chemin = os.path.realpath(lien)
        with open(chemin, "rb") as f:
            f.seek(max(0, os.path.getsize(chemin) - 4096))
            fin = f.read().decode("utf-8", "replace").strip().splitlines()
    except OSError:
        return None
    derniere = fin[-1] if fin else ""
    if derniere.startswith("Publication réussie"):
        resultat = "réussie"
    elif derniere.startswith("Publié, mais"):
        resultat = "partielle"
    elif derniere.startswith("ÉCHEC"):
        resultat = "échec"
    else:
        resultat = "en cours" if publication_en_cours() else "interrompue"
    return {
        "fichier": os.path.basename(chemin),
        "date": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(chemin))),
        "resultat": resultat,
        "message": derniere,
    }


def etat():
    prets, ecartes = lire_ids("media-publies"), lire_ids("media-ecartes")
    publiees = versions_publiees()
    medias = []
    for m in lire_catalogue():
        chemin = os.path.join(DATA_DIR, "downloads", m["fichier"])
        if m["active"]:
            if m["id"] in prets:
                e = "publié"
            elif m["id"] in ecartes:
                e = "écarté"
            else:
                e = "à publier"
        elif m["id"] in prets:
            e = "à retirer"      # désactivé, mais encore servi jusqu'à la publication
        else:
            e = "inactif"
        medias.append({
            **{k: m[k] for k in ("id", "type", "fichier", "libelle", "active", "disponible")},
            "etat": e,
            "telecharge": taille(chemin),
            # Fichier partiel : téléchargement en cours (ou interrompu).
            "en_telechargement": taille(chemin + ".part"),
            # Empreinte de la copie téléchargée et de celle que sert le PXE :
            # différentes, une nouvelle version attend la publication.
            "version": lire_texte(chemin + ".sha256"),
            "version_publiee": publiees.get(m["id"]) if m["id"] in prets else None,
        })
    try:
        st = os.statvfs(DATA_DIR)
        libre = st.f_bavail * st.f_frsize
    except OSError:
        libre = None
    return {
        "serveur": {**reseau(), "donnees": DATA_DIR, "libre": libre},
        "publication": {
            "en_cours": publication_en_cours(),
            "operation": operation_en_cours(),
            "derniere": derniere_publication(),
        },
        "medias": medias,
    }


def journal(depuis):
    # Journal de la dernière opération, publication ou téléchargement.
    lien = os.path.join(LOG_DIR, "derniere.log")
    if not os.path.exists(lien):
        lien = os.path.join(LOG_DIR, "apply-latest.log")
    try:
        chemin = os.path.realpath(lien)
        fin = os.path.getsize(chemin)
        if depuis > fin:
            depuis = 0           # nouveau journal depuis la dernière lecture
        with open(chemin, "rb") as f:
            f.seek(depuis)
            texte = f.read(256 * 1024)
    except OSError:
        return {"fichier": None, "depuis": 0, "fin": 0, "texte": ""}
    return {
        "fichier": os.path.basename(chemin),
        "depuis": depuis,
        "fin": depuis + len(texte),
        "texte": texte.decode("utf-8", "replace"),
    }


# --- actions -------------------------------------------------------------------

def bitsctl(*args, timeout=60):
    r = subprocess.run([*BITSCTL, *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def lancer_publication():
    """Rend None si la publication est lancée, sinon le motif du refus."""
    with _apply_lock:
        if publication_en_cours():
            return "publication déjà en cours"
        r = subprocess.run(APPLIQUER, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return (r.stdout + r.stderr).strip() or f"échec du lancement (code {r.returncode})"
        # Le verrou n'est pris qu'au démarrage effectif de bitsctl : on l'attend
        # un instant, pour que l'état renvoyé juste après soit déjà « en cours ».
        for _ in range(20):
            if publication_en_cours():
                break
            time.sleep(0.1)
        return None


def publier_apres_telechargement(ident, delai=6 * 3600):
    """Attend la fin du téléchargement de « ident », puis publie s'il a
    réussi. Si le service redémarre entre-temps, la publication n'a pas lieu :
    l'interface signale alors la version à publier, et bits-sync la publie au
    prochain démarrage."""
    fin = time.time() + delai
    time.sleep(1)
    while publication_en_cours() and time.time() < fin:
        time.sleep(2)
    nom = os.path.basename(os.path.realpath(os.path.join(LOG_DIR, "derniere.log")))
    if not nom.startswith(f"telechargement-{ident}-"):
        return
    try:
        with open(os.path.join(LOG_DIR, nom), encoding="utf-8", errors="replace") as f:
            lignes = f.read().strip().splitlines()
    except OSError:
        return
    if lignes and lignes[-1].startswith("Téléchargement réussi"):
        refus = lancer_publication()
        if refus:
            sys.stderr.write(f"bits-web : publication après téléchargement de {ident} refusée : {refus}\n")


# --- HTTP ------------------------------------------------------------------------

class Gestionnaire(BaseHTTPRequestHandler):
    server_version = "bits-web"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _json(self, code, donnees):
        corps = json.dumps(donnees, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(corps)

    def _fichier(self, nom, type_mime):
        try:
            with open(os.path.join(STATIC_DIR, nom), "rb") as f:
                corps = f.read()
        except OSError:
            return self._json(HTTPStatus.NOT_FOUND, {"erreur": "introuvable"})
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", type_mime)
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            return self._fichier("index.html", "text/html; charset=utf-8")
        if url.path == "/api/etat":
            return self._json(HTTPStatus.OK, etat())
        if url.path == "/api/journal":
            try:
                depuis = max(0, int(parse_qs(url.query).get("depuis", ["0"])[0]))
            except ValueError:
                depuis = 0
            return self._json(HTTPStatus.OK, journal(depuis))
        m = re.fullmatch(r"/api/media/([a-z0-9][a-z0-9._-]*)/version", url.path)
        if m:
            media = next((x for x in lire_catalogue() if x["id"] == m.group(1)), None)
            if media is None:
                return self._json(HTTPStatus.NOT_FOUND, {"erreur": "média inconnu"})
            forcer = parse_qs(url.query).get("forcer", ["0"])[0] == "1"
            derniere = derniere_version(media, forcer)
            locale = lire_texte(os.path.join(DATA_DIR, "downloads", media["fichier"] + ".sha256"))
            return self._json(HTTPStatus.OK, {
                **derniere,
                "locale": locale,
                # None : rien de téléchargé, ou dernière version inconnue.
                "a_jour": (locale == derniere["empreinte"]) if locale and derniere["empreinte"] else None,
            })
        return self._json(HTTPStatus.NOT_FOUND, {"erreur": "introuvable"})

    def do_POST(self):
        if self.headers.get(CSRF_HEADER) != "1":
            return self._json(HTTPStatus.FORBIDDEN, {"erreur": f"en-tête {CSRF_HEADER} manquant"})
        url = urlparse(self.path)
        longueur = min(int(self.headers.get("Content-Length") or 0), 4096)
        try:
            corps = json.loads(self.rfile.read(longueur) or b"{}")
        except ValueError:
            return self._json(HTTPStatus.BAD_REQUEST, {"erreur": "JSON invalide"})

        m = re.fullmatch(r"/api/media/([a-z0-9][a-z0-9._-]*)/telecharger", url.path)
        if m:
            # Télécharger et vérifier l'image sur le serveur, sans la publier :
            # le menu PXE ne change pas.
            with _apply_lock:
                if publication_en_cours():
                    return self._json(HTTPStatus.CONFLICT, {"erreur": "une opération est déjà en cours"})
                code, sortie = bitsctl("media", "download", "--arriere-plan", m.group(1))
                if code != 0:
                    return self._json(HTTPStatus.BAD_REQUEST, {"erreur": sortie})
                for _ in range(20):
                    if publication_en_cours():
                        break
                    time.sleep(0.1)
            with _versions_lock:
                _versions.pop(m.group(1), None)
            # Mise à jour d'une image déjà servie : la nouvelle version est
            # publiée dès qu'elle est téléchargée et vérifiée.
            if corps.get("publier") is True:
                threading.Thread(target=publier_apres_telechargement, args=(m.group(1),), daemon=True).start()
                sortie += " Publication à la suite."
            return self._json(HTTPStatus.ACCEPTED, {"message": sortie})

        m = re.fullmatch(r"/api/media/([a-z0-9][a-z0-9._-]*)", url.path)
        if m:
            if publication_en_cours():
                return self._json(HTTPStatus.CONFLICT, {"erreur": "publication en cours"})
            if not isinstance(corps.get("active"), bool):
                return self._json(HTTPStatus.BAD_REQUEST, {"erreur": "champ « active » attendu (booléen)"})
            code, sortie = bitsctl("media", "enable" if corps["active"] else "disable", m.group(1))
            if code != 0:
                return self._json(HTTPStatus.BAD_REQUEST, {"erreur": sortie})
            return self._json(HTTPStatus.OK, {"message": sortie})

        if url.path == "/api/appliquer":
            refus = lancer_publication()
            if refus:
                return self._json(HTTPStatus.CONFLICT, {"erreur": refus})
            return self._json(HTTPStatus.ACCEPTED, {"message": "publication lancée"})

        return self._json(HTTPStatus.NOT_FOUND, {"erreur": "introuvable"})


def main():
    serveur = ThreadingHTTPServer((ADDR, PORT), Gestionnaire)
    serveur.daemon_threads = True
    sys.stderr.write(f"bits-web : écoute sur {ADDR}:{PORT}\n")
    serveur.serve_forever()


if __name__ == "__main__":
    main()
