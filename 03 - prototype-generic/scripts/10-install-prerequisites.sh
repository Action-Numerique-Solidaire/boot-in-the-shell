#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  curl ca-certificates gnupg git build-essential liblzma-dev \
  dnsmasq nginx nfs-kernel-server samba wimtools unzip rsync \
  squashfs-tools parted e2fsprogs util-linux iproute2

systemctl disable --now dnsmasq nginx nfs-server smbd nmbd 2>/dev/null || true
echo "Prérequis installés. Les services PXE restent arrêtés."
