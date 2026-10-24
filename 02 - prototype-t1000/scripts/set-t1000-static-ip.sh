#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/netplan/00-installer-config.yaml"
STATE_DIR="/var/lib/t1000-static-ip"
BACKUP_FILE="$STATE_DIR/00-installer-config.yaml.before-static"
TARGET_INTERFACE="enp0s31f6"
TARGET_ADDRESS="192.168.0.101/24"
TARGET_IP="192.168.0.101"
TARGET_GATEWAY="192.168.0.1"
TARGET_DNS="192.168.0.1"
ROLLBACK_UNIT="t1000-netplan-rollback"
SELF_PATH="/home/user/set-t1000-static-ip.sh"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

mode="${1:-}"

write_static_config() {
  local tmp_file
  tmp_file="$(mktemp /etc/netplan/00-installer-config.yaml.new.XXXXXX)"
  cat > "$tmp_file" <<EOF
network:
  version: 2
  ethernets:
    $TARGET_INTERFACE:
      critical: true
      dhcp4: false
      accept-ra: true
      addresses:
        - $TARGET_ADDRESS
      routes:
        - to: default
          via: $TARGET_GATEWAY
      nameservers:
        addresses:
          - $TARGET_DNS
EOF
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$CONFIG_FILE"
}

case "$mode" in
  apply)
    [[ -f "$CONFIG_FILE" ]] || { echo "Configuration Netplan absente." >&2; exit 1; }
    [[ -x "$SELF_PATH" ]] || { echo "Script attendu absent : $SELF_PATH" >&2; exit 1; }
    ip link show "$TARGET_INTERFACE" >/dev/null

    if ping -c 2 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
      echo "Refus : $TARGET_IP repond deja sur le reseau." >&2
      exit 1
    fi

    install -d -m 0700 "$STATE_DIR"
    if [[ ! -f "$BACKUP_FILE" ]]; then
      install -m 0600 "$CONFIG_FILE" "$BACKUP_FILE"
    fi

    write_static_config
    if ! netplan generate; then
      install -m 0600 "$BACKUP_FILE" "$CONFIG_FILE"
      netplan generate
      echo "Configuration invalide, ancienne configuration restauree." >&2
      exit 1
    fi

    systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
    systemctl stop "${ROLLBACK_UNIT}.service" 2>/dev/null || true
    systemd-run \
      --unit="$ROLLBACK_UNIT" \
      --on-active=5m \
      "$SELF_PATH" rollback

    echo "Retour automatique au DHCP programme dans cinq minutes."
    echo "Application de $TARGET_ADDRESS..."
    netplan apply
    echo "Reconnecte-toi a user@$TARGET_IP puis confirme avec :"
    echo "sudo $SELF_PATH confirm"
    ;;

  confirm)
    ip -4 -o addr show dev "$TARGET_INTERFACE" | grep -Fq " $TARGET_ADDRESS " || {
      echo "Refus : $TARGET_ADDRESS n'est pas active sur $TARGET_INTERFACE." >&2
      exit 1
    }
    ping -c 2 -W 2 "$TARGET_GATEWAY" >/dev/null || {
      echo "Refus : la passerelle $TARGET_GATEWAY ne repond pas." >&2
      exit 1
    }
    systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
    systemctl stop "${ROLLBACK_UNIT}.service" 2>/dev/null || true
    date --iso-8601=seconds > "$STATE_DIR/confirmed-at"
    echo "Adresse $TARGET_ADDRESS confirmee. Retour automatique annule."
    ;;

  rollback)
    [[ -f "$BACKUP_FILE" ]] || { echo "Sauvegarde Netplan absente." >&2; exit 1; }
    install -m 0600 "$BACKUP_FILE" "$CONFIG_FILE"
    netplan generate
    netplan apply
    date --iso-8601=seconds > "$STATE_DIR/rolled-back-at"
    echo "Ancienne configuration DHCP restauree."
    ;;

  *)
    echo "Usage : sudo $SELF_PATH {apply|confirm|rollback}" >&2
    exit 2
    ;;
esac
