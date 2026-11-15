#!/bin/sh
# Acceptance / inventory run on the RG35XX Pro. Read-only: nothing is changed.
# Usage on the device:  sh device-acceptance.sh
# Exit code: number of FAIL lines (0 = everything the script can check passed).
set -u

fail=0
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
warn() { printf 'WARN %s\n' "$1"; }
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

sec "session modes (one VT, one session)"
for u in rg35xx-es rg35xx-desktop rg35xx-terminal rg35xx-game; do
  if systemctl list-unit-files "$u.service" >/dev/null 2>&1 &&
     [ -n "$(systemctl list-unit-files "$u.service" --no-legend 2>/dev/null)" ]; then
    ok "$u.service installed (enabled=$(systemctl is-enabled "$u.service" 2>/dev/null), active=$(systemctl is-active "$u.service" 2>/dev/null))"
  else
    bad "$u.service missing"
  fi
done
[ "$(systemctl is-enabled rg35xx-es.service 2>/dev/null)" = "enabled" ] &&
  ok "ES-DE is the boot session" || bad "rg35xx-es.service is not enabled"
[ "$(systemctl is-enabled getty@tty1.service 2>/dev/null)" = "enabled" ] &&
  bad "getty@tty1 is enabled (it would grab the VT from the DRM session)" ||
  ok "getty@tty1 is not enabled"
running=0
for u in rg35xx-es rg35xx-desktop rg35xx-terminal rg35xx-game; do
  [ "$(systemctl is-active "$u.service" 2>/dev/null)" = "active" ] && running=$((running + 1))
done
[ "$running" -le 1 ] && ok "exclusive sessions: $running active" ||
  bad "$running sessions active at the same time"
for p in es-de labwc waybar retroarch; do
  if pgrep -x "$p" >/dev/null 2>&1; then note "$p running"; fi
done
if grep -q '^gamer ' /etc/sudoers.d/10-rg35xx 2>/dev/null; then
  ok "gamer has NOPASSWD sudo (rg35xx-session, PortMaster)"
else
  bad "/etc/sudoers.d/10-rg35xx missing or does not grant gamer sudo"
fi
if [ -d /run/rg35xx ]; then
  perms=$(stat -c '%U:%G %a' /run/rg35xx 2>/dev/null || true)
  [ "$perms" = "root:gamer 775" ] &&
    ok "/run/rg35xx is gamer-writable ($perms)" ||
    bad "/run/rg35xx has $perms, expected root:gamer 775 (desktop clients cannot log/start)"
else
  bad "/run/rg35xx is missing (tmpfiles was skipped?)"
fi

sec "frontend (ES-DE, cores, ports)"
if command -v es-de >/dev/null 2>&1; then
  note "es-de --version: $(es-de --version 2>&1 | head -1)"
  case "$(es-de --version 2>&1 | head -1)" in
    *3.5.0*) ok "ES-DE 3.5.0" ;;
    *) bad "unexpected ES-DE version" ;;
  esac
  miss=$(ldd /usr/bin/es-de 2>/dev/null | grep 'not found')
  [ -z "$miss" ] && ok "es-de links resolve" || bad "es-de: $miss"
else
  bad "es-de missing"
