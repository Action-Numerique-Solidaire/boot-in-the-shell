# boot-in-the-shell
Solution open source dédiée au démarrage réseau, au déploiement et à la maintenance de systèmes informatiques, développée par Action Numérique Solidaire (ANS) pour faciliter le reconditionnement et le réemploi numérique.

## Installer le serveur PXE

```bash
echo "deb [trusted=yes] https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases/download/apt/ ./" \
  | sudo tee /etc/apt/sources.list.d/bits.list
sudo apt update && sudo apt install bits-pxe-server

sudo bitsctl media enable killbit
sudo bitsctl apply
```

Phase alpha : le canal stable (`download/apt/`) n'apparaît qu'avec le premier
tag `v*`. D'ici là, utiliser le canal d'essai, `download/apt-test/`.

## Documentation

| Document | Pour qui |
|---|---|
| [03 - prototype-generic/PLAYBOOK.md](03%20-%20prototype-generic/PLAYBOOK.md) | Installer et exploiter le serveur PXE |
| [tests/README.md](tests/README.md) | Éprouver le paquet, le dépôt apt et la chaîne PXE complète |
| [tools/README.md](tools/README.md) | Compiler iPXE ; clé USB de l'ancienne ISO live |
| [04 - live-iso/README.md](04%20-%20live-iso/README.md) | ISO live — **obsolète**, remplacée par le paquet |

Les tests se lancent avec la même commande chez un contributeur et en CI :

```bash
./packaging/build-deb.sh 0.0.0+essai out/debs
tests/paquet-deb.sh out/debs/*.deb
sudo tests/e2e-paquet.sh out/debs/*.deb
```
