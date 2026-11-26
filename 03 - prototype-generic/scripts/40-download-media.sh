#!/usr/bin/env bash
# Télécharge et vérifie les images activées, et note lesquelles sont prêtes à
# publier.
#
#   --seulement <id>...   télécharge seulement ces images, activées ou non,
#                         sans toucher à l'état de publication : c'est le
#                         bouton « Télécharger » de l'interface web, qui
#                         prépare une image sans changer le menu PXE.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config
require_data_dir

SEULEMENT=()
if [[ "${1:-}" == --seulement ]]; then
  shift
  [[ $# -gt 0 ]] || die "--seulement attend au moins un identifiant."
  for id in "$@"; do safe_id "$id"; done
  SEULEMENT=("$@")
fi

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
  # msdl:<langue> : tableau des empreintes de la page de Microsoft (url =
  # msdl:<page>).
  if [[ "$sha" == msdl:* ]]; then
    python3 -I "$(dirname "$0")/empreinte-microsoft.py" "${url#msdl:}" "${sha#msdl:}"
    return
  fi
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

source_lignes() {
  if [[ ${#SEULEMENT[@]} -eq 0 ]]; then
    enabled_media
    return
  fi
  local id trouve
  for id in "${SEULEMENT[@]}"; do
    trouve="$(catalogue_lines | awk -F '|' -v id="$id" '$2 == id { print; exit }')"
    [[ -n "$trouve" ]] || die "Média inconnu dans $MEDIA_FILE : $id"
    printf '%s\n' "$trouve"
  done
}

while IFS='|' read -r enabled id _ filename url sha label; do
  if [[ ${#SEULEMENT[@]} -eq 0 ]]; then
    [[ "$enabled" == "yes" ]] || continue
  else
    # Image non activée : 00-validate-config.sh ne l'a pas contrôlée.
    [[ "$filename" != */* && -n "$filename" ]] || die "Nom de fichier invalide pour $id"
    [[ "$url" =~ ^(https://|file:///|msdl:https://|msdl:file:///) && "$url" != *REPLACE_* ]] || die "URL à renseigner pour $id."
  fi
  target="$download_dir/$filename"
  log "$label"
  # Lien collé dans l'interface web pour une image Microsoft : lu et effacé
  # d'emblée, pour ne jamais resservir un lien expiré.
  lien_colle="" sha_colle=""
  if [[ "$url" == msdl:* && -f "$PXE_STATE_DIR/lien-$id" ]]; then
    read -r lien_colle sha_colle < "$PXE_STATE_DIR/lien-$id" || true
    rm -f "$PXE_STATE_DIR/lien-$id"
  fi

  # Empreinte attendue. Publiée à côté de l'image (sha256sums:) : si elle est
  # injoignable, on garde la copie locale déjà vérifiée plutôt que d'écarter
  # le média.
  if ! expected="$(expected_sha "$sha" "$url")" || [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    if [[ "${sha_colle,,}" =~ ^[0-9a-f]{64}$ ]]; then
      # Page de Microsoft illisible : l'empreinte saisie avec le lien collé
      # (copiée de cette même page dans un navigateur) en tient lieu.
      expected="${sha_colle,,}"
      echo "AVERTISSEMENT : tableau des empreintes de Microsoft illisible, empreinte saisie utilisée."
    elif [[ -f "$target" && -f "$target.sha256" ]]; then
      echo "AVERTISSEMENT : empreinte publiée injoignable, copie locale conservée."
      ready+=("$id")
    else
      echo "ÉCHEC : empreinte introuvable pour $filename (${sha#sha256sums:})."
      failed+=("$id")
    fi
    [[ "$expected" =~ ^[0-9a-f]{64}$ && -n "$sha_colle" ]] || continue
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

  # Image Microsoft : pas d'adresse fixe, et Microsoft refuse de fournir un
  # lien à un programme. Le lien (valable 24 h) est obtenu dans un navigateur
  # et collé dans l'interface web ; il ne sert qu'une fois.
  if [[ "$url" == msdl:* ]]; then
    if [[ -z "$lien_colle" ]]; then
      echo "ÉCHEC : aucun lien de téléchargement. Coller un lien obtenu sur ${url#msdl:} dans l'interface web (carte $label)."
      failed+=("$id")
      continue
    fi
    url="$lien_colle"
    echo "Lien collé dans l'interface web : ${url%%\?*}"
    if [[ -n "${sha_colle:-}" && "${sha_colle,,}" != "$expected" ]]; then
      echo "AVERTISSEMENT : l'empreinte saisie diffère de celle de la page Microsoft ; celle de la page est vérifiée."
    fi
    # Le lien change à chaque fois, pas le contenu : un .part de la même
    # version (même empreinte attendue) est repris, un autre est jeté.
    if [[ "$(cat "$target.part.attendu" 2>/dev/null)" != "$expected" ]]; then rm -f "$target.part"; fi
    printf '%s' "$expected" > "$target.part.attendu"
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
  rm -f "$target.part.attendu"
  printf '%s' "$expected" > "$target.sha256"
  echo "Téléchargé et vérifié : $filename"
  ready+=("$id")
done < <(source_lignes)

if [[ ${#SEULEMENT[@]} -gt 0 ]]; then
  echo
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Téléchargement en échec : ${failed[*]}"
    exit 1
  fi
  echo "Téléchargé et vérifié, non publié : ${ready[*]}"
  exit 0
fi

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