fi
cores=$(ls /usr/lib/aarch64-linux-gnu/libretro/*_libretro.so 2>/dev/null | wc -l)
[ "$cores" -gt 0 ] && ok "libretro cores: $cores" || bad "no libretro cores"
miss=$(ldd /usr/lib/aarch64-linux-gnu/libretro/*_libretro.so 2>/dev/null | grep 'not found')
[ -z "$miss" ] && ok "core libraries resolve" || bad "core: $miss"
if command -v retroarch >/dev/null 2>&1; then
  /usr/bin/retroarch --features 2>/dev/null | grep -i 'kms' | head -2
  /usr/bin/retroarch --features 2>/dev/null | grep -qE '^[[:space:]]*KMS[[:space:]].*: yes' &&
    ok "RetroArch has KMS/EGL context" || bad "RetroArch built without KMS"
else
  bad "retroarch missing"
fi
# ES-DE loads resources/systems/linuxarm on AArch64, not the x86-64 linux/ directory.
sys=/usr/share/es-de/resources/systems/linuxarm/es_systems.xml
[ -r "$sys" ] || sys=$(find /usr/share/es-de -path '*/systems/linuxarm/es_systems.xml' 2>/dev/null | head -1)
if [ -n "$sys" ] && [ -r "$sys" ]; then
  grep -A8 '<name>ports</name>' "$sys" | grep -q 'rg35xx-run-sh' &&
    ok "ports system launches through rg35xx-run-sh" || bad "ports system not patched"
  first=$(awk 'index($0, "<name>arcade</name>") { f = 1 } f && /<command / { print; exit }' "$sys")
  case "$first" in *fbneo*) ok "arcade defaults to FinalBurn Neo" ;; *) bad "arcade default core: $first" ;; esac
else
  bad "es_systems.xml not found"
fi
[ -s /usr/share/es-de/themes/linear-es-de/theme.xml ] &&
  ok "theme linear-es-de installed" || bad "theme missing (ES-DE would fall back to a dummy theme)"
rules=/usr/share/es-de/resources/systems/linuxarm/es_find_rules.xml
[ -r "$rules" ] || rules=$(find /usr/share/es-de -path '*/systems/linuxarm/es_find_rules.xml' 2>/dev/null | head -1)
if [ -n "$rules" ] && [ -r "$rules" ]; then
  grep -q '<entry>/usr/lib/aarch64-linux-gnu/libretro</entry>' "$rules" &&
    ok "ES-DE searches the arm64 core directory" || bad "es_find_rules.xml lacks the arm64 core path"
else
  bad "es_find_rules.xml not found"
fi
es_settings=/home/gamer/ES-DE/settings/es_settings.xml
if [ -r "$es_settings" ]; then
  grep -q 'name="ThemeAspectRatio" value="4:3"' "$es_settings" &&
    ok "ES-DE uses the 4:3 theme variant" || bad "ES-DE theme aspect ratio is not 4:3"
  grep -q 'name="CustomEventScripts" value="true"' "$es_settings" &&
    ok "ES-DE custom event scripts enabled (quit/poweroff/reboot)" || bad "CustomEventScripts disabled"
else
  bad "$es_settings missing"
fi
[ -x /roms/ports/PortMaster/PortMaster.sh ] && ok "PortMaster installed" || bad "PortMaster missing"
[ -x /roms/ports/PortMaster.sh ] && ok "PortMaster entry /roms/ports/PortMaster.sh" || bad "PortMaster.sh missing"
grep -q 'H700 Gamepad' /roms/ports/PortMaster/gamecontrollerdb.txt 2>/dev/null &&
  ok "PortMaster controller DB has the H700 line" || bad "PortMaster controller DB lacks H700"
grep -q 'platform-rocknix-singleadc-joypad-event-joystick' /roms/ports/PortMaster/control.txt 2>/dev/null &&
  ok "PortMaster control.txt knows the H700 by-path" ||
  bad "PortMaster control.txt lacks the H700 branch (A/B mapping will be empty)"
grep -q 'Hand-written runtime names need not follow' \
     /roms/ports/PortMaster/pylibs/harbourmaster/util.py 2>/dev/null &&
  ok "PortMaster handles list-valued runtime metadata" ||
  bad "PortMaster runtime-list patch missing (opening a port will crash)"
grep -q 'PORTMASTER_NO_SELF_UPDATE' /roms/ports/PortMaster/pugwash 2>/dev/null &&
  ok "PortMaster GUI self-update disabled (stable channel advertises the old 2024 build)" ||
  bad "PortMaster GUI self-update is enabled; it will replace 8.6.1 with the 2024 build"
dpkg --print-foreign-architectures 2>/dev/null | grep -qx armhf &&
  ok "armhf foreign architecture enabled" || bad "armhf not enabled (32-bit ports will not run)"
