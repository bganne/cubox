#!/bin/bash
# qemu virt boot of build/cubox-trixie.img (via a qcow2 overlay; the image is never modified).
# Usage: qemu-test.sh run|test|ssh [cmd...]   (env from Makefile: IMAGE, ROOT_UUID)
# TEST_APT=1 (make test TEST_APT=1): also apt-get update in the guest and report upgradable packages.
# SSH access: throwaway key in build/, injected via systemd credential ssh.authorized_keys.root.
set -euo pipefail
mode=${1:-test}; shift || true
: "${IMAGE:?}" "${ROOT_UUID:?}"
B=build/qemu; mkdir -p "$B"
KEY=$B/id_ed25519
SSH=(ssh -i "$KEY" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10
     # one connection reused by all checks: each new login costs ~1s under TCG
     -o ControlMaster=auto -o "ControlPath=$B/ssh-%C" -o ControlPersist=60
     root@127.0.0.1)

# Defaults (default qemu user net: guest gets 10.0.2.15 via DHCP). local/qemu-test.sh may override
# QEMU_NIC, EXPECTED_FAILED_RE and define local_tests (called after the generic tests; may use
# r, pass, bad; must not access /boot, whose idle unmount is being timed).
QEMU_NIC="user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22"
EXPECTED_FAILED_RE='^$'
local_tests() { :; }
# shellcheck disable=SC1091
[ ! -f local/qemu-test.sh ] || . ./local/qemu-test.sh

if [ "$mode" = ssh ]; then exec "${SSH[@]}" "$@"; fi

