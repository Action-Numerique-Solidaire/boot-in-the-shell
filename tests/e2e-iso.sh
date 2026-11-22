#!/usr/bin/env bash
# L'ISO d'amorçage de bout en bout, comme sur une machine réelle :
#
#   1. une VM au disque interne VIERGE démarre sur l'ISO branchée en clé USB ;
#   2. Debian 13 s'installe seul, depuis le réseau, sur le disque interne
#      (jamais sur la clé), puis redémarre dessus ;
#   3. le test se connecte en SSH root / admin et vérifie : système sur le
#      disque interne, paquets BITS venus du dépôt, services actifs, interface
#      web et menu PXE servis, adresse et SSH sur la console, mises à jour
#      automatiques autorisées pour l'origine BITS.
#
# L'ISO doit être la VARIANTE DE TEST (build-bootstrap-iso.sh --test) : la
# vraie attend qu'on choisisse l'entrée d'installation, ce qu'un test ne peut
# pas faire de façon fiable sur les deux firmwares.
#
# Usage : sudo tests/e2e-iso.sh <bits-amorcage-test.iso> [uefi|bios]...
#         sudo tests/e2e-iso.sh --nettoyer
#
# Sans mode, UEFI puis BIOS. Compter 5 à 10 minutes par mode avec KVM :
# l'installation télécharge le système depuis les miroirs Debian.
#
# Variables : BITS_E2E_WORK, BITS_E2E_SUBNET, BITS_E2E_KEEP=1.
set -Eeuo pipefail