[ -e /lib/ld-linux-armhf.so.3 ] && ok "armhf loader present" || bad "armhf loader missing"
for d in /roms/ports /roms/desktop /roms/nes /roms/snes /roms/psx; do
  [ -d "$d" ] || bad "missing $d"
done

sec "user-data partition (/mnt/userdata -> /roms)"
nparts=$(sfdisk -d /dev/mmcblk0 2>/dev/null | grep -c '^/dev/mmcblk0p')
if [ "${nparts:-0}" -ge 3 ]; then
  ok "/dev/mmcblk0 has $nparts partitions, user-data is there"
else
  bad "/dev/mmcblk0 has ${nparts:-0} partitions: rg35xx-userdata did not create p3"
fi
fstype=$(findmnt -n -o FSTYPE /mnt/userdata 2>/dev/null || true)
[ "$fstype" = vfat ] && ok "/mnt/userdata is mounted FAT (visible in Windows)" ||
  bad "/mnt/userdata is not a FAT mount (fstype: ${fstype:-none})"
[ -d /mnt/userdata/roms ] && ok "partition root carries roms/ (one folder on the card)" ||
  bad "/mnt/userdata/roms is missing: a PC would show the system directories at the root of the card"
source=$(findmnt -n -o SOURCE /roms 2>/dev/null || true)
case "$source" in
  *'[/roms]') ok "/roms is a bind of the partition's roms/ ($source)" ;;
  *) bad "/roms is not a bind from /mnt/userdata/roms (source: ${source:-none})" ;;
esac
findmnt -n -o OPTIONS /mnt/userdata 2>/dev/null | grep -q 'uid=1000' &&
  ok "user-data belongs to gamer" || bad "/mnt/userdata mount options lack uid=1000"
findmnt -n -o OPTIONS /mnt/userdata 2>/dev/null | grep -q 'flush' &&
  ok "user-data mounts with flush (smaller loss window)" || warn "/mnt/userdata does not use flush"
command -v fsck.fat >/dev/null 2>&1 &&
  ok "fsck.fat available for the dirty-bit repair" || bad "fsck.fat missing"
[ "$(systemctl is-enabled rg35xx-userdata-check.service 2>/dev/null)" = "enabled" ] &&
  ok "rg35xx-userdata-check.service runs before mnt-userdata.mount" ||
  bad "rg35xx-userdata-check.service is not enabled"
[ -w /roms ] && ok "/roms is writable" || bad "/roms is not writable"
last3=$(sfdisk -d /dev/mmcblk0 2>/dev/null | sed -n 's|^/dev/mmcblk0p3 *:.*start= *\([0-9]*\), *size= *\([0-9]*\).*|\1 \2|p')
if [ -n "$last3" ]; then
  set -- $last3
  total=$(blockdev --getsz /dev/mmcblk0)
  [ $(( $1 + $2 )) -ge $(( total - 2048 )) ] &&
    ok "user-data partition reaches the end of the card (${2} sectors)" ||
    warn "user-data partition ends $(( total - $1 - $2 )) sectors before the end of the card"
fi

sec "session environment"
for f in /etc/rg35xx/session.env /etc/rg35xx/kms.env; do
  [ -r "$f" ] && ok "$f" || bad "$f missing"
done
grep -q 'SDL_GAMECONTROLLERCONFIG' /etc/rg35xx/session.env 2>/dev/null &&
  ok "SDL controller mapping exported" || bad "SDL_GAMECONTROLLERCONFIG missing"
# PortMaster re-execs pugwash through sudo; without env_keep SDL falls back to a:b0,b:b1.
if SDL_GAMECONTROLLERCONFIG=probe sudo -n env 2>/dev/null | grep -qx 'SDL_GAMECONTROLLERCONFIG=probe'; then
  ok "sudo preserves SDL_GAMECONTROLLERCONFIG (PortMaster A/B mapping)"
else
  bad "sudo drops SDL_GAMECONTROLLERCONFIG: PortMaster will swap A/B"
