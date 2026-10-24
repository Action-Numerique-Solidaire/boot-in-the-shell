#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

source_root="$PXE_BUILD_ROOT/ipxe"
install -d -m 0755 "$PXE_BUILD_ROOT"
if [[ ! -d "$source_root/.git" ]]; then
  git clone "$IPXE_GIT_URL" "$source_root"
fi
git -C "$source_root" fetch --all --tags
git -C "$source_root" checkout --detach "$IPXE_GIT_COMMIT"

boot_script="$PXE_BUILD_ROOT/boot.ipxe"
cat > "$boot_script" <<EOF
#!ipxe
dhcp
chain http://$PXE_IP/pxe/menu.ipxe || shell
EOF

make -C "$source_root/src" clean
make -C "$source_root/src" -j2 bin/undionly.kpxe EMBED="$boot_script"
make -C "$source_root/src" -j2 bin-x86_64-efi/snponly.efi EMBED="$boot_script"
strings "$source_root/src/bin-x86_64-efi/snponly.efi" | grep -Fq "http://$PXE_IP/pxe/menu.ipxe"
echo "Chargeurs iPXE BIOS et UEFI compilés."
