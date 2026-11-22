#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

# Chargeurs iPXE servis en TFTP, par ordre de préférence :
#
#   1. PXE_IPXE_PREBUILT  répertoire de chargeurs déjà compilés
#                         (tools/construire-ipxe.sh) ;
#   2. /usr/lib/ipxe      paquet « ipxe » de la distribution : le cas normal,
#                         rien à compiler ni à télécharger ;
#   3. PXE_IPXE_COMPILE=yes  clone et compilation au commit IPXE_GIT_COMMIT,
#                         avec le script embarqué config/boot.ipxe.
#
# Les chargeurs de la distribution n'embarquent pas de script : une fois
# lancés, ils refont une requête DHCP en s'annonçant iPXE, et dnsmasq leur
# sert alors le menu (règles « tag:ipxe » écrites par 60-publish-media.sh).
# C'est le même chemin que pour une carte réseau dont la ROM est déjà iPXE.
distro_dir=/usr/lib/ipxe
prebuilt_dir="${PXE_IPXE_PREBUILT:-}"
install -d -m 0755 "$PXE_TFTP_ROOT"

if [[ -n "$prebuilt_dir" && -s "$prebuilt_dir/undionly.kpxe" && -s "$prebuilt_dir/snponly.efi" ]]; then
  log "Chargeurs iPXE pré-compilés repris depuis $prebuilt_dir"
  bios_src="$prebuilt_dir/undionly.kpxe"
  efi_src="$prebuilt_dir/snponly.efi"
elif [[ "${PXE_IPXE_COMPILE:-no}" != yes && -s "$distro_dir/undionly.kpxe" && -s "$distro_dir/snponly.efi" ]]; then
  log "Chargeurs iPXE du paquet ipxe ($distro_dir)"
  bios_src="$distro_dir/undionly.kpxe"
  efi_src="$distro_dir/snponly.efi"
else
  [[ "${PXE_IPXE_COMPILE:-no}" == yes ]] \
    || die "Chargeurs iPXE absents de $distro_dir (paquet ipxe). Installer ipxe, ou PXE_IPXE_COMPILE=yes pour compiler."
  for c in git make gcc; do require_command "$c"; done
  [[ -f /usr/include/lzma.h ]] || die "En-têtes lzma absents (paquet liblzma-dev), requis pour compiler iPXE."
  source_root="$PXE_BUILD_ROOT/ipxe"
  boot_script="$PXE_BUILD_ROOT/boot.ipxe"
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
  bios_src="$source_root/src/bin/undionly.kpxe"
  efi_src="$source_root/src/bin-x86_64-efi/snponly.efi"

  # grep SANS « -q » : avec -q, grep sort à la première correspondance,
  # strings reçoit SIGPIPE et rend 141, et « set -o pipefail » en fait un échec.
  # shellcheck disable=SC2016  # ${next-server} est une variable iPXE, littérale ici
  if ! strings "$efi_src" | grep -F 'http://${next-server}/pxe/menu.ipxe' >/dev/null; then
    die "Le chargeur UEFI n'embarque pas l'URL de repli du menu : il n'a pas été compilé avec le bon script."
  fi
fi

install -m 0644 "$bios_src" "$PXE_TFTP_ROOT/undionly.kpxe"
install -m 0644 "$efi_src" "$PXE_TFTP_ROOT/snponly.efi"
echo "Chargeurs iPXE BIOS et UEFI prêts dans $PXE_TFTP_ROOT."
