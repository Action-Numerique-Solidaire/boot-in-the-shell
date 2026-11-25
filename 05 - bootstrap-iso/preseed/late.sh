#!/bin/sh
# Lancé dans le système installé (in-target), en fin d'installation Debian.
#
# Ajoute le dépôt apt de BITS, installe bits-pxe-server et bits-web, ouvre SSH
# à root et met en place les mises à jour automatiques. Ne fait jamais
# échouer l'installation : sans réseau à ce moment-là, les paquets sont
# installés au premier démarrage par bits-installation.service.
exec >> /var/log/bits-installation.log 2>&1
set -x

export DEBIAN_FRONTEND=noninteractive

# Firmwares de la clé (réseau filaire et Wi-Fi), copiés par late_command.
# Ceux des cartes Wi-Fi USB sont chargés directement par l'installateur, qui
# ne les installe donc pas lui-même dans le système : sans eux, le Wi-Fi de
# l'amont ne reviendrait pas au redémarrage. Installés depuis la clé, sans
# réseau ; mis à jour ensuite par apt (non-free-firmware).
if ls /root/bits-firmware/*.deb >/dev/null 2>&1; then
  dpkg -i /root/bits-firmware/*.deb || true
fi
rm -rf /root/bits-firmware

# Le dépôt BITS est servi en HTTPS : sans ca-certificates (absent d'un système
# minimal), apt refuse le certificat de github.com. Installé AVANT de déclarer
# le dépôt, depuis le miroir Debian.
apt-get install -y ca-certificates || true

# BITS_DEPOT : ligne « deb » du dépôt, écrite à la construction de l'ISO.
# shellcheck source=/dev/null
. /root/bits.conf
echo "$BITS_DEPOT" > /etc/apt/sources.list.d/bits.list

# --- accès de débogage : SSH root par mot de passe ---------------------------------
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/bits.conf

# --- console : adresse et accès SSH, recalculés par agetty (\4) ---------------------
mkdir -p /etc/issue.d
printf 'SSH : ssh root@\\4   (mot de passe par défaut : admin, à changer avec passwd)\n\n' \
  > /etc/issue.d/bits-ssh.issue

# --- rattrapage : paquets installés au démarrage s'ils n'ont pas pu l'être ici ------
cat > /etc/systemd/system/bits-installation.service <<'UNIT'
[Unit]
Description=BITS : installation des paquets reportée (réseau absent pendant l'installation)
ConditionPathExists=!/usr/sbin/bitsctl
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
ExecStart=/bin/sh -c 'apt-get update; apt-get install -y ca-certificates && apt-get update && apt-get install -y bits-pxe-server bits-web unattended-upgrades && bitsctl enable && systemctl start bits-web.service bits-sync.service'
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable bits-installation.service

if apt-get update && apt-get install -y bits-pxe-server bits-web unattended-upgrades; then
  # Publication à chaque démarrage, dès le premier : le serveur PXE répond
  # tout de suite, avec un menu vide tant qu'aucune image n'est choisie.
  bitsctl enable
else
  echo "Paquets BITS non installés : nouvel essai au premier démarrage."
fi

# --- mises à jour automatiques : Debian (sécurité) et BITS ------------------------
# Écrites APRÈS l'installation d'unattended-upgrades, dont le postinst
# réécrit 20auto-upgrades.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
cat > /etc/apt/apt.conf.d/51bits-unattended-upgrades <<'APT'
// Paquets de Boot in the Shell : mis à jour automatiquement, comme les
// correctifs de sécurité de Debian (50unattended-upgrades).
Unattended-Upgrade::Origins-Pattern {
        "origin=BITS";
};
APT

rm -f /root/bits-late.sh /root/bits.conf
exit 0
