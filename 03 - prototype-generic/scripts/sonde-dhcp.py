#!/usr/bin/python3 -I
"""Cherche un serveur DHCP déjà présent sur une interface.

    sonde-dhcp.py <interface> [--ignorer <ip>] [--delai <secondes>]

Envoie un DHCPDISCOVER en diffusion et écoute les DHCPOFFER pendant le délai
(6 s par défaut : dnsmasq, par exemple, vérifie par ping pendant environ
3 s que l'adresse est libre avant de l'offrir). Sort avec :
    0  aucun autre serveur n'a répondu ;
    3  un autre serveur a répondu : son adresse est affichée ;
    2  sonde impossible (droits, interface absente).

C'est la garde du mode passerelle : le serveur BITS sert alors un vrai DHCP,
et un câble branché par erreur sur la box ou sur le routeur Wi-Fi au lieu du
switch PXE mettrait deux serveurs en concurrence sur le même réseau.

Sockets AF_PACKET, en émission comme en réception : le port UDP 68 peut déjà
être pris par le client DHCP du système (dhclient sur le Wi-Fi), et la
réponse d'un serveur visé arrive avant que l'interface n'ait d'adresse.
--ignorer : l'adresse de ce serveur, dont le propre dnsmasq peut répondre.
"""

import os
import random
import select
import socket
import struct
import sys
import time

ETH_P_IP = 0x0800


def somme_controle(donnees):
    if len(donnees) % 2:
        donnees += b"\0"
    s = sum(struct.unpack(f"!{len(donnees) // 2}H", donnees))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def trame_discover(mac, xid):
    dhcp = struct.pack("!BBBBIHH4s4s4s4s16s64s128s",
                       1, 1, 6, 0, xid, 0, 0x8000,   # diffusion demandée
                       b"\0" * 4, b"\0" * 4, b"\0" * 4, b"\0" * 4,
                       mac + b"\0" * 10, b"\0" * 64, b"\0" * 128)
    dhcp += b"\x63\x82\x53\x63"                       # cookie magique
    dhcp += b"\x35\x01\x01"                           # DHCPDISCOVER
    dhcp += b"\x37\x03\x01\x03\x06"                   # masque, routeur, DNS
    dhcp += b"\xff"
    dhcp += b"\0" * max(0, 300 - len(dhcp))
    udp = struct.pack("!HHHH", 68, 67, 8 + len(dhcp), 0) + dhcp
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0,
                     b"\0" * 4, b"\xff" * 4)
    ip = ip[:10] + struct.pack("!H", somme_controle(ip)) + ip[12:]
    return b"\xff" * 6 + mac + struct.pack("!H", ETH_P_IP) + ip + udp


def lire_offre(trame, xid):
    """Adresse du serveur si la trame est un DHCPOFFER pour ce xid."""
    if len(trame) < 14 + 20 + 8 + 240 or struct.unpack("!H", trame[12:14])[0] != ETH_P_IP:
        return None
    ip = trame[14:]
    lg_ip = (ip[0] & 0x0F) * 4
    if ip[9] != 17:
        return None
    udp = ip[lg_ip:]
    if struct.unpack("!H", udp[2:4])[0] != 68:
        return None
    dhcp = udp[8:]
    if dhcp[0] != 2 or struct.unpack("!I", dhcp[4:8])[0] != xid or dhcp[236:240] != b"\x63\x82\x53\x63":
        return None
    serveur, type_msg, i = None, None, 240
    while i < len(dhcp) and dhcp[i] != 0xFF:
        if dhcp[i] == 0:
            i += 1
            continue
        code, lg = dhcp[i], dhcp[i + 1]
        val = dhcp[i + 2:i + 2 + lg]
        if code == 53 and lg == 1:
            type_msg = val[0]
        elif code == 54 and lg == 4:
            serveur = socket.inet_ntoa(val)
        i += 2 + lg
    if type_msg != 2:
        return None
    return serveur or socket.inet_ntoa(ip[12:16])


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    interface, ignorer, delai = args[0], set(), 6.0
    i = 1
    while i < len(args):
        if args[i] == "--ignorer" and i + 1 < len(args):
            ignorer.add(args[i + 1]); i += 2
        elif args[i] == "--delai" and i + 1 < len(args):
            delai = float(args[i + 1]); i += 2
        else:
            print(f"argument inconnu : {args[i]}", file=sys.stderr)
            return 2
    try:
        with open(f"/sys/class/net/{interface}/address") as f:
            mac = bytes.fromhex(f.read().strip().replace(":", ""))
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
        # Python convertit lui-même en ordre réseau ; avec le protocole 0, rien
        # ne serait reçu.
        s.bind((interface, ETH_P_IP))
    except OSError as e:
        print(f"sonde impossible sur {interface} : {e}", file=sys.stderr)
        return 2
    xid = random.getrandbits(32)
    trouves = set()
    fin = time.monotonic() + delai
    try:
        # Deux envois : un commutateur dont le port vient de monter perd
        # parfois la première trame.
        s.send(trame_discover(mac, xid))
        prochain_envoi = time.monotonic() + 1.0
        while (reste := fin - time.monotonic()) > 0:
            if prochain_envoi and time.monotonic() >= prochain_envoi:
                s.send(trame_discover(mac, xid))
                prochain_envoi = None
            if select.select([s], [], [], min(reste, 0.2))[0]:
                serveur = lire_offre(s.recv(4096), xid)
                if serveur and serveur not in ignorer:
                    trouves.add(serveur)
    except OSError as e:
        print(f"sonde impossible sur {interface} : {e}", file=sys.stderr)
        return 2
    finally:
        s.close()
    if trouves:
        print(" ".join(sorted(trouves)))
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
