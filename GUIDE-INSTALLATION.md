# Guide d'installation — serveur PXE Boot in the Shell

Ce guide transforme un PC en **serveur PXE permanent** : un Debian 13 minimal,
accessible en SSH, qui se met à jour seul et sert en démarrage réseau les
images choisies dans une interface web (Ubuntu, Zorin OS, Killbit,
Clonezilla…).

Il faut : une clé USB d'au moins 256 Mo et le PC qui deviendra le serveur.

Deux montages sont possibles, choisis par la façon dont on installe :

**Passerelle (installation en Wi-Fi)** : le serveur a internet par le Wi-Fi
et sert un réseau PXE à lui, sur sa carte Ethernet reliée à un switch. Il y
distribue les adresses (192.168.42.0/24) et donne internet aux postes. Il faut
une carte ou une clé USB Wi-Fi sur le serveur.

```
box ─câble─ routeur Wi-Fi ))) Wi-Fi ((( serveur BITS ─câble─ switch ─ postes PXE
                                                     192.168.42.1
```

**Proxy (installation par câble)** : le serveur rejoint le réseau existant,
dont la box distribue les adresses ; il n'ajoute que le démarrage PXE.

> **Phase alpha.** Les clés produites aujourd'hui installent les paquets du
> canal d'essai (`apt-test`). Le canal stable n'existera qu'avec la première
> version `v*`.

---

## Étape 1 — Préparer la clé USB

### 1.1 Récupérer l'image

Sur la page des releases du projet, prendre la plus récente qui contient
`bits-amorcage.iso` (~170 Mo), avec son fichier `SHA256SUMS` :

<https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases>

Vérifier l'image, dans le dossier où sont les deux fichiers :

```bash
sha256sum -c --ignore-missing SHA256SUMS
```

La ligne `./bits-amorcage.iso: OK` doit apparaître.

### 1.2 Écrire la clé

**Tout le contenu de la clé est effacé.**

Depuis Linux, avec le script du dépôt (il refuse le disque système, un disque
non amovible et un disque monté) :

```bash
lsblk -o NAME,SIZE,TRAN,MODEL      # repérer la clé : TRAN = usb
sudo tools/creer-cle-usb.sh --iso bits-amorcage.iso --cible /dev/sdX --sans-donnees --confirmer EFFACER
```

Sans le dépôt, `dd` fait la même écriture, sans les garde-fous :

```bash
sudo dd if=bits-amorcage.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

Remplacer `/dev/sdX` par la clé, **jamais** par le disque de l'ordinateur.

---

## Étape 2 — Installer le serveur

**Le disque interne du PC est entièrement effacé**, sans autre question. La
clé, elle, n'est jamais touchée.

1. Passerelle : brancher la carte Ethernet du serveur sur le **switch du
   réseau PXE** (jamais sur la box ni sur le routeur Wi-Fi). Proxy : la
   brancher sur le réseau de la box. Puis brancher la clé.
2. Démarrer sur la clé : menu de démarrage du firmware (souvent F12, F11, F8
   ou Échap au démarrage), entrée USB.
   Le PC peut démarrer en UEFI ou en BIOS (« legacy »). En cas de refus avec
   Secure Boot activé, le désactiver dans le firmware : la clé contient le
   chargeur signé de Debian, mais ce cas n'a pas été éprouvé.
3. Le menu **Boot in the Shell** attend un choix — il ne lance rien tout seul :
   - **Installer le serveur BITS (EFFACE le disque interne)** ← celle-ci ;
   - *Installation Debian manuelle* : installateur Debian normal, sans BITS ;
   - *Démarrer sur le disque local*.
4. Seules les questions du réseau sont posées, en français :
   - **la carte réseau**, si le PC en a plusieurs : choisir la carte **sans
     fil** (souvent `wlp…`, « Wireless ») pour le montage passerelle, la carte
     Ethernet (`enp…`) pour le montage proxy ;
   - en Wi-Fi, **le réseau** dans la liste des réseaux détectés, le type de
     sécurité (WPA/WPA2 PSK) et **le mot de passe** du Wi-Fi.

   Le reste se déroule seul : effacement du disque, système, paquets BITS.
   Compter 5 à 6 minutes sur une bonne connexion (mesuré en machine
   virtuelle) ; plus sur une connexion lente ou en Wi-Fi.
5. À la fin, le PC redémarre. **Retirer la clé** à ce moment-là. Si elle est
   restée branchée, le menu de la clé réapparaît et attend : la retirer et
   redémarrer.

---

## Étape 3 — Premier démarrage du serveur

L'écran du serveur affiche, au-dessus de l'invite de connexion :

```text
Boot in the Shell - interface web : http://192.168.1.42/

