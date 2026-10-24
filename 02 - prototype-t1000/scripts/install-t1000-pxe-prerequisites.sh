#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre execute avec sudo." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  dnsmasq \
  ipxe \
  nginx \
  nfs-kernel-server \
  squashfs-tools \
  samba \
  wimtools \
  unzip \
  git \
  build-essential \
  liblzma-dev

systemctl disable --now dnsmasq 2>/dev/null || true
systemctl disable --now nginx 2>/dev/null || true
systemctl disable --now nfs-server 2>/dev/null || true
systemctl disable --now smbd 2>/dev/null || true
systemctl disable --now nmbd 2>/dev/null || true

echo
echo "Prerequis PXE installes. Les services PXE restent arretes."
