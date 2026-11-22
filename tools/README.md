# Outils de fabrication

## Graver l'ISO d'amorçage (cas normal)

```bash
sudo tools/creer-cle-usb.sh --iso bits-amorcage.iso --cible /dev/sdX \
     --sans-donnees --confirmer EFFACER
```

L'ISO d'amorçage (`05 - bootstrap-iso`, ou la release) est écrite telle quelle.
L'outil refuse le disque qui porte `/`, un disque non amovible (sauf
`--autoriser-fixe`) et un disque dont une partition est montée. Un `dd` direct
fonctionne aussi, sans ces garde-fous.

`construire-ipxe.sh` reste utile pour qui veut des chargeurs iPXE compilés
avec le script de BITS (`PXE_IPXE_PREBUILT`) ; le paquet utilise par défaut
ceux du paquet `ipxe` de la distribution.

---

## Ancienne clé « ISO live + médias » (obsolète)

La suite décrit la clé de l'ISO live, qui montait son serveur PXE **sans accès
internet**. Elle est remplacée par l'ISO d'amorçage et les paquets.

### Pourquoi ces outils existaient

L'ISO live seule ne suffit pas. Au premier démarrage, l'assistant joue le
pipeline d'installation, qui télécharge les médias et **compile iPXE**. Sur un
site sans réseau utilisable — le cas d'un atelier de reconditionnement — rien ne
monte. Et l'assistant, par construction, refusait de se servir du média de
démarrage comme stockage : il fallait un second disque.

Une clé fabriquée ici porte donc deux partitions :

| Partition | Contenu |
|---|---|
| 1 | l'ISO live, écrite telle quelle — c'est elle qui démarre |
| 2 | ext4 étiquetée `PXE_DATA` : les médias à servir, et les chargeurs iPXE déjà compilés |

L'assistant retrouve la partition par son **étiquette**, y compris sur le média
de démarrage, et réutilise son contenu sans rien effacer.

### 1. Compiler les chargeurs iPXE

```bash
sudo tools/construire-ipxe.sh /chemin/sortie
```

Produit `undionly.kpxe` (BIOS) et `snponly.efi` (UEFI). Dépendances :
`git`, `build-essential`, `liblzma-dev`.

Le script embarqué dans ces chargeurs est
[`03 - prototype-generic/config/boot.ipxe`](../03%20-%20prototype-generic/config/boot.ipxe).
Il ne fige **aucune adresse** : il enchaîne sur `${filename}` servi par dnsmasq,
puis sur `http://${next-server}/pxe/menu.ipxe` en repli. Ces deux valeurs
viennent de la réponse DHCP. C'est ce qui permet de compiler les chargeurs une
seule fois et de les livrer avec la clé — auparavant l'adresse du serveur était
figée à la compilation, donc un chargeur ne valait que pour un serveur.

### 2. Fabriquer la clé

```bash
sudo tools/creer-cle-usb.sh \
  --iso /chemin/boot-in-the-shell-live.iso \
  --cible /dev/sdX \
  --ipxe /chemin/sortie \
  --media "/chemin/killbit-live.iso:debian-live-iso:killbit:Killbit - effacement securise" \
  --media "/chemin/lubuntu-26.04-desktop-amd64.iso:casper-iso:lubuntu:Lubuntu 26.04 Live" \
  --confirmer EFFACER
```

Chaque `--media` s'écrit `chemin:type:id:libellé`. Les types sont ceux de
[`media.conf.example`](../03%20-%20prototype-generic/config/media.conf.example) :
`casper-iso` pour les dérivés d'Ubuntu, `debian-live-iso` pour une image
Debian live comme killbit, `clonezilla-zip`, `windows-iso`.

Le script calcule l'empreinte SHA-256 de chaque fichier **réellement copié** et
l'écrit dans le catalogue. L'étape 40 du pipeline la vérifie et, le fichier
étant déjà présent, ne télécharge rien.

#### Garde-fous

- refus si la cible porte le système racine ;
- refus si la cible n'est pas amovible, sauf `--autoriser-fixe` ;
- refus si une partition de la cible est montée ;
- `--confirmer EFFACER` obligatoire : la commande efface la cible entièrement.

#### Tester avant de toucher au matériel

`--cible` accepte un **fichier** ordinaire. La clé est alors fabriquée dans une
image, que l'on peut éprouver en machine virtuelle :

```bash
truncate -s 8G /tmp/cle.img
sudo tools/creer-cle-usb.sh --iso … --cible /tmp/cle.img --ipxe … --media … --confirmer EFFACER

# la clé démarre-t-elle, en BIOS puis en UEFI ?
tests/boot-test.sh /tmp/cle.img bios 900 disque
tests/boot-test.sh /tmp/cle.img uefi 900 disque

# la chaîne PXE complète, en partant de la clé
sudo BITS_E2E_CLE=1 tests/e2e-pxe.sh /tmp/cle.img
```

### Au démarrage de la clé

1. Le système live démarre et annonce `BITS-LIVE-READY` sur la console.
2. L'assistant trouve la partition `PXE_DATA`, propose la configuration réseau
   détectée, et attend une confirmation.
3. Le pipeline s'exécute **hors ligne** : prérequis déjà présents, chargeurs
   iPXE déjà compilés, médias déjà là et vérifiés par leur empreinte.
4. Le serveur sert le menu iPXE. **Aucune image n'est lancée automatiquement** :
   `menu.ipxe` se termine par `choose`, sans délai ni entrée par défaut, donc le
   menu attend l'opérateur.

### Limite connue

La publication recopie chaque média de `downloads/` vers `iso/` sur la même
partition. Une image de 3,9 Go occupe donc 7,8 Go sur la clé. C'est le
fonctionnement du pipeline, pas un défaut du script de fabrication, mais il faut
en tenir compte pour dimensionner la clé.
