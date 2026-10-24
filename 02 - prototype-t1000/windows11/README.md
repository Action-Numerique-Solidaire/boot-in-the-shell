# Windows 11 25H2 par PXE sur le T1000

## Objectif

Ajouter au menu iPXE une installation Windows 11 française x64 classique et interactive, sans automatisation du partitionnement ni de l'installation.

## Chaîne de démarrage

```text
Client UEFI
  -> dnsmasq ProxyDHCP et iPXE
  -> wimboot 2.9.0 par HTTP
  -> boot.wim Windows PE par HTTP
  -> partage Samba \\192.168.0.102\win11 en lecture seule
  -> setup.exe interactif
```

Microsoft ne prend plus en charge le déploiement Windows 11 de bout en bout reposant directement sur le `boot.wim` du média en mode WDS. La méthode retenue démarre WinPE avec wimboot puis lance Windows Setup depuis un partage réseau, ce qui reste un scénario pris en charge.

## Fichiers archivés

- `wimboot-2.9.0` : chargeur officiel iPXE pour BIOS et UEFI x64 ;
- `../scripts/deploy-windows11-pxe.sh` : publication contrôlée sur le T1000.

L'ISO Microsoft de 8,47 Go et son arborescence extraite ne sont pas archivées dans le workspace.

## Paramètres de référence

| Élément | Valeur |
|---|---|
| Serveur de test | `192.168.0.102` |
| Sous-réseau autorisé | `192.168.0.0/24` |
| ISO | `Win11_25H2_French_x64_v2.iso` |
| Média extrait | `/srv/pxe-data/windows/win11-25h2-fr` |
| Publication HTTP | `/var/www/html/pxe/windows11` |
| Partage Samba | `win11`, invité, lecture seule |

## État de validation

- ISO locale : empreinte conforme à Microsoft ;
- ISO copiée dans la zone `incoming` du SSD ;
- contenu essentiel présent : `boot.wim`, `install.wim`, `boot.sdi` et `setup.exe` ;
- Samba et wimtools installés ;
- wimboot 2.9.0 et script contrôlés ;
- publication sur le menu : validée côté serveur ;
- HTTP : six ressources Windows contrôlées en code 200 ;
- Samba : configuration valide, port 445 actif, partage invité limité à `192.168.0.0/24` ;
- services `smbd`, nginx, dnsmasq et NFS : actifs et persistants ;
- démarrage PXE réel : en attente.

Sauvegarde créée avant publication :

```text
/home/user/pxe-backups/pre-windows11-20260925-074855
```

Ne marquer le démarrage réel comme validé qu'après apparition de l'assistant Windows sur un client UEFI.

## Réadressage

La version du script `readdress-pxe-server.sh` archivée avec cette documentation inclut désormais :

- `/etc/samba/smb.conf` pour le sous-réseau autorisé ;
- `/var/www/html/pxe/windows11/install.bat` pour l'adresse du partage ;
- le menu iPXE pour les URL WinPE ;
- la validation et le rechargement de Samba pendant `commit`, `confirm` et `rollback`.
