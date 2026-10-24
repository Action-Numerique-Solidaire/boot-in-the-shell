#!/usr/bin/env bash
set -Eeuo pipefail

SELF_PATH="/home/user/readdress-pxe-server.sh"
STATE_ROOT="/var/lib/bits-readdress"
PENDING_DIR="$STATE_ROOT/pending"
HISTORY_DIR="$STATE_ROOT/history"
ROLLBACK_UNIT="bits-readdress-rollback"
PREPARE_UNIT="bits-readdress-prepare"

NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
DNSMASQ_FILE="/etc/dnsmasq.conf"
EXPORTS_FILE="/etc/exports.d/pxe.exports"
MENU_FILE="/var/www/html/pxe/menu.ipxe"
START_IPXE_FILE="/srv/tftp/start.ipxe"
BIOS_FILE="/srv/tftp/undionly.kpxe"
UEFI_FILE="/srv/tftp/snponly.efi"
BOOT_IPXE_FILE="/home/user/boot.ipxe"
IPXE_SOURCE="/home/user/build-source/ipxe/src"
SMB_FILE="/etc/samba/smb.conf"
WINDOWS_INSTALL_FILE="/var/www/html/pxe/windows11/install.bat"

usage() {
  cat <<EOF
Usage :
  sudo $SELF_PATH prepare NOUVELLE_IP/CIDR PASSERELLE DNS SOUS_RESEAU_PXE
  sudo $SELF_PATH commit
  sudo $SELF_PATH confirm
  sudo $SELF_PATH rollback
  sudo $SELF_PATH status

Exemple de test :
  sudo $SELF_PATH prepare 192.168.0.102/24 192.168.0.1 192.168.0.1 192.168.0.0/24
  sudo $SELF_PATH commit

Apres reconnexion a la nouvelle adresse :
  sudo $SELF_PATH confirm
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Ce script doit etre execute avec sudo." >&2
    exit 1
  fi
}

require_commands() {
  local command_name
  for command_name in \
    python3 ip ping tar install systemctl systemd-run netplan dnsmasq nginx \
    exportfs curl showmount make runuser sha256sum grep sed awk strings testparm; do
    command -v "$command_name" >/dev/null || {
      echo "Commande requise absente : $command_name" >&2
      exit 1
    }
  done
}

load_state() {
  [[ -f "$PENDING_DIR/state" ]] || {
    echo "Aucun readressage prepare." >&2
    exit 1
  }
  # Les valeurs sont validees avant ecriture et ne contiennent que des
  # adresses IPv4, prefixes numeriques et noms d'interface locaux.
  # shellcheck disable=SC1090
  source "$PENDING_DIR/state"
}

active_interface() {
  ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }'
}

active_cidr() {
  local interface_name="$1"
  ip -4 -o addr show dev "$interface_name" scope global \
    | awk 'NR == 1 { print $4 }'
}

validate_network_values() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import ipaddress
import sys

new_interface = ipaddress.ip_interface(sys.argv[1])
gateway = ipaddress.ip_address(sys.argv[2])
dns = ipaddress.ip_address(sys.argv[3])
proxy_network = ipaddress.ip_network(sys.argv[4], strict=True)

if new_interface.version != 4 or gateway.version != 4 or dns.version != 4:
    raise SystemExit("Seules les adresses IPv4 sont prises en charge.")
if proxy_network.version != 4:
    raise SystemExit("Le sous-reseau PXE doit etre IPv4.")
if new_interface.ip not in proxy_network:
    raise SystemExit("La nouvelle adresse ne fait pas partie du sous-reseau PXE.")
if gateway not in new_interface.network:
    raise SystemExit("La passerelle ne fait pas partie du reseau de la nouvelle adresse.")
if new_interface.ip in {new_interface.network.network_address, new_interface.network.broadcast_address}:
    raise SystemExit("Adresse reseau ou broadcast interdite.")
PY
}

network_address() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

print(ipaddress.ip_network(sys.argv[1], strict=False).network_address)
PY
}

backup_active_configuration() {
  local backup_tar="$1"
  tar -C / -cpf "$backup_tar" \
    "${NETPLAN_FILE#/}" \
    "${DNSMASQ_FILE#/}" \
    "${EXPORTS_FILE#/}" \
    "${MENU_FILE#/}" \
    "${START_IPXE_FILE#/}" \
    "${BIOS_FILE#/}" \
    "${UEFI_FILE#/}" \
    "${BOOT_IPXE_FILE#/}" \
    "${SMB_FILE#/}" \
    "${WINDOWS_INSTALL_FILE#/}"
}

