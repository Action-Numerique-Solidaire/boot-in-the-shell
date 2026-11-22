#!/usr/bin/env bash
# Éprouve un dépôt apt BITS avec le vrai apt d'un Debian 13 vierge, dans un
# conteneur : aucune VM, quelques dizaines de secondes.
#
# Usage : tests/depot-apt.sh <répertoire-du-dépôt>   # servi en local
#         tests/depot-apt.sh --distant <url-de-base>  # dépôt publié
#
#   ex. tests/depot-apt.sh --distant \
#         https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases/download/apt-test/
#
# Contrôles :
#   1. apt-get update passe sans erreur ni avertissement sur la source BITS ;
#   2. chaque paquet listé dans Packages a un candidat venant de l'origine BITS ;
#   3. ses dépendances se résolvent contre les dépôts Debian (simulation).
#
# Le 3 demande les miroirs Debian. Sans eux il est annoncé IGNORÉ et le script
# sort en 77, jamais en 0 : un contrôle sauté ne compte pas comme réussi.
#
# Demande docker et l'image debian:trixie (téléchargée au premier lancement).
set -Eeuo pipefail

IMAGE="${BITS_TEST_IMAGE:-debian:trixie}"
log() { printf '\n[depot-apt %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { echo "ÉCHEC : $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker absent"

srv_pid=""
# shellcheck disable=SC2317  # appelée par le trap
cleanup() { if [[ -n "$srv_pid" ]]; then kill "$srv_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT

if [[ "${1:-}" == --distant ]]; then
  BASE="${2:?url de base attendue après --distant}"
  [[ "$BASE" == https://* ]] || die "le dépôt distant doit être servi en https://"
  [[ "$BASE" == */ ]] || BASE="$BASE/"
  log "Dépôt distant : $BASE"
else
  REPO="${1:?usage : $0 <répertoire-du-dépôt> | --distant <url>}"
  [[ -f "$REPO/Release" && -f "$REPO/Packages.gz" ]] || die "$REPO ne contient pas de dépôt (Release, Packages.gz)"
  REPO="$(cd "$REPO" && pwd)"
  port=$(( 20000 + RANDOM % 20000 ))
  # Le serveur sert le dépôt depuis son propre répertoire : -I pour qu'aucun
  # module de ce répertoire ne soit chargé à la place de la bibliothèque.
  python3 -I -m http.server --bind 127.0.0.1 --directory "$REPO" "$port" \
    >/dev/null 2>&1 &
  srv_pid=$!
  for _ in $(seq 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/Release" 2>/dev/null && break
    sleep 0.1
  done
  curl -fsS -o /dev/null "http://127.0.0.1:$port/Release" || die "serveur local injoignable"
  BASE="http://127.0.0.1:$port/"
  log "Dépôt local $REPO servi sur $BASE"
fi

# Dépôt signé : la clé publique est publiée à côté de Release. apt la vérifie
# alors réellement, au lieu de faire confiance au transport.
CLE=""
if curl -fsSL -o /dev/null "${BASE}bits-archive-keyring.gpg" 2>/dev/null; then
  CLE="$(curl -fsSL "${BASE}bits-archive-keyring.gpg" | base64 -w0)"
  log "Dépôt signé : vérification de la signature par apt"
else
  log "Dépôt non signé : source en [trusted=yes]"
fi

# Les paquets attendus, lus dans l'index du dépôt.
PAQUETS="$(curl -fsSL "${BASE}Packages.gz" | gzip -dc | awk '/^Package:/ {print $2}' | sort -u | tr '\n' ' ')"
[[ -n "${PAQUETS// /}" ]] || die "aucun paquet dans ${BASE}Packages.gz"
log "Paquets du dépôt : $PAQUETS"

# Tout le contrôle tourne dans le conteneur ; il rend 0, 1 ou 77.
set +e
docker run --rm --network host -e BASE="$BASE" -e PAQUETS="$PAQUETS" -e CLE="$CLE" "$IMAGE" bash -c '
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "== image : $(. /etc/os-release; echo "$PRETTY_NAME") =="

# Les miroirs Debian sont-ils joignables ? Ils servent au contrôle 3, et, pour
# un dépôt distant, à installer ca-certificates sans lequel apt refuse https.
debian_ok=0
apt-get update -qq >/dev/null 2>&1 && debian_ok=1

if [[ "$BASE" == https://* ]]; then
  [[ $debian_ok == 1 ]] || { echo "ÉCHEC : miroirs Debian injoignables, impossible d installer ca-certificates"; exit 1; }
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null || exit 1
fi

if [[ -n "$CLE" ]]; then
  base64 -d <<<"$CLE" > /usr/share/keyrings/bits-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/bits-archive-keyring.gpg] $BASE ./" > /etc/apt/sources.list.d/bits.list
else
  echo "deb [trusted=yes] $BASE ./" > /etc/apt/sources.list.d/bits.list
fi

# 1. update : on isole la sortie de la source BITS.
out="$(apt-get update 2>&1)"; rc=$?
grep -F "${BASE%/}" <<<"$out"
if [[ $rc -ne 0 ]] || grep -E "^(W|E|Err)" <<<"$out" | grep -F "${BASE%/}" >/dev/null; then
  grep -E "^(W|E|Err)" <<<"$out"; echo "ÉCHEC 1 : apt-get update sur la source BITS"; exit 1
fi
grep -F "${BASE%/}" <<<"$out" | grep -F Packages >/dev/null \
  || { echo "ÉCHEC 1 : l index Packages de la source BITS n a pas été lu"; exit 1; }
echo "OK 1 : apt-get update"

# 2. un candidat BITS pour chaque paquet du dépôt.
for p in $PAQUETS; do
  pol="$(apt-cache policy "$p")"
  cand="$(awk "/Candidate:/ {print \$2}" <<<"$pol")"
  [[ -n "$cand" && "$cand" != "(none)" ]] || { echo "$pol"; echo "ÉCHEC 2 : $p sans candidat"; exit 1; }
  grep -F "${BASE%/} ./ Packages" <<<"$pol" >/dev/null || { echo "$pol"; echo "ÉCHEC 2 : $p ne vient pas de la source BITS"; exit 1; }
  echo "OK 2 : $p $cand"
done

# 3. résolution des dépendances contre Debian.
if [[ $debian_ok != 1 ]]; then
  echo "IGNORÉ 3 : miroirs Debian injoignables, dépendances non résolues"
  exit 77
fi
for p in $PAQUETS; do
  if ! sim="$(apt-get install -s --no-install-recommends "$p" 2>&1)"; then
    echo "$sim" | tail -15; echo "ÉCHEC 3 : dépendances de $p non résolues"; exit 1
  fi
  echo "OK 3 : $p, $(grep -c "^Inst " <<<"$sim") paquets à installer"
done
exit 0
'
rc=$?
set -e

case $rc in
  0)  log "SUCCÈS" ;;
  77) log "INCOMPLET : un contrôle a été ignoré" ;;
  *)  log "ÉCHEC" ;;
esac
exit "$rc"
