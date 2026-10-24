#!/usr/bin/env bash
set -Eeuo pipefail

ISO="/srv/pxe-data/incoming/Win11_25H2_French_x64_v2.iso"
ISO_SHA256="a02693beb8eb166afdfdb7db49176a2b547f81e61030a695fe172277db6a1977"
WIMBOOT_SOURCE="/home/user/wimboot-2.9.0"
WIMBOOT_SHA256="5f067ccdc4d084d5bf77b6c853bd0f8402dfc2b4cd1b103d358993ae97fae8e3"
MEDIA_DIR="/srv/pxe-data/windows/win11-25h2-fr"
WEB_DIR="/var/www/html/pxe/windows11"
MENU_FILE="/var/www/html/pxe/menu.ipxe"
SMB_CONF="/etc/samba/smb.conf"
MOUNT_DIR="/mnt/windows11-pxe-source"
BACKUP_ROOT="/home/user/pxe-backups"
SERVER_IP="192.168.0.102"
PXE_SUBNET="192.168.0.0/24"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

for command_name in sha256sum mountpoint mount rsync python3 testparm systemctl curl; do
  command -v "$command_name" >/dev/null || {
    echo "Commande requise absente : $command_name" >&2
    exit 1
  }
done

[[ -f "$ISO" ]] || { echo "ISO absente : $ISO" >&2; exit 1; }
[[ -f "$WIMBOOT_SOURCE" ]] || { echo "wimboot absent : $WIMBOOT_SOURCE" >&2; exit 1; }
[[ -f "$MENU_FILE" ]] || { echo "Menu PXE absent : $MENU_FILE" >&2; exit 1; }
[[ -f "$SMB_CONF" ]] || { echo "Configuration Samba absente : $SMB_CONF" >&2; exit 1; }

echo "[1/8] Verification des empreintes..."
printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c -
printf '%s  %s\n' "$WIMBOOT_SHA256" "$WIMBOOT_SOURCE" | sha256sum -c -

if grep -Fq "item windows11 " "$MENU_FILE" || [[ -e "$MEDIA_DIR" || -e "$WEB_DIR" ]]; then
  echo "Refus : une publication Windows 11 existe deja." >&2
  exit 1
fi

backup_dir="$BACKUP_ROOT/pre-windows11-$(date '+%Y%m%d-%H%M%S')"
install -d -m 0750 "$backup_dir"
cp -a "$MENU_FILE" "$backup_dir/menu.ipxe"
cp -a "$SMB_CONF" "$backup_dir/smb.conf"

cleanup() {
  if mountpoint -q "$MOUNT_DIR"; then
    umount "$MOUNT_DIR"
  fi
}
trap cleanup EXIT

echo "[2/8] Extraction du media Windows sur le SSD..."
install -d -m 0755 "$MOUNT_DIR" "$MEDIA_DIR" "$WEB_DIR"
mount -o loop,ro "$ISO" "$MOUNT_DIR"
rsync -aH --info=progress2 "$MOUNT_DIR/" "$MEDIA_DIR/"
cleanup
trap - EXIT

for required_file in \
  boot/bcd boot/boot.sdi sources/boot.wim sources/install.wim setup.exe; do
  [[ -f "$MEDIA_DIR/$required_file" ]] || {
    echo "Fichier Windows absent apres extraction : $required_file" >&2
    exit 1
  }
done

echo "[3/8] Publication HTTP de WinPE..."
install -m 0755 "$WIMBOOT_SOURCE" "$WEB_DIR/wimboot"
ln -s "$MEDIA_DIR" "$WEB_DIR/media"

cat > "$WEB_DIR/winpeshl.ini" <<'EOF'
[LaunchApps]
"%SYSTEMROOT%\System32\install.bat"
EOF

cat > "$WEB_DIR/install.bat" <<EOF
@echo off
wpeinit
:connect
net use Z: \\\\$SERVER_IP\\win11 /user:guest "" /persistent:no
if errorlevel 1 (
  echo Le partage Windows 11 est indisponible. Nouvelle tentative dans 5 secondes.
  timeout /t 5
  goto connect
)
Z:\\setup.exe
if errorlevel 1 cmd.exe
EOF
chmod 0644 "$WEB_DIR/winpeshl.ini" "$WEB_DIR/install.bat"

