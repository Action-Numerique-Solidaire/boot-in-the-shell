#!/bin/sh
# Lancé par debian-installer avant le partitionnement (partman/early_command).
#
# Choisit le disque à effacer : le premier disque qui n'est ni USB ni
# amovible. La clé d'installation l'est toujours : elle n'est jamais choisie,
# même si le firmware la présente en premier. Sans disque convenable, rien
# n'est fixé et l'installateur pose la question.
for d in $(list-devices disk); do
  n="${d#/dev/}"
  [ "$(cat "/sys/block/$n/removable" 2>/dev/null)" = 1 ] && continue
  udevadm info -q property -n "$d" 2>/dev/null | grep -q '^ID_BUS=usb$' && continue
  debconf-set partman-auto/disk "$d"
  debconf-set grub-installer/bootdev "$d"
  logger -t bits "disque choisi pour l'installation : $d"
  exit 0
done
logger -t bits "aucun disque interne trouvé : question laissée à l'installateur"
exit 0
