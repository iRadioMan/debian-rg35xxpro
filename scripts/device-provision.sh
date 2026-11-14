#!/bin/sh
# Provision the RG35XX Pro Debian rootfs with everything the audio/input/Wi-Fi bring-up needs.
#
#   on the device:   sh device-provision.sh
#   in a chroot:     sh device-provision.sh --offline     (no service starts, no user bus)
#
# Idempotent. Every step below is something that was found broken or missing on real hardware;
# the comments say what it fixes.
set -eu

OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

run() { [ "$OFFLINE" = 1 ] && return 0; "$@"; }
say() { echo "== $* =="; }

SEAT_USER=gamer
SEAT_UID=1000
SEAT_RUNTIME=/run/user/$SEAT_UID

say "1. DNS: never ship WSL's resolver"
# debootstrap inside WSL bakes in "nameserver 10.255.255.254"; on the device every lookup fails
# (apt: "Temporary failure resolving") while resolvectl keeps working. glibc reads this file.
if grep -q '10.255.255.254' /etc/resolv.conf 2>/dev/null; then
  rm -f /etc/resolv.conf
  ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
ls -l /etc/resolv.conf

say "2. packages"
export DEBIAN_FRONTEND=noninteractive
# Games and ports are 64-bit, but a large part of the PortMaster catalogue ships armhf binaries;
# the H700 kernel has CONFIG_COMPAT=y, so add the foreign architecture and the runtime libraries
# those builds link against.
dpkg --add-architecture armhf
apt-get update
apt-get install -y --no-install-recommends \
  alsa-utils pipewire pipewire-pulse pipewire-alsa wireplumber pulseaudio-utils \
  rtkit triggerhappy zram-tools \
  cage seatd earlyoom systemd-timesyncd \
  libsdl2-2.0-0 libsdl2-ttf-2.0-0 fonts-dejavu-core \
  retroarch libretro-core-info retroarch-assets python3 unzip zip \
  labwc waybar pcmanfm foot imv mousepad firefox-esr audacious audacious-plugins smplayer mpv \
  antimicro xwayland xauth swaybg fuzzel pavucontrol brightnessctl dialog bluez \
  libspa-0.2-bluetooth udisks2 gvfs qtwayland5 xdg-utils desktop-file-utils shared-mime-info \
  hicolor-icon-theme adwaita-icon-theme

# 32-bit PortMaster runtimes: SDL2 stack, OpenAL, ALSA, GL/EGL/GBM and the X11 libraries some
# ports still link against.
apt-get install -y --no-install-recommends \
  libc6:armhf libstdc++6:armhf libgcc-s1:armhf \
  libsdl2-2.0-0:armhf libsdl2-image-2.0-0:armhf libsdl2-mixer-2.0-0:armhf \
  libsdl2-ttf-2.0-0:armhf libopenal1:armhf libasound2t64:armhf \
  libgl1:armhf libgl1-mesa-dri:armhf libegl1:armhf libgles2:armhf \
  libgbm1:armhf libdrm2:armhf libx11-6:armhf libxext6:armhf libxrandr2:armhf \
  libxcursor1:armhf libxi6:armhf libxinerama1:armhf libxss1:armhf libxxf86vm1:armhf

say "3. unprivileged seat user"
# pipewire/wireplumber user units carry ConditionUser=!root: under root they are skipped and
# every ALSA client fails with "-112 Host is down".
id "$SEAT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G \
  video,render,input,audio,netdev,plugdev "$SEAT_USER"
usermod -aG video,render,input,audio,netdev,plugdev "$SEAT_USER" 2>/dev/null || true
echo "$SEAT_USER:$SEAT_USER" | chpasswd
run loginctl enable-linger "$SEAT_USER"

