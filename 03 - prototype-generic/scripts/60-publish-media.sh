#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

download_dir="$PXE_DATA_MOUNT/downloads"
menu_file="$PXE_HTTP_ROOT/menu.ipxe"
exports_file=/etc/exports.d/generic-pxe.exports
dnsmasq_file=/etc/dnsmasq.d/generic-pxe.conf
samba_file=/etc/samba/generic-pxe-shares.conf
mount_tmp=/mnt/generic-pxe-import
ipxe_source="$PXE_BUILD_ROOT/ipxe/src"
backup_dir="/var/backups/generic-pxe-$(date '+%Y%m%d-%H%M%S')"

mountpoint -q "$PXE_DATA_MOUNT" || die "$PXE_DATA_MOUNT n'est pas monté."
[[ -s "$ipxe_source/bin/undionly.kpxe" && -s "$ipxe_source/bin-x86_64-efi/snponly.efi" ]] || die "Chargeurs iPXE absents."

install -d -m 0700 "$backup_dir"
for existing in "$menu_file" "$exports_file" "$dnsmasq_file" "$samba_file"; do
  [[ -e "$existing" ]] && cp -a "$existing" "$backup_dir/"
done

cleanup() { findmnt -rn "$mount_tmp" >/dev/null 2>&1 && umount "$mount_tmp" || true; }
trap cleanup EXIT
install -d -m 0755 "$PXE_HTTP_ROOT" "$PXE_TFTP_ROOT" "$PXE_NFS_MOUNT_ROOT" "$mount_tmp" /etc/exports.d
install -m 0644 "$ipxe_source/bin/undionly.kpxe" "$PXE_TFTP_ROOT/undionly.kpxe"
install -m 0644 "$ipxe_source/bin-x86_64-efi/snponly.efi" "$PXE_TFTP_ROOT/snponly.efi"

network_address="$(python3 - "$PXE_SUBNET_CIDR" <<'PY'
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=True).network_address)
PY
)"

cat > "$dnsmasq_file" <<EOF
port=0
interface=$PXE_INTERFACE
bind-interfaces
dhcp-range=$network_address,proxy
enable-tftp
tftp-root=$PXE_TFTP_ROOT
dhcp-userclass=set:ipxe,iPXE
dhcp-match=set:ipxe,175
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:ipxe,http://$PXE_IP/pxe/menu.ipxe
dhcp-boot=tag:!ipxe,tag:efi64,snponly.efi,,$PXE_IP
dhcp-boot=tag:!ipxe,tag:!efi64,undionly.kpxe,,$PXE_IP
pxe-service=tag:!ipxe,BC_EFI,"iPXE UEFI",snponly.efi,$PXE_IP
pxe-service=tag:!ipxe,X86-64_EFI,"iPXE UEFI x64",snponly.efi,$PXE_IP
pxe-service=tag:!ipxe,x86PC,"iPXE BIOS",undionly.kpxe,$PXE_IP
log-dhcp
EOF

cat > "$menu_file" <<'EOF'
#!ipxe
dhcp
:menu
menu Serveur PXE
item --gap -- ---------------- Systèmes et outils ----------------
EOF
: > "$exports_file"
: > "$samba_file"
windows_enabled=no

append_fstab() { grep -Fqx "$1" /etc/fstab || printf '%s\n' "$1" >> /etc/fstab; }

while IFS='|' read -r enabled id type filename url sha label; do
  [[ "$enabled" == "yes" ]] || continue
  safe_id "$id"
  source_file="$download_dir/$filename"
  [[ -f "$source_file" ]] || die "Média absent : $source_file"

  case "$type" in
    casper-iso)
      media_iso="$PXE_DATA_MOUNT/iso/$filename"
      install -m 0444 "$source_file" "$media_iso"
      mount -o loop,ro "$media_iso" "$mount_tmp"
      vmlinuz="$(find "$mount_tmp" -maxdepth 3 -type f -name 'vmlinuz*' | head -n1)"
      initrd="$(find "$mount_tmp" -maxdepth 3 -type f \( -name initrd -o -name 'initrd.*' \) | head -n1)"
      [[ -n "$vmlinuz" && -n "$initrd" ]] || die "Noyau ou initrd introuvable dans $filename"
      install -d -m 0755 "$PXE_HTTP_ROOT/$id"
      install -m 0644 "$vmlinuz" "$PXE_HTTP_ROOT/$id/vmlinuz"
      install -m 0644 "$initrd" "$PXE_HTTP_ROOT/$id/initrd"
      umount "$mount_tmp"
      nfs_mount="$PXE_NFS_MOUNT_ROOT/$id"
      install -d -m 0755 "$nfs_mount"
      append_fstab "$media_iso $nfs_mount iso9660 loop,ro,nofail 0 0"
      mountpoint -q "$nfs_mount" || mount "$nfs_mount"
      printf '%s %s(ro,sync,no_subtree_check)\n' "$nfs_mount" "$PXE_SUBNET_CIDR" >> "$exports_file"
      cat >> "$menu_file" <<EOF
