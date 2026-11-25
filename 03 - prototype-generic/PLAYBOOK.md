# Playbook — serveur PXE Boot in the Shell

Le serveur PXE s'installe par un paquet apt, `bits-pxe-server`. Il ne dépend
d'aucun autre serveur et ne copie aucun ancien contenu PXE.

Éprouvé de bout en bout sur **Debian 13** (`tests/e2e-paquet.sh`). Sur Debian
12, Ubuntu 22.04 et 24.04, toutes les dépendances et les deux chargeurs iPXE
sont présents dans la distribution, mais le démarrage de clients n'y a pas été
testé ; Debian 12 fournit un iPXE de 2019.

## 1. Prérequis

- un accès Internet pendant l'installation et pour télécharger les images ;
- mode proxy (par défaut) : un **DHCP déjà présent** sur le réseau (la box ou
  le routeur du site). Le serveur fonctionne en ProxyDHCP : il ne distribue
  jamais d'adresses ;
- mode passerelle (section 6) : deux cartes réseau, l'une avec accès à
  internet (Wi-Fi par exemple), l'autre reliée au switch du réseau PXE, où le
  serveur distribue lui-même les adresses ;
- une adresse IPv4 sur l'interface réseau, statique ou obtenue par DHCP ;
- de la place pour les images servies dans `/srv/bits-data` : 0,3 Go pour
  Killbit, 4 à 7 Go pour une image Ubuntu ou Zorin.

Ne pas activer deux serveurs ProxyDHCP sur le même réseau.

## 2. Installer

```bash
echo "deb [trusted=yes] https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases/download/apt/ ./" \
  | sudo tee /etc/apt/sources.list.d/bits.list
sudo apt update && sudo apt install bits-pxe-server
```

Canal d'essai (versions produites par les tags `test-*`) : remplacer
`download/apt/` par `download/apt-test/`.

L'installation **n'active rien** : aucun service ne répond aux démarrages PXE
tant que la première publication n'a pas eu lieu. Elle n'installe pas non plus
de serveur DNS : BITS utilise `dnsmasq-base` et lance sa propre instance,
`bits-dnsmasq.service`, sans DNS.

Rien n'est à configurer pour commencer. Le réseau est lu sur l'interface de la
route par défaut ; pour l'imposer, renseigner `PXE_INTERFACE` (et au besoin
`PXE_ADDRESS_CIDR`) dans `/etc/bits-pxe-server/pxe.env`.

### Interface web (facultative)

```bash
sudo apt install bits-web
```

Elle s'ouvre depuis n'importe quel poste du réseau, à l'adresse
`http://<adresse du serveur>/`, affichée aussi sur la console du serveur. Pour
chaque image du catalogue :

- **Télécharger** : récupère et vérifie l'image sur le serveur, **sans changer
  le menu PXE**. Pour préparer à l'avance une image de plusieurs gigaoctets ;
- l'interrupteur l'active ou la désactive, puis **Appliquer au PXE** publie
  (et télécharge ce qui manque) ;
- **Récupérer le fichier** : une image déjà téléchargée se récupère depuis le
  navigateur, sous `http://<adresse>/telechargements/<fichier>` — pour graver
  une clé sur un autre poste, par exemple.

Le journal de l'opération en cours s'affiche en direct. L'interface fait la
même chose que les commandes `bitsctl` ci-dessous.

- Elle prend la place du site `default` de nginx, s'il n'a pas été modifié ;
  il est rétabli à la désinstallation. Un site `default` modifié est laissé en
  place, et l'interface n'est alors pas activée.
- **Pas d'authentification** : tout poste du réseau peut activer une image et
  lancer une publication. Elle ne doit être installée que sur un réseau
  d'atelier.
- Le service tourne sans privilège (utilisateur `bits-web`) ; sudo ne lui
  accorde que `bitsctl media enable|disable` et le lancement de
  `bits-sync.service`.

## 3. Choisir les images

```bash
bitsctl media list
sudo bitsctl media enable killbit
sudo bitsctl media enable ubuntu
sudo bitsctl media download zorin    # télécharger sans publier
```

Le catalogue est `/etc/bits-pxe-server/media.conf`. Chaque ligne :

```text
activé|id|type|fichier|url|sha256|libellé du menu
```

Types : `casper-iso` (Ubuntu, Lubuntu, Zorin), `debian-live-iso` (Killbit),
`clonezilla-zip`, `windows-iso`. L'empreinte est soit les 64 caractères
hexadécimaux du SHA-256, soit `sha256sums:<url>` : elle est alors lue au
téléchargement dans le fichier d'empreintes publié avec l'image. C'est ainsi
que Killbit, publié sous un nom fixe, est suivi à chaque nouvelle version.

## 4. Publier

```bash
sudo bitsctl apply
```

Dans l'ordre :

1. validation de la configuration et du catalogue ;
2. paquets propres à un type de média (samba et wimtools pour Windows), si un
   tel média est activé ;
3. contrôle du réseau (aucune écriture, sauf `PXE_MANAGE_NETWORK=yes`) ;
4. téléchargement des images activées, vérifié avant publication ;
5. chargeurs iPXE BIOS et UEFI, pris dans le paquet `ipxe` ;
6. publication HTTP, TFTP, NFS (et Samba pour Windows), menu iPXE ;
7. activation et contrôle des services.