restore_active_configuration() {
  local backup_tar="$1"
  tar -C / -xpf "$backup_tar"
  chown user:user "$BOOT_IPXE_FILE"
  chmod 0664 "$BOOT_IPXE_FILE"
}

replace_exact_values() {
  local source_file="$1"
  local target_file="$2"
  local old_ip="$3"
  local new_ip="$4"
  local old_subnet="$5"
  local new_subnet="$6"
  python3 - "$source_file" "$target_file" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet" <<'PY'
import ipaddress
from pathlib import Path
import sys

source, target, old_ip, new_ip, old_subnet, new_subnet = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
old_network = str(ipaddress.ip_network(old_subnet, strict=False).network_address)
new_network = str(ipaddress.ip_network(new_subnet, strict=False).network_address)
if old_ip not in text and old_subnet not in text and old_network not in text:
    raise SystemExit(f"Ancienne adresse et ancien sous-reseau absents de {source}")
text = text.replace(old_ip, new_ip)
text = text.replace(old_subnet, new_subnet)
text = text.replace(old_network, new_network)
Path(target).write_text(text, encoding="utf-8")
PY
}

stop_pxe_services() {
  systemctl stop dnsmasq nginx nfs-server
}

start_pxe_services() {
  exportfs -ra
  systemctl start nginx
  systemctl start nfs-server
  systemctl start dnsmasq
}

