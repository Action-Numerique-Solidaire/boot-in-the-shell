# Serveur PXE générique

Ce dossier transforme une installation Ubuntu Server propre en serveur PXE autonome. Il met en place :

- dnsmasq en mode ProxyDHCP et TFTP ;
- iPXE pour les clients BIOS et UEFI ;
- nginx pour le menu, les noyaux et les fichiers de démarrage ;
- NFS pour les médias Casper et le dépôt d'images Clonezilla ;
- Samba uniquement lorsqu'une image Windows est activée.

Les médias sont décrits dans `config/media.conf`. Le serveur les télécharge, contrôle leur empreinte SHA-256 puis les publie automatiquement. Il n'utilise aucun contenu provenant d'un ancien serveur PXE.

Commencer par le document [PLAYBOOK.md](PLAYBOOK.md). Le script `scripts/install.sh` orchestre toutes les étapes, mais chaque script reste exécutable séparément pour faciliter le diagnostic.

## Limite volontaire

Pour les médias distribués derrière un portail, un compte ou une URL temporaire, le playbook ne peut pas inventer un lien stable. Il faut d'abord renseigner une URL HTTPS directe et l'empreinte SHA-256 dans le catalogue. Dès que ces deux valeurs sont présentes, le téléchargement et la publication deviennent automatiques.
