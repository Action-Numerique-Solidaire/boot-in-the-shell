# Playbook simplifié de déploiement du T1000

Ce document donne uniquement l'ordre d'exécution des scripts.

## 0. Télécharger les médias manuellement

Les scripts ne téléchargent aucune ISO ni aucune archive système. Télécharger manuellement les médias depuis leurs sites officiels avant de lancer les scripts de publication.

Pour le déploiement reproduit depuis le T800, `transfer-pxe-content.sh` copie les ISO Linux déjà présentes sur le T800. Si le T800 n'est pas disponible, télécharger manuellement les ISO Linux puis les déposer dans la zone `incoming` du SSD du T1000.

Pour Windows 11, télécharger manuellement l'ISO officielle, puis la copier sous :

```text
/srv/pxe-data/incoming/Win11_25H2_French_x64_v2.iso
```

Pour Clonezilla, télécharger manuellement l'archive officielle, puis la copier sous :

```text
/srv/pxe-data/incoming/clonezilla-live-3.3.3-37-amd64.zip
```

Respecter les noms et versions attendus par les scripts. Les scripts contrôlent les empreintes et refusent un média absent ou différent.

## 1. Sur le T1000

Préparer le SSD de 1 To. Cette commande efface entièrement `/dev/sda` :

```bash
sudo /home/user/prepare-t1000-pxe-ssd.sh ERASE-T1000-SDA
```

Configurer l'adresse fixe initiale de test :

```bash
sudo /home/user/set-t1000-static-ip.sh apply
```

Se reconnecter à `user@192.168.0.101`, puis confirmer :

```bash
sudo /home/user/set-t1000-static-ip.sh confirm
```

## 2. Sur le poste d'administration

Transférer uniquement le contenu PXE du T800 vers le T1000 :

```bash
SOURCE_SSH=regis@192.168.0.100 \
TARGET_SSH=user@192.168.0.101 \
./scripts/transfer-pxe-content.sh
```

## 3. Sur le T1000

Installer les prérequis sans activer le serveur PXE :

```bash
sudo /home/user/install-t1000-pxe-prerequisites.sh
```

Préparer la publication PXE hors ligne :

```bash
sudo /home/user/deploy-t1000-pxe-offline.sh
```

Redémarrer le T1000 et vérifier ses montages.

## 4. Basculer du T800 au T1000

Éteindre le T800 avant l'étape suivante. Les deux serveurs ProxyDHCP ne doivent jamais fonctionner simultanément sur le même réseau.

Sur le T1000 :

```bash
sudo /home/user/activate-t1000-pxe.sh
sudo /home/user/activate-t1000-pxe.sh status
```

## 5. Ajouter Windows 11

Vérifier que l'ISO Windows téléchargée manuellement est présente dans `/srv/pxe-data/incoming/` avant de continuer.

```bash
sudo apt update
sudo apt install -y wimtools samba
sudo /home/user/deploy-windows11-pxe.sh
```

## 6. Ajouter Clonezilla

Vérifier que l'archive Clonezilla téléchargée manuellement est présente dans `/srv/pxe-data/incoming/` avant de continuer.

```bash
sudo apt install -y unzip
sudo /home/user/deploy-clonezilla-pxe.sh
sudo /home/user/prepare-clonezilla-image-repository.sh
sudo /home/user/configure-clonezilla-auto-repository.sh
```

Contrôler l'ensemble :

```bash
sudo /home/user/activate-t1000-pxe.sh status
```

## 7. Réadressage vers le réseau définitif

Utiliser la version corrigée de `readdress-pxe-server.sh`. Remplacer `PASSERELLE_ANS` et `DNS_ANS` par les valeurs du réseau ANS :

```bash
sudo /home/user/readdress-pxe-server.sh prepare \
  192.168.1.15/24 \
  PASSERELLE_ANS \
  DNS_ANS \
  192.168.1.0/24
```

Attendre la fin de la préparation :

```bash
sudo journalctl -fu bits-readdress-prepare.service
sudo /home/user/readdress-pxe-server.sh status
```

Appliquer le changement :

```bash
sudo /home/user/readdress-pxe-server.sh commit
```

Se reconnecter à `user@192.168.1.15`, puis confirmer :

```bash
sudo /home/user/readdress-pxe-server.sh confirm
sudo /home/user/readdress-pxe-server.sh status
```

Vérifier la directive ProxyDHCP :

```bash
grep -Fx 'dhcp-range=192.168.1.0,proxy' /etc/dnsmasq.conf
```

La configuration finale doit contenir :

```ini
dhcp-range=192.168.1.0,proxy
```
