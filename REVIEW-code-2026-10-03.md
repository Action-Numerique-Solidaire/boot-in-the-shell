# Revue de code — Boot in the Shell (2026-10-03)

Revue effectuée sur l'archive `boot-in-the-shell.zip` extraite dans ce dossier, avant toute tentative de reproduction sur un serveur de test.

## Vérifications d'intégrité

- `MANIFEST.sha256` des deux dossiers (`02 - prototype-t1000`, `03 - prototype-generic`) : tous les fichiers OK.
- `windows11/wimboot-2.9.0` : checksum conforme à `WIMBOOT_SHA256` déclaré dans les scripts.
- Tous les scripts shell passent `bash -n` (pas d'erreur de syntaxe). `shellcheck` non disponible dans l'environnement de revue (pas d'accès réseau pour l'installer) — à relancer avec shellcheck si possible plus tard.

## Points forts

- Vérification SHA-256 systématique sur tous les médias téléchargés avant publication.
- `netplan try` avec minuteur de retour automatique pour les changements réseau (évite de se couper l'accès au serveur).
- Garde-fous explicites avant toute opération destructive : le script de formatage du SSD du T1000 vérifie modèle/numéro de série/taille du disque cible avant `wipefs`.
- Montages idempotents (fstab + vérification avant remount), scripts de republication rejouables sans accumulation de doublons (fichiers de conf régénérés depuis zéro à chaque run côté generic).
- `readdress-pxe-server.sh` implémente un vrai cycle *prepare → commit → confirm/rollback* avec minuteur de sécurité systemd (retour arrière automatique si personne ne confirme) — filet de sécurité réseau soigné.

## Problèmes identifiés (par ordre de priorité)

### 1. ~~Protection anti-effacement du disque système sous LVM~~ — vérifié, le garde-fou tient

Fichier : `03 - prototype-generic/scripts/20-prepare-data-disk.sh:9-12` (et équivalent T1000 `prepare-t1000-pxe-ssd.sh`).

**Mise à jour 2026-10-03, testé en conditions réelles sur une VM de laboratoire (voir section Test ci-dessous).** La vérification étroite (comparaison au `PKNAME` de la partition racine) ne couvrirait effectivement pas un layout LVM à elle seule. Mais la seconde vérification, plus large (`lsblk -nrpo MOUNTPOINT` sur tout l'arbre du disque cible), capture bien un volume logique LVM monté quelque part au-dessus de ce disque, même nesté via device-mapper — testé en créant un PV/VG/LV sur un disque de test puis en pointant `PXE_DATA_DISK` dessus : le script a correctement refusé avec « Une partition du disque cible est montée. ». Point clos, pas d'action requise.

**Action avant usage réel sur un nouveau serveur :** tester volontairement ce script en pointant `PXE_DATA_DISK` sur le disque système d'une VM LVM jetable, et confirmer qu'il refuse bien. Opération destructive et irréversible sinon.

### 2. Téléchargement corrompu → blocage silencieux et permanent

Fichier : `03 - prototype-generic/scripts/40-download-media.sh:15-19`.

Si un média téléchargé échoue la vérification SHA-256, le fichier reste sur disque. Au relancement, le script voit que le fichier existe déjà et **ne le retélécharge pas** — il réessaie juste de vérifier le même fichier cassé, et échoue à nouveau, indéfiniment, sans jamais dire à l'utilisateur de le supprimer.

**Correctif simple :** supprimer le fichier (ou le déplacer en `.bad`) dès que `sha256sum -c` échoue, et/ou afficher un message explicite invitant à le supprimer manuellement.

### 3. Dette technique — duplication T1000 vs structure generic

Chaque script `deploy-*-pxe.sh` du T1000 (`deploy-windows11-pxe.sh`, `deploy-clonezilla-pxe.sh`, etc.) réimplémente sa propre logique de sauvegarde, son propre patch Python du menu iPXE, ses propres contrôles HTTP — alors que `03 - prototype-generic` a consolidé tout ça en une pipeline numérotée (`00-validate-config` → `70-enable-and-validate`) pilotée par `config/pxe.env` + `config/media.conf` + `scripts/lib/common.sh`.

C'est la bonne direction pour l'objectif « clé en main » du président. À l'inverse, `readdress-pxe-server.sh` (488 lignes, chemins en dur type `/home/user/...`) est le plus fragile des deux mondes : il fait du chercher-remplacer sur des fichiers de configuration déjà vivants plutôt que de les régénérer depuis un template, ce qui le lie fortement à l'installation spécifique du T1000.

**Recommandation :** faire converger les futures instances sur l'approche « régénération depuis template + variables d'environnement » du prototype générique, et traiter `readdress-pxe-server.sh` comme une pièce héritée du T1000 à ne pas reproduire telle quelle.

### 4. Partages ouverts sans authentification sur tout le sous-réseau

Le dépôt d'images Clonezilla (export NFS en lecture/écriture, `all_squash` vers `nobody`) et le partage Windows (Samba invité, lecture seule) sont accessibles à n'importe quelle machine du réseau local, sans mot de passe — cohérent avec l'objectif de ne pas déployer de second DHCP, mais à documenter clairement : les images disque clonées peuvent contenir des données personnelles des anciens propriétaires de PC.

**Recommandation :** isoler le banc de test/atelier sur un VLAN ou un switch dédié dès que plusieurs structures (associations partenaires, ESN en mécénat de compétences) partageront le même réseau physique.

### 5. Compilation d'iPXE depuis les sources à chaque déploiement

`03 - prototype-generic/scripts/50-build-ipxe.sh` recompile iPXE (clone git + `make`, nécessite `build-essential`/`liblzma-dev`, accès Internet, quelques minutes) à chaque installation complète ou changement d'adresse IP du serveur. Cohérent avec la contrainte (l'adresse du menu est compilée en dur dans le binaire), mais va un peu à l'encontre de l'objectif « clé en main » et laisse une toolchain de compilation installée sur un serveur par ailleurs exposé sur le LAN.

**Piste :** publier des binaires `undionly.kpxe` / `snponly.efi` pré-compilés et versionnés par adresse IP courante, et ne déclencher une recompilation que lors d'un changement d'adresse réel (ce que fait déjà `readdress-pxe-server.sh` côté T1000).

### Notes mineures

- `media.conf.example` : les empreintes SHA-256 fournies ont la bonne longueur (64 caractères hex) ; leur validité réelle (versions encore publiées, URLs toujours actives) reste à reconfirmer au moment du déploiement — ce que la doc signale déjà elle-même.
- `60-publish-media.sh` : si deux médias de type `clonezilla-zip` étaient activés simultanément dans le même catalogue, l'export NFS du dépôt d'images serait dupliqué dans le fichier d'exports généré (cas limite peu probable en pratique).
- Entrées `/etc/fstab` et exports NFS ajoutés par le pipeline générique ne sont jamais nettoyés si un média change d'identifiant ou de nom de fichier entre deux déploiements (accumulation silencieuse au fil des mises à jour).

## Test de reproduction — 2026-10-03, sur `kamos` (KVM/libvirt)

Reproduction complète de `03 - prototype-generic` depuis zéro sur une VM Ubuntu Server 24.04 fraîche (cloud image), réseau virtuel isolé dédié (`pxelab`, 10.77.0.0/24, NAT, DHCP fourni par libvirt — jouant le rôle du « DHCP déjà présent sur le réseau »), catalogue de médias réduit à Clonezilla Live 3.3.3-37 pour aller vite. Deux VM clientes diskless (une BIOS, une UEFI) pour le test de boot réel.

**Résultat : succès de bout en bout.** Pipeline `00` à `70` exécutée sans contournement (seule l'archive Clonezilla a été pré-déposée pour éviter un re-téléchargement redondant — son SHA-256 correspond exactement à l'empreinte officielle documentée). Vérifié via logs serveur (dnsmasq `log-dhcp`, accès nginx, `showmount`) et captures d'écran VNC des clients :

- DHCP/ProxyDHCP : coexistence confirmée avec le DHCP « réel » du réseau de test ; dnsmasq différencie correctement client déjà-iPXE (`user class: iPXE` → URL HTTP directe), client EFI natif (`Arch:00007` → `snponly.efi` par TFTP) et répond uniquement à la partie PXE.
- TFTP : chargeur `snponly.efi` compilé par `50-build-ipxe.sh` livré avec succès à un client UEFI natif (« NBP file downloaded successfully »).
- HTTP : menu + noyau + initrd + squashfs Clonezilla servis avec les tailles exactes (420 614 144 octets pour le squashfs, conforme à la doc T1000).
- NFS : montage automatique du dépôt d'images Clonezilla confirmé côté serveur (`showmount -a` liste le client) — le mécanisme `ocs_prerun` fonctionne.
- Boot réel : client UEFI arrivé jusqu'à l'écran interactif « Démarrage de Clonezilla » (capture d'écran à l'appui), confirmant tout le chemin PXE natif → TFTP → iPXE compilé → HTTP → environnement live.
- Garde-fou disque (point n°1 ci-dessus) : revérifié et confirmé solide, y compris sous LVM simulé.

**Découverte nouvelle — Secure Boot bloque le chargeur UEFI non signé.** Avec Secure Boot activé (clés Microsoft, configuration par défaut de beaucoup de PC récents), le firmware UEFI télécharge `snponly.efi` par TFTP sans problème mais refuse de l'exécuter : `BdsDxe: failed to load Boot0002 "UEFI PXEv4" ... Access Denied`. Le firmware bascule ensuite sur `UEFI HTTP Boot`, que le serveur ne gère pas, et boucle indéfiniment sans jamais atteindre le menu. Avec Secure Boot désactivé, tout fonctionne immédiatement (voir ci-dessus).

**Impact pratique :** sur un PC récent arrivant à l'association avec Secure Boot activé par défaut (cas fréquent), le menu PXE n'apparaîtra jamais côté UEFI tant que Secure Boot n'est pas désactivé manuellement dans le firmware — ou tant que `snponly.efi` n'est pas signé par une clé reconnue (shim/MOK, ou signature Microsoft via un partenariat type UEFI CA). C'est un point à documenter explicitement dans le mode opératoire pour les bénévoles (« désactiver Secure Boot avant de tenter un boot PXE »· et potentiellement à remonter au président comme limite connue du prototype, au même titre que le chaînage PXE natif→iPXE déjà documenté dans ARCHITECTURE.md.

**Limite du test (pas un bug produit) :** le chemin BIOS n'a pas pu être validé jusqu'au bout dans ce labo — la carte réseau virtuelle de QEMU embarque déjà sa propre ROM iPXE générique, ce qui court-circuite artificiellement le scénario « ROM PXE native du poste → chaînage vers notre `undionly.kpxe` compilé » que le projet est spécifiquement conçu pour gérer. Ce chemin a déjà été validé sur matériel réel (T1000, cf. `PLAYBOOK.md`) ; le reproduire fidèlement en VM demanderait de désactiver la ROM iPXE intégrée de QEMU sur la carte réseau, non résolu dans le temps imparti.

## Prochaine étape

Pipeline générique validé de bout en bout sur VM fraîche. Pistes pour la suite : documenter la contrainte Secure Boot dans le playbook, tenter le chemin BIOS avec ROM iPXE désactivée côté QEMU, puis explorer l'infra de test automatisée (KubeVirt) comme souhaité pour la phase suivante.
