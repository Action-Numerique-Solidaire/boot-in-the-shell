#!/usr/bin/env bash
set -Eeuo pipefail

# Ce script s'execute depuis le poste d'administration, qui doit pouvoir ouvrir
# une session SSH par cle vers les deux serveurs.
SOURCE_SSH="${SOURCE_SSH:-regis@192.168.0.100}"
TARGET_SSH="${TARGET_SSH:-user@192.168.0.101}"
TARGET_INCOMING="/srv/pxe-data/incoming"

for command_name in ssh; do
  command -v "$command_name" >/dev/null || {
    echo "Commande requise absente : $command_name" >&2
    exit 1
  }
done

ssh -o BatchMode=yes "$SOURCE_SSH" \
  "tar -C /var/www/html -cf - --exclude='pxe/iso/*.old' pxe" \
  | ssh -o BatchMode=yes "$TARGET_SSH" \
      "mkdir -p '$TARGET_INCOMING/http-root' && tar -C '$TARGET_INCOMING/http-root' -xf -"

ssh -o BatchMode=yes "$SOURCE_SSH" \
  'tar -C /srv -cf - pxe' \
  | ssh -o BatchMode=yes "$TARGET_SSH" \
      "mkdir -p '$TARGET_INCOMING/srv-root' && tar -C '$TARGET_INCOMING/srv-root' -xf -"

source_http_hash="$({
  ssh -o BatchMode=yes "$SOURCE_SSH" \
    'cd /var/www/html/pxe && find . -type f ! -name "*.old" -print0 | sort -z | xargs -0 sha256sum | sha256sum'
} | awk '{print $1}')"

target_http_hash="$({
  ssh -o BatchMode=yes "$TARGET_SSH" \
    "cd '$TARGET_INCOMING/http-root/pxe' && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum"
} | awk '{print $1}')"

source_prepared_hash="$({
  ssh -o BatchMode=yes "$SOURCE_SSH" \
    'cd /srv/pxe && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum'
} | awk '{print $1}')"

target_prepared_hash="$({
  ssh -o BatchMode=yes "$TARGET_SSH" \
    "cd '$TARGET_INCOMING/srv-root/pxe' && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum"
} | awk '{print $1}')"

[[ "$source_http_hash" == "$target_http_hash" ]] || {
  echo "Echec : empreinte HTTP/ISO differente." >&2
  exit 1
}
[[ "$source_prepared_hash" == "$target_prepared_hash" ]] || {
  echo "Echec : empreinte de l'arborescence preparee differente." >&2
  exit 1
}

echo "Transfert verifie."
echo "HTTP/ISO : $target_http_hash"
echo "Prepare  : $target_prepared_hash"
