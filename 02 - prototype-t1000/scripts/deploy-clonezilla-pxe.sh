#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.3.3-37"
SERVER_IP="192.168.0.102"
ARCHIVE="/srv/pxe-data/incoming/clonezilla-live-${VERSION}-amd64.zip"
ARCHIVE_SHA256="bbb02b409708cf37774debe00f96c642c59c48ebb216f7349dc2252f705ff10e"
MEDIA_DIR="/srv/pxe-data/clonezilla/${VERSION}"
WEB_LINK="/var/www/html/pxe/clonezilla-${VERSION}"
MENU_FILE="/var/www/html/pxe/menu.ipxe"
BACKUP_ROOT="/home/user/pxe-backups"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

for command_name in sha256sum unzip python3 install ln nginx curl grep; do
  command -v "$command_name" >/dev/null || {
    echo "Commande requise absente : $command_name" >&2
    exit 1
  }
done

[[ -f "$ARCHIVE" ]] || { echo "Archive absente : $ARCHIVE" >&2; exit 1; }
[[ -f "$MENU_FILE" ]] || { echo "Menu PXE absent : $MENU_FILE" >&2; exit 1; }
[[ ! -e "$MEDIA_DIR" && ! -e "$WEB_LINK" ]] || {
  echo "Refus : une publication Clonezilla ${VERSION} existe deja." >&2
  exit 1
}
grep -Fq "item clonezilla " "$MENU_FILE" && {
  echo "Refus : une entree Clonezilla existe deja dans le menu." >&2
  exit 1
}

echo "[1/6] Verification de l'archive officielle..."
printf '%s  %s\n' "$ARCHIVE_SHA256" "$ARCHIVE" | sha256sum -c -
unzip -t "$ARCHIVE" >/dev/null

backup_dir="$BACKUP_ROOT/pre-clonezilla-$(date '+%Y%m%d-%H%M%S')"
install -d -m 0750 "$backup_dir"
cp -a "$MENU_FILE" "$backup_dir/menu.ipxe"

echo "[2/6] Extraction des composants PXE sur le SSD..."
install -d -m 0755 "$MEDIA_DIR"
unzip -j "$ARCHIVE" \
  live/vmlinuz live/initrd.img live/filesystem.squashfs \
  -d "$MEDIA_DIR"
chmod 0644 "$MEDIA_DIR/vmlinuz" "$MEDIA_DIR/initrd.img" "$MEDIA_DIR/filesystem.squashfs"

echo "[3/6] Publication HTTP..."
ln -s "$MEDIA_DIR" "$WEB_LINK"

echo "[4/6] Ajout au menu iPXE..."
python3 - "$MENU_FILE" "$SERVER_IP" "$VERSION" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
server = sys.argv[2]
version = sys.argv[3]
text = path.read_text(encoding="utf-8")
item_anchor = "item --gap -- ---------------- Outils iPXE ----------------\n"
label_anchor = ":shell\n"
if item_anchor not in text or label_anchor not in text:
    raise SystemExit("Ancres du menu iPXE introuvables.")
text = text.replace(
    item_anchor,
    item_anchor + f"item clonezilla Clonezilla Live {version} - interactif\n",
    1,
)
entry = f""":clonezilla
kernel http://{server}/pxe/clonezilla-{version}/vmlinuz initrd=initrd.img boot=live username=user union=overlay config components quiet noswap edd=on nomodeset locales=fr_FR.UTF-8 keyboard-layouts=fr ocs_prerun="mount -t nfs -o vers=3 {server}:/srv/pxe-data/clonezilla-images /home/partimag" ocs_live_run=ocs-live-general ocs_live_extra_param= ocs_live_batch=no net.ifnames=0 nosplash noprompt fetch=http://{server}/pxe/clonezilla-{version}/filesystem.squashfs
initrd http://{server}/pxe/clonezilla-{version}/initrd.img
boot || goto failed

"""
text = text.replace(label_anchor, entry + label_anchor, 1)
path.write_text(text, encoding="utf-8")
PY

echo "[5/6] Validation HTTP et nginx..."
nginx -t
for file_name in vmlinuz initrd.img filesystem.squashfs; do
  curl -fsSI "http://127.0.0.1/pxe/clonezilla-${VERSION}/${file_name}" >/dev/null
done
curl -fsS "http://127.0.0.1/pxe/menu.ipxe" | grep -F "item clonezilla " >/dev/null

echo "[6/6] Empreintes de la publication..."
sha256sum \
  "$MEDIA_DIR/vmlinuz" "$MEDIA_DIR/initrd.img" "$MEDIA_DIR/filesystem.squashfs" \
  > "$backup_dir/CLONEZILLA-PUBLISHED.sha256"

echo
echo "Clonezilla Live ${VERSION} publie avec succes en mode interactif."
echo "Media : $MEDIA_DIR"
echo "Sauvegarde : $backup_dir"
echo "Aucune operation de clonage ou de restauration n'est automatisee."
echo "Un demarrage PXE BIOS/UEFI reel reste necessaire."
