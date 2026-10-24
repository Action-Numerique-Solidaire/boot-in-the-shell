#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

sync_script=/usr/local/sbin/generic-pxe-sync.sh
service_file=/etc/systemd/system/generic-pxe-sync.service

cat > "$sync_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
"$PROJECT_ROOT/scripts/40-download-media.sh"
"$PROJECT_ROOT/scripts/60-publish-media.sh"
"$PROJECT_ROOT/scripts/70-enable-and-validate.sh"
EOF
chmod 0755 "$sync_script"

cat > "$service_file" <<EOF
[Unit]
Description=Synchronisation des médias PXE au démarrage (téléchargement, publication, contrôle)
Wants=network-online.target
After=network-online.target
RequiresMountsFor=$PXE_DATA_MOUNT

[Service]
Type=oneshot
ExecStart=$sync_script
TimeoutStartSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable generic-pxe-sync.service

echo "Synchronisation au démarrage activée : $service_file"
echo "Déclenchement manuel : sudo systemctl start generic-pxe-sync.service"
echo "Suivi : sudo journalctl -u generic-pxe-sync.service"
