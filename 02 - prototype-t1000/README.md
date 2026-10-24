# Déploiement du T1000 depuis une installation Ubuntu propre

Ce dossier documente le déploiement réellement réalisé le 24 septembre 2026 pour reproduire uniquement le serveur PXE du T800 sur le T1000.

Il complète le cookbook générique `../prototype.md`. Le snapshot historique `../bits-prototype/` reste inchangé.

## Contenu

- `PLAYBOOK.md` : ordre simplifié des scripts à exécuter pour reconstruire le T1000 ;
- `ARCHITECTURE.md` : architecture globale et cinématique détaillée du démarrage PXE ;
- `Architecture_PXE_T1000.pptx` : présentation PowerPoint éditable avec les schémas d'architecture et les parcours de démarrage ;
- `scripts/` : scripts utilisés pendant le déploiement et script consolidé de transfert ;
- `config/` : configurations de référence utilisées pour le déploiement initial sur `192.168.0.101` ;
- `windows11/` : procédure, chargeur wimboot vérifié et état de validation de l'installation Windows 11 par PXE ;
- `clonezilla/` : procédure et état de validation de Clonezilla Live interactif par PXE.

## Périmètre

Le déploiement inclut dnsmasq/ProxyDHCP, TFTP, iPXE BIOS et UEFI, nginx, NFS, quatre médias Linux et l'arborescence Killbit préparée. L'ajout Windows 11 utilise WinPE par HTTP et les fichiers d'installation sur un partage Samba en lecture seule.

Il exclut explicitement Superset, Podman, MariaDB, PostgreSQL et leurs données.

## Avertissement

Les scripts de référence contiennent les identifiants matériels et adresses du T1000 de test. Ils possèdent des garde-fous, mais ne doivent pas être exécutés sur une autre machine sans revue et adaptation. Le formatage du SSD est destructif.

Le script générique de réadressage a été validé par un passage complet de `.101` à `.102`. La migration finale vers `192.168.1.15` réutilisera la même procédure après confirmation des paramètres réseau de l'ANS.