Une image qui ne peut pas être obtenue (miroir injoignable, empreinte fausse)
est **écartée** : les autres sont publiées quand même, et `bitsctl apply` sort
en 3. Une image désactivée est retirée du menu, démontée et n'est plus
exportée ; son fichier téléchargé est gardé dans `/srv/bits-data/downloads`.

Après la première publication, `bits-sync.service` rejoue la publication à
chaque démarrage. Il attend d'abord qu'une interface ait une adresse IPv4
(jusqu'à 2 min : avec ifupdown, `network-online` n'attend pas une interface
`allow-hotplug`), et en cas d'échec il réessaie toutes les 30 s.

Le menu n'a **ni choix par défaut ni délai** : un poste démarré sur le réseau
par erreur attend qu'on choisisse, et ne lance jamais seul une installation
ou un effacement. Il propose toujours le démarrage sur le disque local.

## 5. Contrôler

```bash
sudo bitsctl status
sudo bitsctl log
```

Les journaux de publication sont dans `/var/log/bits/` (les 30 derniers).

Vérifier ensuite avec au moins un poste client :

1. démarrage PXE en UEFI, puis en BIOS si ce mode doit être pris en charge ;
2. affichage du menu ;
3. démarrage réel de chaque image ;
4. pour Clonezilla, montage du dépôt d'images et création d'une image de test ;
5. pour Windows, accès à l'installation et au partage Samba.

Le succès des contrôles serveur ne remplace pas ce test physique.

## 6. Options

### Disque de données dédié

Par défaut les images vont dans `/srv/bits-data`, sur le disque système. Pour
un disque dédié, renseigner dans `pxe.env` `PXE_DATA_DISK` et
`PXE_DATA_PARTITION` avec des chemins `/dev/disk/by-id/...`, puis :

```bash
sudo bits-pxe-install --prepare-data-disk
```

**Cette commande efface entièrement le disque** désigné. Elle refuse le disque
qui porte `/`.

### Mode passerelle : réseau PXE dédié

```
box ─ routeur Wi-Fi ))) Wi-Fi ((( serveur BITS ─ Ethernet ─ switch ─ postes PXE
                                   amont       192.168.42.1/24
```

Le serveur est le routeur d'un réseau PXE à lui. Sur la carte Ethernet, il
porte `192.168.42.1/24` et sert le DHCP (`.100` à `.250`), le DNS (relais vers
ceux de l'amont) et le PXE ; les postes sortent sur internet par l'amont, en
NAT. Depuis l'amont, les postes ne sont pas joignables. L'interface web et SSH
répondent sur les deux réseaux.

La clé d'installation choisit ce mode quand l'installation se fait en Wi-Fi.
À la main, dans `/etc/bits-pxe-server/pxe.env` (ou un fichier
`pxe.env.d/*.env`) :

```bash
PXE_MODE=passerelle
#PXE_LAN_INTERFACE=enp1s0     # défaut : première carte Ethernet hors amont
#PXE_LAN_CIDR=192.168.42.1/24
```

puis `sudo bitsctl apply`. `bits-lan.service` repose l'adresse, le routage et
le NAT à chaque démarrage, sans attendre le Wi-Fi.

**Garde DHCP.** Avant de servir le DHCP, le serveur vérifie qu'aucun autre
serveur DHCP ne répond sur la carte du réseau PXE. Si le câble est branché
sur la box ou sur le routeur Wi-Fi au lieu du switch, la publication refuse
(« un autre serveur DHCP répond sur … »), le DHCP de BITS reste arrêté, et
l'interface web l'affiche en rouge. Rebrancher sur le switch, puis
« Appliquer au PXE ».

Changer de réseau Wi-Fi : `wpa-ssid` et `wpa-psk` dans
`/etc/network/interfaces`, puis `systemctl restart networking` (ou
redémarrer).

Le pare-feu de la passerelle tient dans la table nftables `inet bits`. Docker,
s'il est installé, met la chaîne `FORWARD` d'iptables en `drop` : les postes
n'auraient alors plus internet.

### Réseau géré par BITS (Ubuntu)

Mode proxy seulement. Avec `PXE_MANAGE_NETWORK=yes`, `PXE_ADDRESS_CIDR`, `PXE_GATEWAY` et `PXE_DNS`,
BITS écrit une configuration Netplan statique et l'applique par `netplan try`,
avec retour automatique.

### Chargeurs iPXE compilés

`PXE_IPXE_COMPILE=yes` compile iPXE au commit `IPXE_GIT_COMMIT` avec le script
embarqué `config/boot.ipxe` (demande git, gcc et liblzma-dev).
`PXE_IPXE_PREBUILT` désigne des chargeurs déjà compilés par
`tools/construire-ipxe.sh`.

## 7. Arrêter

```bash
sudo bitsctl disable
```

Le serveur cesse de répondre aux démarrages PXE et ne republie plus au
démarrage. `sudo bitsctl apply` le remet en service.

## 8. Sans le paquet, depuis le dépôt

```bash
cp config/pxe.env.example config/pxe.env
cp config/media.conf.example config/media.conf
# activer des images dans config/media.conf
sudo ./scripts/install.sh
```

Les dépendances ne sont alors pas tirées par apt : installer au préalable
`dnsmasq-base nginx nfs-kernel-server ipxe curl python3 unzip`. Chaque script
de `scripts/` reste exécutable seul, pour le diagnostic.
