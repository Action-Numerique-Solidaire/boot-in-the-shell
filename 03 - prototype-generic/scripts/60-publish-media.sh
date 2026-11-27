#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
require_root
load_config
require_data_dir

download_dir="$PXE_DATA_MOUNT/downloads"
menu_file="$PXE_HTTP_ROOT/menu.ipxe"
exports_file=/etc/exports.d/bits.exports
dnsmasq_file="$PXE_STATE_DIR/dnsmasq.conf"
samba_file=/etc/samba/bits-shares.conf
# Compte samba des installations Windows (voir l'étape 5).
SAMBA_USER=bits-install
backup_root=/var/backups/bits
backup_dir="$backup_root/$(date '+%Y%m%d-%H%M%S')"

[[ -s "$PXE_TFTP_ROOT/undionly.kpxe" && -s "$PXE_TFTP_ROOT/snponly.efi" ]] \
  || die "Chargeurs iPXE absents de $PXE_TFTP_ROOT (étape 50)."

# --- sauvegarde des configurations écrites ici ---------------------------------
# On n'en garde que les dix dernières : la publication tourne à chaque
# démarrage et à chaque action de l'interface web.
install -d -m 0700 "$backup_dir"
for existing in "$menu_file" "$exports_file" "$dnsmasq_file" "$samba_file" /etc/fstab; do
  [[ -e "$existing" ]] && cp -a "$existing" "$backup_dir/"
done
find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort | head -n -10 | xargs -r rm -rf

install -d -m 0755 "$PXE_HTTP_ROOT" "$PXE_TFTP_ROOT" "$PXE_NFS_MOUNT_ROOT" "$PXE_STATE_DIR" /etc/exports.d

# Noms de fichiers des versions précédentes du prototype : retirés pour qu'une
# ancienne configuration ne reste pas active à côté de la nouvelle.
rm -f /etc/dnsmasq.d/generic-pxe.conf /etc/exports.d/generic-pxe.exports

mapfile -t READY < <(ready_media)
declare -A ready_ids=()
for line in "${READY[@]}"; do
  IFS='|' read -r _ id _ <<<"$line"
  safe_id "$id"
  ready_ids[$id]=1
done

# --- 1. exports NFS : uniquement les médias prêts -------------------------------
# Écrits et appliqués AVANT de démonter quoi que ce soit : un répertoire encore
# exporté ne se démonte pas proprement.
{
  for line in "${READY[@]}"; do
    IFS='|' read -r _ id type _ <<<"$line"
    case "$type" in
      casper-iso|debian-live-iso)
        # exportfs refuse un répertoire qui n'existe pas encore : on le crée
        # ici, le montage vient à l'étape 3. mkdir et non « install -d -m » :
        # à une republication, l'image y est déjà montée en lecture seule et
        # le chmod d'install échouerait.
        mkdir -p "$PXE_NFS_MOUNT_ROOT/$id"
        printf '%s %s(ro,sync,no_subtree_check)\n' "$PXE_NFS_MOUNT_ROOT/$id" "$PXE_SUBNET_CIDR" ;;
      clonezilla-zip)
        install -d -o nobody -g nogroup -m 0775 "$PXE_DATA_MOUNT/clonezilla-images"
        printf '%s %s(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534)\n' \
          "$PXE_DATA_MOUNT/clonezilla-images" "$PXE_SUBNET_CIDR" ;;
    esac
  done
} | sort -u > "$exports_file"
exportfs -ra

# --- 2. retrait des médias qui ne sont plus publiés ------------------------------
# Désactivé dans l'interface, ou écarté parce que son téléchargement a échoué :
# démonté, et ses fichiers HTTP retirés. Les téléchargements, eux, sont gardés.
while read -r mnt; do
  id="${mnt#"$PXE_NFS_MOUNT_ROOT"/}"
  [[ -n "${ready_ids[$id]:-}" ]] && continue
  log "Retrait de $id"
  umount "$mnt" 2>/dev/null || umount -l "$mnt"
  rmdir "$mnt" 2>/dev/null || true
