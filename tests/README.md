# Tests

Trois niveaux, la même commande pour un contributeur et pour la CI :

```bash
# construire l'image à tester
cd "04 - live-iso" && sudo ./build-iso.sh /srv/bits-test/boot-in-the-shell-live.iso

# niveaux 1 et 2 : aucun privilège requis
tests/run-all.sh /srv/bits-test/boot-in-the-shell-live.iso

# les trois niveaux
sudo tests/run-all.sh /srv/bits-test/boot-in-the-shell-live.iso
```

| Niveau | Ce que ça prouve | Prérequis | Durée mesurée |
|---|---|---|---|
| 1. `boot-test.sh … bios` | l'ISO démarre réellement sur un firmware legacy | `qemu-system-x86` | **21 s** avec KVM |
| 2. `boot-test.sh … uefi` | ... et sur un firmware récent | `qemu-system-x86`, `ovmf` | **46 s** avec KVM |
| 3. `e2e-pxe.sh` | le serveur s'installe **seul** et des clients BIOS **et** UEFI démarrent dessus | root, libvirt, réseau sortant | dizaines de minutes |

## Dépôt apt

```bash
./packaging/build-deb.sh 0.0.0+essai out/debs
./packaging/build-apt-repo.sh out/apt test out/debs/*.deb
tests/depot-apt.sh out/apt

# le dépôt publié, tel que GitHub le sert
tests/depot-apt.sh --distant \
  https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases/download/apt-test/
```