SSH : ssh root@192.168.1.42   (mot de passe par défaut : admin, à changer avec passwd)

bits login:
```

- **Changer le mot de passe** de root dès maintenant : se connecter (`root` /
  `admin`), puis `passwd`. Tant qu'il vaut `admin`, n'importe quel poste du
  réseau peut prendre la main sur le serveur.
- Le serveur PXE répond déjà, avec un menu sans image.
- Une **adresse fixe** est souhaitable : réserver l'adresse du serveur dans la
  box (réservation DHCP).
- Passerelle : la console affiche aussi
  `Réseau PXE : 192.168.42.1 sur enp1s0 …`. L'interface web répond depuis le
  réseau du Wi-Fi (adresse ci-dessus) et depuis le switch,
  `http://192.168.42.1/`. Si elle affiche en rouge « un autre serveur DHCP
  répond sur le réseau PXE », la carte Ethernet est branchée sur la box ou sur
  le routeur Wi-Fi au lieu du switch : la rebrancher, puis « Appliquer au
  PXE ». Changer de réseau Wi-Fi plus tard : voir le
  [PLAYBOOK](03%20-%20prototype-generic/PLAYBOOK.md#mode-passerelle--réseau-pxe-dédié).

---

## Étape 4 — Choisir les images à servir

Depuis n'importe quel poste du réseau, ouvrir l'adresse affichée
(`http://<adresse du serveur>/`).

- **Télécharger** : récupère et vérifie l'image sur le serveur, sans changer le
  menu de démarrage. Utile pour préparer à l'avance Ubuntu ou Zorin (4 à 7 Go).
- **Interrupteur** puis **Appliquer au PXE** : ajoute l'image au menu de
  démarrage réseau (en la téléchargeant si besoin), ou l'en retire.
- **Récupérer le fichier** : une image téléchargée se récupère aussi depuis le
  navigateur, pour graver une clé sur un autre poste par exemple.
- **Nouvelle version disponible** : pour une image téléchargée, le serveur
  vérifie s'il en existe une plus récente (Killbit en publie une à chaque
  construction ; « Vérifier les mises à jour » relance la vérification).
  **Mettre à jour** la télécharge, la vérifie et, si l'image est servie, la
  publie aussitôt. Une version téléchargée mais pas encore servie est marquée
  « Nouvelle version à publier ».
- Le journal de l'opération en cours s'affiche en direct.

L'interface n'a **pas d'authentification** : elle convient à un réseau
d'atelier, pas à un réseau partagé.

---

## Étape 5 — Démarrer un poste sur le réseau

Sur le PC à reconditionner, branché au même réseau : menu de démarrage du
firmware, entrée réseau (« PXE », « Network », « IPv4 »). Le menu
**Boot in the Shell** liste les images publiées et attend un choix ; il
propose aussi *Démarrer sur le disque local*. Aucune image ne se lance seule.

---

## Mises à jour

Le serveur installe chaque jour, seul, les correctifs de sécurité de Debian
et les nouvelles versions de BITS. Pour le faire tout de suite :

```bash
sudo apt update && sudo apt upgrade
```

## En cas de problème

| Commande | Ce qu'elle montre |
|---|---|
| `bitsctl status` | adresse, services, images et leur état |
| `bitsctl log` | journal de la dernière publication ou du dernier téléchargement |
| `journalctl -u bits-sync` | publication au démarrage |
| `cat /var/log/bits-installation.log` | fin de l'installation (dépôt, paquets) |
| `systemctl status bits-installation` | si les paquets BITS n'ont pas pu s'installer pendant l'installation (réseau), ils sont réessayés ici toutes les minutes |

### L'installation s'arrête à la détection du réseau

La carte réseau n'est pas reconnue. Sur l'écran d'erreur, `Alt+F2` puis Entrée
ouvre un terminal :

```bash
dmesg | grep -iE "firmware|eth"
```

Une ligne `Direct firmware load for rtl_nic/… failed` signale un firmware
manquant. La clé embarque ceux des cartes filaires courantes (Realtek,
Broadcom, Intel…) : c'était le cas d'un Dell OptiPlex 3060 (Realtek RTL8168H,
`rtl_nic/rtl8168h-2.fw`) avec une clé plus ancienne, sans firmware. Si le
message persiste avec une clé à jour, signaler le modèle du PC et la ligne
affichée.

Plus de détails : [PLAYBOOK](03%20-%20prototype-generic/PLAYBOOK.md) (exploitation
du serveur), [ISO d'amorçage](05%20-%20bootstrap-iso/README.md) (construire la
clé soi-même).
