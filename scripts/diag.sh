#!/bin/bash
# On-device diagnostics for boot time, power, flash wear, /boot and apt.
# Run as root on the CuBox: bash diag.sh [sample_seconds] > diag.txt 2>&1
# Changes nothing persistent: mounts debugfs and enables f2fs iostat during the sample (restored
# afterwards). Takes ~sample_seconds (default 60). The output has IPs/hostnames: don't commit it.
SAMPLE=${1:-60}
DEV=${DEV:-mmcblk0}
export LC_ALL=C

sec() { printf '\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; eval "$@" 2>&1; }

sec "system"
run 'date -Is; uname -a; uptime'
run 'cat /proc/cmdline'
run 'free -m'
run "dmesg | grep -iE 'mmc[0-9].*(error|timeout|fail|retry|crc)|I/O error|f2fs.*(error|fsck)'"
run 'journalctl -b -p warning --no-pager | tail -60'

sec "boot / initramfs"
run 'df -h /boot /'
run 'ls -l /boot'
run 'du -sh /boot/* | sort -h'
run 'systemd-analyze'
run 'systemd-analyze blame | head -20'
run 'systemd-analyze critical-chain'
run "dmesg | grep -iE 'unpack|initrd|Run /init|f2fs|mmc0|EXT4-fs'"
run "grep -E 'CONFIG_(F2FS_FS|MMC|MMC_BLOCK|MMC_SDHCI|MMC_SDHCI_PLTFM|MMC_SDHCI_DOVE|EXT4_FS|VIRTIO_BLK)=' /boot/config-\$(uname -r)"
run "grep -E '^(MODULES|COMPRESS)' /etc/initramfs-tools/initramfs.conf /etc/initramfs-tools/conf.d/* 2>/dev/null"
run "lsinitramfs /boot/initrd.img-\$(uname -r) | grep -c '\\.ko'"
run "lsinitramfs /boot/initrd.img-\$(uname -r) | grep '\\.ko' | sed 's|.*/kernel/||' | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -20"

sec "power: cpufreq / cpuidle"
c=/sys/devices/system/cpu/cpu0
run "ls $c/cpufreq $c/cpuidle"
run "grep . $c/cpufreq/* 2>/dev/null"
run "grep . $c/cpuidle/state*/{name,disable,usage,time} 2>/dev/null"
run 'cat /sys/devices/system/cpu/cpuidle/current_driver'

sec "power: drivers, power domains, radios"
run 'lsmod'
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
run 'cat /sys/kernel/debug/pm_genpd/pm_genpd_summary'
run 'cat /sys/kernel/debug/clk/clk_summary'
run 'grep -H . /sys/bus/*/devices/*/power/runtime_status 2>/dev/null | grep -v unsupported'
run 'rfkill list'
run 'hciconfig -a 2>/dev/null || bluetoothctl show'
run 'ls /sys/class/drm /sys/class/graphics'
run 'cat /sys/class/drm/*/status /sys/class/drm/*/enabled'
run 'lsusb; lsusb -t'
run 'ip -s link'
run 'ethtool eth0'

sec "power: timers, services, CPU"
run 'systemctl list-timers --all'
run 'systemctl list-units --type=service --state=running --no-pager'
run 'systemctl --failed --no-pager'
run 'top -bn1 -w 200 | head -25'
run 'cat /proc/loadavg'

sec "activity over ${SAMPLE}s (interrupts, context switches, disk writes)"
i1=$(mktemp); d1=$(mktemp); s1=$(mktemp)
cat /proc/interrupts > "$i1"; grep -E " $DEV(p[0-9]+)? " /proc/diskstats > "$d1"; grep -E '^(ctxt|intr) ' /proc/stat > "$s1"
f2=/sys/fs/f2fs/${DEV}p2
w1=$(cat $f2/lifetime_write_kbytes 2>/dev/null)
ios=$(cat $f2/iostat_enable 2>/dev/null)
[ -z "$ios" ] || echo 1 > $f2/iostat_enable
pio() { for f in /proc/[0-9]*/io; do p=${f%/io}; p=${p#/proc/}
    w=$(sed -n 's/^write_bytes: //p' "$f" 2>/dev/null) && [ -n "$w" ] && echo "$p $w $(cat /proc/$p/comm 2>/dev/null)"; done; }
p1=$(mktemp); pio > "$p1"
sleep "$SAMPLE"
w2=$(cat $f2/lifetime_write_kbytes 2>/dev/null)
printf '\n$ interrupt deltas (count/%ss)\n' "$SAMPLE"
awk 'NR==FNR { if (FNR>1) { k=$1; s=0; for (i=2;i<=NF && $i ~ /^[0-9]+$/;i++) s+=$i; a[k]=s }; next }
     FNR>1 { k=$1; s=0; for (i=2;i<=NF && $i ~ /^[0-9]+$/;i++) s+=$i; d=s-a[k]
             if (d>0) { t=""; for (; i<=NF; i++) t=t " " $i; printf "%8d %s%s\n", d, k, t } }' \
    "$i1" /proc/interrupts | sort -rn
printf '\n$ /proc/stat deltas\n'
grep -E '^(ctxt|intr) ' /proc/stat | awk 'NR==FNR { a[$1]=$2; next } { print $1, $2-a[$1] }' "$s1" -
printf '\n$ diskstats deltas (sectors written, writes)\n'
grep -E " $DEV(p[0-9]+)? " /proc/diskstats | paste "$d1" - | awk '{ n=NF/2; print $3, "sectors_written=" $(n+10)-$10, "writes=" $(n+8)-$8 }'
[ -n "$w1" ] && echo "f2fs lifetime_write_kbytes delta: $((w2 - w1)) KiB"
printf '\n$ per-process write_bytes deltas (KiB/%ss)\n' "$SAMPLE"
pio | awk 'NR==FNR { a[$1]=$2; next } { d=$2-a[$1]; if (d>0) printf "%8d %s %s\n", d/1024, $1, $3 }' "$p1" - | sort -rn | head -20
if [ -n "$ios" ]; then
    run "cat /proc/fs/f2fs/${DEV}p2/iostat_info"
    echo "$ios" > $f2/iostat_enable
fi
rm -f "$i1" "$d1" "$s1" "$p1"

sec "flash wear"
run "grep . /sys/fs/f2fs/${DEV}p2/{features,lifetime_write_kbytes,gc_urgent,gc_idle,discard_granularity,iostat_enable} 2>/dev/null"
run "awk -v d=$DEV '\$3 ~ d { printf \"%s written_since_boot=%d MiB\\n\", \$3, \$10/2048 }' /proc/diskstats"
run 'cat /sys/kernel/debug/f2fs/status'
run "grep -E ' (/|/boot|/tmp|/var/log|/var/lib/mpd/music) ' /proc/mounts"
run "awk '\$2 == \"/\" { n=split(\$4, o, \",\"); for (i=1;i<=n;i++) if (o[i] ~ /discard|background_gc/) print o[i] }' /proc/mounts"
run 'systemctl list-timers fstrim.timer --no-pager'
run 'cat /etc/fstab'
run 'journalctl --header | grep -iE "file path|disk usage"; journalctl --disk-usage'
run 'ls -la /var/log /var/log/mpd /var/lib/mpd'
run "find / -xdev -type f -mmin -60 ! -path '/proc/*' ! -path '/sys/*' -printf '%TT %10s %p\\n' 2>/dev/null | sort | tail -50"
run "cat /sys/block/$DEV/device/{name,manfid,oemid,date,type} 2>/dev/null"
run "cat /sys/block/$DEV/queue/{scheduler,discard_max_bytes,rotational}"

sec "/boot"
run "tune2fs -l /dev/${DEV}p1 | grep -iE 'state|mount count|features|last checked|errors'"

sec "mpd / CIFS"
run 'systemctl show mpd -p Restart -p NRestarts -p ActiveState -p SubState -p ExecMainStatus'
run 'systemctl status --no-pager var-lib-mpd-music.automount var-lib-mpd-music.mount mpd'
run 'journalctl -b --no-pager -u mpd -u var-lib-mpd-music.mount -u var-lib-mpd-music.automount | tail -40'

sec "cron"
run 'systemctl is-enabled cron; systemctl is-active cron'
run 'ls /etc/cron.d /etc/cron.daily /etc/cron.hourly'

sec "apt"
run 'du -sh /var/lib/apt/lists /var/cache/apt /var/lib/dpkg'
run "apt-config dump | grep -iE 'recommends|suggests|languages|gzipindexes|periodic|unattended'"
run "dpkg-query -Wf '\${Installed-Size}\\t\${Package}\\n' | sort -n | tail -25"
run "dpkg-query -Wf '\${Installed-Size}\\n' | awk '{s+=\$1} END {printf \"total installed: %d MiB\\n\", s/1024}'"
llvm=$(dpkg-query -Wf '${Package}\n' 'libllvm*' 2>/dev/null | head -1)
[ -n "$llvm" ] && run "apt-cache rdepends --installed $llvm"
run 'apt-mark showmanual'
run 'tail -20 /var/log/unattended-upgrades/unattended-upgrades.log'
