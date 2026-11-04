# ISO live « Boot in the Shell »

Une seule image, **deux usages** : démarrer un poste en live pour diagnostiquer,
ou déployer durablement le serveur PXE sur un disque. C'est le même ISO dans les
deux cas — le choix se fait dans l'assistant au démarrage.

## Récupérer l'image

Le plus simple : prendre la dernière [release du dépôt](https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases),
qui contient l'ISO, le paquet `.deb` et un `SHA256SUMS`.

```bash
sha256sum -c SHA256SUMS
```

## Écrire sur une clé USB

```bash
sudo dd if=boot-in-the-shell-live.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

> Vérifier `/dev/sdX` avec `lsblk` **avant** de lancer la commande : `dd` écrase
> le disque désigné sans demander confirmation.

L'image est hybride : la même clé démarre en BIOS *et* en UEFI.

> **Secure Boot n'est pas pris en charge.** Il faut le désactiver dans le
> firmware de la machine. C'est de toute façon déjà nécessaire pour les clients
> PXE, dont le chargeur `snponly.efi` n'est pas signé.

## Les deux usages

### 1. Live — ne touche à rien

Le système démarre entièrement en mémoire, obtient une adresse en DHCP et ouvre
l'assistant. Tant qu'on ne valide pas la préparation d'un disque, **aucune
écriture n'a lieu sur les disques de la machine**. C'est le mode à utiliser pour
tester du matériel ou vérifier qu'un réseau convient.

### 2. Installation sur un disque de données

L'assistant détecte les disques et propose deux modes, qui correspondent aux
deux modes de `install.sh` :

| Mode | Effet |
|---|---|
| `--prepare-data-disk` | **Efface entièrement** le disque choisi, le partitionne et l'étiquette `PXE_DATA`. |
| `--reuse-data-disk` | Réutilise un disque déjà préparé lors d'un démarrage précédent. |

Le disque retenu doit avoir un identifiant stable `/dev/disk/by-id/…` : cet
identifiant finit dans `pxe.env` et dans `fstab`, donc un nom instable comme
`/dev/sdb` casserait la configuration au redémarrage suivant. L'assistant refuse
de continuer s'il n'en trouve pas — c'est volontaire.

La configuration est ensuite conservée sur la partition `PXE_DATA`, dans
`boot-config/`, et relue à chaque démarrage : une fois le disque préparé, la
machine redémarre en serveur PXE sans aucune question.

## Installer sans passer par l'ISO

Sur un serveur Debian ou Ubuntu déjà en place, le paquet de la release fait le
même travail :

```bash
sudo apt install ./bits-pxe-server_<version>_all.deb
sudoedit /etc/bits-pxe-server/pxe.env
sudo bits-pxe-install --prepare-data-disk
```

## Construire l'ISO soi-même

```bash
sudo ./build-iso.sh /chemin/de/sortie.iso
```

L'hôte n'a besoin que de `debootstrap`, `squashfs-tools` et `xorriso` : le
chargeur UEFI est construit dans le chroot. `PXE_ISO_WORK` permet de déplacer
le répertoire de travail, et le chroot qui s'y trouve est **réutilisé** d'une
construction à l'autre — c'est ce qui fait la différence entre une première
construction et les suivantes.

| Variable | Rôle |
|---|---|
| `PXE_ISO_WORK` | répertoire de travail (défaut `/srv/pxe-iso-build`) |
| `PXE_ISO_SQUASH_COMP` | compresseur du squashfs (défaut `zstd`) |
| `PXE_ISO_SQUASH_LEVEL` | niveau zstd (défaut `8`) |

Le squashfs est en **zstd**, pas en xz. Mesuré sur cette image, 1,6 Go de
paquets sur 8 cœurs :

| Compresseur | Construction | Taille | Décompression |
|---|---|---|---|
| xz | 131,9 s | 1060 Mo | 44 Mo/s |
| **zstd niveau 8** | **29,2 s** | 1147 Mo | **170 Mo/s** |
| zstd niveau 15 | 90,1 s | 1115 Mo | — |
| zstd niveau 19 | 217,1 s | 1112 Mo | — |

87 Mo de plus, mais la construction va 4,5 fois plus vite et la décompression
3,9 fois — et la décompression, c'est ce que paie **chaque démarrage** de
l'image, pas seulement la construction. Ubuntu a fait le même choix pour ses
images live.

Noter le piège : monter le niveau zstd à 19 donne une image **plus grosse** que
xz pour 217 s de construction. Ce n'est pas un réglage à pousser « pour gagner
de la place ».

> Ne jamais modifier `build-iso.sh` pendant qu'il s'exécute : bash relit le
> fichier au fil de l'exécution, et une insertion décale les octets restants.

## Limites connues

- **Secure Boot** non pris en charge, côté serveur comme côté clients PXE.
- Le serveur live reste en **DHCP**, alors que les menus iPXE et les exports NFS
  sont figés sur l'adresse obtenue au premier démarrage : un changement de bail
  casse la configuration. Une réservation DHCP sur l'adresse MAC du serveur
  évite le problème.
- `dnsmasq` fonctionne en **ProxyDHCP uniquement**, pour coexister avec le DHCP
  du réseau. Le serveur ne distribue jamais d'adresses — c'est une contrainte
  explicite du projet, à ne pas lever.
- Le dépôt d'images Clonezilla (**NFS en écriture**) et le partage Windows
  (**Samba en invité**) sont ouverts à tout le sous-réseau **sans
  authentification**. Acceptable sur un VLAN d'atelier isolé seulement : les
  clones de disque peuvent contenir les données personnelles des anciens
  propriétaires des postes.

## Déployer sans interaction

L'assistant peut se passer d'opérateur, ce qui sert au déploiement en série et
rend la chaîne testable automatiquement. Les paramètres se donnent sur la ligne
de commande du noyau :

```
boot=live components bits.auto bits.data-disk=/dev/disk/by-id/ata-… bits.media=none
```

| Paramètre | Rôle |
|---|---|
| `bits.auto` | aucune question ; journal et marqueurs sur la console |
| `bits.data-disk=<chemin>` | **obligatoire** avec `bits.auto` |
| `bits.hostname=<nom>` | nom du serveur |
| `bits.iface=<ifname>` | interface qui servira le PXE |
| `bits.gateway=<ip>` / `bits.dns=<ip>` | valeurs déclarées dans `pxe.env` |
| `bits.media=none` \| `<chemin>` | catalogue de médias ; `none` n'en active aucun |

`bits.auto` **exige** `bits.data-disk` : le mode automatique ne devine jamais
quel disque effacer. `--prepare-data-disk` efface entièrement sa cible, et un
démarrage automatique sur une machine garnie ne doit pas pouvoir détruire des
données par défaut.

Le mode auto ne reconfigure pas le réseau : l'interface doit déjà porter son
adresse, par DHCP ou par une configuration statique préalable. Il écrit
`BITS-PXE-READY <ip>` en cas de succès et `BITS-PXE-FAILED <raison>` sinon.

## Vérifier une image

```bash
tests/run-all.sh /chemin/image.iso        # l'image démarre, en BIOS et en UEFI
sudo tests/run-all.sh /chemin/image.iso   # ... et la chaîne PXE complète
```

Voir [tests/README.md](../tests/README.md). L'ISO embarque
`bits-live-ready.service`, qui annonce `BITS-LIVE-READY` sur la console une fois
le système live réellement utilisable : c'est ce marqueur que les tests
attendent, et la console série est activée dans les deux chargeurs pour qu'une
machine sans écran puisse être observée.
