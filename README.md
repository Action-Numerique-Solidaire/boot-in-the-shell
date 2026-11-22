# boot-in-the-shell
Solution open source dédiée au démarrage réseau, au déploiement et à la maintenance de systèmes informatiques, développée par Action Numérique Solidaire (ANS) pour faciliter le reconditionnement et le réemploi numérique.

## Deux façons d'avoir un serveur PXE

**Un PC dédié, depuis une clé USB.** Graver `bits-amorcage.iso` (fichier de
release, ~65 Mo), démarrer le PC dessus et choisir *Installer le serveur BITS* :
Debian 13 s'installe sur le disque interne (**entièrement effacé**), puis BITS.
Au redémarrage, la console affiche l'adresse de l'interface web.
Voir [05 - bootstrap-iso](05%20-%20bootstrap-iso/README.md).

**Une machine Debian ou Ubuntu existante, par apt.**

```bash
echo "deb [trusted=yes] https://github.com/Action-Numerique-Solidaire/boot-in-the-shell/releases/download/apt/ ./" \
  | sudo tee /etc/apt/sources.list.d/bits.list
sudo apt update && sudo apt install bits-pxe-server bits-web
```

Puis choisir les images dans l'interface web (`http://<adresse>/`), ou :

```bash
sudo bitsctl media enable killbit
sudo bitsctl apply
```

Phase alpha : le canal stable (`download/apt/`) n'apparaît qu'avec le premier
tag `v*`. D'ici là, utiliser le canal d'essai, `download/apt-test/`.

## Documentation

| Document | Pour qui |
|---|---|
| [05 - bootstrap-iso/README.md](05%20-%20bootstrap-iso/README.md) | La clé USB d'installation : ce qu'elle fait, la construire, la graver |
| [03 - prototype-generic/PLAYBOOK.md](03%20-%20prototype-generic/PLAYBOOK.md) | Installer et exploiter le serveur PXE (paquets, `bitsctl`, interface web) |
| [tests/README.md](tests/README.md) | Éprouver chaque élément : paquets, dépôt apt, ISO, chaîne PXE complète |
| [tools/README.md](tools/README.md) | Graver la clé avec garde-fous ; compiler iPXE |
| [04 - live-iso/README.md](04%20-%20live-iso/README.md) | ISO live — **obsolète**, remplacée par l'ISO d'amorçage et les paquets |

Les tests se lancent avec la même commande chez un contributeur et en CI :

```bash
tests/run-all.sh                  # paquets, dépôt apt, démarrage de l'ISO (~1 min 30)
sudo tests/run-all.sh             # + chaîne PXE complète en VM (~3 min)
sudo tests/run-all.sh --complet   # + installation complète depuis l'ISO (~20 min)
```
