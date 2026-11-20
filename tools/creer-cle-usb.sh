#!/usr/bin/env bash
# Fabrique une clé USB « Boot in the Shell » autonome.
#
# La clé porte deux partitions :
#   1. l'ISO live, écrite telle quelle — c'est elle qui démarre ;
#   2. une partition ext4 étiquetée PXE_DATA, qui porte les médias à servir en
#      PXE et les chargeurs iPXE pré-compilés.
#
# L'assistant de démarrage retrouve la partition PXE_DATA par son étiquette, y
# compris sur le média de démarrage, et réutilise son contenu sans rien
# effacer. Les médias étant déjà présents et les chargeurs déjà compilés, la
# clé monte son serveur PXE SANS INTERNET.
#
# Usage :
#   sudo tools/creer-cle-usb.sh --iso <image.iso> --cible <disque|fichier> \
#        --ipxe <repertoire> \
#        [--media <chemin>:<type>:<id>:<libellé>]... \
#        --confirmer EFFACER
#
# --cible accepte un fichier ordinaire : la clé est alors fabriquée dans une
# image, ce qui permet de la tester en machine virtuelle avant de toucher à un
# vrai périphérique.
set -Eeuo pipefail

ISO=""; CIBLE=""; IPXE_DIR=""; CONFIRME=""; AUTORISER_FIXE=0
MEDIAS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)             ISO="${2:?}"; shift 2 ;;
    --cible)           CIBLE="${2:?}"; shift 2 ;;
    --ipxe)            IPXE_DIR="${2:?}"; shift 2 ;;
    --media)           MEDIAS+=("${2:?}"); shift 2 ;;
    --confirmer)       CONFIRME="${2:?}"; shift 2 ;;
    --autoriser-fixe)  AUTORISER_FIXE=1; shift ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ ${EUID} -eq 0 ]] || die "À lancer avec sudo."
[[ -n "$ISO" && -f "$ISO" ]] || die "--iso <image.iso> manquant ou introuvable."
[[ -n "$CIBLE" ]] || die "--cible <disque|fichier> manquant."
[[ "$CONFIRME" == "EFFACER" ]] \
  || die "Cette commande EFFACE entièrement $CIBLE. Ajouter --confirmer EFFACER pour confirmer."
for cmd in sfdisk partprobe mkfs.ext4 blkid blockdev losetup sha256sum; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd (paquets : fdisk parted e2fsprogs util-linux coreutils)"
done

# --- Garde-fous sur la cible --------------------------------------------------
boucle=""
if [[ -b "$CIBLE" ]]; then
  nom="$(basename "$(readlink -f "$CIBLE")")"
  racine_src="$(findmnt -n -o SOURCE / || true)"
  racine_disque="$(lsblk -ndo PKNAME "$racine_src" 2>/dev/null || true)"
  [[ "$nom" != "$racine_disque" && "/dev/$nom" != "$racine_src" ]] \
    || die "Refus : $CIBLE porte le système racine."
  amovible="$(cat "/sys/block/$nom/removable" 2>/dev/null || echo 0)"
  if [[ "$amovible" != "1" && $AUTORISER_FIXE -eq 0 ]]; then
    lsblk -o NAME,PATH,SIZE,TRAN,MODEL,SERIAL "$CIBLE" >&2
    die "Refus : $CIBLE n'est pas un périphérique amovible. Ajouter --autoriser-fixe si c'est voulu."
  fi
  montes="$(lsblk -nrpo MOUNTPOINT "$CIBLE" | grep -c '/' || true)"
  [[ "$montes" -eq 0 ]] || { lsblk -o NAME,PATH,SIZE,MOUNTPOINTS "$CIBLE" >&2; die "Une partition de $CIBLE est montée."; }
  cible_bloc="$CIBLE"
elif [[ -f "$CIBLE" ]]; then
  cible_bloc=""   # résolu après l'attachement en boucle
else
  die "--cible doit désigner un périphérique bloc existant ou un fichier image existant."
fi

taille_iso="$(stat -c %s "$ISO")"
log "Écriture de l'ISO ($(numfmt --to=iec "$taille_iso")) sur $CIBLE"
# notrunc : sans lui, dd TRONQUE le fichier de sortie à la taille de l'ISO.
# Une image pré-dimensionnée perdait sa place libre, et la partition de données
# devenait impossible (« No free sectors available »). Sans effet sur un
# périphérique bloc.
dd if="$ISO" of="$CIBLE" bs=4M conv=fsync,notrunc status=progress
sync

if [[ -z "$cible_bloc" ]]; then
  boucle="$(losetup --find --show --partscan "$CIBLE")"
  cible_bloc="$boucle"
  log "Image attachée sur $boucle"
fi
nettoyage() {
  if mountpoint -q "${MNT:-/nonexistent}"; then
    umount "$MNT" || true
  fi
  if [[ -n "$boucle" ]]; then
    losetup -d "$boucle" 2>/dev/null || true
  fi
}
trap nettoyage EXIT

