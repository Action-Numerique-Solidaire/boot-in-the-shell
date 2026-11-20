#!/usr/bin/env bash
# Démarre l'ISO live dans QEMU et vérifie qu'elle atteint réellement un système
# utilisable, en attendant le marqueur émis par bits-live-ready.service.
#
# Ce test existe parce qu'une ISO peut contenir tous les bons fichiers et
# paniquer au démarrage : le contrôle El Torito prouve que les deux modes
# d'amorçage sont déclarés, pas que le système démarre. L'ISO a par ailleurs
# été BIOS seul pendant un mois sans que rien ne le signale.
#
# Ne demande NI root, NI libvirt : n'importe qui peut le lancer.
#
# Usage : tests/boot-test.sh <image> [bios|uefi] [timeout_s] [cdrom|disque]
#
# « disque » présente l'image comme une clé USB plutôt que comme un CD :
# c'est ce qu'il faut pour tester une clé fabriquée par
# tools/creer-cle-usb.sh, dont la table de partitions et le chargeur sont
# justement ce qu'on veut éprouver.
set -Eeuo pipefail

ISO="${1:?Usage: boot-test.sh <image> [bios|uefi] [timeout_s] [cdrom|disque]}"
MODE="${2:-bios}"
TIMEOUT="${3:-900}"
SUPPORT="${4:-cdrom}"
MARKER="BITS-LIVE-READY"
# Motifs d'échec : sans eux, un noyau qui panique ne se distingue pas d'un
# démarrage lent, et le test attendrait son délai entier pour rien.
FAILURES='Kernel panic|Attempted to kill init|No init found|Failed to mount|Entering emergency mode|You are in emergency mode|Unable to find a medium'

[[ -f "$ISO" ]] || { echo "ERREUR : introuvable : $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "ERREUR : qemu-system-x86_64 absent" >&2; exit 1; }
case "$MODE" in bios|uefi) ;; *) echo "ERREUR : mode inconnu : $MODE (bios|uefi)" >&2; exit 1 ;; esac
case "$SUPPORT" in cdrom|disque) ;; *) echo "ERREUR : support inconnu : $SUPPORT (cdrom|disque)" >&2; exit 1 ;; esac

workdir="$(mktemp -d)"
log="$workdir/boot.log"
trap 'rm -rf "$workdir"' EXIT

qemu_args=(
  # 2,5 Gio : le live monte son squashfs et travaille dans un overlay en RAM.
  -m 2560 -smp 2
  -display none
  -serial "file:$log"
  -no-reboot
  # Une carte réseau en mode utilisateur suffit et évite que
  # network-online.target attende son délai complet faute de lien, ce qui
  # ajouterait deux minutes à chaque exécution.
  -nic "user,model=virtio-net-pci"
)

if [[ "$SUPPORT" == "disque" ]]; then
  # usb-storage derrière un contrôleur xHCI : au plus près d'une vraie clé,
  # donc le test éprouve le même chemin d'amorçage que le matériel.
  qemu_args+=(
    -drive "file=$ISO,format=raw,if=none,id=cle"
    -device "qemu-xhci,id=xhci"
    -device "usb-storage,bus=xhci.0,drive=cle"
  )
else
  qemu_args+=(-cdrom "$ISO")
fi

# L'accélération KVM n'est pas disponible sur un runner GitHub : on retombe sur
# l'émulation, plus lente mais suffisante pour un test d'amorçage.
if [[ -w /dev/kvm ]]; then
  qemu_args+=(-enable-kvm -cpu host)
  echo "[boot-test] KVM disponible"
else
  # Emulation : la TCG multi-thread repartit les vCPU sur plusieurs fils de
  # l'hote, ce qui compte sur un runner GitHub (4 cœurs, pas de KVM). Passe
  # sans condition : si la cible ne gere pas la MTTCG, QEMU emet un
  # avertissement et retombe de lui-meme en mono-thread. Pas de sonde, parce
  # qu'un QEMU lance pour tester un drapeau reste bloque faute de disque.
  qemu_args+=(-accel "tcg,thread=multi")
  echo "[boot-test] pas de KVM, emulation logicielle (plus lent)"
fi

if [[ "$MODE" == "uefi" ]]; then
  ovmf_code=""
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/ovmf/OVMF.fd; do
    [[ -f "$c" ]] && { ovmf_code="$c"; break; }
  done
  [[ -n "$ovmf_code" ]] || { echo "ERREUR : firmware OVMF introuvable (paquet ovmf)" >&2; exit 1; }
  ovmf_vars_src=""
  for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f "$v" ]] && { ovmf_vars_src="$v"; break; }
  done
  [[ -n "$ovmf_vars_src" ]] || { echo "ERREUR : variables OVMF introuvables" >&2; exit 1; }
  cp "$ovmf_vars_src" "$workdir/vars.fd"
  qemu_args+=(
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code"
    -drive "if=pflash,format=raw,unit=1,file=$workdir/vars.fd"
  )
fi

echo "[boot-test] mode=$MODE timeout=${TIMEOUT}s iso=$ISO"
started=$SECONDS
qemu-system-x86_64 "${qemu_args[@]}" &
qemu_pid=$!
# shellcheck disable=SC2064
trap "kill $qemu_pid 2>/dev/null || true; rm -rf '$workdir'" EXIT

deadline=$(( SECONDS + TIMEOUT ))
status=1
while (( SECONDS < deadline )); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "[boot-test] QEMU s'est arrete avant le marqueur"
    break
  fi
  if grep -qa "$MARKER" "$log" 2>/dev/null; then
    echo "[boot-test] MARQUEUR TROUVE apres $(( SECONDS - started ))s : $(grep -ha "$MARKER" "$log" | head -1)"
    status=0
    break
  fi
  if grep -qaE "$FAILURES" "$log" 2>/dev/null; then
    echo "[boot-test] ECHEC detecte dans la console serie :"
    grep -haE "$FAILURES" "$log" | head -5
    status=2
    break
  fi
  sleep 3
done

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true

if (( status == 1 )); then
  echo "[boot-test] DELAI DEPASSE sans marqueur ni panique"
fi
echo "----- 40 dernieres lignes de la console serie -----"
tail -40 "$log" 2>/dev/null || echo "(console vide)"
echo "---------------------------------------------------"
exit "$status"
