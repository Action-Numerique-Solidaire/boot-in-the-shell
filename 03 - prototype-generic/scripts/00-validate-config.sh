#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config

python3 - "$PXE_ADDRESS_CIDR" "$PXE_GATEWAY" "$PXE_DNS" "$PXE_SUBNET_CIDR" <<'PY'
import ipaddress, sys
interface = ipaddress.ip_interface(sys.argv[1])
gateway = ipaddress.ip_address(sys.argv[2])
dns = ipaddress.ip_address(sys.argv[3])
network = ipaddress.ip_network(sys.argv[4], strict=True)
if interface.version != 4 or gateway.version != 4 or dns.version != 4 or network.version != 4:
    raise SystemExit("Seul IPv4 est pris en charge.")
if interface.ip not in network:
    raise SystemExit("L'adresse du serveur n'appartient pas au sous-réseau PXE.")
if gateway not in interface.network:
    raise SystemExit("La passerelle n'appartient pas au réseau de l'adresse du serveur.")
PY

[[ "$PXE_DATA_DISK" == /dev/disk/by-id/* ]] || die "PXE_DATA_DISK doit utiliser /dev/disk/by-id/."
[[ "$PXE_DATA_PARTITION" == /dev/disk/by-id/* ]] || die "PXE_DATA_PARTITION doit utiliser /dev/disk/by-id/."
[[ -f "$MEDIA_FILE" ]] || die "Catalogue absent : $MEDIA_FILE"

count=0
while IFS='|' read -r enabled id type filename url sha label; do
  [[ "$enabled" == "yes" ]] || continue
  safe_id "$id"
  # Trois endroits énumèrent les types : ici, et les deux « case » de
  # 60-publish-media.sh (publication puis entrée de menu). Ajouter un type
  # demande de les mettre à jour tous les trois, et 70-enable-and-validate.sh
  # avec, sinon le média n'est pas contrôlé après publication.
  [[ "$type" =~ ^(casper-iso|debian-live-iso|clonezilla-zip|windows-iso)$ ]] || die "Type inconnu pour $id : $type"
  [[ -n "$filename" && -n "$label" ]] || die "Ligne média incomplète pour $id."
  # https:// pour ce qui vient du réseau, file:// pour un média déjà sur le
  # disque de données — le cas d'une clé USB pré-remplie, où il n'y a rien à
  # télécharger. L'exigence de HTTPS visait le transport en clair ; file:// ne
  # transporte rien, et l'empreinte SHA-256 reste vérifiée dans les deux cas.
  [[ "$url" =~ ^(https://|file:///) ]] || die "URL invalide pour $id : attendu https:// ou file:///."
  [[ "$url" != *REPLACE_* ]] || die "URL à renseigner pour $id."
  [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA-256 à renseigner pour $id."
  count=$((count + 1))
done < <(enabled_media)
(( count > 0 )) || die "Aucun média activé."

echo "Configuration valide : $PXE_IP sur $PXE_INTERFACE, $count média(s) activé(s)."
