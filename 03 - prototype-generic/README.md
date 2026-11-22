# Serveur PXE générique

Le cœur de Boot in the Shell, empaqueté en `bits-pxe-server` (voir
`packaging/`). Il met en place :

- dnsmasq en mode ProxyDHCP et TFTP, dans sa propre instance sans DNS ;
- iPXE pour les clients BIOS et UEFI (chargeurs du paquet `ipxe`) ;
- nginx pour le menu, les noyaux et les fichiers de démarrage ;
- NFS pour les médias Casper et Debian live, et le dépôt d'images Clonezilla ;
- Samba uniquement lorsqu'une image Windows est activée.

Les médias sont décrits dans `config/media.conf`. Le serveur les télécharge,
contrôle leur empreinte SHA-256 puis les publie. Le réseau est lu sur
l'interface active : rien n'est à configurer pour commencer.

Commencer par le document [PLAYBOOK.md](PLAYBOOK.md). `bitsctl apply` (paquet)
ou `scripts/install.sh` (depuis le dépôt) enchaîne toutes les étapes, et chaque
script reste exécutable séparément pour le diagnostic.

## Limite volontaire

Pour les médias distribués derrière un portail, un compte ou une URL temporaire, le playbook ne peut pas inventer un lien stable. Il faut d'abord renseigner une URL HTTPS directe et l'empreinte SHA-256 dans le catalogue. Dès que ces deux valeurs sont présentes, le téléchargement et la publication deviennent automatiques.
