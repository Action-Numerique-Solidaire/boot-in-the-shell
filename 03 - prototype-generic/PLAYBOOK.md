# Playbook autonome — serveur PXE générique

Ce playbook part d'un Ubuntu Server propre. Il ne dépend d'aucun autre serveur et ne copie aucun ancien contenu PXE.

## 1. Préparer le serveur

Installer Ubuntu Server sur le disque système, créer un compte administrateur autorisé à utiliser `sudo`, activer OpenSSH et appliquer les mises à jour du système.

Le serveur doit disposer :

- d'une adresse IPv4 fixe ;
- d'un disque système distinct du disque destiné aux médias, si un disque de données est utilisé ;
- d'un accès Internet pendant l'installation ;
- d'un DHCP déjà présent sur le réseau. Le serveur PXE fonctionne en ProxyDHCP et ne distribue pas les adresses IP.

Ne pas activer deux serveurs ProxyDHCP sur le même réseau de test.

## 2. Copier le prototype

Copier le dossier `generic-proto` sur le serveur, par exemple sous `/home/user/generic-proto`, puis rendre les scripts exécutables :

```bash
chmod +x /home/user/generic-proto/scripts/*.sh
```

## 3. Créer les fichiers de configuration

```bash
cd /home/user/generic-proto
cp config/pxe.env.example config/pxe.env
cp config/media.conf.example config/media.conf
```

Modifier `config/pxe.env` : nom du serveur, interface réseau, adresse avec son préfixe (par exemple `192.168.1.15/24`), passerelle, DNS et sous-réseau (par exemple `192.168.1.0/24`).

Identifier le disque de données avec un nom stable :

```bash
ls -l /dev/disk/by-id/
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

Reporter dans `PXE_DATA_DISK` le lien `/dev/disk/by-id/...` du disque entier et dans `PXE_DATA_PARTITION` le lien correspondant à sa première partition (`...-part1`). Ne jamais utiliser le disque qui contient `/`.

Avec `PXE_MANAGE_NETWORK=yes`, le playbook écrit une configuration Netplan et utilise `netplan try` avec retour automatique. Avec `no`, configurer l'adresse fixe avant l'installation : le script vérifiera seulement sa présence.

## 4. Choisir les médias

Modifier `config/media.conf`. Chaque ligne contient :

```text
enabled|id|type|filename|url|sha256|libellé du menu
```

Conserver `yes` uniquement pour les médias à publier. Pour chaque média activé, fournir :

1. une URL HTTPS directe vers l'ISO ou le ZIP ;
2. l'empreinte SHA-256 publiée par l'éditeur ;
3. un type pris en charge : `casper-iso`, `clonezilla-zip` ou `windows-iso`.

Ubuntu, Lubuntu et Clonezilla disposent d'URL publiques dans l'exemple. Leur version et leur empreinte doivent être vérifiées au moment du déploiement. Windows, certains médias Zorin et les images personnalisées utilisent souvent un portail ou une URL temporaire : télécharger ou publier le fichier sur un serveur HTTPS accessible, puis renseigner son URL directe et son SHA-256.

Pour calculer l'empreinte d'un fichier obtenu manuellement :

```bash
sha256sum /chemin/vers/le-fichier.iso
```

Le script refusera tout média activé dont l'URL ou l'empreinte est absente.

## 5. Valider sans modifier le serveur

```bash
cd /home/user/generic-proto
./scripts/00-validate-config.sh
```

Corriger toutes les erreurs avant la suite.

## 6. Lancer l'installation complète

### Nouveau disque de données à effacer

Cette commande détruit intégralement le disque défini par `PXE_DATA_DISK` :

```bash
sudo ./scripts/install.sh --prepare-data-disk
```

### Disque de données déjà préparé et monté

Vérifier d'abord que `PXE_DATA_MOUNT` est réellement monté, puis lancer :

```bash
findmnt /srv/pxe-data
sudo ./scripts/install.sh --reuse-data-disk
```

L'orchestrateur exécute dans cet ordre :

1. validation de la configuration ;
2. installation des paquets ;
3. préparation optionnelle du disque de données ;
4. configuration ou contrôle de l'adresse réseau ;
5. téléchargement et vérification SHA-256 des médias ;
6. compilation des chargeurs iPXE BIOS et UEFI avec la bonne adresse ;
7. publication HTTP, TFTP, NFS et, si nécessaire, Samba ;
8. activation et contrôle des services ;
9. activation d'un service systemd (`generic-pxe-sync.service`) qui rejoue les étapes 5, 7 et 8 à chaque démarrage du serveur : tout média activé mais absent ou manquant dans `config/media.conf` est alors automatiquement téléchargé, vérifié et publié, sans intervention manuelle.

## 7. Contrôler le résultat

```bash
sudo ./scripts/70-enable-and-validate.sh
systemctl --no-pager --full status dnsmasq nginx nfs-server
```

Si Windows est activé :

```bash
systemctl --no-pager --full status smbd
```

Vérifier ensuite avec au moins un ordinateur client :

1. démarrage PXE en mode UEFI ;
2. affichage du menu iPXE ;
3. démarrage réel de chaque média ;
4. démarrage BIOS si ce mode doit être supporté ;
5. montage automatique du dépôt Clonezilla et création d'une image de test ;
6. accès à l'installation Windows et au partage Samba.

Le succès des contrôles serveur ne remplace pas ce test physique.

## 8. Mettre à jour ou ajouter un média

Ajouter ou modifier sa ligne dans `config/media.conf`, puis rejouer :

```bash
sudo ./scripts/40-download-media.sh
sudo ./scripts/60-publish-media.sh
sudo ./scripts/70-enable-and-validate.sh
```

Avec `generic-pxe-sync.service` actif, un simple redémarrage du serveur suffit aussi : le service rejoue ces trois étapes automatiquement au boot. Pour forcer la synchronisation sans redémarrer :

```bash
sudo systemctl start generic-pxe-sync.service
sudo journalctl -u generic-pxe-sync.service
```

Pour un changement d'adresse IP ou de sous-réseau, modifier toutes les valeurs réseau de `config/pxe.env`, appliquer le réseau, puis rejouer les scripts `50`, `60` et `70`. Cette étape reconstruit les deux chargeurs iPXE et recalcule notamment la directive `dhcp-range` à partir de `PXE_SUBNET_CIDR`.

## 9. Sauvegarder la configuration

Conserver hors du serveur :

- ce dossier et les deux fichiers de configuration finalisés ;
- les empreintes officielles des médias ;
- la sortie de `lsblk` et les identifiants stables du disque ;
- le résultat du test physique BIOS/UEFI.

Les ISO et ZIP peuvent être retéléchargés : ils ne sont pas nécessaires dans la sauvegarde du playbook.
