# Tests

Chaque élément s'éprouve seul, avec la même commande chez un contributeur et
en CI :

```bash
./packaging/build-deb.sh 0.0.0+essai out/debs

# 1. les paquets, installés par le vrai apt d'un Debian 13 vierge (conteneur)
tests/paquet-deb.sh out/debs/bits-pxe-server_*.deb out/debs/bits-web_*.deb

# 2. le dépôt apt (voir plus bas)
./packaging/build-apt-repo.sh out/apt test out/debs/*.deb
tests/depot-apt.sh out/apt

# 3. de bout en bout : vrai Debian 13, publication par l'interface web,
#    clients PXE BIOS et UEFI qui démarrent Killbit
sudo tests/e2e-paquet.sh out/debs/bits-pxe-server_*.deb out/debs/bits-web_*.deb [killbit-live.iso]

# 4. idem en mode passerelle : le serveur est le routeur du réseau PXE
sudo tests/e2e-paquet.sh --passerelle out/debs/bits-pxe-server_*.deb out/debs/bits-web_*.deb
```

| Test | Ce que ça prouve | Prérequis | Durée mesurée |
|---|---|---|---|
| `lien-microsoft.sh` | lien Windows : empreinte lue dans la page de Microsoft, les deux appels à son API dans l'ordre du navigateur (session, Referer, langue), refus de Microsoft rendu en code 3 avec son message, lien hors de microsoft.com refusé — contre un faux site servi en local, **sans aucun appel à microsoft.com** : le format réel des réponses ne s'éprouve que par un vrai téléchargement | python3 | **1 s** |
| `paquet-deb.sh` | installation par apt ; rien n'est activé ; `bitsctl` ; lien Windows collé : contrôlé par `bitsctl`, utilisé une fois, ISO vérifiée par l'empreinte de la page ; réseau déduit ; chargeurs iPXE du paquet `ipxe` ; site nginx, service web sous son utilisateur, ce que sudo lui accorde et lui refuse, garde CSRF ; détection d'une nouvelle version ; mode passerelle sur une paire veth (adresse, NAT, garde DHCP face à un vrai dnsmasq, retour au mode proxy) ; purge | docker | **55 s** |
| `depot-apt.sh` | le dépôt est lu par apt, chaque paquet a un candidat BITS, ses dépendances se résolvent ; signature vérifiée si le dépôt est signé | docker | **12 s** |
| `e2e-paquet.sh` | Debian 13 réel (image cloud) ; Killbit activé et publié par l'interface web ; clients BIOS et UEFI : menu, choix de Killbit, noyau et initrd en HTTP, racine en NFS ; après redémarrage du serveur, publication rejouée et adresse affichée sur la console | root, libvirt, KVM, `sshpass`, accès sortant | **2 min 42** avec KVM |
| `e2e-paquet.sh --passerelle` | le même, le serveur ayant une seconde carte sur un pont isolé sans DHCP (le réseau NAT tient lieu du Wi-Fi) : clients BIOS et UEFI servis par le DHCP du serveur ; TFTP limité au réseau PXE ; un poste Debian du réseau PXE obtient 192.168.42.x, résout un nom et atteint internet en HTTPS ; ce poste reste injoignable depuis l'amont, même routé par le serveur ; un autre serveur DHCP sur le réseau PXE fait refuser la publication et arrêter le DHCP de BITS ; après redémarrage, `bits-lan.service` repose l'adresse et la console l'affiche | idem | **5 min 24** avec KVM |

