#!/usr/bin/env bash
# Déroule la chaîne PXE complète dans un labo jetable : l'ISO live s'installe
# sans interaction sur un disque de données, puis deux clients — un BIOS, un
# UEFI — démarrent réellement par le réseau sur ce serveur et doivent atteindre
# le menu iPXE.
#
# C'est le test que le projet n'avait pas : la CI prouve que l'image se
# construit et expose ses deux modes d'amorçage, pas que le déploiement va au
# bout ni qu'un client démarre dessus.
#
# Le labo est sur SON PROPRE pont : il ne peut pas répondre en ProxyDHCP sur le
# réseau physique, et peut donc tourner à côté d'un labo existant sans créer
# deux répondeurs concurrents. Il est en revanche en NAT, car le pipeline
# installe des paquets et clone iPXE : sans accès sortant il échoue à l'étape 10.
#
# Usage : sudo tests/e2e-pxe.sh <image.iso> [timeout_serveur_s] [timeout_client_s]
#         sudo BITS_E2E_CLE=1 tests/e2e-pxe.sh <cle.img> [...]
#         sudo tests/e2e-pxe.sh --nettoyer
#
# BITS_E2E_CLE=1 : le support donné est une clé fabriquée par
# tools/creer-cle-usb.sh. Elle est alors présentée au serveur comme une clé USB,
# et c'est SA partition PXE_DATA et SON catalogue qui servent — aucun disque de
# données n'est créé, et rien n'est téléchargé. C'est le scénario réel de la
# clé, éprouvé de bout en bout.
#
# Variables : BITS_E2E_WORK (répertoire de travail), BITS_E2E_SUBNET (3 premiers
#             octets), BITS_E2E_KEEP=1 (conserver le labo pour inspection).
set -Eeuo pipefail

ISO="${1:?Usage: sudo e2e-pxe.sh <image.iso>|--nettoyer [timeout_serveur_s] [timeout_client_s]}"
SERVER_TIMEOUT="${2:-3600}"
CLIENT_TIMEOUT="${3:-420}"

