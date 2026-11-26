#!/usr/bin/env bash
# Installe réellement le paquet bits-pxe-server dans un Debian 13 vierge, en
# conteneur, et éprouve ce qui ne demande ni systemd ni noyau NFS : quelques
# dizaines de secondes, sans VM. La publication complète et les clients PXE
# sont l'affaire de tests/e2e-paquet.sh.
#
# Usage : tests/paquet-deb.sh <bits-pxe-server.deb> [bits-web.deb]
#
# Contrôles :
#   1. apt installe le paquet et ses dépendances ;
#   2. l'installation n'active rien (aucun service, aucun dnsmasq) ;
#   3. bitsctl : media list / enable / disable modifient le catalogue ; un
#      argument en trop est refusé ; media download télécharge une image sans
#      la publier ;
#   4. la validation déduit le réseau sans aucune configuration ;
#   5. l'étape iPXE prend les chargeurs du paquet ipxe ;
#   6. purge : l'état est retiré, les images téléchargées sont gardées.
#
# Avec bits-web :
#   7. le site nginx remplace « default », la configuration est valide ;
#   8. le service répond, en direct et derrière nginx, sous son utilisateur ;
#   9. sudo lui accorde l'activation et le téléchargement d'une image, et
#      refuse « bitsctl apply » ; nginx sert les images téléchargées ;
#  10. un POST sans l'en-tête X-BITS-Requete est refusé ;
#  11. une nouvelle version d'une image à nom fixe est détectée, puis
#      reconnue à jour une fois téléchargée ;
#  12. mode passerelle (sans bits-web aussi) : validation, adresse du réseau
#      PXE, table nftables, garde DHCP face à un autre serveur, retrait.
#
# Demande docker et l'image debian:trixie.
set -Eeuo pipefail

DEB="${1:?usage : $0 <bits-pxe-server.deb> [bits-web.deb]}"
WEB="${2:-}"
IMAGE="${BITS_TEST_IMAGE:-debian:trixie}"
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
[[ -f "$DEB" ]] || { echo "ÉCHEC : paquet introuvable : $DEB" >&2; exit 1; }
[[ -z "$WEB" || -f "$WEB" ]] || { echo "ÉCHEC : paquet introuvable : $WEB" >&2; exit 1; }
DEB="$(abs "$DEB")"
montages=(-v "$DEB:/tmp/bits.deb:ro")
if [[ -n "$WEB" ]]; then WEB="$(abs "$WEB")"; montages+=(-v "$WEB:/tmp/bits-web.deb:ro"); fi
command -v docker >/dev/null || { echo "ÉCHEC : docker absent" >&2; exit 1; }

