#!/usr/bin/env bash
# Les paquets BITS de bout en bout, dans un labo jetable :
#
#   1. un Debian 13 réel (image cloud officielle) installe les .deb par apt ;
#   2. Killbit est activé et publié : par l'interface web si bits-web est
#      fourni (comme le ferait un utilisateur, depuis l'hôte), sinon par
#      « bitsctl apply » ;
#   3. un client BIOS puis un client UEFI démarrent par le réseau, atteignent
#      le menu, choisissent Killbit, et le serveur constate qu'ils ont chargé
#      noyau et initrd en HTTP puis monté leur racine en NFS.
#
# Le labo a son propre pont, en NAT : apt doit joindre les miroirs Debian. Le
# DHCP de libvirt tient le rôle du routeur du site ; le serveur sous test ne
# fait que du ProxyDHCP, comme en production.
#
# Usage : sudo tests/e2e-paquet.sh <bits-pxe-server.deb> [bits-web.deb] [killbit.iso]
#         sudo tests/e2e-paquet.sh --nettoyer
#
#   Les arguments sont reconnus à leur extension.
#   killbit.iso : copie locale de l'image Killbit publiée, pour ne pas la
#   retélécharger. Sans elle, le serveur la télécharge depuis la release.
#
# Variables : BITS_E2E_WORK (travail, défaut /srv/bits-e2e), BITS_E2E_SUBNET
#             (3 premiers octets), BITS_E2E_KEEP=1 (garder le labo).
set -Eeuo pipefail

[[ $# -ge 1 ]] || { echo "Usage: sudo e2e-paquet.sh <bits-pxe-server.deb> [bits-web.deb] [killbit.iso] | --nettoyer" >&2; exit 2; }
DEBS=() MEDIA="" WEB=0
if [[ "$1" != --nettoyer ]]; then
  for a in "$@"; do
    case "$a" in
      *.deb) [[ -f "$a" ]] || { echo "ERREUR : paquet introuvable : $a" >&2; exit 1; }
             DEBS+=("$(readlink -f "$a")"); [[ "$(basename "$a")" == bits-web_* ]] && WEB=1 ;;
      *.iso) MEDIA="$a" ;;
      *)     echo "ERREUR : argument non reconnu (ni .deb ni .iso) : $a" >&2; exit 2 ;;
    esac
  done
fi
SERVER_TIMEOUT="${BITS_E2E_SERVER_TIMEOUT:-1200}"
CLIENT_TIMEOUT="${BITS_E2E_CLIENT_TIMEOUT:-300}"