prepare_change() {
  require_root
  require_commands
  [[ $# -eq 4 ]] || { usage >&2; exit 2; }
  [[ ! -e "$PENDING_DIR" ]] || {
    echo "Un readressage est deja en attente. Utilise status, confirm ou rollback." >&2
    exit 1
  }

  local new_cidr="$1"
  local new_gateway="$2"
  local new_dns="$3"
  local new_subnet="$4"
  local interface_name old_cidr old_ip old_prefix old_subnet new_ip
  local old_network_address new_network_address stage_root

  echo "[1/7] Validation du reseau et de l'etat actif..."
  validate_network_values "$new_cidr" "$new_gateway" "$new_dns" "$new_subnet"
  interface_name="$(active_interface)"
  [[ -n "$interface_name" ]] || { echo "Interface par defaut introuvable." >&2; exit 1; }
  old_cidr="$(active_cidr "$interface_name")"
  [[ -n "$old_cidr" ]] || { echo "Adresse IPv4 active introuvable." >&2; exit 1; }
  old_ip="${old_cidr%/*}"
  old_prefix="${old_cidr#*/}"
  new_ip="${new_cidr%/*}"
  old_subnet="$(python3 - "$old_cidr" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  old_network_address="$(network_address "$old_subnet")"
  new_network_address="$(network_address "$new_subnet")"

  [[ "$old_ip" != "$new_ip" ]] || { echo "La nouvelle adresse est identique a l'adresse actuelle." >&2; exit 1; }
  if ping -c 2 -W 1 "$new_ip" >/dev/null 2>&1; then
    echo "Refus : $new_ip repond deja sur le reseau." >&2
    exit 1
  fi

  for required_file in \
    "$NETPLAN_FILE" "$DNSMASQ_FILE" "$EXPORTS_FILE" "$MENU_FILE" \
    "$START_IPXE_FILE" "$BIOS_FILE" "$UEFI_FILE" "$BOOT_IPXE_FILE" \
    "$SMB_FILE" "$WINDOWS_INSTALL_FILE"; do
    [[ -f "$required_file" ]] || { echo "Fichier actif absent : $required_file" >&2; exit 1; }
  done
  [[ -d "$IPXE_SOURCE" ]] || { echo "Sources iPXE absentes : $IPXE_SOURCE" >&2; exit 1; }

  echo "[2/7] Sauvegarde de la configuration active..."
  install -d -m 0755 "$PENDING_DIR" "$PENDING_DIR/staged" "$PENDING_DIR/logs" "$HISTORY_DIR"
  backup_active_configuration "$PENDING_DIR/backup.tar"

  cat > "$PENDING_DIR/state" <<EOF
INTERFACE_NAME=$interface_name
OLD_CIDR=$old_cidr
OLD_IP=$old_ip
OLD_PREFIX=$old_prefix
OLD_SUBNET=$old_subnet
OLD_NETWORK_ADDRESS=$old_network_address
NEW_CIDR=$new_cidr
NEW_IP=$new_ip
NEW_GATEWAY=$new_gateway
NEW_DNS=$new_dns
NEW_SUBNET=$new_subnet
NEW_NETWORK_ADDRESS=$new_network_address
PREPARED_AT=$(date --iso-8601=seconds)
EOF
  chmod 0600 "$PENDING_DIR/state"

  echo "[3/7] Generation des configurations candidates..."
  stage_root="$PENDING_DIR/staged"
  cat > "$stage_root/netplan.yaml" <<EOF
network:
  version: 2
  ethernets:
    $interface_name:
      critical: true
      dhcp4: false
      accept-ra: true
      addresses:
        - $new_cidr
      routes:
        - to: default
          via: $new_gateway
      nameservers:
        addresses:
          - $new_dns
EOF

  replace_exact_values "$DNSMASQ_FILE" "$stage_root/dnsmasq.conf" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"
  replace_exact_values "$EXPORTS_FILE" "$stage_root/pxe.exports" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"
  replace_exact_values "$MENU_FILE" "$stage_root/menu.ipxe" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"
  replace_exact_values "$START_IPXE_FILE" "$stage_root/start.ipxe" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"
  replace_exact_values "$BOOT_IPXE_FILE" "$stage_root/boot.ipxe" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"
  replace_exact_values "$SMB_FILE" "$stage_root/smb.conf" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"
  replace_exact_values "$WINDOWS_INSTALL_FILE" "$stage_root/windows-install.bat" "$old_ip" "$new_ip" "$old_subnet" "$new_subnet"

  chmod 0600 "$stage_root/netplan.yaml"
  chmod 0644 "$stage_root/dnsmasq.conf" "$stage_root/pxe.exports" "$stage_root/menu.ipxe" "$stage_root/start.ipxe" "$stage_root/boot.ipxe"
  chmod 0644 "$stage_root/smb.conf" "$stage_root/windows-install.bat"

  install -d -m 0755 "$stage_root/netplan-root/etc/netplan"
  install -m 0600 "$stage_root/netplan.yaml" "$stage_root/netplan-root/etc/netplan/00-installer-config.yaml"
  netplan generate --root-dir "$stage_root/netplan-root"
  dnsmasq --test --conf-file="$stage_root/dnsmasq.conf"
  grep -Fxq "dhcp-range=$new_network_address,proxy" "$stage_root/dnsmasq.conf" || {
    echo "Refus : dhcp-range n'a pas ete mis a jour vers $new_network_address." >&2
    exit 1
  }
  testparm -s "$stage_root/smb.conf" >/dev/null

  echo "[4/7] Nettoyage des anciens artefacts iPXE..."
  runuser -u user -- make -C "$IPXE_SOURCE" clean > "$PENDING_DIR/logs/ipxe-clean.log"
  echo "[5/7] Compilation du chargeur BIOS..."
  runuser -u user -- make -C "$IPXE_SOURCE" -j2 bin/undionly.kpxe EMBED="$stage_root/boot.ipxe" \
    > "$PENDING_DIR/logs/ipxe-bios.log"
  echo "[6/7] Compilation du chargeur UEFI..."
  runuser -u user -- make -C "$IPXE_SOURCE" -j2 bin-x86_64-efi/snponly.efi EMBED="$stage_root/boot.ipxe" \
    > "$PENDING_DIR/logs/ipxe-uefi.log"
  install -m 0644 "$IPXE_SOURCE/bin/undionly.kpxe" "$stage_root/undionly.kpxe"
  install -m 0644 "$IPXE_SOURCE/bin-x86_64-efi/snponly.efi" "$stage_root/snponly.efi"

  strings "$stage_root/snponly.efi" | grep -Fq "http://$new_ip/pxe/menu.ipxe"
  if grep -R -a -F "$old_ip" \
    "$stage_root/dnsmasq.conf" "$stage_root/pxe.exports" "$stage_root/menu.ipxe" \
    "$stage_root/start.ipxe" "$stage_root/boot.ipxe" \
    "$stage_root/undionly.kpxe" "$stage_root/snponly.efi" \
    "$stage_root/smb.conf" "$stage_root/windows-install.bat" >/dev/null; then
    echo "Ancienne adresse encore presente dans la preparation." >&2
    exit 1
  fi

  echo "[7/7] Validation finale et calcul des empreintes..."
  sha256sum \
    "$stage_root/netplan.yaml" "$stage_root/dnsmasq.conf" "$stage_root/pxe.exports" \
    "$stage_root/menu.ipxe" "$stage_root/start.ipxe" "$stage_root/boot.ipxe" \
    "$stage_root/undionly.kpxe" "$stage_root/snponly.efi" \
    "$stage_root/smb.conf" "$stage_root/windows-install.bat" \
    > "$PENDING_DIR/SHA256SUMS"

  echo
  echo "Readressage prepare, sans modification active."
  echo "Actuel  : $old_cidr"
  echo "Nouveau : $new_cidr"
  echo "Reseau PXE : $old_subnet -> $new_subnet"
  echo "Pour basculer : sudo $SELF_PATH commit"
}

dispatch_prepare() {
  require_root
  [[ $# -eq 4 ]] || { usage >&2; exit 2; }
  if systemctl is-active --quiet "${PREPARE_UNIT}.service"; then
    echo "Une preparation est deja en cours." >&2
    exit 1
  fi
  [[ ! -e "$PENDING_DIR" ]] || {
    echo "Une preparation incomplete ou en attente existe deja." >&2
    echo "Utilise status, confirm ou rollback avant de recommencer." >&2
    exit 1
  }
  systemd-run \
    --unit="$PREPARE_UNIT" \
    --collect \
    --property=Type=oneshot \
    "$SELF_PATH" prepare-worker "$@"
  echo "Preparation lancee en arriere-plan."
  echo "Suivi : sudo journalctl -fu ${PREPARE_UNIT}.service"
  echo "Etat  : sudo $SELF_PATH status"
}

commit_change() {
  require_root
  require_commands
  load_state

  ip -4 -o addr show dev "$INTERFACE_NAME" | grep -Fq " $OLD_CIDR " || {
    echo "Refus : l'adresse active n'est plus $OLD_CIDR." >&2
    exit 1
  }
  if ping -c 2 -W 1 "$NEW_IP" >/dev/null 2>&1; then
    echo "Refus : $NEW_IP repond deja sur le reseau." >&2
    exit 1
  fi
  (cd "$PENDING_DIR" && sha256sum -c SHA256SUMS)

  systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
  systemctl stop "${ROLLBACK_UNIT}.service" 2>/dev/null || true
  systemd-run --unit="$ROLLBACK_UNIT" --on-active=5m "$SELF_PATH" rollback

  trap 'echo "Erreur pendant la bascule. Le retour automatique reste programme." >&2' ERR
  stop_pxe_services

  install -m 0600 "$PENDING_DIR/staged/netplan.yaml" "$NETPLAN_FILE"
  install -m 0644 "$PENDING_DIR/staged/dnsmasq.conf" "$DNSMASQ_FILE"
  install -m 0644 "$PENDING_DIR/staged/pxe.exports" "$EXPORTS_FILE"
  install -m 0644 "$PENDING_DIR/staged/menu.ipxe" "$MENU_FILE"
  install -m 0644 "$PENDING_DIR/staged/start.ipxe" "$START_IPXE_FILE"
  install -m 0644 "$PENDING_DIR/staged/undionly.kpxe" "$BIOS_FILE"
  install -m 0644 "$PENDING_DIR/staged/snponly.efi" "$UEFI_FILE"
  install -m 0664 -o user -g user "$PENDING_DIR/staged/boot.ipxe" "$BOOT_IPXE_FILE"
  install -m 0644 "$PENDING_DIR/staged/smb.conf" "$SMB_FILE"
  install -m 0644 "$PENDING_DIR/staged/windows-install.bat" "$WINDOWS_INSTALL_FILE"

  netplan generate
  dnsmasq --test
  nginx -t
  testparm -s "$SMB_FILE" >/dev/null
  systemctl daemon-reload
  netplan apply
  start_pxe_services
  systemctl reload smbd

  echo
  echo "Bascule appliquee vers $NEW_CIDR."
  echo "Reconnecte-toi a user@$NEW_IP puis execute dans les cinq minutes :"
  echo "sudo $SELF_PATH confirm"
}

confirm_change() {
  require_root
  require_commands
  load_state

  ip -4 -o addr show dev "$INTERFACE_NAME" | grep -Fq " $NEW_CIDR " || {
    echo "Refus : $NEW_CIDR n'est pas active." >&2
    exit 1
  }
  ping -c 2 -W 2 "$NEW_GATEWAY" >/dev/null || {
    echo "Refus : la passerelle $NEW_GATEWAY ne repond pas." >&2
    exit 1
  }
  systemctl is-active --quiet dnsmasq
  systemctl is-active --quiet nginx
  systemctl is-active --quiet nfs-server
  systemctl is-active --quiet smbd
  curl -fsS "http://127.0.0.1/pxe/menu.ipxe" | grep -F "$NEW_IP" >/dev/null
  showmount -e localhost | grep -F "$NEW_SUBNET" >/dev/null
  strings "$UEFI_FILE" | grep -F "http://$NEW_IP/pxe/menu.ipxe" >/dev/null
  grep -Fxq "dhcp-range=$NEW_NETWORK_ADDRESS,proxy" "$DNSMASQ_FILE" || {
    echo "Refus : dhcp-range actif ne correspond pas au reseau $NEW_NETWORK_ADDRESS." >&2
    exit 1
  }
  if grep -R -a -F "$OLD_IP" \
    "$DNSMASQ_FILE" "$EXPORTS_FILE" "$MENU_FILE" "$START_IPXE_FILE" \
    "$BIOS_FILE" "$UEFI_FILE" "$BOOT_IPXE_FILE" \
    "$SMB_FILE" "$WINDOWS_INSTALL_FILE" >/dev/null; then
    echo "Refus : ancienne adresse encore presente dans la publication active." >&2
    exit 1
  fi

  local history_path="$HISTORY_DIR/confirmed-$(date '+%Y%m%d-%H%M%S')-${OLD_IP}-to-${NEW_IP}"
  mv "$PENDING_DIR" "$history_path"
  date --iso-8601=seconds > "$history_path/CONFIRMED_AT"

  # Enregistrer d'abord la confirmation. Ainsi, meme si l'arret d'une unite
  # transitoire coupe ou interrompt la commande, le rollback ne retrouve plus
  # de dossier pending et ne peut pas restaurer l'ancienne configuration.
  systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
  systemctl stop "${ROLLBACK_UNIT}.service" 2>/dev/null || true

  echo "Readressage confirme : $OLD_CIDR -> $NEW_CIDR"
  echo "Historique : $history_path"
}

rollback_change() {
  require_root
  require_commands
  load_state

  trap - ERR
  stop_pxe_services || true
  restore_active_configuration "$PENDING_DIR/backup.tar"
  netplan generate
  dnsmasq --test
  nginx -t
  testparm -s "$SMB_FILE" >/dev/null
  systemctl daemon-reload
  netplan apply
  start_pxe_services
  systemctl reload smbd

  local history_path="$HISTORY_DIR/rolled-back-$(date '+%Y%m%d-%H%M%S')-${NEW_IP}-to-${OLD_IP}"
  mv "$PENDING_DIR" "$history_path"
  date --iso-8601=seconds > "$history_path/ROLLED_BACK_AT"

  echo "Retour effectue vers $OLD_CIDR."
  echo "Historique : $history_path"
}

show_status() {
  require_root
  echo "Adresse active :"
  ip -4 -br addr
  echo
  if [[ -f "$PENDING_DIR/state" ]]; then
    echo "Readressage en attente :"
    sed -n '1,120p' "$PENDING_DIR/state"
    echo
    systemctl status "${ROLLBACK_UNIT}.timer" --no-pager 2>/dev/null || true
  else
    echo "Aucun readressage en attente."
  fi
  echo
  systemctl status "${PREPARE_UNIT}.service" --no-pager 2>/dev/null || true
}

mode="${1:-}"
shift || true

case "$mode" in
  prepare) dispatch_prepare "$@" ;;
  prepare-worker) prepare_change "$@" ;;
  commit) [[ $# -eq 0 ]] || { usage >&2; exit 2; }; commit_change ;;
  confirm) [[ $# -eq 0 ]] || { usage >&2; exit 2; }; confirm_change ;;
  rollback) [[ $# -eq 0 ]] || { usage >&2; exit 2; }; rollback_change ;;
  status) [[ $# -eq 0 ]] || { usage >&2; exit 2; }; show_status ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
