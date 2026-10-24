#!/usr/bin/env bash
set -Eeuo pipefail

MENU_FILE="/var/www/html/pxe/menu.ipxe"
SERVER_IP="192.168.0.102"
REPOSITORY="/srv/pxe-data/clonezilla-images"
BACKUP_ROOT="/home/user/pxe-backups"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

for command_name in python3 install nginx curl grep; do
  command -v "$command_name" >/dev/null || {
    echo "Commande requise absente : $command_name" >&2
    exit 1
  }
done

[[ -f "$MENU_FILE" ]] || { echo "Menu PXE absent : $MENU_FILE" >&2; exit 1; }
[[ -d "$REPOSITORY" ]] || { echo "Depot Clonezilla absent : $REPOSITORY" >&2; exit 1; }
grep -Fq "item clonezilla " "$MENU_FILE" || {
  echo "Entree Clonezilla absente du menu." >&2
  exit 1
}
grep -Fq "ocs_prerun=" "$MENU_FILE" && {
  echo "Le montage automatique du depot Clonezilla est deja configure." >&2
  exit 1
}

backup_dir="$BACKUP_ROOT/pre-clonezilla-auto-repository-$(date '+%Y%m%d-%H%M%S')"
install -d -m 0750 "$backup_dir"
cp -a "$MENU_FILE" "$backup_dir/menu.ipxe"

python3 - "$MENU_FILE" "$SERVER_IP" "$REPOSITORY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
server = sys.argv[2]
repository = sys.argv[3]
text = path.read_text(encoding="utf-8")
marker = " ocs_live_run=ocs-live-general"
if text.count(marker) != 1:
    raise SystemExit("Ligne Clonezilla inattendue : modification refusee.")
prerun = (
    f' ocs_prerun="mount -t nfs -o vers=3 '
    f'{server}:{repository} /home/partimag"'
)
text = text.replace(marker, prerun + marker, 1)
path.write_text(text, encoding="utf-8")
PY

nginx -t
curl -fsS "http://127.0.0.1/pxe/menu.ipxe" \
  | grep -F "ocs_prerun=\"mount -t nfs -o vers=3 $SERVER_IP:$REPOSITORY /home/partimag\"" \
  >/dev/null

echo
echo "Depot Clonezilla monte automatiquement au demarrage."
echo "Serveur : $SERVER_IP"
echo "Export  : $REPOSITORY"
echo "Sauvegarde : $backup_dir"
echo "Les choix de sauvegarde, restauration et disque restent interactifs."
