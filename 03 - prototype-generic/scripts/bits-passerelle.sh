#!/usr/bin/env bash
# Réseau du mode passerelle : le serveur est le routeur du réseau PXE.
#
#   bits-passerelle.sh            applique la configuration du mode en cours :
#                                 en passerelle, adresse du réseau PXE, routage,
#                                 NAT et garde DHCP ; en proxy, retire ce
#                                 qu'une passerelle aurait laissé
#   bits-passerelle.sh --retirer  retire tout, quel que soit le mode (prerm)
#
# Appelé par bits-lan.service au démarrage (avant bits-dnsmasq, sans attendre
# l'amont : le réseau PXE doit répondre même si le Wi-Fi tarde), et par
# 30-configure-network.sh à chaque publication.
#
# Rien n'est écrit dans la configuration réseau du système (ifupdown,
# NetworkManager, netplan) : l'adresse est posée à chaque démarrage. Seul
# NetworkManager, s'il est présent, reçoit l'ordre de ne pas gérer l'interface
# du réseau PXE, sinon il y lancerait un client DHCP.
#
# Code de sortie 4 : un autre serveur DHCP répond sur le réseau PXE. Le DHCP
# de BITS n'est pas démarré (bits-dnsmasq a une condition sur
# /run/bits/dhcp-refuse) : un câble branché sur la box ou sur le routeur
# Wi-Fi au lieu du switch ne met pas deux serveurs en concurrence.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root

ETAT=/var/lib/bits/passerelle
REFUS=/run/bits/dhcp-refuse
NM_CONF=/etc/NetworkManager/conf.d/90-bits-passerelle.conf
ISSUE=/run/issue.d/bits-passerelle.issue
SONDE="$(dirname "$0")/sonde-dhcp.py"

nm_recharger() {
  if command -v nmcli >/dev/null; then nmcli general reload >/dev/null 2>&1 || true; fi
}

retirer() {
  nft delete table inet bits 2>/dev/null || true
  if [[ -f "$ETAT" ]]; then
    local interface cidr forward
    read -r interface cidr forward < "$ETAT" || true
    if [[ -n "${interface:-}" && -n "${cidr:-}" ]]; then
      ip addr del "$cidr" dev "$interface" 2>/dev/null || true
    fi
    # ip_forward n'est rendu à 0 que si c'est la passerelle qui l'avait mis à 1.
    if [[ "${forward:-}" == 0 ]]; then sysctl -qw net.ipv4.ip_forward=0 || true; fi
    rm -f "$ETAT"
    echo "Passerelle retirée${interface:+ de $interface}."
  fi
  if [[ -f "$NM_CONF" ]]; then rm -f "$NM_CONF"; nm_recharger; fi
  rm -f "$ISSUE" "$REFUS"
}

if [[ "${1:-}" == --retirer ]]; then
  retirer
  exit 0