log() { printf '\n[paquet-deb %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
log "Paquets : $(basename "$DEB")${WEB:+, $(basename "$WEB")}"

set +e
# NET_ADMIN : le contrôle 12 crée des interfaces et une table nftables, dans
# l'espace réseau du conteneur seulement.
docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW "${montages[@]}" "$IMAGE" bash -c '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
fail() { echo "ÉCHEC $*"; exit 1; }

apt-get update -qq
t0=$(date +%s)
apt-get install -y -qq /tmp/bits.deb > /tmp/apt.log 2>&1 || { tail -30 /tmp/apt.log; fail "1 : apt install"; }
nb=$(grep -c "^Setting up " /tmp/apt.log || true)
echo "OK 1 : installé avec $nb paquets en $(( $(date +%s) - t0 )) s"

# 2. rien d actif : pas de configuration dnsmasq écrite, pas de lien
# d activation pour les unités BITS.
[[ ! -e /var/lib/bits/dnsmasq.conf ]] || fail "2 : configuration dnsmasq écrite à l installation"
for u in bits-sync bits-dnsmasq; do
  [[ -f /usr/lib/systemd/system/$u.service ]] || fail "2 : unité $u absente"
  ! ls /etc/systemd/system/*.wants/$u.service >/dev/null 2>&1 || fail "2 : $u activée à l installation"
done
dpkg -s dnsmasq >/dev/null 2>&1 && fail "2 : le paquet dnsmasq (serveur DNS) a été installé"
echo "OK 2 : aucune unité BITS activée, pas de serveur DNS installé"

# 3. catalogue
bitsctl media list | grep -E "^ +non +killbit " >/dev/null || { bitsctl media list; fail "3 : killbit absent ou déjà activé"; }
bitsctl media enable killbit >/dev/null
grep -E "^yes\|killbit\|" /etc/bits-pxe-server/media.conf >/dev/null || fail "3 : media enable sans effet"
bitsctl media list | grep -E "^ +à publier +killbit " >/dev/null || { bitsctl media list; fail "3 : état après enable"; }
bitsctl media disable killbit >/dev/null
grep -E "^no\|killbit\|" /etc/bits-pxe-server/media.conf >/dev/null || fail "3 : media disable sans effet"
if bitsctl media enable inexistant 2>/dev/null; then fail "3 : un média inconnu est accepté"; fi
# Le catalogue est un conffile : bitsctl ne doit pas changer ses droits.
[[ "$(stat -c %a /etc/bits-pxe-server/media.conf)" == 644 ]] || fail "3 : droits du catalogue modifiés"
# sudo accorde « bitsctl media … * » à l interface web : un argument en trop
# doit être refusé, pas ignoré.
if bitsctl media enable killbit autre >/dev/null 2>&1; then fail "3 : argument en trop accepté"; fi
grep -E "^no\|killbit\|" /etc/bits-pxe-server/media.conf >/dev/null || fail "3 : l appel refusé a modifié le catalogue"
echo "OK 3 : media list / enable / disable, arguments stricts"

# Télécharger sans publier : une image fictive servie en file://, pour ne
# dépendre d aucun réseau.
head -c 1048576 /dev/urandom > /tmp/essai.iso
sha=$(sha256sum /tmp/essai.iso | cut -d" " -f1)
echo "no|essai|debian-live-iso|essai.iso|file:///tmp/essai.iso|$sha|Essai" >> /etc/bits-pxe-server/media.conf
bitsctl media download essai > /tmp/dl.log 2>&1 || { cat /tmp/dl.log; fail "3 : media download"; }
cmp -s /tmp/essai.iso /srv/bits-data/downloads/essai.iso || fail "3 : image non téléchargée"
grep -E "^no\|essai\|" /etc/bits-pxe-server/media.conf >/dev/null || fail "3 : media download a activé l image"
[[ ! -s /var/lib/bits/media-prets && ! -e /var/lib/bits/media-publies ]] || fail "3 : media download a touché l état de publication"
[[ "$(readlink /var/log/bits/derniere.log)" == telechargement-essai-* ]] || fail "3 : journal du téléchargement"
echo "OK 3 : media download télécharge et vérifie sans publier"

# Windows (msdl:) : le paquet installe l entrée Microsoft, bitsctl contrôle
# le lien collé, et 40-download-media.sh le prend avec l empreinte de la page.
grep -qE "^no\|windows11\|windows-iso\|[^|]*\|msdl:https://www\.microsoft\.com/" /etc/bits-pxe-server/media.conf || fail "3 : entrée Windows 11 sans msdl:"
if bitsctl media download --arriere-plan essai --lien https://software.download.prss.microsoft.com/a.iso >/dev/null 2>&1; then fail "3 : --lien accepté pour une image non Microsoft"; fi
if bitsctl media download --arriere-plan windows11 --lien https://exemple.org/a.iso >/dev/null 2>&1; then fail "3 : lien hors de microsoft.com accepté"; fi
if bitsctl media download --arriere-plan windows11 --lien "https://x.microsoft.com/a b" >/dev/null 2>&1; then fail "3 : lien avec espace accepté"; fi
[[ ! -e /var/lib/bits/lien-windows11 ]] || fail "3 : un lien refusé a été enregistré"
# Accepté : enregistré pour 40-download-media.sh (le lancement de l unité
# échoue ici, sans systemd).
bitsctl media download --arriere-plan windows11 --lien "https://software.download.prss.microsoft.com/dbazure/Win11.iso?t=x&e=1" >/dev/null 2>&1 || true
[[ "$(cat /var/lib/bits/lien-windows11 2>/dev/null)" == "https://software.download.prss.microsoft.com/dbazure/Win11.iso?t=x&e=1 " ]] || fail "3 : lien accepté non enregistré"
[[ "$(stat -c %a /var/lib/bits/lien-windows11)" == 600 ]] || fail "3 : droits du lien enregistré"
# Téléchargement avec ce lien : une page Microsoft fictive (file://) porte
# l empreinte, le lien collé (file://, posé à la main : bitsctl n accepte
# que microsoft.com) porte l image.
head -c 1048576 /dev/urandom > /tmp/win.iso
sha=$(sha256sum /tmp/win.iso | cut -d" " -f1)
install -d /tmp/fr-fr
echo "<table><tr><td>Fran&ccedil;ais 64-bit</td><td>${sha^^}</td></tr></table>" > /tmp/fr-fr/windows11.html
sed -i "s#^no|windows11|.*#no|windows11|windows-iso|Win11_x64_fr.iso|msdl:file:///tmp/fr-fr/windows11.html|msdl:Français|Windows 11#" /etc/bits-pxe-server/media.conf
rm -f /var/lib/bits/lien-windows11
if bitsctl media download windows11 > /tmp/dl.log 2>&1; then fail "3 : téléchargement Windows sans lien collé accepté"; fi
grep -q "Coller un lien" /tmp/dl.log || { cat /tmp/dl.log; fail "3 : consigne absente sans lien collé"; }
echo "file:///tmp/win.iso" > /var/lib/bits/lien-windows11
bitsctl media download windows11 > /tmp/dl.log 2>&1 || { cat /tmp/dl.log; fail "3 : téléchargement par lien collé"; }
cmp -s /tmp/win.iso /srv/bits-data/downloads/Win11_x64_fr.iso || fail "3 : image Windows non téléchargée"
[[ ! -e /var/lib/bits/lien-windows11 ]] || fail "3 : lien collé non effacé après usage"
grep -q "Lien collé" /tmp/dl.log || fail "3 : lien collé non utilisé"
echo "OK 3 : Windows : lien collé contrôlé, téléchargé et vérifié par l empreinte de la page"

# 4. réseau déduit, sans toucher pxe.env
export PXE_CONFIG_FILE=/etc/bits-pxe-server/pxe.env PXE_MEDIA_FILE=/etc/bits-pxe-server/media.conf
out=$(/usr/share/bits-pxe-server/scripts/00-validate-config.sh) || fail "4 : validation"
echo "$out"
grep -F "sur eth0" <<<"$out" >/dev/null || fail "4 : interface non déduite"
echo "OK 4 : réseau déduit"

# 5. chargeurs iPXE du paquet ipxe, dans une arborescence TFTP jetable
cp /etc/bits-pxe-server/pxe.env /tmp/pxe.env
echo "PXE_TFTP_ROOT=/tmp/tftp" >> /tmp/pxe.env
PXE_CONFIG_FILE=/tmp/pxe.env /usr/share/bits-pxe-server/scripts/50-build-ipxe.sh | tail -2
cmp -s /tmp/tftp/undionly.kpxe /usr/lib/ipxe/undionly.kpxe || fail "5 : undionly.kpxe"
cmp -s /tmp/tftp/snponly.efi /usr/lib/ipxe/snponly.efi || fail "5 : snponly.efi"
echo "OK 5 : chargeurs iPXE du paquet ipxe"

if [[ -f /tmp/bits-web.deb ]]; then
  apt-get install -y -qq /tmp/bits-web.deb > /tmp/apt-web.log 2>&1 || { tail -30 /tmp/apt-web.log; fail "7 : apt install bits-web"; }
  [[ -L /etc/nginx/sites-enabled/bits ]] || fail "7 : site nginx bits non activé"
  [[ ! -e /etc/nginx/sites-enabled/default ]] || fail "7 : site default encore actif"
  [[ -e /var/lib/bits-web/default-desactive ]] || fail "7 : désactivation de default non notée"
  nginx -t 2>/dev/null || { nginx -t; fail "7 : nginx -t"; }
  visudo -c -f /etc/sudoers.d/bits-web >/dev/null || fail "7 : sudoers invalide"
  [[ "$(stat -c %a /etc/sudoers.d/bits-web)" == 440 ]] || fail "7 : droits du fichier sudoers"
  echo "OK 7 : site nginx et sudoers"

  # 8. le service sous son utilisateur, comme le lancerait systemd.
  runuser -u bits-web -- python3 -I /usr/share/bits-web/bits-web.py 2>/tmp/web.log &
  nginx
  for _ in $(seq 50); do curl -fsS -o /dev/null http://127.0.0.1:8080/api/etat 2>/dev/null && break; sleep 0.1; done
  etat=$(curl -fsS http://127.0.0.1/api/etat) || { cat /tmp/web.log; fail "8 : API injoignable derrière nginx"; }
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert any(m[\"id\"]==\"killbit\" for m in d[\"medias\"])" "$etat" || fail "8 : killbit absent de l état"
  curl -fsS http://127.0.0.1/ | grep -F "<title>Boot in the Shell</title>" >/dev/null || fail "8 : page d accueil"
  echo "#!ipxe" > /var/www/html/pxe-essai; mkdir -p /var/www/html/pxe && mv /var/www/html/pxe-essai /var/www/html/pxe/menu.ipxe
  curl -fsS http://127.0.0.1/pxe/menu.ipxe | grep -Fx "#!ipxe" >/dev/null || fail "8 : /pxe/ non servi par nginx"
  echo "OK 8 : service web et nginx"

  # 9. frontière de privilèges
  r=$(curl -s -X POST -H "X-BITS-Requete: 1" -H "Content-Type: application/json" -d "{\"active\": true}" http://127.0.0.1/api/media/killbit)
  grep -E "^yes\|killbit\|" /etc/bits-pxe-server/media.conf >/dev/null || { echo "$r"; cat /tmp/web.log; fail "9 : activation par l API"; }
  if runuser -u bits-web -- sudo -n /usr/sbin/bitsctl apply >/dev/null 2>&1; then fail "9 : sudo accorde bitsctl apply"; fi
  if runuser -u bits-web -- sudo -n /bin/bash -c true >/dev/null 2>&1; then fail "9 : sudo accorde un shell"; fi
  runuser -u bits-web -- sudo -n -l /usr/bin/systemctl start --no-block bits-sync.service >/dev/null || fail "9 : lancement de bits-sync non accordé"
  runuser -u bits-web -- sudo -n -l /usr/sbin/bitsctl media download --arriere-plan killbit >/dev/null || fail "9 : téléchargement non accordé"
  if runuser -u bits-web -- sudo -n -l /usr/sbin/bitsctl media download killbit >/dev/null 2>&1; then fail "9 : téléchargement au premier plan accordé"; fi
  # Lien Windows collé dans l interface : passé par l API, jusqu à bitsctl.
  r=$(curl -s -X POST -H "X-BITS-Requete: 1" -H "Content-Type: application/json" -d "{}" http://127.0.0.1/api/media/windows11/telecharger)
  [[ "$r" == *lien* ]] || fail "9 : téléchargement Windows sans lien accepté par l API ($r)"
  r=$(curl -s -X POST -H "X-BITS-Requete: 1" -H "Content-Type: application/json" -d "{\"lien\": \"https://exemple.org/a.iso\"}" http://127.0.0.1/api/media/windows11/telecharger)
  [[ "$r" == *microsoft.com* ]] || fail "9 : lien hors de microsoft.com accepté par l API ($r)"
  curl -s -X POST -H "X-BITS-Requete: 1" -H "Content-Type: application/json" -d "{\"lien\": \"https://software.download.prss.microsoft.com/w.iso?t=1\"}" http://127.0.0.1/api/media/windows11/telecharger >/dev/null
  [[ "$(cat /var/lib/bits/lien-windows11 2>/dev/null)" == "https://software.download.prss.microsoft.com/w.iso?t=1 " ]] || { cat /tmp/web.log; fail "9 : lien collé non transmis par sudo à bitsctl"; }
  rm -f /var/lib/bits/lien-windows11
  echo "OK 9 : sudo n accorde que l activation, le téléchargement et le lancement de bits-sync"
  curl -fsS -o /tmp/recup.iso http://127.0.0.1/telechargements/essai.iso || fail "9 : /telechargements/ non servi"
  cmp -s /tmp/essai.iso /tmp/recup.iso || fail "9 : fichier récupéré différent"
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/telechargements/)
  [[ "$code" == 403 || "$code" == 404 ]] || fail "9 : liste du répertoire des images exposée (code $code)"
  echo "OK 9 : images téléchargées récupérables, sans liste du répertoire"

  # 10. garde CSRF
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "{\"active\": false}" http://127.0.0.1/api/media/killbit)
  [[ "$code" == 403 ]] || fail "10 : POST sans en-tête accepté (code $code)"
  grep -E "^yes\|killbit\|" /etc/bits-pxe-server/media.conf >/dev/null || fail "10 : le POST refusé a quand même modifié le catalogue"
  echo "OK 10 : POST sans en-tête refusé"

  # 11. dernière version : une image à nom fixe dont le fichier d empreinte
  # change à chaque version, comme Killbit.
  head -c 524288 /dev/urandom > /tmp/maj.iso
  ( cd /tmp && sha256sum maj.iso > maj.iso.sha256 )
  echo "no|maj|debian-live-iso|maj.iso|file:///tmp/maj.iso|sha256sums:file:///tmp/maj.iso.sha256|Mise à jour" >> /etc/bits-pxe-server/media.conf
  version() { curl -fsS "http://127.0.0.1/api/media/maj/version$1" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"a_jour\"])"; }
  [[ "$(version "")" == None ]] || fail "11 : version annoncée pour une image non téléchargée"
  bitsctl media download maj >/dev/null 2>&1 || fail "11 : téléchargement de la première version"
  [[ "$(version "")" == True ]] || fail "11 : copie à jour non reconnue"
  head -c 524288 /dev/urandom > /tmp/maj.iso
  ( cd /tmp && sha256sum /tmp/maj.iso > maj.iso.sha256 )   # chemin absolu, comme celui de Killbit
  [[ "$(version "")" == True ]] || fail "11 : le cache de 10 min n est pas utilisé"
  [[ "$(version "?forcer=1")" == False ]] || fail "11 : nouvelle version non détectée"
  bitsctl media download maj >/dev/null 2>&1 || fail "11 : téléchargement de la nouvelle version"
  cmp -s /tmp/maj.iso /srv/bits-data/downloads/maj.iso || fail "11 : nouvelle version non téléchargée"
  [[ "$(version "")" == True ]] || fail "11 : à jour après téléchargement"
  echo "OK 11 : nouvelle version détectée, téléchargée, puis reconnue à jour"
  nginx -s stop
fi

# 12. mode passerelle, sur une paire veth : lan0 tient lieu de port Ethernet
# du réseau PXE, lan1 de ce qui y est branché.
apt-get install -y -qq dnsmasq-base >/dev/null 2>&1 || true
ip link add lan0 type veth peer name lan1 || fail "12 : création des interfaces de test"
ip link set lan1 up
mkdir -p /etc/bits-pxe-server/pxe.env.d
printf "PXE_MODE=passerelle\nPXE_LAN_INTERFACE=lan0\n" > /etc/bits-pxe-server/pxe.env.d/50-essai.env
out=$(/usr/share/bits-pxe-server/scripts/00-validate-config.sh) || { echo "$out"; fail "12 : validation en mode passerelle"; }
grep -F "réseau PXE 192.168.42.1/24 sur lan0" <<<"$out" >/dev/null || { echo "$out"; fail "12 : réseau PXE"; }
P=/usr/share/bits-pxe-server/scripts/bits-passerelle.sh
$P > /tmp/pg.log 2>&1 || { cat /tmp/pg.log; fail "12 : bits-passerelle.sh"; }
ip -4 -o addr show dev lan0 | grep -F " 192.168.42.1/24 " >/dev/null || fail "12 : adresse du réseau PXE absente"
nft list table inet bits | grep -F "masquerade" >/dev/null || fail "12 : NAT absent"
[[ -s /run/issue.d/bits-passerelle.issue ]] || fail "12 : console sans l adresse du réseau PXE"
[[ ! -e /run/bits/dhcp-refuse ]] || fail "12 : refus DHCP sans autre serveur"
grep -F "DHCP 192.168.42.100-192.168.42.250" /tmp/pg.log >/dev/null || { cat /tmp/pg.log; fail "12 : plage DHCP"; }
echo "OK 12 : passerelle appliquée (adresse, NAT, aucun autre DHCP)"
# Un autre serveur DHCP derrière lan0 : câble branché sur la box au lieu du switch.
ip addr add 10.99.0.1/24 dev lan1
dnsmasq --port=0 --interface=lan1 --bind-interfaces --dhcp-range=10.99.0.10,10.99.0.20 --pid-file=/run/autre-dhcp.pid --dhcp-leasefile=/run/autre.leases
set +e; $P > /tmp/pg2.log 2>&1; rc=$?; set -e
kill "$(cat /run/autre-dhcp.pid)"
[[ $rc -eq 4 ]] || { cat /tmp/pg2.log; fail "12 : autre serveur DHCP non détecté (code $rc)"; }
grep -Fx 10.99.0.1 /run/bits/dhcp-refuse >/dev/null || fail "12 : refus non noté"
echo "OK 12 : autre serveur DHCP détecté, DHCP de BITS refusé"
rm -f /etc/bits-pxe-server/pxe.env.d/50-essai.env
$P > /tmp/pg3.log 2>&1 || { cat /tmp/pg3.log; fail "12 : retour au mode proxy"; }
! nft list table inet bits >/dev/null 2>&1 || fail "12 : table nftables restée en mode proxy"
! ip -4 -o addr show dev lan0 | grep -F 192.168.42.1 >/dev/null || fail "12 : adresse restée en mode proxy"
[[ ! -e /run/bits/dhcp-refuse && ! -e /run/issue.d/bits-passerelle.issue ]] || fail "12 : état resté en mode proxy"
echo "OK 12 : retour au mode proxy, passerelle retirée"
ip link del lan0

# 6. purge
mkdir -p /srv/bits-data/downloads && touch /srv/bits-data/downloads/image.iso
a_purger=(bits-pxe-server); [[ -f /tmp/bits-web.deb ]] && a_purger+=(bits-web)
apt-get purge -y -qq "${a_purger[@]}" >/tmp/purge.log 2>&1 || { cat /tmp/purge.log; fail "6 : purge"; }
if [[ -f /tmp/bits-web.deb ]]; then
  [[ -L /etc/nginx/sites-enabled/default && ! -e /etc/nginx/sites-enabled/bits ]] || fail "6 : site default non rétabli"
fi
[[ ! -e /var/lib/bits && ! -e /var/log/bits && ! -e /etc/bits-pxe-server ]] || fail "6 : état restant après purge"
[[ -e /srv/bits-data/downloads/image.iso ]] || fail "6 : images supprimées par la purge"
echo "OK 6 : purge"
'
rc=$?
set -e
if [[ $rc -eq 0 ]]; then log "SUCCÈS"; else log "ÉCHEC"; fi
exit "$rc"
