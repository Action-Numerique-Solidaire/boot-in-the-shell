#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

source_root="$PXE_BUILD_ROOT/ipxe"
prebuilt_dir="${PXE_IPXE_PREBUILT:-$PXE_DATA_MOUNT/ipxe-prebuilt}"
bios_out="$source_root/src/bin/undionly.kpxe"
efi_out="$source_root/src/bin-x86_64-efi/snponly.efi"
boot_script="$PXE_BUILD_ROOT/boot.ipxe"

# L'URL du menu n'est plus figée à la compilation. ${filename} est ce que
# dnsmasq sert à un client déjà iPXE, et ${next-server} l'adresse du serveur
# dans la réponse DHCP. Les chargeurs cessent donc d'être liés à une adresse :
# ils peuvent être compilés une fois et livrés tels quels avec la clé USB, et
# changer l'adresse du serveur ne demande plus de les recompiler.
MENU_URL_REPLI='http://${next-server}/pxe/menu.ipxe'

if [[ -s "$prebuilt_dir/undionly.kpxe" && -s "$prebuilt_dir/snponly.efi" ]]; then
  # Chemin hors ligne : les chargeurs sont déjà là, rien à cloner ni compiler.
  log "Chargeurs iPXE pré-compilés repris depuis $prebuilt_dir"
  install -d -m 0755 "$(dirname "$bios_out")" "$(dirname "$efi_out")"
  install -m 0644 "$prebuilt_dir/undionly.kpxe" "$bios_out"
  install -m 0644 "$prebuilt_dir/snponly.efi" "$efi_out"
else
  require_command git
  require_command make
  install -d -m 0755 "$PXE_BUILD_ROOT"
  if [[ ! -d "$source_root/.git" ]]; then
    git clone "$IPXE_GIT_URL" "$source_root"
  fi
  git -C "$source_root" fetch --all --tags
  git -C "$source_root" checkout --detach "$IPXE_GIT_COMMIT"

  # Script partagé avec tools/construire-ipxe.sh : un seul endroit à changer.
  [[ -f "$PROJECT_ROOT/config/boot.ipxe" ]] || die "Script iPXE absent : $PROJECT_ROOT/config/boot.ipxe"
  install -m 0644 "$PROJECT_ROOT/config/boot.ipxe" "$boot_script"

  make -C "$source_root/src" clean
  make -C "$source_root/src" -j2 bin/undionly.kpxe EMBED="$boot_script"
  make -C "$source_root/src" -j2 bin-x86_64-efi/snponly.efi EMBED="$boot_script"
fi

[[ -s "$bios_out" && -s "$efi_out" ]] || die "Chargeurs iPXE absents après l'étape 50."
# grep SANS « -q » : avec -q, grep sort a la premiere correspondance, strings
# recoit SIGPIPE et rend 141, et « set -o pipefail » en fait un echec. Le
# defaut etait deja present avant l'URL non figee, et se declenchait au hasard.
if ! strings "$efi_out" | grep -F "$MENU_URL_REPLI" >/dev/null; then
  die "Le chargeur UEFI n'embarque pas l'URL de repli du menu : il n'a pas été compilé avec le bon script."
fi
echo "Chargeurs iPXE BIOS et UEFI prêts."