fi
[ -r "/home/gamer/.config/retroarch/autoconfig/udev/H700 Gamepad.cfg" ] &&
  ok "RetroArch H700 autoconfig" || bad "RetroArch H700 autoconfig missing"
for b in rg35xx-session rg35xx-game-exec rg35xx-run-sh retroarch; do
  [ -x "/usr/local/bin/$b" ] && ok "/usr/local/bin/$b" || bad "/usr/local/bin/$b missing"
done
if id gamer >/dev/null 2>&1; then
  id -nG gamer | grep -qw input && ok "gamer in input group (AntiMicroX uinput)" || bad "gamer not in input group"
fi
[ -e /dev/uinput ] && ok "/dev/uinput present ($(stat -c '%a %G' /dev/uinput 2>/dev/null))" ||
  note "/dev/uinput missing (uinput module not loaded)"
[ -x /usr/local/bin/rg35xx-settings ] && [ -x /usr/local/bin/rg35xx-wifi ] &&
  ok "desktop settings helpers installed" || bad "desktop settings helpers missing"
for f in /home/gamer/.config/labwc/autostart /home/gamer/.config/waybar/config /home/gamer/.config/fuzzel/fuzzel.ini; do
  [ -r "$f" ] && ok "$f" || bad "$f missing"
done
[ -x /usr/local/bin/rg35xx-desktop-autostart ] && ok "desktop autostart wrapper present" ||
  bad "desktop autostart wrapper missing"
if systemctl is-active --quiet rg35xx-desktop 2>/dev/null; then
  for c in labwc waybar swaybg pcmanfm; do
    if pgrep -x "$c" > /dev/null 2>&1; then
      ok "desktop client running: $c"
    else
      bad "desktop client not running: $c"
    fi
  done
  grep -q '^font=.*pixelsize' /home/gamer/.config/fuzzel/fuzzel.ini 2>/dev/null &&
    ok "fuzzel font is DPI-independent" || bad "fuzzel font uses point size (menu overflows the panel)"
  if pgrep -f rg35xx-stick-mouse > /dev/null 2>&1; then
    ok "stick-to-mouse mapper running"
  else
    bad "stick-to-mouse mapper not running (pointer cannot be moved)"
  fi
  grep -q 'N: Name="rg35xx-mouse"' /proc/bus/input/devices 2>/dev/null &&
    ok "virtual mouse device present" || bad "virtual mouse device missing"
else
  note "desktop session is not active, client checks skipped"
fi
[ -r /run/rg35xx/desktop.log ] && { ok "desktop session log available"; tail -20 /run/rg35xx/desktop.log | sed 's/^/     /'; } ||
  note "no desktop log (the desktop session has not run since boot)"
[ -r /run/rg35xx/game.log ] && { ok "game log available"; tail -20 /run/rg35xx/game.log | sed 's/^/     /'; } ||
  note "no game log (nothing was launched since boot)"
[ -r /roms/ports/PortMaster/log.txt ] && { ok "PortMaster log available"; tail -15 /roms/ports/PortMaster/log.txt | sed 's/^/     /'; } ||
  note "no PortMaster log yet"

sec "network"
ip -br a 2>&1
rfkill list 2>/dev/null | head -10
if rfkill list wifi 2>/dev/null | grep -q 'blocked: yes'; then
  bad "Wi-Fi radio is blocked (rfkill)"
else
  ok "Wi-Fi radio not blocked"
fi
systemctl is-active wpa_supplicant@wlan0 >/dev/null 2>&1 && ok "wpa_supplicant@wlan0 active" ||
  bad "wpa_supplicant@wlan0 not active"
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
if systemctl is-active --quiet rg35xx-desktop rg35xx-es rg35xx-game 2>/dev/null; then
  # kmscube needs to be DRM master; a running session owns the device by design.
  note "a graphical session holds the DRM device, kmscube check skipped"
elif command -v kmscube >/dev/null 2>&1; then
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

sec "storage policy (SD wear)"
root=$(findmnt -n -o OPTIONS / 2>/dev/null)
case "$root" in
  *noatime*) ok "root mounted noatime" ;;
  *) bad "root is not mounted with noatime ($root)" ;;
