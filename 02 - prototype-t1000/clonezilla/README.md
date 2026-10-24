# Clonezilla Live 3.3.3-37 par PXE

## Objectif

Ajouter au menu du T1000 un Clonezilla Live interactif pour réaliser manuellement des images, clonages et restaurations.

Cette entrée ne contient aucune commande `ocs-sr`, aucun mode batch et aucune sélection automatique de disque.

## Chaîne de démarrage

```text
Client BIOS ou UEFI
  -> dnsmasq ProxyDHCP et iPXE
  -> vmlinuz + initrd.img par HTTP
  -> filesystem.squashfs par HTTP avec fetch=
  -> interface interactive Clonezilla
```

## Média vérifié

| Élément | Valeur |
|---|---|
| Version | `3.3.3-37` stable, Debian-based |
| Architecture | `amd64` |
| Archive | `clonezilla-live-3.3.3-37-amd64.zip` |
| Taille | `494074389` octets |
| SHA-256 | `bbb02b409708cf37774debe00f96c642c59c48ebb216f7349dc2252f705ff10e` |
| Emplacement entrant | `/srv/pxe-data/incoming/` |
| Média publié | `/srv/pxe-data/clonezilla/3.3.3-37` |

L'archive elle-même et le squashfs de 420 Mo ne sont pas stockés dans le workspace.

## Sécurité

- `ocs_live_batch=no` conserve toutes les confirmations interactives ;
- aucune partition ni aucun disque n'est présélectionné ;
- le premier test doit s'arrêter avant toute sauvegarde ou restauration ;
- pour une restauration réelle, relever au préalable modèle, série et capacité des disques.

## État de validation

- téléchargement officiel : terminé ;
- empreinte officielle : conforme ;
- structure ZIP : conforme ;
- transfert vers T1000 : terminé ;
- script de publication : contrôlé et déposé ;
- publication HTTP/menu : validée côté serveur ;
- noyau, initrd et squashfs : accessibles en HTTP 200 avec leurs tailles attendues ;
- services PXE : actifs après publication ;
- démarrage réel : validé jusqu'à l'écran de sélection du dépôt ;
- dépôt NFS d'images : créé, exporté et contrôlé.

Sauvegarde créée avant publication :

```text
/home/user/pxe-backups/pre-clonezilla-20260925-080435
```

## Dépôt d'images

Le dépôt persistant se trouve sur le SSD :

```text
Serveur : 192.168.0.102
Export  : /srv/pxe-data/clonezilla-images
Accès   : lecture/écriture depuis 192.168.0.0/24
Espace  : environ 834 Go lors de la création
```

L'export utilise `all_squash` avec l'identité anonyme `65534:65534`. Les autres exports PXE restent en lecture seule.

Le menu iPXE monte automatiquement cet export en NFSv3 sur `/home/partimag` grâce à `ocs_prerun`. Clonezilla arrive donc directement aux choix de sauvegarde ou restauration sans redemander le type de stockage, le serveur et le chemin. Les images créées apparaissent sous `/srv/pxe-data/clonezilla-images`.

Sauvegarde créée avant l'ajout de l'export :

```text
/home/user/pxe-backups/pre-clonezilla-repository-20260925-081243
```

Sauvegarde du menu avant activation du montage automatique :

```text
/home/user/pxe-backups/pre-clonezilla-auto-repository-20260925-081626
```

Les choix de l'opération, du nom de l'image et des disques restent entièrement interactifs.