say "4. suspend must stay off until TF-A carries the PSCI-suspend patch"
# Without 001-allwinner-h616-psci-system-suspend + h700-suspend-stub a suspend hangs the SoC, and
# a half-finished resume strands sun4i-codec (clocks_suspended=true -> every stream gets -EIO).
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/50-rg35xxpro-nosleep.conf <<'EOF'
[Login]
HandlePowerKey=poweroff
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
for u in suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
  ln -sfn /dev/null "/etc/systemd/system/$u"
done

say "5. Wi-Fi power save off"
# rtw88_8821cs with LPS on wedges after idle: wlan0 keeps its address and association but no
# packet gets through, which looks exactly like a dead device from the network.
cat > /etc/systemd/system/wifi-powersave-off.service <<'EOF'
[Unit]
Description=Disable 802.11 power save on wlan0 (rtw88 LPS wedges and drops all traffic)
After=wpa_supplicant@wlan0.service sys-subsystem-net-devices-wlan0.device
Wants=wpa_supplicant@wlan0.service
ConditionPathExists=/sys/class/net/wlan0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iw dev wlan0 set power_save off

[Install]
WantedBy=multi-user.target
EOF
run systemctl enable wifi-powersave-off.service

say "6. volume keys -> default sink"
# gpio-keys-volume is its own evdev device (KEY_VOLUMEUP 115 / KEY_VOLUMEDOWN 114). thd ships as
# User=nobody, which cannot open /dev/input/event* (root:input 0640), so it never fires.
cat > /usr/local/bin/rg35-volume <<'EOF'
#!/bin/sh
# Called by thd (root). Hand the command to the seat user, which owns the PipeWire session.
set -eu
exec runuser -u gamer -- env XDG_RUNTIME_DIR=/run/user/1000 \
  wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "${1:-5%+}"
EOF
chmod +x /usr/local/bin/rg35-volume
mkdir -p /etc/systemd/system/triggerhappy.service.d
cat > /etc/systemd/system/triggerhappy.service.d/root-and-volume.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --user root --deviceglob /dev/input/event*
EOF
mkdir -p /etc/triggerhappy/triggers.d
cat > /etc/triggerhappy/triggers.d/rg35xx-volume.conf <<'EOF'
KEY_VOLUMEUP   1   /usr/local/bin/rg35-volume 5%+
KEY_VOLUMEDOWN 1   /usr/local/bin/rg35-volume 5%-
EOF
run systemctl enable triggerhappy.service

say "7. zram (1 GB RAM device)"
if [ -f /etc/default/zramswap ]; then
  # 512 MiB of zram-backed swap on 1 GiB of RAM: a swapped-out frontend or browser tab costs
  # CPU instead of an OOM kill, and it never touches the SD card.
  sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
  sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap
  grep -q '^SIZE=' /etc/default/zramswap && sed -i 's/^SIZE=.*/SIZE=/' /etc/default/zramswap
  run systemctl enable zramswap.service
fi

say "7b. schedutil CPU governor, capped journal (flash wear on a handheld)"
# ROCKNIX's H700 kernel config pins every policy to "performance" (1416 MHz at all times): steady
# heat and battery drain. schedutil scales 480..1416 MHz on demand. The unit ships as an overlay
# file, config/rootfs/etc/systemd/system/rg35xx-cpu-governor.service: a second copy here ran after
# the overlay and silently overwrote it, so the two were free to drift apart.
if [ ! -s /etc/systemd/system/rg35xx-cpu-governor.service ]; then
  echo "rg35xx-cpu-governor.service is missing: the rootfs overlay was not installed" >&2
  exit 1
fi
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sfn ../rg35xx-cpu-governor.service /etc/systemd/system/multi-user.target.wants/rg35xx-cpu-governor.service
run systemctl daemon-reload
run systemctl enable --now rg35xx-cpu-governor.service

# The journal is the main source of idle SD writes; systemd defaults to 10 % of the filesystem
# (~800 MiB on this card). The caps (32 MiB, one week, 5 min sync) ship as an image overlay file,
# config/rootfs/etc/systemd/journald.conf.d/00-size.conf; restart the daemon so a re-run picks up
# an updated copy.
run systemctl restart systemd-journald