PREFIX=bits-e2e
NET="$PREFIX-net"
BRIDGE=virbr-bitse2e
SUBNET="${BITS_E2E_SUBNET:-192.168.90}"
WORK="${BITS_E2E_WORK:-/srv/bits-e2e}"
DATA_SERIAL=bitsdata
SERVER="$PREFIX-server"
CLIENT_BIOS="$PREFIX-client-bios"
CLIENT_UEFI="$PREFIX-client-uefi"
VIRSH=(virsh -c qemu:///system)

READY=BITS-PXE-READY
FAILED=BITS-PXE-FAILED
PANIC='Kernel panic|Attempted to kill init|No init found|Entering emergency mode|Unable to find a medium'
MENU_MARKER='Serveur PXE'

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[e2e %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

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
for cmd in virsh qemu-img xorriso curl; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd (paquets : libvirt-clients libvirt-daemon-system qemu-system-x86 qemu-utils xorriso curl)"
done
"${VIRSH[@]}" version >/dev/null 2>&1 || die "libvirt injoignable. Démarrer le service : systemctl start libvirtd"

if [[ "$ISO" == "--nettoyer" ]]; then teardown; echo "Labo démonté."; exit 0; fi
[[ -f "$ISO" ]] || die "ISO introuvable : $ISO"

ovmf_code=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
  [[ -f "$c" ]] && { ovmf_code="$c"; break; }
done
[[ -n "$ovmf_code" ]] || die "Firmware OVMF introuvable (paquet ovmf) : le client UEFI ne peut pas démarrer."
ovmf_vars=""
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
  [[ -f "$v" ]] && { ovmf_vars="$v"; break; }
done
[[ -n "$ovmf_vars" ]] || die "Variables OVMF introuvables (paquet ovmf)."

# Un sous-réseau déjà routé ferait entrer le labo en collision avec le réseau
# existant : mieux vaut refuser que produire un échec incompréhensible.
if ip -4 route show | grep -Fq "$SUBNET.0/24"; then
  die "$SUBNET.0/24 est déjà routé sur cette machine. Choisir un autre labo : BITS_E2E_SUBNET=192.168.91"
fi

DOMTYPE=qemu
if [[ -w /dev/kvm ]]; then
  DOMTYPE=kvm
  log "KVM accessible ici : labo accéléré si libvirt y a droit aussi"
else
  log "pas de KVM : émulation logicielle, comptez plusieurs heures"
fi

# libvirt ne lance pas QEMU sous l'utilisateur appelant mais sous le sien
# (libvirt-qemu), qui doit pouvoir ouvrir /dev/kvm. Une ACL posée pour
# l'utilisateur de session ne lui profite pas, et le groupe de /dev/kvm n'est
# pas toujours « kvm » — vu avec un GID orphelin, où le démarrage échouait sur
# « Could not access KVM kernel module: Permission denied ». On bascule alors en
# émulation au lieu d'abandonner, pour que le test tourne chez tout le monde.
demarrer_domaine() {
  local nom="$1" xml="$2"
  local err="${WORK:?}/start-$nom.err"
  "${VIRSH[@]}" define "$xml" >/dev/null
  if "${VIRSH[@]}" start "$nom" >/dev/null 2>"$err"; then
    return 0
  fi
  if [[ "$DOMTYPE" == "kvm" ]] && grep -qi "kvm" "$err"; then
    echo "AVERTISSEMENT : libvirt ne peut pas utiliser KVM, bascule en émulation." >&2
    head -2 "$err" >&2
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

final() {
  local rc=$?
  if [[ "${BITS_E2E_KEEP:-0}" == "1" ]]; then
    echo
    echo "[e2e] BITS_E2E_KEEP=1 : labo conservé, journaux dans $WORK."
    echo "[e2e] Démontage manuel : sudo $0 --nettoyer"
  else
    log "Démontage du labo"
    teardown
  fi
  exit "$rc"
}

log "Préparation : purge d'un labo précédent éventuel"
teardown
trap final EXIT

install -d -m 0755 "${WORK:?}"
find "${WORK:?}" -maxdepth 1 -type f \( -name '*.log' -o -name '*.fd' -o -name '*.xml' \) -delete

# --- 1. Réseau du labo --------------------------------------------------------
# Une clé préparée ne doit avoir besoin d'AUCUN accès sortant : médias déjà
# présents, chargeurs iPXE déjà compilés, prérequis déjà installés. On lui
# retire donc le NAT, sinon le test ne prouverait pas le fonctionnement hors
# ligne — le pipeline irait chercher ce qui manque sur internet sans qu'on le
# voie. Le chemin ISO + disque vierge, lui, a besoin du réseau à l'étape 10 et
# à la compilation d'iPXE.
if [[ "${BITS_E2E_CLE:-0}" == "1" ]]; then
  FORWARD=""
  log "Définition du réseau $NET ($SUBNET.0/24, ISOLÉ sans accès sortant, DHCP $SUBNET.50-99)"
else
  FORWARD="  <forward mode='nat'/>"
  log "Définition du réseau $NET ($SUBNET.0/24, NAT, DHCP $SUBNET.50-99)"
fi
cat > "${WORK:?}/net.xml" <<EOF
<network>
  <name>$NET</name>
$FORWARD
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <ip address='$SUBNET.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$SUBNET.50' end='$SUBNET.99'/>
    </dhcp>
  </ip>
</network>
EOF
"${VIRSH[@]}" net-define "${WORK:?}/net.xml" >/dev/null
"${VIRSH[@]}" net-start "$NET" >/dev/null
# Le DHCP du réseau libvirt tient le rôle du routeur du site : il distribue les
# adresses. Le serveur sous test ne fait que du ProxyDHCP — c'est exactement la
# topologie de production, et c'est pour ça que le test a une valeur.

# --- 2. Noyau et initrd de l'ISO ---------------------------------------------
# Démarrage direct du noyau : c'est le seul moyen de passer bits.auto sans
# modifier l'image. Les chargeurs isolinux et GRUB sont couverts séparément par
# le contrôle El Torito et par tests/boot-test.sh.
log "Extraction du noyau et de l'initrd depuis l'ISO"
find "${WORK:?}" -maxdepth 1 -type f \( -name 'vmlinuz' -o -name 'initrd.img' -o -name 'data.qcow2' \) -delete
xorriso -osirrox on -indev "$ISO" \
  -extract /live/vmlinuz "${WORK:?}/vmlinuz" \
  -extract /live/initrd.img "${WORK:?}/initrd.img" >/dev/null 2>&1
[[ -s "${WORK:?}/vmlinuz" && -s "${WORK:?}/initrd.img" ]] || die "Extraction du noyau/initrd échouée depuis $ISO"

# --- 3. Serveur PXE sous test -------------------------------------------------
if [[ "${BITS_E2E_CLE:-0}" == "1" ]]; then
  log "Support traité comme une clé prête : ni disque de données, ni téléchargement"
else
  log "Création du disque de données (8 Gio)"
  qemu-img create -f qcow2 "${WORK:?}/data.qcow2" 8G >/dev/null
fi

if [[ "${BITS_E2E_CLE:-0}" == "1" ]]; then
  # La clé est présentée en USB, comme sur le matériel. Aucune option de disque
  # de données : l'assistant doit retrouver seul la partition PXE_DATA par son
  # étiquette, y compris sur le média de démarrage. Aucun bits.media non plus :
  # c'est le catalogue de la clé qui doit faire foi.
  CMDLINE="boot=live components console=tty0 console=ttyS0,115200 bits.auto"
  SUPPORT_XML="    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='$ISO'/>
      <target dev='sda' bus='usb'/>
    </disk>"
else
  CMDLINE="boot=live components console=tty0 console=ttyS0,115200 bits.auto bits.data-disk=/dev/disk/by-id/virtio-$DATA_SERIAL bits.media=none"
  SUPPORT_XML="    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$ISO'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${WORK:?}/data.qcow2'/>
      <target dev='vdb' bus='virtio'/>
      <serial>$DATA_SERIAL</serial>
    </disk>"
fi

server_log="${WORK:?}/server.log"
: > "$server_log"
chmod 0666 "$server_log"
cat > "${WORK:?}/server.xml" <<EOF
<domain type='$DOMTYPE'>
  <name>$SERVER</name>
  <memory unit='MiB'>3072</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <kernel>${WORK:?}/vmlinuz</kernel>
    <initrd>${WORK:?}/initrd.img</initrd>
    <cmdline>$CMDLINE</cmdline>
  </os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_reboot>destroy</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
$SUPPORT_XML
    <interface type='network'>
      <source network='$NET'/>
      <model type='virtio'/>
    </interface>
    <serial type='file'>
      <source path='$server_log'/>
      <target port='0'/>
    </serial>
  </devices>
</domain>
EOF
demarrer_domaine "$SERVER" "${WORK:?}/server.xml"

log "Installation sans interaction en cours (apt + compilation d'iPXE), délai max ${SERVER_TIMEOUT}s"
server_ip=""
deadline=$(( SECONDS + SERVER_TIMEOUT ))
started=$SECONDS
while (( SECONDS < deadline )); do
  if grep -qa "$READY" "$server_log" 2>/dev/null; then
    server_ip="$(grep -ha "$READY" "$server_log" | head -1 | awk '{print $2}' | cut -d/ -f1)"
    log "serveur prêt après $(( SECONDS - started ))s sur $server_ip"
    break
  fi
  if grep -qa "$FAILED" "$server_log" 2>/dev/null; then
    echo "----- échec annoncé par l'assistant -----"
    grep -ha "$FAILED" "$server_log" | head -3
    tail -60 "$server_log"
    die "L'installation non interactive a échoué."
  fi
  if grep -qaE "$PANIC" "$server_log" 2>/dev/null; then
    echo "----- panique au démarrage -----"
    grep -haE "$PANIC" "$server_log" | head -5
    tail -60 "$server_log"
    die "Le serveur n'a pas démarré."
  fi
  if ! "${VIRSH[@]}" domstate "$SERVER" 2>/dev/null | grep -q running; then
    tail -40 "$server_log"
    die "La VM serveur s'est arrêtée avant d'être prête."
  fi
  sleep 5
done
[[ -n "$server_ip" ]] || { tail -60 "$server_log"; die "Délai dépassé sans marqueur $READY."; }

# --- 4. Contrôle depuis l'hôte ------------------------------------------------
# L'hôte porte le pont du labo : il voit le serveur comme un client le verrait.
# Ces contrôles prouvent HTTP et TFTP sans rien supposer du client.
log "Contrôle des services depuis l'hôte ($server_ip)"
curl --fail --silent --show-error --max-time 30 "http://$server_ip/pxe/menu.ipxe" -o "${WORK:?}/menu.ipxe" \
  || die "menu.ipxe inaccessible en HTTP sur $server_ip"
grep -q '#!ipxe' "${WORK:?}/menu.ipxe" || die "menu.ipxe servi mais ce n'est pas un script iPXE."
echo "  HTTP  menu.ipxe : $(wc -l < "${WORK:?}/menu.ipxe") lignes"
for loader in undionly.kpxe snponly.efi; do
  curl --fail --silent --show-error --max-time 60 "tftp://$server_ip/$loader" -o "${WORK:?}/$loader" \
    || die "$loader inaccessible en TFTP sur $server_ip"
  echo "  TFTP  $loader : $(du -h "${WORK:?}/$loader" | cut -f1)"
done

# --- 5. Clients réels, BIOS puis UEFI -----------------------------------------
# C'est l'assertion qui manquait : un client qui démarre par le réseau doit
# recevoir la réponse ProxyDHCP, charger le bon chargeur en TFTP, lancer iPXE
# et afficher le menu servi en HTTP. Le menu contient toujours « Serveur PXE »,
# même avec un catalogue de médias vide.
client_test() {
  local name="$1" mode="$2"
  # Deux « local » distincts : dans une seule declaration, $name n'est pas
  # encore affecte quand clog l'utilise (shellcheck SC2318).
  local clog="${WORK:?}/$name.log"
  : > "$clog"; chmod 0666 "$clog"
  local firmware=""
  if [[ "$mode" == uefi ]]; then
    cp -f "$ovmf_vars" "${WORK:?}/$name-vars.fd"
    firmware="<loader readonly='yes' type='pflash'>$ovmf_code</loader>
    <nvram template='$ovmf_vars'>${WORK:?}/$name-vars.fd</nvram>"
  else
    # useserial : SeaBIOS recopie la console BIOS sur la ligne série, ce qui
    # rend lisibles les messages du ROM PXE puis d'iPXE. Sans ce drapeau tout
    # reste sur l'écran VGA et le test ne peut rien observer.
    firmware="<bios useserial='yes' rebootTimeout='-1'/>"
  fi
  cat > "${WORK:?}/$name.xml" <<EOF
<domain type='$DOMTYPE'>
  <name>$name</name>
  <memory unit='MiB'>1536</memory>
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
  demarrer_domaine "$name" "${WORK:?}/$name.xml"
  log "client $mode démarré, attente du menu iPXE (délai max ${CLIENT_TIMEOUT}s)"
  local cdl=$(( SECONDS + CLIENT_TIMEOUT )) cstart=$SECONDS
  while (( SECONDS < cdl )); do
    if grep -qa "$MENU_MARKER" "$clog" 2>/dev/null; then
      log "client $mode : MENU ATTEINT après $(( SECONDS - cstart ))s"
      "${VIRSH[@]}" destroy "$name" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 5
  done
  echo "----- console du client $mode -----"
  tail -50 "$clog" 2>/dev/null || echo "(console vide)"
  echo "-----------------------------------"
  return 1
}

rc=0
client_test "$CLIENT_BIOS" bios || { echo "::error::le client BIOS n'a pas atteint le menu iPXE"; rc=1; }
client_test "$CLIENT_UEFI" uefi || { echo "::error::le client UEFI n'a pas atteint le menu iPXE"; rc=1; }

echo
if (( rc == 0 )); then
  echo "[e2e] SUCCÈS : serveur installé sans interaction, clients BIOS et UEFI démarrés par le réseau."
else
  echo "[e2e] ÉCHEC : voir les consoles ci-dessus et les journaux dans $WORK."
fi
exit "$rc"
