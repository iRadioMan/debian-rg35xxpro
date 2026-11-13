#!/bin/sh
# Acceptance / inventory run on the RG35XX Pro. Read-only: nothing is changed.
# Usage on the device:  sh device-acceptance.sh
# Exit code: number of FAIL lines (0 = everything the script can check passed).
set -u

fail=0
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
note() { printf '     %s\n' "$1"; }
sec()  { printf '\n=== %s ===\n' "$1"; }

sec "identity"
note "uname: $(uname -sr)"
note "debian: $(cat /etc/debian_version 2>/dev/null)"
note "cmdline: $(cat /proc/cmdline)"
[ "$(uname -r)" = "7.1.2" ] && ok "kernel 7.1.2" || bad "kernel is $(uname -r), expected 7.1.2"
case "$(cat /etc/debian_version 2>/dev/null)" in 13*) ok "Debian 13";; *) bad "not Debian 13";; esac

sec "services"
for u in ssh systemd-networkd systemd-resolved wpa_supplicant@wlan0; do
  st=$(systemctl is-active "$u" 2>/dev/null)
  [ "$st" = "active" ] && ok "$u active" || bad "$u is '$st'"
done
systemctl is-active boot-report.service >/dev/null 2>&1 && ok "boot-report service present" || note "boot-report not present (older image)"

sec "network"
ip -br a 2>&1
if iw dev wlan0 link 2>/dev/null | grep -q '^Connected to'; then
  ok "wlan0 associated: $(iw dev wlan0 link | awk '/SSID/{print $2}')"
  note "signal: $(iw dev wlan0 link | awk '/signal/{print $2, $3}')"
else
  bad "wlan0 not associated"
fi
ip -4 addr show wlan0 2>/dev/null | grep -q 'inet ' && ok "wlan0 has IPv4" || bad "wlan0 has no IPv4"
iw reg get 2>/dev/null | head -3

sec "gpu / drm"
ls -l /dev/dri 2>&1
if [ -e /dev/dri/card0 ]; then ok "/dev/dri/card0"; else bad "/dev/dri/card0 missing"; fi
if [ -e /dev/dri/renderD128 ]; then ok "/dev/dri/renderD128"; else bad "render node missing"; fi
dmesg 2>/dev/null | grep -qi 'panfrost 1800000.gpu: mali-g31' && ok "panfrost bound to Mali-G31" || bad "panfrost not bound"
dmesg 2>/dev/null | grep -qi 'mali_kbase' && bad "BSP mali_kbase loaded (should be panfrost only)" || ok "no mali_kbase"

sec "framebuffer / panel"
for f in /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/bits_per_pixel; do
  [ -r "$f" ] && note "$f = $(cat "$f")"
done
dmesg 2>/dev/null | grep -i 'panel-mipi' | tail -3
dmesg 2>/dev/null | grep -qi 'panel-mipi.*loaded successfully' && ok "panel firmware loaded" || note "panel firmware line not found"

sec "egl / gles (surfaceless)"
if command -v eglinfo >/dev/null 2>&1; then
  EGL_PLATFORM=surfaceless eglinfo -B 2>&1 | grep -iE 'vendor|renderer|version' | head -6
  EGL_PLATFORM=surfaceless eglinfo -B 2>&1 | grep -qi 'panfrost\|Mali-G31' && ok "EGL renderer is Panfrost/Mali-G31" || bad "EGL renderer not Mali-G31"
else
  bad "eglinfo missing"
fi

sec "kmscube (5 s, must not crash)"
if command -v kmscube >/dev/null 2>&1; then
  # the modeset device is sun4i-drm (card1 here), not panfrost (card0 = render-only GPU)
  MODESET=""
  for c in /sys/class/drm/card*/device/uevent; do
    [ -r "$c" ] || continue
    if grep -q 'DRIVER=sun4i-drm' "$c"; then
      card=$(echo "$c" | sed -n 's#.*/drm/\(card[0-9][0-9]*\)/device/uevent#\1#p')
      [ -n "$card" ] && MODESET=/dev/dri/$card
      break
    fi
  done
  note "modeset card: ${MODESET:-none}"
  if [ -n "$MODESET" ]; then
    timeout 5 kmscube -D "$MODESET" >/tmp/kmscube.log 2>&1
    rc=$?
    if [ $rc -eq 124 ] || [ $rc -eq 0 ]; then ok "kmscube ran on $MODESET (rc=$rc)"; else bad "kmscube failed rc=$rc"; fi
    grep -iE 'renderer|vendor' /tmp/kmscube.log | head -2
    tail -2 /tmp/kmscube.log
  else
    bad "no sun4i-drm modeset card found"
  fi
else
  bad "kmscube missing"
fi

sec "input devices"
grep -E '^N:|^H:' /proc/bus/input/devices 2>/dev/null | paste - - 2>/dev/null | head -20
if [ -e /dev/input/js0 ] || grep -qi 'joypad\|gpio-keys-gamepad' /proc/bus/input/devices 2>/dev/null; then
  ok "gamepad buttons device present ($(ls /dev/input/js* 2>/dev/null | tr '\n' ' '))"
else
  bad "no gamepad buttons device"
fi
grep -qi 'gpio-keys-volume\|Volume' /proc/bus/input/devices && ok "volume keys device present" || bad "volume keys device missing"
grep -qi 'Keyboard' /proc/bus/input/devices && ok "USB keyboard present" || note "no USB keyboard attached"

sec "usb"
lsusb 2>/dev/null | head -10

sec "storage"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | head -15
[ -b /dev/mmcblk1 ] && ok "second SD slot has a card (/dev/mmcblk1)" || note "no card in second slot"
dmesg 2>/dev/null | grep -i 'mmc1:\|mmc2:' | tail -4

sec "audio"
cat /proc/asound/cards 2>/dev/null
if command -v aplay >/dev/null 2>&1; then aplay -l 2>/dev/null | head -8; else note "alsa-utils not installed (aplay/amixer)"; fi
grep -q 'sun4i-codec' /proc/asound/cards 2>/dev/null && ok "sun4i-codec card present" || bad "no sun4i-codec card"
grep -q 'Headphone Jack' /proc/bus/input/devices 2>/dev/null && ok "headphone jack detect device present" || note "no jack-detect input device"
if command -v amixer >/dev/null 2>&1; then amixer -c 0 scontrols 2>/dev/null | head -10; fi

sec "memory"
free -m
swapon --show 2>/dev/null || true
zramctl 2>/dev/null || note "zram not configured"
ps -eo rss,comm --sort=-rss 2>/dev/null | head -8

printf '\n=== FAILURES: %s ===\n' "$fail"
exit "$fail"