Mesures du 2026-11-22 sur arkantos, KVM, image Killbit locale : serveur prêt
en 71 à 106 s (dont 48 s d'installation des paquets), publication par
l'interface en 7 s, client BIOS au menu en 12 s puis racine NFS montée 7 s
après le choix, client UEFI au menu en 30 s puis 7 s ; après redémarrage du
serveur, publication rejouée en 7 s. Total : 2 min 42.

`paquet-deb.sh` et `depot-apt.sh` tournent en CI (`paquet.yml`, `depot-apt.yml`),
`lien-microsoft.sh` dans `verif-scripts.yml`.
`e2e-paquet.sh` demande KVM : il se lance en local.

## ISO d'amorçage

```bash
# démarrage jusqu'à l'installateur, BIOS puis UEFI, ISO présentée en clé USB
"05 - bootstrap-iso/build-bootstrap-iso.sh" /srv/bits-test/serie.iso --test --console-serie
BITS_BOOT_MARKER='1\*installer' tests/boot-test.sh /srv/bits-test/serie.iso bios 600 disque

# installation complète, UEFI puis BIOS
"05 - bootstrap-iso/build-bootstrap-iso.sh" /srv/bits-test/test.iso --test
sudo tests/e2e-iso.sh /srv/bits-test/test.iso uefi bios
```

`e2e-iso.sh` fait ce que ferait une personne : une VM au disque interne vierge
démarre sur l'ISO branchée **en clé USB**, Debian s'installe seul depuis le
réseau, la VM s'arrête au redémarrage de fin d'installation, la clé est
retirée, la VM redémarre sur son disque. Puis, en SSH root / admin : système
sur le disque interne et pas sur la clé, paquets venus du dépôt BITS publié,
publication du premier démarrage, interface web, menu PXE sans choix par
défaut, adresse et commande SSH sur la console, mises à jour automatiques
autorisées pour l'origine BITS.

L'installation tire les paquets du dépôt **publié** (`apt-test`), pas de ceux
construits en local : elle éprouve ce qu'une vraie clé installerait.

Mesures du 2026-11-22, KVM : installation 5 min 31 (UEFI) et 5 min 30 (BIOS),
puis 21 à 25 s jusqu'à SSH sur le disque interne. Sur GitHub, sans KVM, le
démarrage jusqu'à l'installateur prend 34 à 51 s.

Ce que ce test a trouvé :

1. `preseed/file=` ne vaut que pour un CD : sur le `mini.iso` (amorçage réseau)
   le preseed n'était jamais chargé. Il est maintenant à la racine de l'initrd.
2. Sur une console série, l'installateur ignore la langue préréglée et pose la
   question : la variante de test reste sur l'écran VGA.
3. `ca-certificates` manque dans un Debian minimal : apt refusait le dépôt
   HTTPS de GitHub, les paquets BITS ne s'installaient pas.
4. Au premier démarrage, la publication partait avant le bail DHCP (interface
   `allow-hotplug`, que `network-online` n'attend pas avec ifupdown) : serveur
   PXE arrêté. `bits-sync` attend maintenant l'adresse et réessaie.
5. Pour le test lui-même : SeaBIOS ne tente que le premier disque dur, donc
   « disque interne d'abord, clé ensuite » ne démarrait jamais la clé en BIOS.

### Ce que `e2e-paquet.sh` a trouvé à sa première exécution

1. L'étape 60 appliquait les exports NFS **avant** de créer les points de
   montage : `exportfs` refusait, la publication échouait.
2. Elle écrivait `/etc/samba/bits-shares.conf` même sans samba installé, donc
   sans `/etc/samba`.
3. La **republication** — qui a lieu à chaque démarrage — échouait :
   `install -d -m` tentait un `chmod` sur l'image déjà montée en lecture seule.

Et deux pièges du labo lui-même, à connaître pour écrire un test du même genre :
libvirt ne crée pas de carte vidéo si le domaine n'en déclare pas, et le GRUB
de l'image cloud Debian boucle alors sans jamais lancer le noyau ;
`serial-getty` révoque les descripteurs ouverts sur `/dev/ttyS0`, donc un
script qui y écrit devient muet — les marqueurs passent par `/dev/kmsg`.

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

## ISO live et clé USB (obsolètes)

Ces tests concernent l'ancienne ISO live, remplacée par les paquets. Ils
restent utilisables :

```bash
tests/run-all.sh /chemin/boot-in-the-shell-live.iso
```

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
