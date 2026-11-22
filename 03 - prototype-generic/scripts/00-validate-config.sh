#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config

python3 - "$PXE_ADDRESS_CIDR" "$PXE_SUBNET_CIDR" "${PXE_GATEWAY:-}" "${PXE_DNS:-}" <<'PY'
import ipaddress, sys
interface = ipaddress.ip_interface(sys.argv[1])
network = ipaddress.ip_network(sys.argv[2], strict=True)
if interface.version != 4 or network.version != 4:
    raise SystemExit("Seul IPv4 est pris en charge.")
if interface.ip not in network:
    raise SystemExit("L'adresse du serveur n'appartient pas au sous-réseau PXE.")
# Passerelle et DNS ne servent qu'à une configuration réseau gérée par BITS
# (PXE_MANAGE_NETWORK=yes) : facultatifs, mais cohérents s'ils sont donnés.
if sys.argv[3] and ipaddress.ip_address(sys.argv[3]) not in interface.network:
    raise SystemExit("La passerelle n'appartient pas au réseau de l'adresse du serveur.")
if sys.argv[4]:
    ipaddress.ip_address(sys.argv[4])
PY

if [[ -n "$PXE_DATA_DISK" ]]; then
  [[ "$PXE_DATA_DISK" == /dev/disk/by-id/* ]] || die "PXE_DATA_DISK doit utiliser /dev/disk/by-id/."
  [[ "$PXE_DATA_PARTITION" == /dev/disk/by-id/* ]] || die "PXE_DATA_PARTITION doit utiliser /dev/disk/by-id/."
fi
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
  [[ "$filename" != */* ]] || die "Nom de fichier invalide pour $id : $filename"
  # https:// pour ce qui vient du réseau, file:// pour un média déjà présent
  # localement. L'empreinte SHA-256 est vérifiée dans les deux cas.
  [[ "$url" =~ ^(https://|file:///) ]] || die "URL invalide pour $id : attendu https:// ou file:///."
  [[ "$url" != *REPLACE_* ]] || die "URL à renseigner pour $id."
  # sha256sums:<url> : l'empreinte est lue au téléchargement dans le fichier
  # SHA256SUMS publié avec l'image, pour une image publiée sous un nom fixe
  # qui change de contenu (Killbit, release « latest »).
  if [[ "$sha" == sha256sums:* ]]; then
    [[ "${sha#sha256sums:}" =~ ^https:// ]] || die "Empreinte de $id : sha256sums: doit être suivi d'une URL https://."
  else
    [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA-256 à renseigner pour $id."
  fi
  count=$((count + 1))
done < <(enabled_media)

echo "Configuration valide : $PXE_IP sur $PXE_INTERFACE ($PXE_SUBNET_CIDR), $count média(s) activé(s)."
(( count > 0 )) || echo "Aucun média activé : le menu PXE ne proposera que le disque local et la console iPXE."