esac
case "$root" in
  *commit=120*) ok "root commit=120 (up to 2 min of writes lost on power loss)" ;;
  *) bad "root is missing commit=120 ($root)" ;;
esac
findmnt -n -o FSTYPE,OPTIONS /tmp 2>/dev/null | grep -q '^tmpfs.*size=256M' &&
  ok "/tmp is tmpfs $(( $(findmnt -n -o SIZE /tmp 2>/dev/null || echo 0) / 1048576 )) MiB" ||
  note "/tmp is not the 256M tmpfs"
[ "$(systemctl is-enabled fstrim.timer 2>/dev/null)" = "enabled" ] &&
  ok "fstrim.timer enabled" || bad "fstrim.timer not enabled"
grep -q 'discard' /etc/fstab && bad "fstab uses discard (defeats fstrim, adds writes)" || ok "no discard in fstab"
grep -q '^tmpfs' /etc/fstab && ok "fstab has the /tmp tmpfs" || bad "fstab has no /tmp tmpfs"
note "journal: $(journalctl --disk-usage 2>/dev/null)"
systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^(SystemMaxUse|MaxRetentionSec|SyncIntervalSec)=' | head -3
case "$(systemd-analyze cat-config systemd/coredump.conf 2>/dev/null | grep '^Storage=')" in
  *none*) ok "core dumps disabled" ;;
  *) bad "core dumps are not disabled" ;;
esac
grep -q '^vm.dirty_expire_centisecs=3000' /etc/sysctl.d/99-rg35xxpro-sd.conf 2>/dev/null &&
  ok "writeback timers tuned for the card" || note "sd sysctl tuning missing"
note "boot-report.timer: $(systemctl show -p TimersMonotonic boot-report.timer 2>/dev/null | cut -c1-80)"

sec "audio"
cat /proc/asound/cards 2>/dev/null
if command -v aplay >/dev/null 2>&1; then aplay -l 2>/dev/null | head -8; else note "alsa-utils not installed (aplay/amixer)"; fi
grep -q 'sun4i-codec' /proc/asound/cards 2>/dev/null && ok "sun4i-codec card present" || bad "no sun4i-codec card"
grep -q 'Headphone Jack' /proc/bus/input/devices 2>/dev/null && ok "headphone jack detect device present" || note "no jack-detect input device"
if command -v amixer >/dev/null 2>&1; then amixer -c 0 scontrols 2>/dev/null | head -10; fi
grep -q 'default.clock.min-quantum = 1024' /etc/pipewire/pipewire.conf.d/50-rg35xx-quantum.conf 2>/dev/null &&
  ok "PipeWire minimum quantum is 1024 frames (no FAudio/SDL underruns)" ||
  bad "PipeWire minimum quantum config missing"

sec "memory"
free -m
swapon --show 2>/dev/null || true
if [ -r /sys/block/zram0/disksize ]; then
  zsize=$(( $(cat /sys/block/zram0/disksize) / 1048576 ))
  note "zram0 = ${zsize} MiB"
  [ "$zsize" -ge 400 ] && ok "zram is half of RAM ($zsize MiB)" || bad "zram too small ($zsize MiB)"
else
  note "zram not configured"
fi
zramctl 2>/dev/null || note "zramctl not available"
grep -q '^PERCENT=50' /etc/default/zramswap 2>/dev/null && ok "zramswap PERCENT=50" ||
  note "zramswap config not the expected one"
for u in rg35xx-es rg35xx-desktop; do
  cur=$(systemctl show -p MemoryCurrent "$u.service" 2>/dev/null | cut -d= -f2)
  [ -n "$cur" ] && [ "$cur" != "[not set]" ] && note "$u MemoryCurrent=$((cur / 1048576)) MiB"
done
ps -eo rss,comm --sort=-rss 2>/dev/null | head -8

printf '\n=== FAILURES: %s ===\n' "$fail"
exit "$fail"