echo "[4/8] Configuration du partage Samba en lecture seule..."
python3 - "$SMB_CONF" "$MEDIA_DIR" "$PXE_SUBNET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
media = sys.argv[2]
subnet = sys.argv[3]
text = path.read_text(encoding="utf-8")
if "# BEGIN BITS WINDOWS11" in text or "[win11]" in text.lower():
    raise SystemExit("Une configuration Samba win11 existe deja.")
global_header = "[global]"
if global_header not in text:
    raise SystemExit("Section [global] Samba introuvable.")
text = text.replace(global_header, global_header + "\n   map to guest = Bad User", 1)
text += f"""

# BEGIN BITS WINDOWS11
[win11]
   comment = Installation Windows 11 PXE
   path = {media}
   browseable = yes
   read only = yes
   guest ok = yes
   guest only = yes
   force user = nobody
   hosts allow = {subnet} 127.0.0.1
   hosts deny = 0.0.0.0/0
# END BITS WINDOWS11
"""
path.write_text(text, encoding="utf-8")
PY
testparm -s "$SMB_CONF" >/dev/null

echo "[5/8] Ajout au menu iPXE..."
python3 - "$MENU_FILE" "$SERVER_IP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
server = sys.argv[2]
text = path.read_text(encoding="utf-8")
item_anchor = "item --gap -- ---------------- Outils iPXE ----------------"
label_anchor = ":shell\n"
if item_anchor not in text or label_anchor not in text:
    raise SystemExit("Ancres du menu iPXE introuvables.")
text = text.replace(item_anchor, "item windows11 Windows 11 25H2 - installation\n" + item_anchor, 1)
entry = f""":windows11
kernel http://{server}/pxe/windows11/wimboot quiet
initrd http://{server}/pxe/windows11/media/boot/bcd BCD
initrd http://{server}/pxe/windows11/media/boot/boot.sdi boot.sdi
initrd http://{server}/pxe/windows11/media/sources/boot.wim boot.wim
initrd http://{server}/pxe/windows11/winpeshl.ini winpeshl.ini
initrd http://{server}/pxe/windows11/install.bat install.bat
boot || goto failed

"""
text = text.replace(label_anchor, entry + label_anchor, 1)
path.write_text(text, encoding="utf-8")
PY

echo "[6/8] Activation et controles des services..."
systemctl enable --now smbd
systemctl reload smbd
systemctl is-active --quiet smbd
nginx -t
systemctl is-active --quiet nginx

echo "[7/8] Controle HTTP et Samba local..."
curl -fsSI "http://127.0.0.1/pxe/windows11/wimboot" >/dev/null
curl -fsSI "http://127.0.0.1/pxe/windows11/media/boot/boot.sdi" >/dev/null
curl -fsSI "http://127.0.0.1/pxe/windows11/media/sources/boot.wim" >/dev/null
curl -fsS "http://127.0.0.1/pxe/menu.ipxe" | grep -F "item windows11 " >/dev/null

echo "[8/8] Empreintes de la publication..."
sha256sum \
  "$WEB_DIR/wimboot" "$WEB_DIR/winpeshl.ini" "$WEB_DIR/install.bat" \
  "$MEDIA_DIR/boot/bcd" "$MEDIA_DIR/boot/boot.sdi" \
  "$MEDIA_DIR/sources/boot.wim" "$MEDIA_DIR/sources/install.wim" \
  > "$backup_dir/WINDOWS11-PUBLISHED.sha256"

echo
echo "Windows 11 PXE publie avec succes."
echo "Media : $MEDIA_DIR"
echo "Partage : \\\\$SERVER_IP\\win11 (invite, lecture seule)"
echo "Sauvegarde : $backup_dir"
echo "Un demarrage PXE UEFI reel reste necessaire."