# --- Seconde partition --------------------------------------------------------
# L'ISO hybride n'a PAS de table GPT : sa table est un MBR dans lequel la
# partition 1 commence au secteur 0 et où la partition EFI (type ef) est
# IMBRIQUÉE dans la première. Les outils GPT refusent ce chevauchement
# (« Invalid partition data! »), alors qu'il est voulu par isohybrid et
# nécessaire à l'amorçage BIOS. On ajoute donc une entrée MBR supplémentaire,
# sans toucher aux deux premières ni au drapeau d'amorçage.
log "Ajout de la partition de données"
fin="$(sfdisk -d "$cible_bloc" \
  | awk -F'[=,]' '/start=/ { s = $2 + 0; t = $4 + 0; if (s + t > m) m = s + t } END { print m + 0 }')"
[[ "$fin" -gt 0 ]] || die "Table de partitions illisible sur $cible_bloc."
debut=$(( ((fin + 2047) / 2048) * 2048 ))
total="$(blockdev --getsz "$cible_bloc")"
restant=$(( total - debut ))
[[ "$restant" -ge 2097152 ]] \
  || die "Place insuffisante après l'ISO : $(( restant / 2048 )) Mio, 1024 Mio au minimum. Support trop petit."
log "ISO jusqu'au secteur $fin, partition de données à partir de $debut ($(numfmt --to=iec $(( restant * 512 ))))"
printf 'start=%s, type=83\n' "$debut" | sfdisk --append --no-reread --force "$cible_bloc" >/dev/null
partprobe "$cible_bloc" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2

# Un MBR ne porte pas d'étiquette de partition : on retrouve la nôtre par son
# secteur de départ, qui est le seul identifiant dont on soit sûr.
partition="$(sfdisk -d "$cible_bloc" | awk -v d="$debut" '
  /start=/ { gsub(/[ \t]/, ""); if (index($0, "start=" d ",") > 0) { split($0, a, ":"); print a[1]; exit } }')"
[[ -n "$partition" && -b "$partition" ]] \
  || die "Partition de données introuvable après création (départ attendu : secteur $debut)."
log "Partition de données : $partition ($(lsblk -ndo SIZE "$partition"))"

mkfs.ext4 -F -q -L PXE_DATA "$partition"

MNT="$(mktemp -d)"
mount "$partition" "$MNT"

# Les répertoires que le pipeline attend. En mode --reuse-data-disk l'étape 20
# n'est pas jouée, donc personne d'autre ne les crée.
install -d -m 0755 "$MNT"/{downloads,iso,live,windows,clonezilla,clonezilla-images,boot-config,ipxe-prebuilt}

# --- Chargeurs iPXE -----------------------------------------------------------
if [[ -n "$IPXE_DIR" ]]; then
  [[ -s "$IPXE_DIR/undionly.kpxe" && -s "$IPXE_DIR/snponly.efi" ]] \
    || die "Chargeurs iPXE absents de $IPXE_DIR (lancer tools/construire-ipxe.sh)."
  install -m 0644 "$IPXE_DIR/undionly.kpxe" "$IPXE_DIR/snponly.efi" "$MNT/ipxe-prebuilt/"
  log "Chargeurs iPXE embarqués"
else
  echo "AVERTISSEMENT : aucun chargeur iPXE embarqué (--ipxe absent)." >&2
  echo "                La clé exigera un accès réseau pour compiler iPXE au premier démarrage." >&2
fi

# --- Médias et catalogue ------------------------------------------------------
catalogue="$MNT/boot-config/media.conf"
{
  echo "# Catalogue écrit par tools/creer-cle-usb.sh le $(date '+%Y-%m-%d %H:%M')."
  echo "# Les fichiers sont déjà dans downloads/ : l'étape 40 vérifie leur empreinte"
  echo "# et ne télécharge rien."
} > "$catalogue"

for spec in "${MEDIAS[@]:-}"; do
  [[ -n "$spec" ]] || continue
  IFS=':' read -r chemin type id libelle <<< "$spec"
  [[ -f "$chemin" ]] || die "Média introuvable : $chemin"
  [[ -n "$type" && -n "$id" ]] || die "Spécification incomplète : $spec (chemin:type:id:libellé)"
  nom="$(basename "$chemin")"
  log "Copie de $nom ($(numfmt --to=iec "$(stat -c %s "$chemin")"))"
  install -m 0644 "$chemin" "$MNT/downloads/$nom"
  # Empreinte calculée sur le fichier réellement embarqué, pas recopiée d'un
  # catalogue : c'est elle que l'étape 40 vérifiera.
  somme="$(sha256sum "$MNT/downloads/$nom" | cut -d' ' -f1)"
  # L'URL ne sert que si le fichier disparaissait de downloads/ : elle pointe
  # alors sur ce même emplacement, et l'échec est explicite au lieu d'aller
  # chercher une image sur internet à l'insu de l'opérateur.
  printf 'yes|%s|%s|%s|file:///srv/pxe-data/downloads/%s|%s|%s\n' \
    "$id" "$type" "$nom" "$nom" "$somme" "${libelle:-$id}" >> "$catalogue"
done

sync
log "Contenu de la partition de données"
du -sh "$MNT"/* 2>/dev/null || true
df -h "$MNT" | tail -1
umount "$MNT"
rmdir "$MNT"
MNT=""
sync

log "Clé prête : $CIBLE"