done < <(findmnt -rn -o TARGET | awk -v r="$PXE_NFS_MOUNT_ROOT/" 'index($0, r) == 1 && substr($0, length(r) + 1) !~ /\//')

for entry in "$PXE_HTTP_ROOT"/*; do
  [[ -d "$entry" ]] || continue
  id="$(basename "$entry")"
  [[ "$id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || continue
  [[ -n "${ready_ids[$id]:-}" ]] && continue
  rm -rf "$entry"
done

# --- 3. publication des médias prêts ---------------------------------------------
fstab_lines=()
windows_enabled=no

# Monte l'image téléchargée elle-même sous la racine NFS. Plus de copie dans un
# répertoire iso/ : chaque image occupait deux fois sa taille. Si le fichier a
# changé depuis le montage (nouvelle version téléchargée), on remonte.
mount_iso() {
  local src="$1" mnt="$2" dev back
  mkdir -p "$mnt"
  if mountpoint -q "$mnt"; then
    dev="$(findmnt -no SOURCE "$mnt")"
    back="$(losetup -nO BACK-FILE "$dev" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    if [[ "$back" != "$src" ]]; then
      log "Nouvelle version de $(basename "$src") : remontage"
      umount "$mnt" 2>/dev/null || umount -l "$mnt"
    fi
  fi
  mountpoint -q "$mnt" || mount -o loop,ro "$src" "$mnt"
  fstab_lines+=("$src $mnt iso9660 loop,ro,nofail 0 0")
}

# Le noyau et l'initrd ne sont réextraits que si l'image a changé : la
# publication tourne à chaque démarrage, et recopier ~100 Mo par image à
# chaque fois n'apporte rien.
up_to_date() { [[ "$(cat "$1/.source-sha256" 2>/dev/null)" == "$2" ]]; }

for line in "${READY[@]}"; do
  IFS='|' read -r _ id type filename _ _ label <<<"$line"
  src="$download_dir/$filename"
  [[ -f "$src" ]] || die "Média absent : $src"
  sha="$(cat "$src.sha256" 2>/dev/null || sha256sum "$src" | cut -d' ' -f1)"
  http_dir="$PXE_HTTP_ROOT/$id"
  log "Publication : $label"

  case "$type" in
    casper-iso)
      mount_iso "$src" "$PXE_NFS_MOUNT_ROOT/$id"
      if ! up_to_date "$http_dir" "$sha"; then
        mnt="$PXE_NFS_MOUNT_ROOT/$id"
        vmlinuz="$(find "$mnt" -maxdepth 3 -type f -name 'vmlinuz*' | head -n1)"
        initrd="$(find "$mnt" -maxdepth 3 -type f \( -name initrd -o -name 'initrd.*' \) | head -n1)"
        [[ -n "$vmlinuz" && -n "$initrd" ]] || die "Noyau ou initrd introuvable dans $filename"
        install -d -m 0755 "$http_dir"
        install -m 0644 "$vmlinuz" "$http_dir/vmlinuz"
        install -m 0644 "$initrd" "$http_dir/initrd"
        printf '%s' "$sha" > "$http_dir/.source-sha256"
      fi
      ;;
    debian-live-iso)
      # Image Debian live (live-boot) : noyau et initrd sous /live, démarrage
      # en « boot=live ». C'est le format de l'ISO killbit d'ANS ; servie par
      # la branche casper, elle ne trouvait jamais son système de fichiers.
      mount_iso "$src" "$PXE_NFS_MOUNT_ROOT/$id"
      if ! up_to_date "$http_dir" "$sha"; then
        mnt="$PXE_NFS_MOUNT_ROOT/$id"
        vmlinuz="$(find "$mnt/live" -maxdepth 1 -type f -name 'vmlinuz*' | head -n1)"
        initrd="$(find "$mnt/live" -maxdepth 1 -type f -name 'initrd*' | head -n1)"
        [[ -n "$vmlinuz" && -n "$initrd" ]] || die "Noyau ou initrd introuvable sous /live dans $filename"
        install -d -m 0755 "$http_dir"
        install -m 0644 "$vmlinuz" "$http_dir/vmlinuz"
        install -m 0644 "$initrd" "$http_dir/initrd.img"
        printf '%s' "$sha" > "$http_dir/.source-sha256"
      fi
      ;;
    clonezilla-zip)
      media_dir="$PXE_DATA_MOUNT/clonezilla/$id"
      if ! up_to_date "$media_dir" "$sha"; then
        install -d -m 0755 "$media_dir"
        unzip -j -o "$src" live/vmlinuz live/initrd.img live/filesystem.squashfs -d "$media_dir"
        printf '%s' "$sha" > "$media_dir/.source-sha256"
      fi
      ln -sfn "$media_dir" "$http_dir"
      ;;
    windows-iso)
      windows_enabled=yes
      require_command rsync
      media_dir="$PXE_DATA_MOUNT/windows/$id"
      install -d -m 0755 "$media_dir" "$http_dir"
      if ! up_to_date "$media_dir" "$sha"; then
        mount_tmp="$(mktemp -d)"
        mount -o loop,ro "$src" "$mount_tmp"
        rsync -aH --delete --exclude=.source-sha256 "$mount_tmp/" "$media_dir/"
        umount "$mount_tmp"; rmdir "$mount_tmp"
        printf '%s' "$sha" > "$media_dir/.source-sha256"
      fi
      ln -sfn "$media_dir" "$http_dir/media"
      wimboot="$http_dir/wimboot"
      if [[ ! -f "$wimboot" ]]; then curl -fL "$WIMBOOT_URL" -o "$wimboot"; fi
      printf '%s  %s\n' "$WIMBOOT_SHA256" "$wimboot" | sha256sum -c -
      # wimboot dépose ces fichiers dans X:\Windows\System32 (pas à la racine
      # de X:). Quand le programme lancé par winpeshl.ini se termine, WinPE
      # redémarre : « cmd /k » garde une invite si install.bat échoue.
      # Fins de ligne CRLF : cmd lit mal les étiquettes (goto) d'un fichier LF.
      sed 's/$/\r/' > "$http_dir/winpeshl.ini" <<'EOF'
[LaunchApps]
"%SYSTEMROOT%\System32\cmd.exe", "/k %SYSTEMROOT%\System32\install.bat"
EOF
      sed 's/$/\r/' > "$http_dir/install.bat" <<EOF
@echo off
echo BITS : initialisation du reseau...
wpeinit
set essai=0
:montage
set /a essai+=1
net use Z: \\\\$PXE_IP\\pxe_$id /user:$SAMBA_USER $SAMBA_USER && goto setup
if %essai% GEQ 10 goto echec
echo Partage $PXE_IP injoignable, nouvel essai dans 3 s (%essai%/10)...
ping -n 4 127.0.0.1 >nul
goto montage
:setup
Z:\\setup.exe
goto fin
:echec
echo.
echo ECHEC : partage \\\\$PXE_IP\\pxe_$id injoignable.
echo Diagnostic : ipconfig, ping $PXE_IP, net use.
ipconfig
:fin
EOF
      ;;
  esac
done

# --- 4. fstab : remplacer nos lignes, garder toutes les autres -------------------
# Nos lignes sont celles dont le point de montage est sous la racine NFS de
# BITS. Écrit à côté puis renommé : un fstab tronqué empêche le démarrage.
awk -v r="$PXE_NFS_MOUNT_ROOT/" '!($0 !~ /^[[:space:]]*#/ && index($2, r) == 1)' /etc/fstab > /etc/fstab.bits-tmp
for l in "${fstab_lines[@]}"; do printf '%s\n' "$l"; done >> /etc/fstab.bits-tmp
chmod --reference=/etc/fstab /etc/fstab.bits-tmp
mv -f /etc/fstab.bits-tmp /etc/fstab
systemctl daemon-reload

# --- 5. samba : seulement si une image Windows est servie -------------------------
# Sans image Windows, samba n'est en général pas installé et /etc/samba
# n'existe pas : on ne touche à rien, on retire seulement nos partages.
if [[ "$windows_enabled" == yes ]]; then
  # Compte dédié plutôt qu'invité : Windows 11 (24H2 et après) refuse les
  # connexions SMB invitées et exige la signature, impossible sans compte.
  # Son mot de passe n'a rien de secret (il est servi en HTTP dans
  # install.bat) : il n'ouvre que les supports d'installation, en lecture
  # seule, et seulement depuis le réseau PXE.
  id "$SAMBA_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SAMBA_USER"
  printf '%s\n%s\n' "$SAMBA_USER" "$SAMBA_USER" | smbpasswd -s -a "$SAMBA_USER" >/dev/null
  : > "$samba_file"
  for line in "${READY[@]}"; do
    IFS='|' read -r _ id type _ <<<"$line"
    [[ "$type" == windows-iso ]] || continue
    cat >> "$samba_file" <<EOF
[pxe_$id]
path = $PXE_DATA_MOUNT/windows/$id
read only = yes
guest ok = no
valid users = $SAMBA_USER
browseable = yes
hosts allow = $PXE_SUBNET_CIDR
EOF
  done
  grep -Fq "include = $samba_file" /etc/samba/smb.conf || \
    printf '\ninclude = %s\n' "$samba_file" >> /etc/samba/smb.conf
elif [[ -e "$samba_file" ]]; then
  : > "$samba_file"
fi

# --- 6. dnsmasq --------------------------------------------------------------------
# Écrit dans /var/lib/bits et lu par bits-dnsmasq.service, pas par le service
# dnsmasq du système.
#
# Mode proxy : ProxyDHCP et TFTP, sans DNS. Le DHCP du réseau reste celui de
# la box ; BITS n'ajoute que les informations de démarrage.
#
# Mode passerelle : DHCP complet, DNS et TFTP sur l'interface du réseau PXE
# seule. Le DNS relaie vers les serveurs de l'amont (resolv.conf) et n'écoute
# que sur ce réseau : rien ne change côté Wi-Fi. Pas de pxe-service : en DHCP
# complet, dhcp-boot suffit, y compris pour un client déjà iPXE.
boot_commun() {
  cat <<EOF
enable-tftp
tftp-root=$PXE_TFTP_ROOT
dhcp-userclass=set:ipxe,iPXE
dhcp-match=set:ipxe,175
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:ipxe,http://$PXE_IP/pxe/menu.ipxe
dhcp-boot=tag:!ipxe,tag:efi64,snponly.efi,,$PXE_IP
dhcp-boot=tag:!ipxe,tag:!efi64,undionly.kpxe,,$PXE_IP
EOF
}

if [[ "$PXE_MODE" == passerelle ]]; then
  {
    cat <<EOF
# Écrit par bits-pxe-server (60-publish-media.sh, mode passerelle) : toute
# modification à la main est perdue à la prochaine publication.
interface=$PXE_INTERFACE
bind-interfaces
domain-needed
bogus-priv
no-hosts
dhcp-authoritative
dhcp-range=$PXE_DHCP_DEBUT,$PXE_DHCP_FIN,$PXE_NETMASK,12h
dhcp-option=option:router,$PXE_IP
dhcp-option=option:dns-server,$PXE_IP
dhcp-leasefile=$PXE_STATE_DIR/dnsmasq.leases
EOF
    boot_commun
    echo "log-dhcp"
  } > "$dnsmasq_file"
else
network_address="${PXE_SUBNET_CIDR%/*}"
{
cat <<EOF
# Écrit par bits-pxe-server (60-publish-media.sh, mode proxy) : toute
# modification à la main est perdue à la prochaine publication.
port=0
interface=$PXE_INTERFACE
bind-interfaces
dhcp-range=$network_address,proxy
EOF
boot_commun
cat <<EOF
pxe-service=tag:!ipxe,BC_EFI,"iPXE UEFI",snponly.efi,$PXE_IP
pxe-service=tag:!ipxe,X86-64_EFI,"iPXE UEFI x64",snponly.efi,$PXE_IP
pxe-service=tag:!ipxe,x86PC,"iPXE BIOS",undionly.kpxe,$PXE_IP
# Client déjà iPXE : ROM de la carte réseau, ou chargeur ci-dessus qui refait
# sa requête DHCP. En ProxyDHCP c'est pxe-service qui délivre le fichier, pas
# dhcp-boot : sans ces trois lignes, un tel client s'arrêtait sur « Nothing to
# boot ». On lui sert le menu par TFTP ; iPXE l'exécute parce qu'il commence par
# « #!ipxe ». Lui servir undionly.kpxe aurait créé une boucle.
pxe-service=tag:ipxe,x86PC,"Boot in the Shell",menu.ipxe,$PXE_IP
pxe-service=tag:ipxe,X86-64_EFI,"Boot in the Shell",menu.ipxe,$PXE_IP
pxe-service=tag:ipxe,BC_EFI,"Boot in the Shell",menu.ipxe,$PXE_IP
log-dhcp
EOF
} > "$dnsmasq_file"
fi

# --- 7. menu iPXE ----------------------------------------------------------------
# Aucune entrée par défaut et aucun délai : « choose » attend un choix. Un
# poste démarré sur le réseau par erreur ne lance jamais une installation ni un
# effacement de lui-même.
{
  cat <<EOF
#!ipxe
dhcp
:menu
menu Boot in the Shell - $PXE_IP
item --gap -- ---------------- Systèmes et outils ----------------
EOF
  if [[ ${#READY[@]} -eq 0 ]]; then
    echo "item --gap -- (aucune image publiée : les choisir dans http://$PXE_IP/)"
  fi
  for line in "${READY[@]}"; do
    IFS='|' read -r _ id _ _ _ _ label <<<"$line"
    echo "item $id $label"
  done
  cat <<'EOF'
item --gap -- ----------------------------------------------------
item local Démarrer sur le disque local
item shell Console iPXE
item reboot Redémarrer
choose target && goto ${target}
EOF

  for line in "${READY[@]}"; do
    IFS='|' read -r _ id type _ <<<"$line"
    case "$type" in
      casper-iso)
        cat <<EOF
:$id
kernel http://$PXE_IP/pxe/$id/vmlinuz initrd=initrd boot=casper netboot=nfs nfsroot=$PXE_IP:$PXE_NFS_MOUNT_ROOT/$id ip=dhcp ---
initrd http://$PXE_IP/pxe/$id/initrd
boot || goto failed
EOF
        ;;
      debian-live-iso)
        cat <<EOF
:$id
kernel http://$PXE_IP/pxe/$id/vmlinuz initrd=initrd.img boot=live components netboot=nfs nfsroot=$PXE_IP:$PXE_NFS_MOUNT_ROOT/$id ip=dhcp
initrd http://$PXE_IP/pxe/$id/initrd.img
boot || goto failed
EOF
        ;;
      clonezilla-zip)
        cat <<EOF
:$id
kernel http://$PXE_IP/pxe/$id/vmlinuz initrd=initrd.img boot=live config components locales=fr_FR.UTF-8 keyboard-layouts=fr ocs_prerun="mount -t nfs -o vers=3 $PXE_IP:$PXE_DATA_MOUNT/clonezilla-images /home/partimag" ocs_live_run=ocs-live-general ocs_live_batch=no fetch=http://$PXE_IP/pxe/$id/filesystem.squashfs
initrd http://$PXE_IP/pxe/$id/initrd.img
boot || goto failed
EOF
        ;;
      windows-iso)
        cat <<EOF
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
  done

  cat <<'EOF'
:local
# Rendre la main au firmware, qui passe au périphérique d'amorçage suivant.
exit
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
} > "$menu_file.tmp"
chmod 0644 "$menu_file.tmp"
mv -f "$menu_file.tmp" "$menu_file"

# Le menu est servi en HTTP pour les clients qui chaînent une URL, et en TFTP
# pour ceux dont la ROM iPXE reçoit un simple nom de fichier par ProxyDHCP.
install -m 0644 "$menu_file" "$PXE_TFTP_ROOT/menu.ipxe"

exportfs -ra
dnsmasq --test --conf-file="$dnsmasq_file"
nginx -t
[[ "$windows_enabled" == no ]] || testparm -s >/dev/null
echo "Publié : ${#READY[@]} média(s). Sauvegarde des configurations précédentes : $backup_dir"