ISO="${1:?Usage: sudo e2e-iso.sh <bits-amorcage-test.iso> [uefi|bios]... | --nettoyer}"
shift || true
MODES=("$@"); [[ ${#MODES[@]} -gt 0 ]] || MODES=(uefi bios)
INSTALL_TIMEOUT="${BITS_E2E_INSTALL_TIMEOUT:-2400}"

PREFIX=bits-e2e
NET="$PREFIX-net"
BRIDGE=virbr-bitse2e
SUBNET="${BITS_E2E_SUBNET:-192.168.90}"
WORK="${BITS_E2E_WORK:-/srv/bits-e2e}"
VIRSH=(virsh -c qemu:///system)

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { printf '\n[e2e-iso %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

domaines() { for m in uefi bios; do echo "$PREFIX-iso-$m"; done; }
teardown() {
  local d
  for d in $(domaines); do
    "${VIRSH[@]}" destroy "$d" >/dev/null 2>&1 || true
    "${VIRSH[@]}" undefine "$d" --nvram >/dev/null 2>&1 \
      || "${VIRSH[@]}" undefine "$d" >/dev/null 2>&1 || true
  done
  "${VIRSH[@]}" net-destroy "$NET" >/dev/null 2>&1 || true
  "${VIRSH[@]}" net-undefine "$NET" >/dev/null 2>&1 || true
}

[[ ${EUID} -eq 0 ]] || die "À lancer avec sudo : le labo définit un réseau et des VM libvirt."
for cmd in virsh qemu-img curl sshpass ssh; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd"
done
"${VIRSH[@]}" version >/dev/null 2>&1 || die "libvirt injoignable : systemctl start libvirtd"
if [[ "$ISO" == --nettoyer ]]; then teardown; echo "Labo démonté."; exit 0; fi
[[ -f "$ISO" ]] || die "ISO introuvable : $ISO"
ISO="$(readlink -f "$ISO")"
for m in "${MODES[@]}"; do [[ "$m" =~ ^(uefi|bios)$ ]] || die "mode inconnu : $m"; done

ovmf_code="" ovmf_vars=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { ovmf_code="$c"; break; }; done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [[ -f "$v" ]] && { ovmf_vars="$v"; break; }; done

if ip -4 route show | grep -Fq "$SUBNET.0/24"; then
  die "$SUBNET.0/24 est déjà routé ici. Autre labo : BITS_E2E_SUBNET=192.168.91"
fi
DOMTYPE=qemu; [[ -w /dev/kvm ]] && DOMTYPE=kvm
log "Accélération : $DOMTYPE"

# shellcheck disable=SC2317  # appelée par le trap
final() {
  local rc=$?
  if [[ "${BITS_E2E_KEEP:-0}" == 1 ]]; then
    echo; echo "[e2e-iso] BITS_E2E_KEEP=1 : labo conservé ($WORK). Démontage : sudo $0 --nettoyer"
  else
    log "Démontage du labo"; teardown
  fi
  exit "$rc"
}
teardown
trap final EXIT
install -d -m 0755 "$WORK"

log "Réseau $NET ($SUBNET.0/24, NAT) : l'installation télécharge depuis les miroirs"
cat > "$WORK/net-iso.xml" <<EOF
<network>
  <name>$NET</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <ip address='$SUBNET.1' netmask='255.255.255.0'>
    <dhcp><range start='$SUBNET.50' end='$SUBNET.99'/></dhcp>
  </ip>
</network>
EOF
"${VIRSH[@]}" net-define "$WORK/net-iso.xml" >/dev/null
"${VIRSH[@]}" net-start "$NET" >/dev/null

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)

# Les commandes entre apostrophes sont développées sur le serveur, pas ici ;
# ${target} est une variable iPXE.
# shellcheck disable=SC2016
essai() {
  local mode="$1"
  local nom="$PREFIX-iso-$mode"
  local disque="$WORK/iso-$mode.qcow2" clog="$WORK/iso-$mode.log"
  qemu-img create -q -f qcow2 "$disque" 12G
  : > "$clog"; chmod 0666 "$clog"
  local firmware=""
  if [[ "$mode" == uefi ]]; then
    [[ -n "$ovmf_code" && -n "$ovmf_vars" ]] || die "OVMF introuvable (paquet ovmf)"
    cp -f "$ovmf_vars" "$WORK/iso-$mode-vars.fd"
    firmware="<loader readonly='yes' type='pflash'>$ovmf_code</loader>
    <nvram template='$ovmf_vars'>$WORK/iso-$mode-vars.fd</nvram>"
  fi
  # Disque interne en premier dans l'ordre d'amorçage : vierge au départ, le
  # firmware passe à la clé ; installé, il démarre dessus. C'est l'ordre d'un
  # PC réel où l'on a branché la clé sans toucher au firmware.
  cat > "$WORK/iso-$mode.xml" <<EOF
<domain type='$DOMTYPE'>
  <name>$nom</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    $firmware
  </os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_reboot>restart</on_reboot>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$disque'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='$ISO'/>
      <target dev='sda' bus='usb'/>
      <readonly/>
      <boot order='2'/>
    </disk>
    <interface type='network'>
      <source network='$NET'/>
      <model type='virtio'/>
    </interface>
    <serial type='file'>
      <source path='$clog'/>
      <target port='0'/>
    </serial>
    <video><model type='vga'/></video>
  </devices>
</domain>
EOF
  "${VIRSH[@]}" define "$WORK/iso-$mode.xml" >/dev/null
  if ! "${VIRSH[@]}" start "$nom" >/dev/null 2>"$WORK/iso-$mode.err"; then
    if [[ "$DOMTYPE" == kvm ]] && grep -qi kvm "$WORK/iso-$mode.err"; then
      DOMTYPE=qemu; "${VIRSH[@]}" undefine "$nom" --nvram >/dev/null 2>&1 || "${VIRSH[@]}" undefine "$nom" >/dev/null 2>&1 || true
      sed -i "s|<domain type='kvm'>|<domain type='qemu'>|" "$WORK/iso-$mode.xml"
      "${VIRSH[@]}" define "$WORK/iso-$mode.xml" >/dev/null; "${VIRSH[@]}" start "$nom" >/dev/null
    else
      cat "$WORK/iso-$mode.err"; die "démarrage de $nom impossible"
    fi
  fi
  local mac ip="" t0=$SECONDS
  mac="$("${VIRSH[@]}" domiflist "$nom" | awk 'NR > 2 && $5 {print $5; exit}')"
  log "$mode : installation en cours (délai max ${INSTALL_TIMEOUT}s)"

  # SSH root/admin ne répond qu'une fois le système INSTALLÉ démarré :
  # l'installateur n'ouvre pas SSH. On attend donc simplement qu'il réponde.
  while (( SECONDS - t0 < INSTALL_TIMEOUT )); do
    ip="$("${VIRSH[@]}" net-dhcp-leases "$NET" --mac "$mac" 2>/dev/null | awk '/ipv4/ {split($5, a, "/"); print a[1]}' | tail -1)"
    if [[ -n "$ip" ]] && sshpass -p admin ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null; then
      break
    fi
    "${VIRSH[@]}" domstate "$nom" 2>/dev/null | grep -q running || die "$mode : la VM s'est arrêtée"
    sleep 10
  done
  if ! sshpass -p admin ssh "${SSH_OPTS[@]}" "root@${ip:-0}" true 2>/dev/null; then
    # L'installateur affiche sur l'écran VGA : sa capture dit où il s'est arrêté.
    "${VIRSH[@]}" screenshot "$nom" "$WORK/iso-$mode-ecran.ppm" >/dev/null 2>&1 \
      && echo "Capture de l'écran : $WORK/iso-$mode-ecran.ppm"
    die "$mode : système installé injoignable en SSH root/admin après ${INSTALL_TIMEOUT}s"
  fi
  log "$mode : système installé, SSH root/admin ouvert sur $ip après $(( SECONDS - t0 ))s"
  local SSH=(sshpass -p admin ssh "${SSH_OPTS[@]}" "root@$ip")

  # La publication du premier démarrage (bits-sync) peut être encore en cours.
  local t1=$SECONDS
  until "${SSH[@]}" 'systemctl is-active --quiet bits-dnsmasq.service && systemctl is-active --quiet bits-web.service' 2>/dev/null; do
    (( SECONDS - t1 < 300 )) || {
      "${SSH[@]}" 'systemctl --no-pager status bits-sync bits-dnsmasq bits-web bits-installation; tail -30 /var/log/bits-installation.log' || true
      die "$mode : services BITS inactifs"; }
    sleep 5
  done

  local err=0
  verifier() {
    local libelle="$1"; shift
    if "$@"; then echo "  OK      $libelle"; else echo "  ÉCHEC   $libelle"; err=1; fi
  }
  verifier "système sur le disque interne, pas sur la clé" \
    "${SSH[@]}" 'findmnt -no SOURCE / | grep -q "^/dev/vda"'
  verifier "nom d'hôte bits" "${SSH[@]}" '[ "$(hostname)" = bits ]'
  verifier "paquets bits-pxe-server et bits-web installés" \
    "${SSH[@]}" 'dpkg-query -W -f="\${Status}\n" bits-pxe-server bits-web | grep -c "install ok installed" | grep -qx 2'
  verifier "dépôt BITS dans sources.list.d" \
    "${SSH[@]}" 'grep -q "releases/download/apt" /etc/apt/sources.list.d/bits.list'
  verifier "paquets venus du dépôt BITS (candidat d'origine BITS)" \
    "${SSH[@]}" 'apt-cache policy bits-pxe-server | grep -q "releases/download/apt"'
  verifier "publication au premier démarrage réussie" \
    "${SSH[@]}" '[ "$(systemctl show -p Result --value bits-sync.service)" = success ] && grep -q "Publication réussie" /var/log/bits/apply-latest.log'
  local page menu banniere
  page="$(curl -fsS --max-time 10 "http://$ip/" || true)"
  menu="$(curl -fsS --max-time 10 "http://$ip/pxe/menu.ipxe" || true)"
  # agetty exige un terminal : script lui en fournit un.
  banniere="$("${SSH[@]}" 'script -qc "agetty --show-issue" /dev/null' | tr -d '\r' || true)"
  verifier "interface web sur le port 80" grep -qF '<title>Boot in the Shell</title>' <<<"$page"
  verifier "menu PXE servi, sans image publiée" grep -q 'aucune image publiée' <<<"$menu"
  verifier "menu PXE sans choix par défaut ni délai" grep -qx 'choose target && goto ${target}' <<<"$menu"
  verifier "console : adresse de l'interface web" grep -qF "http://$ip/" <<<"$banniere"
  verifier "console : commande SSH" grep -qF "ssh root@$ip" <<<"$banniere"
  verifier "mises à jour automatiques activées" \
    "${SSH[@]}" 'apt-config dump | grep -q "APT::Periodic::Unattended-Upgrade \"1\""'
  verifier "unattended-upgrades autorise l'origine BITS" \
    "${SSH[@]}" 'unattended-upgrade --dry-run -v 2>&1 | grep -i "allowed origins" | grep -q "origin=BITS"'
  verifier "service de rattrapage non déclenché (paquets installés pendant l'installation)" \
    "${SSH[@]}" '[ "$(systemctl show -p ConditionResult --value bits-installation.service)" = no ]'

  "${VIRSH[@]}" destroy "$nom" >/dev/null 2>&1 || true
  return "$err"
}

rc=0
for m in "${MODES[@]}"; do essai "$m" || rc=1; done
echo
if (( rc == 0 )); then
  echo "[e2e-iso] SUCCÈS : installation depuis la clé, serveur BITS opérationnel au redémarrage (${MODES[*]})."
else
  echo "[e2e-iso] ÉCHEC : voir ci-dessus et les consoles dans $WORK."
fi
exit "$rc"