fi
[[ $# -eq 0 ]] || die "usage : $0 [--retirer]"

source_config
if [[ "$PXE_MODE" != passerelle ]]; then
  retirer
  exit 0
fi
# Au démarrage, la carte du réseau PXE peut apparaître après ce service :
# on lui laisse 20 s.
for _ in $(seq 20); do
  ( load_config ) >/dev/null 2>&1 && break
  sleep 1
done
load_config
require_command nft

lan="$PXE_LAN_INTERFACE"
install -d -m 0755 "$(dirname "$ETAT")" "$(dirname "$REFUS")" "$(dirname "$ISSUE")"

# --- 1. NetworkManager laisse l'interface du réseau PXE ---------------------------
if [[ -d /etc/NetworkManager ]]; then
  contenu="# Écrit par bits-pxe-server (mode passerelle) : interface du réseau PXE.
[keyfile]
unmanaged-devices=interface-name:$lan"
  if [[ "$(cat "$NM_CONF" 2>/dev/null)" != "$contenu" ]]; then
    install -d -m 0755 "$(dirname "$NM_CONF")"
    printf '%s\n' "$contenu" > "$NM_CONF"
    nm_recharger
  fi
fi

# --- 2. adresse du réseau PXE --------------------------------------------------------
# L'ancienne adresse est retirée si PXE_LAN_CIDR a changé.
if [[ -f "$ETAT" ]]; then
  read -r ancienne_if ancienne_cidr forward_initial < "$ETAT" || true
  if [[ "${ancienne_if:-}" != "$lan" || "${ancienne_cidr:-}" != "$PXE_LAN_CIDR" ]]; then
    ip addr del "$ancienne_cidr" dev "$ancienne_if" 2>/dev/null || true
  fi
else
  forward_initial="$(sysctl -n net.ipv4.ip_forward)"
fi
ip link set dev "$lan" up
ip addr replace "$PXE_LAN_CIDR" dev "$lan"
printf '%s %s %s\n' "$lan" "$PXE_LAN_CIDR" "${forward_initial:-0}" > "$ETAT"

# --- 3. routage et NAT ---------------------------------------------------------------
# Les postes du réseau PXE sortent par n'importe quelle autre interface,
# masqués derrière l'adresse du serveur : l'amont peut changer (Wi-Fi qui
# change de nom, câble de secours) sans réécrire les règles. Depuis l'amont,
# seules les réponses entrent : les postes ne sont pas joignables depuis le
# réseau du routeur Wi-Fi.
# Écrit seulement s'il le faut : dans un conteneur, /proc/sys est en lecture seule.
[[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || sysctl -qw net.ipv4.ip_forward=1
nft -f - <<EOF
table inet bits
delete table inet bits
table inet bits {
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$lan" ip saddr $PXE_SUBNET_CIDR accept
    iifname "$lan" drop
    oifname "$lan" ct state established,related accept
    oifname "$lan" drop
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $PXE_SUBNET_CIDR oifname != "$lan" masquerade
  }
}
EOF

# --- 4. garde DHCP ----------------------------------------------------------------------
# Sans porteuse (câble débranché), personne ne peut répondre : on attend
# quelques secondes qu'un lien qui vient de monter négocie, puis on sonde.
for _ in 1 2 3 4 5; do
  [[ "$(cat "/sys/class/net/$lan/carrier" 2>/dev/null)" == 1 ]] && break
  sleep 1
done
if [[ "$(cat "/sys/class/net/$lan/carrier" 2>/dev/null)" == 1 ]]; then
  set +e
  autres="$(python3 -I "$SONDE" "$lan" --ignorer "$PXE_IP")"
  rc=$?
  set -e
  case $rc in
    0) rm -f "$REFUS" ;;
    3)
      printf '%s\n' "$autres" > "$REFUS"
      systemctl stop bits-dnsmasq.service 2>/dev/null || true
      echo "REFUS : un autre serveur DHCP répond sur $lan ($autres)." >&2
      echo "Le port $lan doit être relié au switch du réseau PXE, pas à la box ni au routeur Wi-Fi." >&2
      echo "Le DHCP de BITS reste arrêté ; il redémarre à la prochaine publication réussie." >&2
      exit 4 ;;
    *) echo "AVERTISSEMENT : sonde DHCP impossible sur $lan, garde non appliquée." >&2; rm -f "$REFUS" ;;
  esac
else
  rm -f "$REFUS"
  echo "Aucun câble sur $lan : le réseau PXE attend le switch."
fi

# --- 5. console -----------------------------------------------------------------------------
cat > "$ISSUE" <<EOF
Réseau PXE : $PXE_IP sur $lan ($PXE_SUBNET_CIDR) - interface web aussi sur http://$PXE_IP/

EOF

echo "Passerelle : $PXE_LAN_CIDR sur $lan, DHCP $PXE_DHCP_DEBUT-$PXE_DHCP_FIN, sortie par ${PXE_UPLINK_INTERFACE:-<aucune route par défaut>}."
