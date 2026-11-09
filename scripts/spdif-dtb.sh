#!/bin/sh
# Add the internal S/PDIF (Toslink) sound card to the CuBox DTB. Run once at build time by
# customize.sh on the image kernel's DTB; the result in /etc/flash-kernel/dtbs/ is frozen:
# flash-kernel appends it to every later kernel (Dove's DT no longer changes; a rebuild regenerates it).
# Mainline dove-cubox.dts enables audio1 (kirkwood-i2s, Si5351 extclk, spdifo pinmux) but has
# no sound card. The packaged DTB has no __symbols__, so this edits it with fdtput instead of an overlay.
# usage: spdif-dtb.sh IN.dtb OUT.dtb   (host tools: fdtput, fdtget, dtc)
set -eu
src=$1
out=$2
a=/mbus/internal-regs/audio-controller@b4000
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp "$src" "$tmp"
fdtget "$tmp" $a compatible >/dev/null   # fail loudly if the audio node moved
if fdtget "$tmp" /sound compatible >/dev/null 2>&1; then
    echo "spdif-dtb.sh: $src already has a /sound node" >&2; exit 1
fi
max=$(dtc -q -I dtb -O dts "$tmp" | sed -n 's/.*phandle = <\(0x[0-9a-f]*\)>.*/\1/p' |
      while read -r h; do printf '%d\n' "$h"; done | sort -n | tail -1)
ph=$((max + 1)); ph2=$((max + 2))
fdtput -t i "$tmp" $a phandle $ph
fdtput -t i "$tmp" $a '#sound-dai-cells' 1
fdtput -c "$tmp" /spdif-out
fdtput -t s "$tmp" /spdif-out compatible linux,spdif-dit
fdtput -t i "$tmp" /spdif-out '#sound-dai-cells' 0
fdtput -t i "$tmp" /spdif-out phandle $ph2
fdtput -c -p "$tmp" /sound/simple-audio-card,cpu /sound/simple-audio-card,codec
fdtput -t s "$tmp" /sound compatible simple-audio-card
fdtput -t s "$tmp" /sound simple-audio-card,name CuBox-SPDIF
# kirkwood set_fmt rejects an unset format; it only affects the I2S lines, not S/PDIF
fdtput -t s "$tmp" /sound simple-audio-card,format i2s
# DAI 1 of kirkwood-i2s is "spdif"
fdtput -t i "$tmp" /sound/simple-audio-card,cpu sound-dai $ph 1
fdtput -t i "$tmp" /sound/simple-audio-card,codec sound-dai $ph2
mkdir -p "${out%/*}"
cp "$tmp" "$out"
