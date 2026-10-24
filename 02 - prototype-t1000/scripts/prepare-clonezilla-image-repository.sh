#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="/srv/pxe-data/clonezilla-images"
EXPORTS_FILE="/etc/exports.d/pxe.exports"
PXE_SUBNET="192.168.0.0/24"
BACKUP_ROOT="/home/user/pxe-backups"
BEGIN_MARKER="# BEGIN BITS CLONEZILLA IMAGES"
END_MARKER="# END BITS CLONEZILLA IMAGES"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

for command_name in install cp exportfs showmount runuser grep; do
  command -v "$command_name" >/dev/null || {
    echo "Commande requise absente : $command_name" >&2
    exit 1
  }
done

[[ -f "$EXPORTS_FILE" ]] || {
  echo "Fichier d'exports absent : $EXPORTS_FILE" >&2
  exit 1
}

if grep -Fq "$BEGIN_MARKER" "$EXPORTS_FILE"; then
  echo "Refus : le depot Clonezilla est deja configure." >&2
  exit 1
fi

backup_dir="$BACKUP_ROOT/pre-clonezilla-repository-$(date '+%Y%m%d-%H%M%S')"
install -d -m 0750 "$backup_dir"
cp -a "$EXPORTS_FILE" "$backup_dir/pxe.exports"

install -d -m 0770 -o nobody -g nogroup "$REPOSITORY"

cat >> "$EXPORTS_FILE" <<EOF

$BEGIN_MARKER
$REPOSITORY $PXE_SUBNET(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534)
$END_MARKER
EOF

exportfs -ra
exportfs -v | grep -F "$REPOSITORY" >/dev/null
showmount -e localhost | grep -F "$REPOSITORY" >/dev/null

test_file="$REPOSITORY/.write-test-$$"
runuser -u nobody -- touch "$test_file"
rm -f "$test_file"

echo
echo "Depot d'images Clonezilla prepare avec succes."
echo "Serveur NFS : 192.168.0.102"
echo "Chemin      : $REPOSITORY"
echo "Acces       : lecture/ecriture depuis $PXE_SUBNET"
echo "Sauvegarde  : $backup_dir"