Le vrai apt d'un Debian 13 vierge, dans un conteneur `debian:trixie` : il lit le
dépôt, trouve un candidat d'origine BITS pour chaque paquet, puis résout ses
dépendances contre les miroirs Debian (simulation, rien n'est installé). Si le
dépôt publie `bits-archive-keyring.gpg`, la source est déclarée en `signed-by`
et apt vérifie réellement la signature ; un `Release` altéré fait échouer le
test. Sans accès aux miroirs, le contrôle des dépendances est **IGNORÉ** et le
script sort en 77. Demande docker. Mesuré : 12 s.

## Clé USB (ISO live, obsolète)

Deux modes s'ajoutent pour la clé USB :

```bash
# la clé démarre-t-elle vraiment, en BIOS puis en UEFI ?
tests/boot-test.sh /chemin/cle.img bios 900 disque
tests/boot-test.sh /chemin/cle.img uefi 900 disque

# la chaîne complète en partant de la clé, sur un réseau SANS accès sortant
sudo BITS_E2E_CLE=1 tests/e2e-pxe.sh /chemin/cle.img
```

`BITS_E2E_CLE=1` présente le support comme une clé USB, n'ouvre **aucun accès
sortant** sur le réseau du labo et ne crée aucun disque de données : c'est la
partition `PXE_DATA` de la clé et son catalogue qui servent. Sans l'isolement du
réseau, le test ne prouverait pas le fonctionnement hors ligne — le pipeline
irait chercher sur internet ce qui manque, sans qu'on le voie.

Mesures du 2026-11-20, avec KVM : clé amorcée en 21 s en BIOS et 30 s en UEFI ;
serveur installé depuis la clé en 40 s ; client BIOS au menu en 15 s, client
UEFI en 20 s.

Sans KVM, les deux premiers niveaux tournent en émulation. Mesuré sur un runner
GitHub, menés **en parallèle** : 145 s pour les deux.

Un niveau qui ne peut pas tourner est annoncé **IGNORÉ**, jamais réussi. Un test
sauté qui compte comme vert est exactement le défaut qui a laissé publier une
release sans ISO.

## Pourquoi ces tests existent

Les deux premiers défauts trouvés par ces tests, dès leur première exécution :

1. **L'ISO ne démarrait pas en UEFI.** Le `grub.cfg` embarqué dans
   `BOOTX64.EFI` écrasait `$prefix` pour le faire pointer sur l'ISO. GRUB
   cherchait alors ses modules sur l'ISO, qui n'en contient aucun, et
   `configfile` n'étant pas déjà chargé, l'amorçage s'arrêtait sur l'invite
   `grub>`. Le contrôle El Torito ne pouvait pas le voir : l'entrée UEFI était
   bien déclarée, elle ne démarrait pas.
2. **Les services PXE étaient activés dans l'image.** `dnsmasq`, `nginx`,
   `nfs-server`, `smbd`, `nmbd` et `samba-ad-dc` démarraient à chaque amorçage
   live, sans configuration, et échouaient.

Aucun des deux n'était détectable sans démarrer réellement l'image.

Le contrôle El Torito de la CI prouve que l'image **déclare** ses deux modes
d'amorçage. Il ne prouve pas qu'elle démarre : une ISO peut contenir tous les
bons fichiers et paniquer. Et rien ne prouvait que le déploiement allait au
bout — le pipeline n'avait jamais été validé au-delà de la préparation du
disque.

### Niveaux 1 et 2 — l'amorçage

QEMU démarre l'ISO, la console série est lue, et le test attend le marqueur
`BITS-LIVE-READY` émis par `bits-live-ready.service`. Des motifs d'échec
(`Kernel panic`, `No init found`, `Unable to find a medium`…) sont surveillés en
parallèle : sans eux, un noyau qui panique ne se distingue pas d'un démarrage
lent et le test attendrait son délai entier.

Ni root ni libvirt : c'est volontaire, pour que ces deux niveaux tournent chez
tout le monde et sur un runner GitHub.

### Niveau 3 — la chaîne complète

`e2e-pxe.sh` monte un labo jetable en libvirt :

- un **réseau à lui** (`bits-e2e-net`, `192.168.90.0/24` par défaut) sur son
  propre pont. Le labo ne peut donc pas répondre en ProxyDHCP sur le réseau
  physique, et peut tourner à côté d'un labo existant sans créer deux
  répondeurs concurrents ;
- le **DHCP de ce réseau libvirt tient le rôle du routeur du site** : il
  distribue les adresses. Le serveur sous test ne fait que du ProxyDHCP. C'est
  exactement la topologie de production, et c'est ce qui donne sa valeur au
  test ;
- le réseau est en **NAT** : le pipeline installe des paquets et clone iPXE.
  Sans accès sortant il échoue à l'étape 10.

Déroulé : l'ISO s'installe sans interaction sur un disque de données virtio,
puis l'hôte vérifie HTTP et TFTP depuis le pont, puis **deux clients réels**
démarrent par le réseau — un BIOS, un UEFI — et doivent afficher le menu iPXE.

Le serveur est démarré en **noyau direct** (`<kernel>`/`<cmdline>` libvirt) :
c'est le seul moyen de passer `bits.auto` sans modifier l'image. Les chargeurs
isolinux et GRUB sont donc couverts ailleurs — par le contrôle El Torito et par
les niveaux 1 et 2.

Le marqueur attendu côté client est `Serveur PXE`, le titre du menu iPXE, qui
est présent même avec un catalogue de médias vide.

### Ce que chaque client couvre réellement

Les deux clients ne suivent pas le même chemin, et c'est utile de le savoir pour
lire un échec :

- le **client UEFI** part du firmware OVMF, qui n'est pas iPXE. dnsmasq ne le
  marque donc pas `ipxe` et lui sert `snponly.efi` en **TFTP** ; iPXE démarre
  ensuite et enchaîne sur le menu en HTTP. Ce client couvre toute la chaîne ;
- le **client BIOS** utilise la ROM e1000 de QEMU, **qui est déjà iPXE**.
  dnsmasq le marque `ipxe` et lui donne directement l'URL HTTP du menu : le
  téléchargement TFTP du chargeur n'est pas exercé par ce client.

C'est pourquoi le test récupère aussi `undionly.kpxe` et `snponly.efi` **en TFTP
depuis l'hôte** avant de lancer les clients : sans ce contrôle, une panne du
serveur TFTP pour le chargeur BIOS passerait inaperçue en labo et n'apparaîtrait
que sur du matériel réel.

```bash
BITS_E2E_KEEP=1 sudo tests/e2e-pxe.sh image.iso   # conserver le labo pour inspection
sudo tests/e2e-pxe.sh --nettoyer                  # le démonter ensuite
BITS_E2E_SUBNET=192.168.91 sudo tests/e2e-pxe.sh image.iso   # si 192.168.90/24 est pris
```

## Ce que coûte la CI

Première exécution du workflow, cache du chroot vide, total 10 min 51 :

| Étape | Durée |
|---|---|
| Dépendances de l'hôte (`qemu-system-x86`, `ovmf` et leurs dépendances) | 205 s |
| Construire l'ISO | 278 s |
| Amorçage BIOS et UEFI, en parallèle | 145 s |
| Préparer puis envoyer le cache du chroot | 14 s |
| Reste (checkout, espace disque, El Torito, récapitulatif) | 1 s |

`apt-get update` ne pèse que 5 s dans les 205 : le reste est le téléchargement
et le dépaquetage de QEMU et d'OVMF. `squashfs-tools` est déjà présent sur le
runner.

Pour référence, la construction de l'ISO mesurée en local : **13 min 27 à
froid**, dont environ 11 min 45 d'apt dans le chroot pour 1017 Mo téléchargés,
et **102 s à chaud** quand le chroot est réutilisé — 41 s de squashfs, 31 s de
`xorriso` et d'empreinte, 24 s de régénération de l'initramfs. C'est ce que le
cache du chroot supprime en CI.

## Le mode non interactif, hors tests

Le niveau 3 n'a été possible qu'en rendant l'assistant pilotable, ce qui sert
aussi à déployer en série. Paramètres lus sur la ligne de commande du noyau :

| Paramètre | Rôle |
|---|---|
| `bits.auto` | aucune question, journal et marqueurs sur la console |
| `bits.data-disk=<chemin>` | **obligatoire** avec `bits.auto` |
| `bits.hostname=<nom>` | nom du serveur |
| `bits.iface=<ifname>` | interface qui servira le PXE |
| `bits.gateway=<ip>` / `bits.dns=<ip>` | valeurs déclarées dans `pxe.env` |
| `bits.media=none` \| `<chemin>` | catalogue de médias ; `none` n'en active aucun |

`bits.auto` **exige** `bits.data-disk` : le mode automatique ne devine jamais
quel disque effacer. `--prepare-data-disk` efface entièrement sa cible, et un
démarrage automatique sur une machine garnie ne doit pas pouvoir détruire des
données par défaut.

Le mode auto ne touche pas au réseau : l'interface doit déjà porter son adresse
(DHCP ou configuration statique préalable). Il écrit `BITS-PXE-READY <ip>` en
cas de succès, `BITS-PXE-FAILED <raison>` sinon.