[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C qemu-test -f "$KEY"

# --- extract kernel + initrd from p1 (no root) ---
read -r start size < <(sfdisk -d "$IMAGE" | sed -n 's/^.*1 *: *start= *\([0-9]*\), *size= *\([0-9]*\),.*/\1 \2/p' | head -1)
dd if="$IMAGE" of="$B/p1.img" bs=512 skip="$start" count="$size" status=none
files=$(debugfs -R 'ls -p /' "$B/p1.img" 2>/dev/null | awk -F/ '{print $6}')
vmlinuz=$(echo "$files" | grep '^vmlinuz-' | sort -V | tail -1)
initrd=$(echo "$files" | grep '^initrd.img-' | sort -V | tail -1)
[ -n "$vmlinuz" ] && [ -n "$initrd" ] || { echo "kernel/initrd not found in p1" >&2; exit 1; }
debugfs -R "dump /$vmlinuz $B/vmlinuz" "$B/p1.img" 2>/dev/null
debugfs -R "dump /$initrd $B/initrd.img" "$B/p1.img" 2>/dev/null
rm -f "$B/p1.img"

# --- fresh overlay ---
rm -f "$B/overlay.qcow2"
qemu-img create -q -f qcow2 -F raw -b "$(realpath "$IMAGE")" "$B/overlay.qcow2"

cred=$(base64 -w0 < "$KEY.pub")
# single vCPU: -smp 4 with multi-threaded TCG boots this armv7 guest 2x slower (112s vs 52s to ssh)
qemu_cmd=(qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -m 1G -nographic
  -kernel "$B/vmlinuz" -initrd "$B/initrd.img"
  -append "root=UUID=$ROOT_UUID rootfstype=f2fs rootwait console=ttyAMA0 net.ifnames=0 systemd.set_credential_binary=ssh.authorized_keys.root:$cred"
  -drive "if=virtio,format=qcow2,file=$B/overlay.qcow2"
  -nic "$QEMU_NIC")

if [ "$mode" = run ]; then
  echo "Booting (Ctrl-A X quits; 'make ssh' from another terminal)..." >&2
  exec "${qemu_cmd[@]}"
fi

# --- automated test ---
LOG=$B/serial.log
"${qemu_cmd[@]}" -serial "file:$LOG" -monitor none -display none </dev/null >/dev/null 2>&1 &
QPID=$!
trap '"${SSH[@]}" -O exit 2>/dev/null || true; kill $QPID 2>/dev/null || true' EXIT
t0=$SECONDS
fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
r() { "${SSH[@]}" "$@"; }

echo "waiting for ssh (serial log: $LOG)..."
up=
for _ in $(seq 300); do
  kill -0 $QPID 2>/dev/null || { echo "qemu exited early"; tail -30 "$LOG"; exit 1; }
  if r true 2>/dev/null; then up=1; break; fi
  sleep 3
done
[ -n "$up" ] || { echo "FAIL: ssh never came up"; tail -30 "$LOG"; exit 1; }
echo "ssh up after $((SECONDS - t0))s"
# Kernel/initramfs update path first (slow under TCG, overlaps the end of the boot). It is the
# last /boot access: the idle unmount (x-systemd.idle-timeout=60) is checked after the other
# tests, which must not touch /boot (findmnt /boot would reset the timer: read /proc/mounts).
bootfs() { r "awk '\$2 == \"/boot\" { print \$3 }' /proc/mounts"; }
# apt-get update runs in the guest in the background, collected at the end
[ "${TEST_APT:-}" != 1 ] || r 'systemd-run -q --unit=test-apt sh -c "{ if apt-get -qq update; then apt list --upgradable 2>/dev/null | grep -c / || true; else echo \"apt-get update failed\"; fi; } > /run/test-apt.tmp; mv /run/test-apt.tmp /run/test-apt"' \
  || bad "could not start apt-get update"

before=$(r 'stat -c %Y /boot/uInitrd /boot/boot.scr')
sleep 2
if r 'update-initramfs -u' >"$B/uirfs.log" 2>&1; then
  after=$(r 'stat -c %Y /boot/uInitrd /boot/boot.scr')
  [ "$(echo "$before" | sed -n 1p)" != "$(echo "$after" | sed -n 1p)" ] && pass "uInitrd mtime changed" || bad "uInitrd mtime unchanged"
  [ "$(echo "$before" | sed -n 2p)" != "$(echo "$after" | sed -n 2p)" ] && pass "boot.scr mtime changed" || bad "boot.scr mtime unchanged"
  r 'mkimage -l /boot/uImage' >/dev/null && pass "mkimage -l /boot/uImage valid" || bad "uImage invalid"
  # boot.scr falls back to this pair (overlay/etc/flash-kernel/ubootenv.d/50-bak-fallback)
  r 'mkimage -l /boot/uImage.bak && mkimage -l /boot/uInitrd.bak' >/dev/null \
    && pass "uImage.bak/uInitrd.bak fallback pair valid" || bad "uImage.bak/uInitrd.bak missing or invalid"
else
  bad "update-initramfs -u failed"; tail -20 "$B/uirfs.log"
fi


state=$(r 'systemctl is-system-running --wait' || true)
if [ "$state" = running ]; then pass "system running"
else
  echo "state: $state"; r 'systemctl --failed --no-legend' || true
  unexpected=$(r 'systemctl --failed --no-legend --plain' | awk '{print $1}' | grep -Ev "$EXPECTED_FAILED_RE" || true)
  [ -z "$unexpected" ] && pass "system $state (only expected failures)" || bad "system $state; unexpected failed units: $unexpected"
fi

ip=$(r 'ip -4 -o addr show eth0' || true)
[ -n "$ip" ] && pass "eth0 has an address: $(echo "$ip" | awk '{print $4}')" || bad "eth0 has no IPv4 address"

r 'systemctl is-enabled apt-daily-upgrade.timer' >/dev/null 2>&1 && pass "apt-daily-upgrade.timer enabled" || bad "apt-daily-upgrade.timer not enabled"
[ "$(r 'apt-config shell X Unattended-Upgrade::Automatic-Reboot' 2>/dev/null)" = "X='true'" ] && pass "unattended-upgrades auto-reboot on" || bad "unattended-upgrades auto-reboot off"
opts=$(r 'findmnt -no OPTIONS /' || true)
echo "$opts" | grep -qw noatime && pass "/ mounted noatime" || bad "/ not mounted noatime"
echo "$opts" | grep -qw background_gc=off && pass "/ mounted background_gc=off" || bad "/ lacks background_gc=off: $opts"
echo "$opts" | grep -qw discard && bad "/ mounted with online discard: $opts" || pass "/ mounted without online discard"
r 'grep -qw inode_checksum /sys/fs/f2fs/vda2/features && grep -qw sb_checksum /sys/fs/f2fs/vda2/features' \
  && pass "f2fs has inode/sb checksums" || bad "f2fs lacks inode/sb checksums"
bootfs 2>/dev/null | grep -qx autofs && pass "/boot is an automount" || bad "/boot is not an automount"
prio=$(r 'systemctl show -p Nice -p IOSchedulingClass apt-daily-upgrade.service' || true)
echo "$prio" | grep -qx 'Nice=19' && echo "$prio" | grep -Eqx 'IOSchedulingClass=(3|idle)' \
  && pass "apt-daily-upgrade runs at low CPU/IO priority" || bad "apt-daily-upgrade lowprio drop-in not applied"
r '! systemctl is-active -q cron.service' && pass "no cron daemon" || bad "cron is running"
r '! ls /var/log/journal/*/*.journal >/dev/null 2>&1 && ls /run/log/journal/*/*.journal >/dev/null' && pass "journal is volatile" || bad "journal not volatile"

# must not touch /boot
local_tests

# /boot (last accessed by the update-initramfs test) is unmounted again: only the autofs is left
idle=
for _ in $(seq 36); do
  if m=$(bootfs 2>/dev/null) && [ "$m" = autofs ]; then idle=1; break; fi
  sleep 5
done
[ -n "$idle" ] && pass "/boot unmounted when idle" || bad "/boot still mounted after 180s idle"

if [ "${TEST_APT:-}" = 1 ]; then
  # informational: the archive moves daily; expect 0 right after 'make refresh'
  apt=
  for _ in $(seq 60); do apt=$(r 'cat /run/test-apt 2>/dev/null' || true); [ -z "$apt" ] || break; sleep 5; done
  echo "INFO: upgradable packages after apt-get update: $(echo "$apt" | head -1 | grep . || echo unknown) ('make refresh' rebuilds the base)"
fi

r 'poweroff' || true
for _ in $(seq 60); do kill -0 $QPID 2>/dev/null || break; sleep 2; done
if kill -0 $QPID 2>/dev/null; then bad "qemu did not exit after poweroff"; else pass "poweroff"; fi

echo "total time $((SECONDS - t0))s"
[ $fail = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
