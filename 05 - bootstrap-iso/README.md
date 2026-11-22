# ISO d'amorçage

Une clé USB qui transforme n'importe quel PC en serveur PXE Boot in the Shell.
Pour s'en servir, pas à pas : [GUIDE-INSTALLATION.md](../GUIDE-INSTALLATION.md).

L'ISO est le `mini.iso` officiel de Debian 13 (installation par le réseau)
avec un preseed et les firmwares des cartes réseau filaires courantes
(~79 Mo). Sans ces firmwares, une carte Realtek ou Broadcom qui en charge
un au démarrage n'est pas vue, et l'installation échoue dès la détection du
réseau : constaté sur une machine réelle. Elle n'embarque aucun paquet : tout vient du réseau
pendant l'installation, et le serveur se met ensuite à jour seul.

## Ce que fait la clé

1. Menu de démarrage, **sans choix par défaut ni délai** :
   - *Installer le serveur BITS (EFFACE le disque interne)* ;
   - *Installation Debian manuelle* (sans BITS, sans effacement automatique) ;
   - *Démarrer sur le disque local*.
2. L'entrée BITS installe Debian 13 minimal **sur le disque interne, entièrement
   effacé, sans question** : le premier disque qui n'est ni USB ni amovible.
   La clé n'est jamais choisie, même si le firmware la présente en premier.
3. En fin d'installation :
   - dépôt apt de BITS ajouté, `bits-pxe-server` et `bits-web` installés ;
   - SSH ouvert à **root, mot de passe `admin`** ;
   - mises à jour automatiques (unattended-upgrades) pour les correctifs de
     sécurité Debian **et** les paquets BITS.
4. Redémarrage. Si la clé est restée branchée et passe en premier, elle
   s'arrête sur son menu : pas de réinstallation en boucle.
5. Au démarrage du système installé :
   - le serveur PXE répond tout de suite (menu sans image) ;
   - la console affiche l'adresse de l'interface web et la commande SSH ;
   - les images se choisissent dans l'interface web, `http://<adresse>/`.

```text
Boot in the Shell - interface web : http://192.168.1.42/

SSH : ssh root@192.168.1.42   (mot de passe par défaut : admin, à changer avec passwd)

bits login:
```

**Le mot de passe `admin` et l'interface web sans authentification
conviennent à un réseau d'atelier, pas à un réseau partagé.** Changer le mot de
passe : `passwd`.

## Prérequis

- un accès Internet en DHCP sur une interface filaire pendant l'installation ;
- une adresse fixe pour le serveur est souhaitable (réservation DHCP sur la
  box), les postes PXE la retrouvant par ProxyDHCP à chaque démarrage ;
- Secure Boot : le `mini.iso` de Debian démarre avec Secure Boot activé
  (shim signé).

Sans réseau pendant l'installation, Debian s'installe quand même si le miroir
est joignable plus tard ; les paquets BITS sont alors installés au premier
démarrage qui a du réseau (`bits-installation.service`, réessai toutes les
minutes).

## Construire

```bash
./build-bootstrap-iso.sh /chemin/bits-amorcage.iso                  # canal test (alpha)
./build-bootstrap-iso.sh /chemin/bits-amorcage.iso --canal stable   # canal stable
```

Prérequis : `curl xorriso cpio gzip`. Le `mini.iso` est vérifié contre le
`SHA256SUMS` de Debian, lui-même vérifié contre le `InRelease` signé de
l'archive quand le trousseau `debian-archive-keyring` de l'hôte connaît une des
clés de signature.

Construction mesurée : 14 s (dont le téléchargement du `mini.iso`, mis en cache
dans `~/.cache/bits-iso`).

## Graver

```bash
lsblk -o NAME,SIZE,MODEL,TRAN     # identifier la clé : TRAN = usb
sudo dd if=bits-amorcage.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

`dd` écrase la cible sans confirmation : vérifier `/dev/sdX` d'abord. Toute
clé de 128 Mo ou plus convient.

## Éprouver

```bash
./build-bootstrap-iso.sh /srv/bits-test/bits-amorcage-test.iso --test
sudo tests/e2e-iso.sh /srv/bits-test/bits-amorcage-test.iso uefi bios
```

La variante `--test` part seule sur l'entrée BITS après 1 s et ajoute la
console série : **à ne pas graver**. Voir `tests/README.md`.

## Fichiers

| Fichier | Rôle |
|---|---|
| `build-bootstrap-iso.sh` | télécharge et vérifie le `mini.iso`, y ajoute `/bits` dans l'initrd, remplace les deux menus, rejoue la structure d'amorçage BIOS + UEFI d'origine |
| `preseed/preseed.cfg` | réponses de l'installateur (langue, réseau, root, partitionnement, paquets) |
| `preseed/choisir-disque.sh` | choix du disque interne à effacer, jamais la clé |
| `preseed/late.sh` | dans le système installé : dépôt BITS, paquets, SSH, mises à jour automatiques, console |