PREFIX=bits-e2e
NET="$PREFIX-net"
BRIDGE=virbr-bitse2e
SUBNET="${BITS_E2E_SUBNET:-192.168.90}"
WORK="${BITS_E2E_WORK:-/srv/bits-e2e}"
CACHE="$WORK/cache"
SERVER="$PREFIX-server"
CLIENT_BIOS="$PREFIX-client-bios"
CLIENT_UEFI="$PREFIX-client-uefi"
VIRSH=(virsh -c qemu:///system)

CLOUD_BASE=https://cloud.debian.org/images/cloud/trixie/latest
CLOUD_IMG=debian-13-genericcloud-amd64.qcow2

READY=BITS-E2E-READY          # paquets installés (et publiés sans bits-web)
FAILED=BITS-E2E-FAILED
MENU_MARKER='Console iPXE'   # une entrée du menu, en ASCII : lisible sur toute console

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[e2e-paquet %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

teardown() {
  local d
  for d in "$CLIENT_UEFI" "$CLIENT_BIOS" "$SERVER"; do
    "${VIRSH[@]}" destroy "$d" >/dev/null 2>&1 || true
    "${VIRSH[@]}" undefine "$d" --nvram >/dev/null 2>&1 \
      || "${VIRSH[@]}" undefine "$d" >/dev/null 2>&1 || true
  done
  "${VIRSH[@]}" net-destroy "$NET" >/dev/null 2>&1 || true
  "${VIRSH[@]}" net-undefine "$NET" >/dev/null 2>&1 || true
}

# --- Préalables ---------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "À lancer avec sudo : le labo définit un réseau et des VM libvirt."
for cmd in virsh qemu-img xorriso curl sshpass ssh; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd (paquets : libvirt-clients libvirt-daemon-system qemu-utils xorriso curl sshpass openssh-client)"
done
"${VIRSH[@]}" version >/dev/null 2>&1 || die "libvirt injoignable : systemctl start libvirtd"

if [[ "$1" == "--nettoyer" ]]; then teardown; echo "Labo démonté."; exit 0; fi
[[ ${#DEBS[@]} -ge 1 ]] || die "Aucun paquet .deb donné."
[[ -z "$MEDIA" || -f "$MEDIA" ]] || die "Image Killbit introuvable : $MEDIA"

ovmf_code="" ovmf_vars=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { ovmf_code="$c"; break; }; done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [[ -f "$v" ]] && { ovmf_vars="$v"; break; }; done
[[ -n "$ovmf_code" && -n "$ovmf_vars" ]] || die "Firmware OVMF introuvable (paquet ovmf)."

if ip -4 route show | grep -Fq "$SUBNET.0/24"; then
  die "$SUBNET.0/24 est déjà routé sur cette machine. Choisir un autre labo : BITS_E2E_SUBNET=192.168.91"
fi

DOMTYPE=qemu
[[ -w /dev/kvm ]] && DOMTYPE=kvm
log "Accélération : $DOMTYPE"

# Même repli que tests/e2e-pxe.sh : libvirt lance QEMU sous son propre
# utilisateur, qui n'a pas toujours accès à /dev/kvm.
demarrer_domaine() {
  local nom="$1" xml="$2"
  local err="${WORK:?}/start-$nom.err"
  "${VIRSH[@]}" define "$xml" >/dev/null
  if "${VIRSH[@]}" start "$nom" >/dev/null 2>"$err"; then return 0; fi
  if [[ "$DOMTYPE" == kvm ]] && grep -qi kvm "$err"; then
    echo "AVERTISSEMENT : libvirt ne peut pas utiliser KVM, bascule en émulation." >&2
    DOMTYPE=qemu
    "${VIRSH[@]}" undefine "$nom" >/dev/null 2>&1 || true
    sed -i "s|<domain type='kvm'>|<domain type='qemu'>|" "$xml"
    "${VIRSH[@]}" define "$xml" >/dev/null
    "${VIRSH[@]}" start "$nom" >/dev/null
    return 0
  fi
  cat "$err" >&2
  die "Démarrage du domaine $nom impossible."
}

# shellcheck disable=SC2317  # appelée par le trap
final() {
  local rc=$?
  if [[ "${BITS_E2E_KEEP:-0}" == 1 ]]; then
    echo; echo "[e2e-paquet] BITS_E2E_KEEP=1 : labo conservé, journaux dans $WORK."
    echo "[e2e-paquet] Serveur : ssh root@${server_ip:-?} (mot de passe admin). Démontage : sudo $0 --nettoyer"
  else
    log "Démontage du labo"
    teardown
  fi
  exit "$rc"
}

log "Purge d'un labo précédent éventuel"
teardown
trap final EXIT
install -d -m 0755 "$WORK" "$CACHE"
find "$WORK" -maxdepth 1 -type f \( -name '*.log' -o -name '*.fd' -o -name '*.xml' -o -name '*.err' -o -name 'seed.iso' -o -name 'server.qcow2' \) -delete

# --- 1. Image Debian 13 -------------------------------------------------------
# Mise en cache et vérifiée contre le SHA512SUMS publié avec elle.
log "Image cloud Debian 13"
curl -fsSL "$CLOUD_BASE/SHA512SUMS" -o "$CACHE/SHA512SUMS"
attendu="$(awk -v f="$CLOUD_IMG" '$2 == f {print $1}' "$CACHE/SHA512SUMS")"
[[ -n "$attendu" ]] || die "$CLOUD_IMG absent de $CLOUD_BASE/SHA512SUMS"
if [[ ! -f "$CACHE/$CLOUD_IMG" ]] || ! printf '%s  %s\n' "$attendu" "$CACHE/$CLOUD_IMG" | sha512sum -c --status -; then
  echo "  téléchargement de $CLOUD_IMG"
  curl -fsSL "$CLOUD_BASE/$CLOUD_IMG" -o "$CACHE/$CLOUD_IMG.part"
  printf '%s  %s\n' "$attendu" "$CACHE/$CLOUD_IMG.part" | sha512sum -c --status - || die "Empreinte de $CLOUD_IMG incorrecte"
  mv -f "$CACHE/$CLOUD_IMG.part" "$CACHE/$CLOUD_IMG"
fi
echo "  $CLOUD_IMG vérifiée"
# Disque du serveur : une couche au-dessus de l'image en cache, agrandie pour
# tenir les images servies.
qemu-img create -q -f qcow2 -b "$CACHE/$CLOUD_IMG" -F qcow2 "$WORK/server.qcow2" 20G

# --- 2. Réseau du labo ----------------------------------------------------------
log "Réseau $NET ($SUBNET.0/24, NAT, DHCP $SUBNET.50-99)"
cat > "$WORK/net.xml" <<EOF
<network>
  <name>$NET</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <ip address='$SUBNET.1' netmask='255.255.255.0'>
    <dhcp><range start='$SUBNET.50' end='$SUBNET.99'/></dhcp>
  </ip>
</network>
EOF
"${VIRSH[@]}" net-define "$WORK/net.xml" >/dev/null
"${VIRSH[@]}" net-start "$NET" >/dev/null

# --- 3. Serveur : cloud-init installe les paquets ------------------------------------
# Les paquets voyagent dans user-data (quelques dizaines de Ko) : pas de serveur
# à monter sur l'hôte, ni de règle de pare-feu à supposer.
fichiers_deb=""
for d in "${DEBS[@]}"; do
  fichiers_deb+="  - path: /root/debs/$(basename "$d")
    encoding: b64
    content: $(base64 -w0 "$d")
"
done
media_disk=""
media_step="echo 'Pas d image locale : Killbit sera téléchargé.'"
if [[ -n "$MEDIA" ]]; then
  # Sans ordre d'amorçage, ce disque n'est pas amorçable : l'image Killbit est
  # hybride, et avec un simple <boot dev='hd'/> SeaBIOS démarrait dessus au
  # lieu du disque système.
  media_disk="    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='$(readlink -f "$MEDIA")'/>
      <target dev='vdb' bus='virtio'/>
      <serial>bitsmedia</serial>
      <readonly/>
    </disk>"
  # Copiée sous le nom du catalogue : l'étape 40 la vérifie contre l'empreinte
  # publiée et ne télécharge rien.
  media_step="install -d /srv/bits-data/downloads && dd if=/dev/disk/by-id/virtio-bitsmedia of=/srv/bits-data/downloads/killbit-live.iso bs=4M status=none && echo 'Image Killbit locale copiée.'"
fi

cat > "$WORK/meta-data" <<EOF
instance-id: bits-e2e-$(date +%s)
local-hostname: bits
EOF
cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
  users:
    - {name: root, password: admin, type: text}
write_files:
  - path: /etc/ssh/sshd_config.d/bits-e2e.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
$fichiers_deb  - path: /root/e2e.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Journal complet dans un fichier, relu par SSH en cas d'échec. Seuls
      # les marqueurs passent par /dev/kmsg, que le noyau recopie sur la
      # console : écrire directement sur /dev/ttyS0 ne marche pas, car
      # serial-getty révoque (vhangup) les descripteurs déjà ouverts dessus.
      exec > /var/log/bits-e2e.log 2>&1
      marque() { echo "\$*" > /dev/kmsg; echo "\$*"; }
      ip=\$(ip -4 -o addr show scope global | awk '{print \$4; exit}')
      fail() { marque "$FAILED \${ip%/*} \$*"; exit 1; }
      systemctl restart ssh
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q || fail "apt-get update"
      t0=\$(date +%s)
      apt-get install -y -q /root/debs/*.deb || fail "apt install"
      marque "BITS-E2E-ETAPE paquets installés en \$(( \$(date +%s) - t0 )) s"
      $media_step
      if [ -e /usr/share/bits-web/bits-web.py ]; then
        # L'hôte pilote la suite par l'interface web.
        marque "$READY \$ip web"
        exit 0
      fi
      bitsctl media enable killbit || fail "media enable"
      t0=\$(date +%s)
      bitsctl apply; rc=\$?
      marque "BITS-E2E-ETAPE publication : code \$rc en \$(( \$(date +%s) - t0 )) s"
      [ \$rc -eq 0 ] || fail "bitsctl apply (code \$rc)"
      marque "$READY \$ip"
runcmd:
  - [/root/e2e.sh]
EOF
xorriso -as mkisofs -quiet -o "$WORK/seed.iso" -V cidata -J -R "$WORK/user-data" "$WORK/meta-data" 2>/dev/null

server_log="$WORK/server.log"
: > "$server_log"; chmod 0666 "$server_log"
cat > "$WORK/server.xml" <<EOF
<domain type='$DOMTYPE'>
  <name>$SERVER</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>2</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_reboot>restart</on_reboot>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$WORK/server.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
$media_disk
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$WORK/seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='$NET'/>
      <model type='virtio'/>
    </interface>
    <serial type='file'>
      <source path='$server_log'/>
      <target port='0'/>
    </serial>
    <!-- Sans carte vidéo, le GRUB de l'image cloud (gfxpayload=keep) échoue
         à lancer le noyau et relance l'entrée sans fin. QEMU seul en ajoute
         une d'office ; libvirt n'en crée pas si le domaine n'en déclare pas. -->
    <video><model type='vga'/></video>
  </devices>
</domain>
EOF
demarrer_domaine "$SERVER" "$WORK/server.xml"

log "Serveur : démarrage, installation du paquet et publication (délai max ${SERVER_TIMEOUT}s)"
server_ip=""
deadline=$(( SECONDS + SERVER_TIMEOUT )); started=$SECONDS
while (( SECONDS < deadline )); do
  if grep -qa "$READY" "$server_log"; then
    server_ip="$(grep -hao "$READY [0-9.]*" "$server_log" | head -1 | awk '{print $2}')"
    log "Serveur prêt après $(( SECONDS - started ))s sur $server_ip"
    break
  fi
  if grep -qa "$FAILED" "$server_log"; then
    ip_echec="$(grep -hao "$FAILED [0-9.]*" "$server_log" | head -1 | awk '{print $2}')"
    echo "----- journal du serveur (/var/log/bits-e2e.log) -----"
    sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=10 "root@$ip_echec" 'tail -60 /var/log/bits-e2e.log; tail -30 /var/log/bits/apply-latest.log 2>/dev/null' || true
    die "Échec sur le serveur : $(grep -hao "$FAILED.*" "$server_log" | head -1)"
  fi
  "${VIRSH[@]}" domstate "$SERVER" 2>/dev/null | grep -q running || { tail -40 "$server_log"; die "La VM serveur s'est arrêtée."; }
  sleep 5
done
[[ -n "$server_ip" ]] || { tail -60 "$server_log"; die "Délai dépassé sans marqueur $READY."; }
grep -hao "BITS-E2E-ETAPE.*" "$server_log" | sed 's/^BITS-E2E-ETAPE /  /'

SSH=(sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "root@$server_ip")
"${SSH[@]}" true || die "SSH root/admin refusé sur $server_ip"

# --- 3 bis. Publication par l'interface web, comme un utilisateur ---------------------
if (( WEB )); then
  log "Interface web : http://$server_ip/"
  curl -fsS --max-time 10 "http://$server_ip/" | grep -qF "<title>Boot in the Shell</title>" \
    || die "Page d'accueil de l'interface injoignable sur le port 80"
  api() { curl -fsS --max-time 30 -H "X-BITS-Requete: 1" -H "Content-Type: application/json" "$@"; }
  champ() {  # champ <clé python> : lit une valeur dans /api/etat
    curl -fsS --max-time 10 "http://$server_ip/api/etat" 2>/dev/null \
      | python3 -c 'import json, sys; d = json.load(sys.stdin); k = next(m for m in d["medias"] if m["id"] == "killbit"); print(eval(sys.argv[1]))' "$1" 2>/dev/null || echo "?"
  }

  # « Télécharger » : l'image est récupérée et vérifiée, rien n'est publié.
  t0=$SECONDS
  api -X POST -d '{}' "http://$server_ip/api/media/killbit/telecharger" >/dev/null \
    || die "Téléchargement de Killbit refusé par l'interface"
  until [[ "$(champ 'd["publication"]["en_cours"]')" == False && "$(champ 'k["telecharge"] is not None')" == True ]]; do
    (( SECONDS - t0 < SERVER_TIMEOUT )) || die "Téléchargement de Killbit non terminé"
    sleep 3
  done
  echo "  Killbit téléchargé par l'interface en $(( SECONDS - t0 ))s, sans publication"
  [[ "$(champ 'k["active"]')" == False ]] || die "« Télécharger » a activé Killbit"
  if curl -fsS --max-time 10 "http://$server_ip/pxe/menu.ipxe" 2>/dev/null | grep -q '^item killbit '; then
    die "« Télécharger » a publié Killbit dans le menu PXE"
  fi
  taille_srv="$("${SSH[@]}" 'stat -c %s /srv/bits-data/downloads/killbit-live.iso')"
  taille_http="$(curl -fsSI --max-time 10 "http://$server_ip/telechargements/killbit-live.iso" | awk 'tolower($1) == "content-length:" { print $2 + 0 }')"
  [[ -n "$taille_http" && "$taille_http" == "$taille_srv" ]] \
    || die "Image non récupérable par /telechargements/ (HTTP $taille_http octets, serveur $taille_srv)"
  echo "  image récupérable par le navigateur : /telechargements/killbit-live.iso ($taille_http octets)"

  api -X POST -d '{"active": true}' "http://$server_ip/api/media/killbit" >/dev/null \
    || die "Activation de Killbit refusée par l'interface"
  echo "  Killbit activé par l'interface"
  t0=$SECONDS
  api -X POST -d '{}' "http://$server_ip/api/appliquer" >/dev/null || die "Publication refusée par l'interface"
  echo "  publication lancée par l'interface"
  etat_killbit=""
  while (( SECONDS - t0 < SERVER_TIMEOUT )); do
    etat_json="$(curl -fsS --max-time 10 "http://$server_ip/api/etat" || true)"
    [[ -n "$etat_json" ]] || etat_json='{}'
    read -r en_cours etat_killbit resultat < <(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
k = next(m for m in d["medias"] if m["id"] == "killbit")
der = d["publication"]["derniere"] or {}
print(d["publication"]["en_cours"], k["etat"].replace(" ", "_"), der.get("resultat", "aucune").replace(" ", "_"))
' "$etat_json" 2>/dev/null || echo "? ? ?")
    [[ "$en_cours" == False && "$etat_killbit" == "publié" ]] && break
    [[ "$en_cours" == False && "$resultat" == "échec" ]] && break
    sleep 3
  done
  echo "  état après $(( SECONDS - t0 ))s : killbit $etat_killbit, publication $resultat"
  if [[ "$etat_killbit" != "publié" || "$resultat" != "réussie" ]]; then
    "${SSH[@]}" 'tail -30 /var/log/bits/apply-latest.log' || true
    die "La publication lancée par l'interface n'a pas abouti."
  fi
  # Version servie notée, et égale à la copie téléchargée : l'interface ne
  # doit rien proposer à republier.
  # shellcheck disable=SC2016  # évalué sur le serveur
  "${SSH[@]}" 'grep -qx "killbit $(cat /srv/bits-data/downloads/killbit-live.iso.sha256)" /var/lib/bits/versions-publiees' \
    || die "Version publiée de Killbit non notée dans /var/lib/bits/versions-publiees"
  python3 -c '
import json, sys
k = next(m for m in json.loads(sys.argv[1])["medias"] if m["id"] == "killbit")
assert k["version"] and k["version"] == k["version_publiee"], k
' "$(curl -fsS --max-time 10 "http://$server_ip/api/etat")" || die "Versions téléchargée et publiée différentes dans l'état"
  v_json="$(curl -fsS --max-time 60 "http://$server_ip/api/media/killbit/version")" || die "/api/media/killbit/version injoignable"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["a_jour"] is True and d["flottante"] is True, d' "$v_json" \
    || die "Dernière version de Killbit : $v_json"
  echo "  version publiée notée ; dernière version de Killbit vérifiée en amont : à jour"
fi

# --- 4. Contrôle depuis l'hôte ------------------------------------------------------
log "Contrôle des services depuis l'hôte"
curl -fsS --max-time 30 "http://$server_ip/pxe/menu.ipxe" -o "$WORK/menu.ipxe" || die "menu.ipxe inaccessible en HTTP"
grep -q '^#!ipxe' "$WORK/menu.ipxe" || die "menu.ipxe n'est pas un script iPXE"
grep -q '^item killbit ' "$WORK/menu.ipxe" || die "Killbit absent du menu"
# shellcheck disable=SC2016  # ${target} est une variable iPXE, littérale ici
grep -q '^choose target && goto ${target}$' "$WORK/menu.ipxe" || die "Le menu a un choix par défaut ou un délai"
echo "  HTTP  menu.ipxe : $(wc -l < "$WORK/menu.ipxe") lignes, Killbit présent, aucun choix par défaut"
for loader in undionly.kpxe snponly.efi menu.ipxe; do
  curl -fsS --max-time 60 "tftp://$server_ip/$loader" -o "$WORK/tftp-$loader" || die "$loader inaccessible en TFTP"
  echo "  TFTP  $loader : $(du -h "$WORK/tftp-$loader" | cut -f1)"
done

# --- 5. Clients : menu, choix de Killbit, démarrage réel ---------------------------
# Le menu n'a pas de choix par défaut : le test appuie sur Entrée, ce qui
# choisit la première entrée, Killbit. Le serveur doit alors voir le client
# charger noyau et initrd en HTTP, puis ouvrir une connexion NFS.
client_test() {
  local name="$1" mode="$2"
  local clog="$WORK/$name.log"
  : > "$clog"; chmod 0666 "$clog"
  local firmware
  if [[ "$mode" == uefi ]]; then
    cp -f "$ovmf_vars" "$WORK/$name-vars.fd"
    firmware="<loader readonly='yes' type='pflash'>$ovmf_code</loader>
    <nvram template='$ovmf_vars'>$WORK/$name-vars.fd</nvram>"
  else
    # useserial : SeaBIOS recopie la console sur la ligne série.
    firmware="<bios useserial='yes' rebootTimeout='-1'/>"
  fi
  cat > "$WORK/$name.xml" <<EOF
<domain type='$DOMTYPE'>
  <name>$name</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    $firmware
    <boot dev='network'/>
  </os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_reboot>destroy</on_reboot>
  <devices>
    <interface type='network'>
      <source network='$NET'/>
      <model type='e1000'/>
    </interface>
    <serial type='file'>
      <source path='$clog'/>
      <target port='0'/>
    </serial>
  </devices>
</domain>
EOF
  demarrer_domaine "$name" "$WORK/$name.xml"
  local mac cip=""
  mac="$("${VIRSH[@]}" domiflist "$name" | awk 'NR > 2 && $5 {print $5; exit}')"

  log "Client $mode : attente du menu (délai max ${CLIENT_TIMEOUT}s)"
  local cdl=$(( SECONDS + CLIENT_TIMEOUT )) cstart=$SECONDS
  until grep -qa "$MENU_MARKER" "$clog"; do
    (( SECONDS < cdl )) || { tail -40 "$clog"; echo "::error::client $mode : menu non atteint"; return 1; }
    sleep 2
  done
  log "Client $mode : menu atteint après $(( SECONDS - cstart ))s, choix de Killbit"
  sleep 2
  "${VIRSH[@]}" send-key "$name" KEY_ENTER >/dev/null

  # Adresse du client : bail du DHCP du labo (le routeur du site).
  local _
  for _ in $(seq 30); do
    cip="$("${VIRSH[@]}" net-dhcp-leases "$NET" --mac "$mac" 2>/dev/null | awk '/ipv4/ {split($5, a, "/"); print a[1]; exit}')"
    [[ -n "$cip" ]] && break
    sleep 2
  done
  [[ -n "$cip" ]] || { echo "::error::client $mode : aucune adresse DHCP"; return 1; }

  cstart=$SECONDS
  local http=0 nfs=0
  while (( SECONDS < cdl )); do
    if (( ! http )) && "${SSH[@]}" "grep -F '$cip ' /var/log/nginx/access.log | grep -F 'GET /pxe/killbit/initrd.img' | grep -q ' 200 '"; then
      http=1; log "Client $mode ($cip) : noyau et initrd chargés en HTTP"
    fi
    if (( http )) && "${SSH[@]}" "ss -Htn state established '( sport = :2049 )' | grep -qF '$cip:'"; then
      nfs=1; log "Client $mode ($cip) : racine montée en NFS après $(( SECONDS - cstart ))s"
      break
    fi
    sleep 3
  done
  "${VIRSH[@]}" destroy "$name" >/dev/null 2>&1 || true
  if (( ! http )); then echo "::error::client $mode : Killbit non chargé en HTTP"; tail -30 "$clog"; return 1; fi
  if (( ! nfs )); then echo "::error::client $mode : pas de connexion NFS"; return 1; fi
  return 0
}

rc=0
client_test "$CLIENT_BIOS" bios || rc=1
client_test "$CLIENT_UEFI" uefi || rc=1

# --- 6. Redémarrage du serveur : la publication doit revenir seule -----------------
# bits-sync.service rejoue la publication à chaque démarrage. Sans lui, un
# serveur redémarré ne répondrait plus aux postes.
log "Redémarrage du serveur"
"${SSH[@]}" 'systemctl reboot' >/dev/null 2>&1 || true
sleep 10
t0=$SECONDS
until "${SSH[@]}" true 2>/dev/null; do
  (( SECONDS - t0 < 300 )) || die "Serveur injoignable en SSH après redémarrage"
  sleep 3
done
# shellcheck disable=SC2016  # développé sur le serveur, pas ici
until "${SSH[@]}" '[ "$(systemctl show -p ActiveState --value bits-sync.service)" = inactive ] && [ "$(systemctl show -p Result --value bits-sync.service)" = success ] && systemctl is-active --quiet bits-dnsmasq.service' 2>/dev/null; do
  if (( SECONDS - t0 > 300 )); then
    "${SSH[@]}" 'systemctl status --no-pager bits-sync.service bits-dnsmasq.service; tail -20 /var/log/bits/apply-latest.log' || true
    die "La publication n'est pas revenue après redémarrage"
  fi
  sleep 3
done
curl -fsS --max-time 10 "http://$server_ip/pxe/menu.ipxe" | grep -q '^item killbit ' || die "Menu sans Killbit après redémarrage"
echo "  publication rejouée au démarrage, bits-dnsmasq actif, Killbit au menu ($(( SECONDS - t0 ))s)"
if (( WEB )); then
  # La console doit donner l'adresse de l'interface : agetty remplace \4 par
  # l'adresse IPv4 courante.
  # agetty exige un terminal : script lui en fournit un.
  banniere="$("${SSH[@]}" 'script -qc "agetty --show-issue" /dev/null' | tr -d '\r' || true)"
  grep -qF "http://$server_ip/" <<<"$banniere" || { echo "$banniere"; die "La console n'affiche pas http://$server_ip/"; }
  echo "  console : « $(grep -F "http://$server_ip/" <<<"$banniere" | head -1) »"
fi

echo
if (( rc == 0 )); then
  echo "[e2e-paquet] SUCCÈS : paquet installé par apt, Killbit publié, clients BIOS et UEFI démarrés dessus par le réseau."
else
  echo "[e2e-paquet] ÉCHEC : voir les consoles ci-dessus et les journaux dans $WORK."
fi
exit "$rc"
