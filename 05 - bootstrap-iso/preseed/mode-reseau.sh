#!/bin/sh
# Lancé par l'installateur (late_command), HORS du système installé : c'est
# ici que l'on sait sur quelle interface l'installation a eu internet.
#
# Installation faite en Wi-Fi, et une carte Ethernet présente : le serveur
# sera la passerelle du réseau PXE (Wi-Fi = amont, Ethernet = réseau PXE
# 192.168.42.0/24). Sinon rien n'est écrit : mode proxy, comme avant.
#
# Le choix est écrit dans pxe.env.d/, hors conffile : installer le paquet
# ensuite ne pose aucune question à dpkg.
exec >> /target/var/log/bits-installation.log 2>&1
set -x

# Interface configurée par netcfg : /etc/network/interfaces de l'installateur
# (il n'est copié dans /target qu'après late_command).
amont="$(sed -n 's/^iface \([^ ]*\) inet .*/\1/p' /etc/network/interfaces 2>/dev/null | grep -vx lo | head -n 1)"
if [ -z "$amont" ] || [ ! -d "/sys/class/net/$amont/wireless" ]; then
  echo "Installation par ${amont:-?} (filaire) : mode proxy."
  exit 0
fi

lan=""
for chemin in /sys/class/net/*; do
  nom="${chemin##*/}"
  [ "$nom" = "$amont" ] && continue
  [ -e "$chemin/device" ] || continue
  [ "$(cat "$chemin/type" 2>/dev/null)" = 1 ] || continue
  [ -d "$chemin/wireless" ] && continue
  lan="$nom"
  break
done
if [ -z "$lan" ]; then
  echo "Installation en Wi-Fi par $amont, mais aucune carte Ethernet : mode proxy."
  exit 0
fi

mkdir -p /target/etc/bits-pxe-server/pxe.env.d
cat > /target/etc/bits-pxe-server/pxe.env.d/10-installation.env <<CONF
# Écrit par la clé d'installation : installation faite en Wi-Fi par $amont.
# Le serveur est la passerelle du réseau PXE, sur $lan (voir pxe.env).
PXE_MODE=passerelle
PXE_UPLINK_INTERFACE=$amont
PXE_LAN_INTERFACE=$lan
CONF

# Pays du Wi-Fi : canaux et puissances autorisés en France.
mkdir -p /target/etc/modprobe.d
echo "options cfg80211 ieee80211_regdom=FR" > /target/etc/modprobe.d/bits-wifi.conf
echo "Mode passerelle : amont $amont (Wi-Fi), réseau PXE sur $lan."
