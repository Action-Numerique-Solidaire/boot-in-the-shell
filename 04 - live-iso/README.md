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
chargeur UEFI est construit dans le chroot. Comptez ~13 min à froid, ~90 s si
le chroot de `/srv/pxe-iso-build` est réutilisé. `PXE_ISO_WORK` permet de
déplacer le répertoire de travail.

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