item $id $label
EOF
      ;;
    clonezilla-zip)
      media_dir="$PXE_DATA_MOUNT/clonezilla/$id"
      install -d -m 0755 "$media_dir"
      unzip -j -o "$source_file" live/vmlinuz live/initrd.img live/filesystem.squashfs -d "$media_dir"
      ln -sfn "$media_dir" "$PXE_HTTP_ROOT/$id"
      install -d -o nobody -g nogroup -m 0775 "$PXE_DATA_MOUNT/clonezilla-images"
      printf '%s %s(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534)\n' "$PXE_DATA_MOUNT/clonezilla-images" "$PXE_SUBNET_CIDR" >> "$exports_file"
      cat >> "$menu_file" <<EOF
item $id $label
EOF
      ;;
    windows-iso)
      windows_enabled=yes
      media_dir="$PXE_DATA_MOUNT/windows/$id"
      install -d -m 0755 "$media_dir" "$PXE_HTTP_ROOT/$id"
      mount -o loop,ro "$source_file" "$mount_tmp"
      rsync -aH --delete "$mount_tmp/" "$media_dir/"
      umount "$mount_tmp"
      ln -sfn "$media_dir" "$PXE_HTTP_ROOT/$id/media"
      wimboot="$PXE_HTTP_ROOT/$id/wimboot"
      if [[ ! -f "$wimboot" ]]; then curl -fL "$WIMBOOT_URL" -o "$wimboot"; fi
      printf '%s  %s\n' "$WIMBOOT_SHA256" "$wimboot" | sha256sum -c -
      cat > "$PXE_HTTP_ROOT/$id/install.bat" <<EOF
@echo off
wpeinit
net use Z: \\\\$PXE_IP\\pxe_$id /user:Guest ""
Z:\\setup.exe
EOF
      cat > "$PXE_HTTP_ROOT/$id/winpeshl.ini" <<'EOF'
[LaunchApps]
"%SYSTEMROOT%\System32\cmd.exe", "/c X:\install.bat"
EOF
      cat >> "$samba_file" <<EOF
[pxe_$id]
path = $media_dir
read only = yes
guest ok = yes
browseable = yes
hosts allow = $PXE_SUBNET_CIDR
EOF
      cat >> "$menu_file" <<EOF
item $id $label
EOF
      ;;
  esac
done < <(enabled_media)

cat >> "$menu_file" <<'EOF'
item shell Console iPXE
item reboot Redémarrer
choose target && goto ${target}
EOF

while IFS='|' read -r enabled id type filename url sha label; do
  [[ "$enabled" == "yes" ]] || continue
  case "$type" in
    casper-iso)
      cat >> "$menu_file" <<EOF
:$id
kernel http://$PXE_IP/pxe/$id/vmlinuz initrd=initrd boot=casper netboot=nfs nfsroot=$PXE_IP:$PXE_NFS_MOUNT_ROOT/$id ip=dhcp ---
initrd http://$PXE_IP/pxe/$id/initrd
boot || goto failed
EOF
      ;;
    clonezilla-zip)
      cat >> "$menu_file" <<EOF
:$id
kernel http://$PXE_IP/pxe/$id/vmlinuz initrd=initrd.img boot=live config components locales=fr_FR.UTF-8 keyboard-layouts=fr ocs_prerun="mount -t nfs -o vers=3 $PXE_IP:$PXE_DATA_MOUNT/clonezilla-images /home/partimag" ocs_live_run=ocs-live-general ocs_live_batch=no fetch=http://$PXE_IP/pxe/$id/filesystem.squashfs
initrd http://$PXE_IP/pxe/$id/initrd.img
boot || goto failed
EOF
      ;;
    windows-iso)
      cat >> "$menu_file" <<EOF
:$id
kernel http://$PXE_IP/pxe/$id/wimboot quiet
initrd http://$PXE_IP/pxe/$id/media/boot/bcd BCD
initrd http://$PXE_IP/pxe/$id/media/boot/boot.sdi boot.sdi
initrd http://$PXE_IP/pxe/$id/media/sources/boot.wim boot.wim
initrd http://$PXE_IP/pxe/$id/winpeshl.ini winpeshl.ini
initrd http://$PXE_IP/pxe/$id/install.bat install.bat
boot || goto failed
EOF
      ;;
  esac
done < <(enabled_media)

cat >> "$menu_file" <<'EOF'
:shell
shell
goto menu
:failed
echo Échec du démarrage
prompt Appuyer sur une touche pour revenir au menu
goto menu
:reboot
reboot
EOF

if [[ "$windows_enabled" == yes ]]; then
  grep -Fq 'include = /etc/samba/generic-pxe-shares.conf' /etc/samba/smb.conf || \
    printf '\ninclude = /etc/samba/generic-pxe-shares.conf\n' >> /etc/samba/smb.conf
fi

systemctl daemon-reload
exportfs -ra
dnsmasq --test
nginx -t
[[ "$windows_enabled" == no ]] || testparm -s >/dev/null
echo "Médias et configurations PXE publiés."
echo "Sauvegarde des configurations précédentes : $backup_dir"
