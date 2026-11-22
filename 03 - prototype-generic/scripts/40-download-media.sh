#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config
require_data_dir

download_dir="$PXE_DATA_MOUNT/downloads"
ready_file="$PXE_STATE_DIR/media-prets"
install -d -m 0755 "$PXE_STATE_DIR"

# Un média qui ne peut pas être obtenu est écarté, pas fatal : les autres sont
# publiés quand même. Sinon un seul miroir injoignable, ou un démarrage sans
# réseau, laissait le serveur PXE entièrement arrêté. La liste des médias
# prêts est lue par 60-publish-media.sh et 70-enable-and-validate.sh.
ready=()
failed=()

expected_sha() {
  local sha="$1" url="$2" sums_url remote_name
  if [[ "$sha" != sha256sums:* ]]; then
    printf '%s' "${sha,,}"
    return
  fi
  # On compare le nom de base : le fichier d'empreinte de Killbit porte le
  # chemin absolu du runner qui l'a produit, pas le nom publié.
  sums_url="${sha#sha256sums:}"
  remote_name="$(basename "${url%%\?*}")"
  curl --fail --silent --show-error --location "$sums_url" \
    | awk -v n="$remote_name" '{ f = $2; sub(/^\*/, "", f); sub(/.*\//, "", f) } f == n { print tolower($1); exit }'
}

while IFS='|' read -r enabled id _ filename url sha label; do
  [[ "$enabled" == "yes" ]] || continue
  target="$download_dir/$filename"
  log "$label"

  # Empreinte attendue. Publiée à côté de l'image (sha256sums:) : si elle est
  # injoignable, on garde la copie locale déjà vérifiée plutôt que d'écarter
  # le média.
  if ! expected="$(expected_sha "$sha" "$url")" || [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    if [[ -f "$target" && -f "$target.sha256" ]]; then
      echo "AVERTISSEMENT : empreinte publiée injoignable, copie locale conservée."
      ready+=("$id")
    else
      echo "ÉCHEC : empreinte introuvable pour $filename (${sha#sha256sums:})."
      failed+=("$id")
    fi
    continue
  fi

  # Copie locale à jour ? Une image publiée sous un nom fixe (Killbit,
  # « latest ») change d'empreinte à chaque version : on la retélécharge.
  if [[ -f "$target" ]]; then
    if [[ -f "$target.sha256" && "$(cat "$target.sha256")" == "$expected" ]] \
       || printf '%s  %s\n' "$expected" "$target" | sha256sum -c --status -; then
      printf '%s' "$expected" > "$target.sha256"
      echo "Déjà présent et vérifié : $filename"
      ready+=("$id")
      continue
    fi
    echo "Nouvelle version ou copie altérée : $filename est retéléchargé."
  fi

  # Téléchargement dans .part, vérifié AVANT de prendre la place de la copie
  # en service : une image tronquée n'est jamais publiée.
  if ! curl --fail --location --continue-at - --output "$target.part" "$url"; then
    echo "ÉCHEC : téléchargement de $url"
    failed+=("$id")
    continue
  fi
  if ! printf '%s  %s\n' "$expected" "$target.part" | sha256sum -c --status -; then
    echo "ÉCHEC : empreinte SHA-256 incorrecte pour $filename, fichier supprimé."
    rm -f "$target.part"
    failed+=("$id")
    continue
  fi
  mv -f "$target.part" "$target"
  printf '%s' "$expected" > "$target.sha256"
  echo "Téléchargé et vérifié : $filename"
  ready+=("$id")
done < <(enabled_media)

# Une ligne par identifiant ; un tableau vide donne un fichier vide, pas une
# ligne vide.
for i in "${ready[@]}"; do echo "$i"; done > "$ready_file.tmp"
mv -f "$ready_file.tmp" "$ready_file"
for i in "${failed[@]}"; do echo "$i"; done > "$PXE_STATE_DIR/media-ecartes"

echo
echo "Médias prêts : ${#ready[@]}${ready[*]:+ (${ready[*]})}"
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Médias écartés : ${#failed[@]} (${failed[*]})"
fi
