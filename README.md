# boot-in-the-shell
Solution open source dédiée au démarrage réseau, au déploiement et à la maintenance de systèmes informatiques, développée par Action Numérique Solidaire (ANS) pour faciliter le reconditionnement et le réemploi numérique.

## Documentation

| Document | Pour qui |
|---|---|
| [04 - live-iso/README.md](04%20-%20live-iso/README.md) | Graver l'ISO, les deux usages, le déploiement sans interaction |
| [03 - prototype-generic/README.md](03%20-%20prototype-generic/README.md) | Installer le serveur PXE sur une machine existante |
| [tests/README.md](tests/README.md) | Vérifier une image : amorçage BIOS/UEFI et chaîne PXE complète |

Les tests se lancent avec la même commande chez un contributeur et en CI :

```bash
tests/run-all.sh /chemin/image.iso
```