say "7c. Wayland seat + OOM policy"
# The graphics stack (Mesa/Panfrost, Wayland, cage) stays installed and seatd is enabled so the
# labwc desktop session (rg35xx-desktop.service) gets a seat for gamer (seatd runs with -g video
# and gamer is in that group). What runs at boot is decided by the session contract, not here:
# rg35xx-es.service is what multi-user.target pulls in.
run systemctl enable --now seatd
# --offline skips the line above, so make the enablement explicit for the image build too.
for u in seatd earlyoom; do
  src=/usr/lib/systemd/system/$u.service
  [ -f "$src" ] || src=/lib/systemd/system/$u.service
  ln -sfn "$src" "/etc/systemd/system/multi-user.target.wants/$u.service"
done

# zram-backed swap is nearly free, so prefer swapping anonymous pages to dropping page cache.
printf '# zram-backed swap is free to use: prefer anonymous pages there instead of dropping cache\nvm.swappiness=100\n' \
  > /etc/sysctl.d/99-rg35xxpro-zram.conf
run sysctl -q -p /etc/sysctl.d/99-rg35xxpro-zram.conf

# Kernel OOM kills the whole cgroup late and takes the session with it; earlyoom kills the
# largest offender (the emulator, the browser) first and leaves systemd/sshd/PipeWire/the
# session alive, so the device stays reachable and can be restarted from the shell.
mkdir -p /etc/default
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-m 10 -s 5 -r 60 --prefer (^|/)(firefox|firefox-esr|smplayer|mpv|audacious|es-de|retroarch|pugwash|ppsspp|dolphin|flycast)$ --avoid (^|/)(systemd|sshd|pipewire|wireplumber|dbus-daemon|labwc|waybar|foot|pcmanfm|seatd)$"
EOF
run systemctl enable --now earlyoom

say "7d. clock: NTP on top of the pcf8563 RTC"
# RTC_HCTOSYS=y with hctosys=rtc0 already restores the wall clock from the pcf8563 at boot; without
# a sync service the clock drifts and "System clock synchronized: no" stays forever.
run systemctl enable --now systemd-timesyncd
# --offline never runs systemctl: replicate the two symlinks enable would create.
ln -sfn /usr/lib/systemd/system/systemd-timesyncd.service \
  /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service 2>/dev/null || true
ln -sfn /usr/lib/systemd/system/systemd-timesyncd.service \
  /etc/systemd/system/dbus-org.freedesktop.timesync1.service 2>/dev/null || true

say "8. codec: 0 dB on the analog stages, -1.9 dB of headroom in PipeWire"
# Line Out 0..31 = -43.5..0 dB, DAC 0..63 = -73.08..0 dB; 0 dB is the ceiling, so nothing may add
# digital gain on top. 80% on the sink keeps that headroom for already-mastered content.
run amixer -c 0 sset 'Line Out' 31 unmute
run amixer -c 0 sset 'DAC' 63 unmute
run amixer -c 0 sset 'Line Out Source' 'Stereo'
run alsactl store
if [ "$OFFLINE" = 0 ]; then
  su - "$SEAT_USER" -c "export XDG_RUNTIME_DIR=$SEAT_RUNTIME; wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 0.8" || true
fi

say "9. inventory"
cat /proc/asound/cards 2>/dev/null || true
aplay -l 2>/dev/null || true
amixer -c 0 contents 2>/dev/null | head -60 || true
grep -E 'gpio-261' /sys/kernel/debug/gpio 2>/dev/null || true
for r in /sys/class/regulator/regulator.*; do
  [ -r "$r/name" ] || continue
  case "$(cat "$r/name")" in *spkr*) echo "$(cat "$r/name") state=$(cat "$r/state")";; esac
done
[ "$OFFLINE" = 1 ] || systemctl --user -M "$SEAT_USER@" is-active pipewire pipewire-pulse wireplumber 2>/dev/null || true

say "done"
