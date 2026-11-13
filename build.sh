#!/bin/bash
# RG35XX Pro (Allwinner H700): full image build from sources.
#
#   sudo ./build.sh              # everything
#   sudo ./build.sh --deps       # only install host packages
#   sudo ./build.sh kernel image # run/re-run selected stages
#
# Stages: deps sources atf uboot kernel rootfs frontend image
# Work happens in $BUILD_DIR (default /var/tmp/rg35xxpro-build); artifacts land in ./out.
#
# Everything the device needs comes from pinned upstreams plus this repository:
#   Linux 7.1.2, U-Boot v2026.01, TF-A v2.12.0 + ROCKNIX PSCI-suspend patch, the H700 SRAM
#   suspend stub, ROCKNIX tag 20261101 (DTS + patches), Debian 13 (trixie) arm64 rootfs,
#   ES-DE 3.5.0 built from source for GLES2/KMS, the libretro buildbot cores pinned by hash,
#   the PortMaster release, and config/ (our DTS, patches, rootfs overlay).
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR=${BUILD_DIR:-/var/tmp/rg35xxpro-build}
OUT=$REPO/out
CFG=$REPO/config

LINUX_VER=7.1.2
UBOOT_VER=2026.01
ATF_VER=2.12.0
ROCKNIX_TAG=20261101

LINUX_SHA256=37198c93727be247c9fb5309bb86cd5e496c61e5322cd8c4eca9476bb0b5883f
UBOOT_SHA256=03bb43c58d2343ee48dd191e0f181f0108425b179d84519add3a977071c3f654
ATF_SHA256=d95aaf292792c98035910d7e6c64ebfb297c897fef510415db1612f6d39f9223
# ROCKNIX pins TF-A 2.12.0 for H700 because 001-allwinner-h616-psci-system-suspend uses the
# pre-2.15 plat_psci_ops API (pwr_domain_pwr_down_wfi); do not bump it without porting that patch.
STUB_VER=712653d11230b2450061ddb8e25f31e072da7a48
STUB_SHA256=3698da9aad40c26c10f6aa31f8366158914e0a351d31f1084c6b8032147f4616

# Frontend: ES-DE upstream (not the ROCKNIX fork: it does not depend on /storage or sway and
# builds straight for KMS/GLES), libretro cores from the buildbot, PortMaster release.
ES_DE_VER=3.5.0
ES_DE_SHA256=3f35aaebaf65ab267d347d0957028af50e0413323277f8ae2b74fcfb836c6f7f
ES_DE_URL=https://gitlab.com/es-de/emulationstation-de/-/archive/v$ES_DE_VER/emulationstation-de-v$ES_DE_VER.tar.gz
# Core zips are pinned individually in config/retroarch-cores.sha256: the buildbot's "latest"
# directory is rebuilt continuously, so a checksum failure means "refresh the hashes", not "skip".
CORES_URL=https://buildbot.libretro.com/nightly/linux/aarch64/latest
PM_VER=2026-11-02_1442
PM_SHA256=b7a221c8a580a173bc6eb9bb7ec9ec2f616f2bfa37c0f95c127347954120aa11
PM_URL=https://github.com/PortsMaster/PortMaster-New/releases/download/$PM_VER/PortMaster.zip

LINUX_DIR=$BUILD_DIR/linux-$LINUX_VER
UBOOT_DIR=$BUILD_DIR/u-boot-$UBOOT_VER
ATF_DIR=$BUILD_DIR/trusted-firmware-a-$ATF_VER
STUB_DIR=$BUILD_DIR/h700-suspend-stub-$STUB_VER
STUB_BUILD=$BUILD_DIR/suspend-stub-lpddr3
RN_DIR=$BUILD_DIR/rocknix
ROOTFS=$BUILD_DIR/rootfs

CROSS=aarch64-linux-gnu-
JOBS=$(nproc)
IMG_NAME=rg35xxpro-debian.img

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# fetch <url> <sha256> <file>: reuse a cached download that still matches, otherwise download and
# verify. Any mismatch aborts the build; no tarball is ever used unverified.
fetch() {
  [ -s "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] && { echo "ok $(basename "$3")"; return; }
  echo "fetch $1"; curl -fL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - || die "checksum mismatch for $3"
}

[ "$(id -u)" = 0 ] || die "run as root (debootstrap/chroot); try: sudo $0 $*"

# Wi-Fi credentials are optional. config/wifi.env (gitignored, real values) wins; the committed
# template config/wifi.env.example contains placeholders. With no real credentials the image still
# gets a valid wpa_supplicant config, but no network block: configure Wi-Fi on the device or from
# /wifi.conf on the FAT boot partition.
load_wifi() {
  WIFI_SSID=
  WIFI_PSK=
  WIFI_COUNTRY=00
  local f
  for f in "$CFG/wifi.env" "$CFG/wifi.env.example"; do
    if [ -r "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      break
    fi
  done
  # Tolerate CRLF from editors on Windows; the values must not carry a stray \r into
  # wpa_supplicant or /wifi.conf.
  WIFI_SSID=${WIFI_SSID%$'\r'}
  WIFI_PSK=${WIFI_PSK%$'\r'}
  WIFI_COUNTRY=${WIFI_COUNTRY%$'\r'}
  WIFI_COUNTRY=${WIFI_COUNTRY:-00}
}

wifi_configured() {
  case "${WIFI_SSID:-}" in "" | "YOUR_SSID" | "CHANGEME") return 1 ;; esac
  case "${WIFI_PSK:-}" in "" | "YOUR_PASSPHRASE" | "CHANGEME") return 1 ;; esac
  return 0
}

# Escape a value for a double-quoted shell assignment in /wifi.conf.
sh_dquote() { printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g'; }

write_wpa_config() { # destination
  local dst=$1 block
  mkdir -p "$(dirname "$dst")"
  {
    echo "country=$WIFI_COUNTRY"
    echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    echo "powersave=0"
    echo
    if wifi_configured; then
      block=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PSK") ||
        die "wpa_passphrase rejected WIFI_SSID/WIFI_PSK from config/wifi.env"
      # wpa_passphrase keeps the passphrase in a comment next to the hash; do not ship it twice.
      printf '%s\n' "$block" | sed -e '/^[[:space:]]*#psk=/d'
    else
      echo "# No Wi-Fi network is baked into this image. Add one with wpa_cli, or put a"
      echo "# wifi.conf on the FAT boot partition (see README.md)."
    fi
  } > "$dst"
  chmod 600 "$dst"
}

# ---------------------------------------------------------------- deps
stage_deps() {
  log "host packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev libelf-dev libncurses-dev python3 python3-setuptools \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu cpp-aarch64-linux-gnu \
    device-tree-compiler u-boot-tools \
    debootstrap qemu-user-static binfmt-support \
    dosfstools mtools fdisk gdisk parted e2fsprogs rsync \
    wget curl xz-utils git ca-certificates file zstd unzip \
    libgnutls28-dev swig pkg-config wpasupplicant \
    linux-firmware
  # /lib/firmware pieces the kernel embeds (CONFIG_EXTRA_FIRMWARE)
  for f in /lib/firmware/rtw88/rtw8821c_fw.bin /lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s; do
    [ -s "$f" ] || echo "WARNING: $f missing (install linux-firmware)"
  done
}

# ---------------------------------------------------------------- sources
stage_sources() {
  log "sources in $BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$OUT"

  cd "$BUILD_DIR"
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VER%%.*}.x/linux-$LINUX_VER.tar.xz" \
        "$LINUX_SHA256" "linux-$LINUX_VER.tar.xz"
  fetch "https://github.com/u-boot/u-boot/archive/v$UBOOT_VER.tar.gz" \
        "$UBOOT_SHA256" "u-boot-v$UBOOT_VER.tar.gz"
  fetch "https://github.com/TrustedFirmware-A/trusted-firmware-a/archive/v$ATF_VER.tar.gz" \
        "$ATF_SHA256" "tf-a-v$ATF_VER.tar.gz"
  fetch "https://github.com/Jacob-Matthew-Cook/h700-suspend-stub/archive/$STUB_VER.tar.gz" \
        "$STUB_SHA256" "h700-suspend-stub-$STUB_VER.tar.gz"

  [ -d "$LINUX_DIR" ] || tar xf "linux-$LINUX_VER.tar.xz"
  [ -d "$UBOOT_DIR" ] || tar xf "u-boot-v$UBOOT_VER.tar.gz"
  [ -d "$ATF_DIR" ]   || tar xf "tf-a-v$ATF_VER.tar.gz"
  [ -d "$STUB_DIR" ]  || tar xf "h700-suspend-stub-$STUB_VER.tar.gz"

  if [ ! -d "$RN_DIR/.git" ] || [ "$(git -C "$RN_DIR" describe --tags 2>/dev/null || true)" != "$ROCKNIX_TAG" ]; then
    rm -rf "$RN_DIR"
    git clone --depth 1 --branch "$ROCKNIX_TAG" https://github.com/ROCKNIX/distribution.git "$RN_DIR"
  fi
  log "ROCKNIX $(git -C "$RN_DIR" describe --tags) $(git -C "$RN_DIR" rev-parse --short HEAD)"
}

# ---------------------------------------------------------------- TF-A
stage_atf() {
  log "TF-A $ATF_VER (BL31 with PSCI SYSTEM_SUSPEND)"
  cd "$ATF_DIR"
  if [ ! -f .rg35xxpro-patched ]; then
    patch -p1 < "$RN_DIR/projects/ROCKNIX/packages/tools/atf/patches/H700/000-use-gcc-for-asm.patch"
    patch -p1 -N --no-backup-if-mismatch \
      < "$RN_DIR/projects/ROCKNIX/packages/tools/atf/patches/H700/001-allwinner-h616-psci-system-suspend.patch"
    touch .rg35xxpro-patched
  fi

  # SRAM stub for PSCI SYSTEM_SUSPEND: BL31 copies it into SRAM A1, it puts DRAM into self-refresh
  # and resumes the same session. Built against U-Boot's DRAM driver + Kconfig from the same
  # defconfig the bootloader uses, so the timings match exactly. The Pro is LPDDR3; ROCKNIX also
  # ships an LPDDR4 stub, this build does not need it.
  [ -f "$UBOOT_DIR/configs/anbernic_rg35xx_h700_lpddr3_defconfig" ] || \
    cp "$RN_DIR/projects/ROCKNIX/devices/H700/packages/u-boot-DDR3/sources/configs/anbernic_rg35xx_h700_lpddr3_defconfig" \
       "$UBOOT_DIR/configs/"
  mkdir -p "$STUB_BUILD"
  make -C "$STUB_BUILD" -f "$STUB_DIR/Makefile" \
    SRC_DIR="$STUB_DIR" UBOOT_DIR="$UBOOT_DIR" ATF_DIR="$ATF_DIR" \
    DEFCONFIG="$UBOOT_DIR/configs/anbernic_rg35xx_h700_lpddr3_defconfig" \
    OUT=suspend_stub_lpddr3.bin CROSS_COMPILE=$CROSS
  test -s "$STUB_DIR/suspend_stub_lpddr3.bin"

  # ROCKNIX patch 000 replaces the "$(ARCH)-as" rule with "$(CC) -x assembler-with-cpp", and TF-A
  # never sets CC from CROSS_COMPILE, so CC must be given explicitly or the rule expands empty.
  make PLAT=sun50i_h616 CROSS_COMPILE=$CROSS CC=${CROSS}gcc CFLAGS="" LDFLAGS="" -j"$JOBS" \
    SUNXI_SYSTEM_SUSPEND=1 SUNXI_SUSPEND_STUB="$STUB_DIR/suspend_stub_lpddr3.bin" bl31
  test -s build/sun50i_h616/release/bl31.bin
  ls -l build/sun50i_h616/release/bl31.bin
}

# ---------------------------------------------------------------- U-Boot
stage_uboot() {
  log "U-Boot $UBOOT_VER (sunxi-with-spl, BL31 inside)"
  cd "$UBOOT_DIR"
  if [ ! -f .rg35xxpro-patched ]; then
    for p in "$RN_DIR"/projects/ROCKNIX/devices/H700/packages/u-boot-DDR3/patches/*.patch; do
      echo "--- $(basename "$p")"; patch -p1 < "$p"
    done
    touch .rg35xxpro-patched
  fi
  cp "$RN_DIR/projects/ROCKNIX/devices/H700/packages/u-boot-DDR3/sources/configs/anbernic_rg35xx_h700_lpddr3_defconfig" configs/
  make ARCH=arm CROSS_COMPILE=$CROSS anbernic_rg35xx_h700_lpddr3_defconfig
  scripts/config --file .config \
    --enable BOOTSTD_DEFAULTS --enable USE_BOOTCOMMAND --enable CMD_FAT --enable CMD_SOURCE \
    --enable CMD_BOOTI --enable CMD_MMC --enable DOS_PARTITION --enable PARTITIONS
  scripts/config --file .config --set-str BOOTCOMMAND \
    'if fatload mmc 0:1 ${scriptaddr} boot.scr; then source ${scriptaddr}; fi'
  make ARCH=arm CROSS_COMPILE=$CROSS olddefconfig
  make ARCH=arm CROSS_COMPILE=$CROSS BL31="$ATF_DIR/build/sun50i_h616/release/bl31.bin" -j"$JOBS"
  test -s u-boot-sunxi-with-spl.bin
  mkdir -p "$OUT"
  cp u-boot-sunxi-with-spl.bin "$OUT/"
  ls -l "$OUT/u-boot-sunxi-with-spl.bin"
}

# ---------------------------------------------------------------- kernel
stage_kernel() {
  log "Linux $LINUX_VER + ROCKNIX patches + our patches/DTS"
  cd "$LINUX_DIR"

  # ROCKNIX joypad driver (GPL-2.0-or-later): GPIO buttons plus analog sticks on the single
  # gpadc channel behind the PI1/PI2 analog mux. Sources are vendored under config/kernel/joypad;
  # the patches below add only the Kconfig/Makefile hooks and the local fixup.
  cp "$CFG"/kernel/joypad/rocknix-singleadc-joypad.c "$CFG"/kernel/joypad/rocknix-joypad.h \
     drivers/input/joystick/

  if [ ! -f .rg35xxpro-patched ]; then
    for p in "$RN_DIR"/packages/linux/patches/default/*.patch; do
      echo "--- default/$(basename "$p")"; patch -p1 -N --no-backup-if-mismatch < "$p"
    done
    for p in $(ls "$RN_DIR"/projects/ROCKNIX/devices/H700/patches/linux/*.patch | sort); do
      case "$p" in *.disabled) echo "skip $(basename "$p")"; continue;; esac
      echo "--- H700/$(basename "$p")"; patch -p1 -N --no-backup-if-mismatch < "$p"
    done
    for p in "$CFG"/patches/*.patch; do
      echo "--- ours/$(basename "$p")"; patch -p1 -N --no-backup-if-mismatch < "$p"
    done
    touch .rg35xxpro-patched
  fi

  cp "$CFG/dts/sun50i-h700-anbernic-rg35xx-pro.dts" arch/arm64/boot/dts/allwinner/
  grep -q 'sun50i-h700-anbernic-rg35xx-pro.dtb' arch/arm64/boot/dts/allwinner/Makefile || \
    echo 'dtb-$(CONFIG_ARCH_SUNXI) += sun50i-h700-anbernic-rg35xx-pro.dtb' >> arch/arm64/boot/dts/allwinner/Makefile

  log "kernel config"
  cp "$RN_DIR/projects/ROCKNIX/devices/H700/linux/linux.aarch64.conf" .config
  scripts/config --file .config \
    --set-str INITRAMFS_SOURCE "" \
    --set-str DEFAULT_HOSTNAME "rg35xxpro" \
    --set-str EXTRA_FIRMWARE "rtw88/rtw8821c_fw.bin panels/anbernic,rg35xx-plus-panel.panel regulatory.db regulatory.db.p7s rtl_bt/rtl8821cs_fw.bin rtl_bt/rtl8821cs_config.bin" \
    --set-str EXTRA_FIRMWARE_DIR "external-firmware" \
    --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG \
    --disable JOYSTICK_SINGLEADC_JOYPAD --enable JOYSTICK_ROCKNIX_SINGLEADC
  make ARCH=arm64 CROSS_COMPILE=$CROSS olddefconfig

  log "firmware blobs for CONFIG_EXTRA_FIRMWARE"
  mkdir -p external-firmware/rtw88 external-firmware/panels
  # config/firmware is the authoritative copy (156 KiB) so the build does not depend on the
  # host's linux-firmware packaging, which ships .zst and may lag behind.
  put_fw() { # destination-name source-in-config-firmware [host-path]
    local dst=$1 src=$2 host=$3
    if [ -s "$CFG/firmware/$src" ]; then
      cp "$CFG/firmware/$src" "$dst"
    elif [ -n "$host" ] && [ -s "$host" ]; then
      cp "$host" "$dst"
    elif [ -n "$host" ] && [ -s "$host.zst" ]; then
      zstd -d -q -o "$dst" "$host.zst"
    else
      die "firmware blob missing: $src (no config/firmware/$src and no $host)"
    fi
  }
  put_fw external-firmware/rtw88/rtw8821c_fw.bin rtw88/rtw8821c_fw.bin /lib/firmware/rtw88/rtw8821c_fw.bin
  put_fw external-firmware/regulatory.db regulatory.db /lib/firmware/regulatory.db
  put_fw external-firmware/regulatory.db.p7s regulatory.db.p7s /lib/firmware/regulatory.db.p7s
  put_fw external-firmware/panels/anbernic,rg35xx-plus-panel.panel \
    panels/anbernic,rg35xx-plus-panel.panel \
    "$RN_DIR/projects/ROCKNIX/packages/linux-firmware/kernel-firmware/extra-firmware/panels/anbernic,rg35xx-plus-panel.panel"
  mkdir -p external-firmware/rtl_bt
  put_fw external-firmware/rtl_bt/rtl8821cs_fw.bin rtl_bt/rtl8821cs_fw.bin /lib/firmware/rtl_bt/rtl8821cs_fw.bin
  put_fw external-firmware/rtl_bt/rtl8821cs_config.bin rtl_bt/rtl8821cs_config.bin /lib/firmware/rtl_bt/rtl8821cs_config.bin
  for f in external-firmware/rtw88/rtw8821c_fw.bin external-firmware/regulatory.db \
           external-firmware/regulatory.db.p7s external-firmware/panels/anbernic,rg35xx-plus-panel.panel \
           external-firmware/rtl_bt/rtl8821cs_fw.bin external-firmware/rtl_bt/rtl8821cs_config.bin; do
    test -s "$f" || die "missing firmware blob $f"
  done
  ls -l external-firmware/rtw88/ external-firmware/ external-firmware/panels/

  log "kernel build"
  # Pin the strings the kernel embeds in uname -v: without this every build differs, which makes
  # comparing two trees (clean vs incremental) impossible. Date is the ROCKNIX tag this repo pins.
  export KBUILD_BUILD_TIMESTAMP="2026-11-01 00:00:00 UTC"
  export KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=rg35xxpro
  make ARCH=arm64 CROSS_COMPILE=$CROSS -j"$JOBS" Image dtbs modules
  test -s arch/arm64/boot/Image

  mkdir -p "$OUT"
  cp arch/arm64/boot/Image "$OUT/Image"
  cp arch/arm64/boot/dts/allwinner/sun50i-h700-anbernic-rg35xx-pro.dtb "$OUT/"
  ls -l "$OUT/Image" "$OUT/sun50i-h700-anbernic-rg35xx-pro.dtb"
}

# ---------------------------------------------------------------- rootfs
stage_rootfs() {
  log "Debian 13 rootfs in $ROOTFS"
  if [ ! -x "$ROOTFS/debootstrap/debootstrap" ] && [ ! -x "$ROOTFS/usr/bin/apt-get" ]; then
    debootstrap --arch=arm64 --foreign --variant=minbase trixie "$ROOTFS" http://deb.debian.org/debian
    cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
    chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
  fi

  printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
  chmod +x "$ROOTFS/usr/sbin/policy-rc.d"
  cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

  cat > "$ROOTFS/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
deb http://security.debian.org/debian-security trixie-security main
EOF

  export DEBIAN_FRONTEND=noninteractive
  chroot "$ROOTFS" apt-get update
  chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    systemd-sysv openssh-server wpasupplicant iw iproute2 systemd-resolved avahi-daemon \
    libnss-mdns kbd console-setup usbutils evtest kmod ca-certificates curl nano sudo udev \
    mesa-utils mesa-utils-extra libgl1-mesa-dri libegl1 libgles2 libgbm1 libdrm-tests kmscube \
    wireless-regdb alsa-utils pipewire pipewire-pulse pipewire-alsa wireplumber \
    pulseaudio-utils rtkit triggerhappy zram-tools unzip

  log "base configuration"
  echo "rg35xxpro" > "$ROOTFS/etc/hostname"
  printf '127.0.0.1\tlocalhost\n127.0.1.1\trg35xxpro\n' > "$ROOTFS/etc/hosts"
  printf '/dev/mmcblk0p2\t/\text4\tdefaults,noatime,commit=120,errors=remount-ro\t0 1\n/dev/mmcblk0p1\t/boot/firmware\tvfat\tdefaults,noatime,nofail\t0 2\ntmpfs\t/tmp\ttmpfs\tdefaults,noatime,nosuid,nodev,size=256M,mode=1777\t0 0\n' \
    > "$ROOTFS/etc/fstab"
  echo 'root:root' | chroot "$ROOTFS" chpasswd

  log "repository rootfs overlay"
  ( cd "$CFG/rootfs" && find . -type f -print0 | while IFS= read -r -d '' f; do
      install -D -m 0644 "./$f" "$ROOTFS/${f#./}"
    done )
  # The overlay lands 0644; restore what has to be executable or unreadable by others.
  find "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/sbin" -type f -exec chmod 0755 {} +
  find "$ROOTFS/roms" -name '*.sh' -exec chmod 0755 {} +
  find "$ROOTFS/home/gamer/ES-DE/scripts" -name '*.sh' -exec chmod 0755 {} +
  chmod 0755 "$ROOTFS/home/gamer/.config/labwc/autostart"
  chmod 0440 "$ROOTFS/etc/sudoers.d/10-rg35xx"

  log "wpa_supplicant config (config/wifi.env)"
  load_wifi
  if wifi_configured; then
    echo "baking network \"$WIFI_SSID\", country $WIFI_COUNTRY"
  else
    echo "no credentials in config/wifi.env (placeholders only): Wi-Fi must be configured on the device"
  fi
  write_wpa_config "$ROOTFS/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

  log "provisioning (user, PipeWire, suspend guard, volume keys, zram, ALSA defaults)"
  cp "$REPO/scripts/device-provision.sh" "$ROOTFS/tmp/"
  chroot "$ROOTFS" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/sh /tmp/device-provision.sh --offline
  rm -f "$ROOTFS/tmp/device-provision.sh"

  log "roms tree"
  # One directory per system ES-DE is configured for, plus the ports and desktop entries.
  for d in ports desktop nes snes gb gbc gba genesis psx n64 nds arcade pcengine ngp \
           wonderswan virtualboy amiga c64 dos scummvm dreamcast psp 3do atari2600 atari7800; do
    install -d -o 1000 -g 1000 "$ROOTFS/roms/$d"
  done
  # gamer owns its home and the ROM tree; device-provision.sh created the user above.
  chown -R 1000:1000 "$ROOTFS/home/gamer" "$ROOTFS/roms"

  log "enable units"
  for u in ssh.service systemd-networkd.service systemd-resolved.service \
           wpa_supplicant@wlan0.service wifi-provision.service wifi-powersave-off.service \
           boot-report.timer fstrim.timer avahi-daemon.service triggerhappy.service \
           zramswap.service rg35xx-codec-defaults.service rg35xx-es.service; do
    dst=$ROOTFS/etc/systemd/system/$(dirname "$u").wants
    case "$u" in
      *.timer) dst=$ROOTFS/etc/systemd/system/timers.target.wants ;;
      wpa_supplicant@wlan0.service) dst=$ROOTFS/etc/systemd/system/multi-user.target.wants ;;
      *) dst=$ROOTFS/etc/systemd/system/multi-user.target.wants ;;
    esac
    mkdir -p "$dst"
    if [ -e "$ROOTFS/usr/lib/systemd/system/$u" ]; then
      ln -sfn "/usr/lib/systemd/system/$u" "$dst/$u"
    elif [ -e "$ROOTFS/etc/systemd/system/$u" ]; then
      ln -sfn "/etc/systemd/system/$u" "$dst/$u"
    else
      echo "WARNING: unit $u not found"
    fi
  done
  # tty1 belongs to the session contract (ES-DE, labwc, or getty started on demand by
  # rg35xx-terminal.service). A boot-time getty there would grab the VT and race the DRM client.
  rm -f "$ROOTFS/etc/systemd/system/getty.target.wants/getty@tty1.service" \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/getty@tty1.service"
  mkdir -p "$ROOTFS/var/lib/systemd/linger" && touch "$ROOTFS/var/lib/systemd/linger/gamer"
  mkdir -p "$ROOTFS/etc/systemd/user/default.target.wants" \
           "$ROOTFS/etc/systemd/user/sockets.target.wants" \
           "$ROOTFS/etc/systemd/user/pipewire.service.wants"
  ln -sfn /usr/lib/systemd/user/pipewire.socket "$ROOTFS/etc/systemd/user/sockets.target.wants/pipewire.socket"
  ln -sfn /usr/lib/systemd/user/pipewire-pulse.socket "$ROOTFS/etc/systemd/user/sockets.target.wants/pipewire-pulse.socket"
  ln -sfn /usr/lib/systemd/user/wireplumber.service "$ROOTFS/etc/systemd/user/pipewire.service.wants/wireplumber.service"

  log "kernel modules"
  make -C "$LINUX_DIR" ARCH=arm64 CROSS_COMPILE=$CROSS INSTALL_MOD_PATH="$ROOTFS" modules_install
  depmod -b "$ROOTFS" "$LINUX_VER"

  log "cleanup"
  chroot "$ROOTFS" apt-get clean
  rm -rf "$ROOTFS"/var/lib/apt/lists/*
  rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" "$ROOTFS/usr/sbin/policy-rc.d"
  # /etc/resolv.conf must point at resolved, never at the build host's resolver
  rm -f "$ROOTFS/etc/resolv.conf"
  ln -sfn /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
  mkdir -p "$ROOTFS/boot/firmware"
  du -sh "$ROOTFS"
}

# ---------------------------------------------------------------- frontend
# ES-DE 3.5.0 (built inside the rootfs under qemu-user, GLES2 + KMS), the libretro cores from the
# buildbot, and the PortMaster release. Everything lands in $ROOTFS, so the rootfs stage must have
# run first. Build dependencies are installed and purged in this stage only: the image keeps the
# runtime libraries, not a compiler.
stage_frontend() {
  log "frontend: ES-DE $ES_DE_VER, libretro cores, PortMaster"
  [ -x "$ROOTFS/usr/bin/apt-get" ] || die "rootfs stage has not run yet ($ROOTFS)"

  local libretro=$ROOTFS/usr/lib/aarch64-linux-gnu/libretro
  local cores_sum es_deps systems
  cores_sum=$(sha256sum "$CFG/retroarch-cores.sha256" | cut -d' ' -f1)
  # Installed for the build, purged afterwards; listed once so install and purge cannot diverge.
  es_deps="build-essential cmake gettext libharfbuzz-dev libicu-dev libsdl2-dev \
libavcodec-dev libavfilter-dev libavformat-dev libavutil-dev libfreeimage-dev libfreetype-dev \
libgit2-dev libcurl4-openssl-dev libpugixml-dev libasound2-dev libbluetooth-dev libgl1-mesa-dev \
libgles-dev libegl-dev libpoppler-cpp-dev"

  # The rootfs stage deletes its qemu copy in cleanup; cmake/make/dpkg/ldd inside the chroot need it.
  install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"

  if [ "$(cat "$ROOTFS/etc/rg35xx-cores.version" 2>/dev/null || true)" != "$cores_sum" ]; then
    log "libretro cores from $CORES_URL"
    mkdir -p "$libretro"
    while read -r sha core; do
      case "${core:-}" in '' | '#'*) continue ;; esac
      fetch "$CORES_URL/${core}_libretro.so.zip" "$sha" "$BUILD_DIR/core-$core.zip"
      unzip -o -j -q "$BUILD_DIR/core-$core.zip" -d "$libretro"
    done < "$CFG/retroarch-cores.sha256"
    chmod 0644 "$libretro"/*.so
    printf '%s\n' "$cores_sum" > "$ROOTFS/etc/rg35xx-cores.version"
    ls -l "$libretro" | tail -5
  fi

  if [ "$(cat "$ROOTFS/etc/rg35xx-es-de.version" 2>/dev/null || true)" != "$ES_DE_VER" ]; then
    log "ES-DE build dependencies"
    chroot "$ROOTFS" apt-get update
    # shellcheck disable=SC2086
    chroot "$ROOTFS" apt-get install -y --no-install-recommends $es_deps

    log "ES-DE $ES_DE_VER sources"
    fetch "$ES_DE_URL" "$ES_DE_SHA256" "$BUILD_DIR/emulationstation-de-v$ES_DE_VER.tar.gz"
    rm -rf "$ROOTFS/tmp/es-de-src" "$ROOTFS/tmp/es-de-build"
    tar xf "$BUILD_DIR/emulationstation-de-v$ES_DE_VER.tar.gz" -C "$ROOTFS/tmp"
    mv "$ROOTFS/tmp/emulationstation-de-v$ES_DE_VER" "$ROOTFS/tmp/es-de-src"

    log "ES-DE build"
    # -j2, not -j$JOBS: every compiler process runs emulated by qemu-user, and one aarch64 gcc
    # easily costs a few hundred MiB of host RAM.
    # COMPILE_LOCALIZATIONS stays ON (the default): without the compiled .mo files ES-DE logs
    # "Program resource missing ... locale/<lang>/LC_MESSAGES/<lang>.mo", calls it critical and
    # performs an emergency shutdown before the first window.
    chroot "$ROOTFS" cmake -S /tmp/es-de-src -B /tmp/es-de-build \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
      -DGLES=ON -DDEINIT_ON_LAUNCH=ON -DAPPLICATION_UPDATER=OFF \
      -DVIDEO_HW_DECODING=OFF
    chroot "$ROOTFS" make -C /tmp/es-de-build -j2
    chroot "$ROOTFS" make -C /tmp/es-de-build install

    # `make install` brings three themes (linear-es-de, modern-es-de, slate-es-de, 68 MiB total).
    # We use linear-es-de: it is the theme ES-DE falls back to by itself and it carries
    # aspect-ratio-4-3.xml, which is what this 640x480 panel needs. Drop the other two.
    log "themes: keep linear-es-de (4:3), drop the rest"
    themes=$ROOTFS/usr/share/es-de/themes
    test -s "$themes/linear-es-de/theme.xml" || die "linear-es-de theme was not installed"
    test -s "$themes/linear-es-de/capabilities.xml" ||
      die "linear-es-de has no capabilities.xml, ES-DE would ignore it"
    for t in "$themes"/*; do
      case "$(basename "$t")" in linear-es-de) continue ;; esac
      echo "removing theme $(basename "$t")"
      rm -rf "$t"
    done

    log "runtime libraries -> apt-mark manual"
    cat > "$ROOTFS/tmp/rg35xx-mark-manual.sh" <<'EOS'
#!/bin/sh
# Everything ES-DE and the cores link against has to survive the purge of the build dependencies,
# so mark the owning packages manual before autoremove gets a chance to drop them.
set -e
list=/tmp/rg35xx-runtime-libs
for f in /usr/bin/es-de /usr/lib/*/libretro/*.so; do
  if [ -e "$f" ]; then ldd "$f" 2>/dev/null; fi
done | sed -n 's/^.*=> \(\/usr\/[^ ]*\).*$/\1/p' | sort -u > "$list"
xargs -r dpkg -S < "$list" | cut -d: -f1 | sort -u | xargs -r apt-mark manual
rm -f "$list"
EOS
    chroot "$ROOTFS" /bin/sh /tmp/rg35xx-mark-manual.sh
    rm -f "$ROOTFS/tmp/rg35xx-mark-manual.sh"

    log "purge build dependencies"
    # shellcheck disable=SC2086
    chroot "$ROOTFS" apt-get purge -y $es_deps
    chroot "$ROOTFS" apt-get autoremove -y
    chroot "$ROOTFS" apt-get clean

    log "ES-DE verification"
    chroot "$ROOTFS" /usr/bin/es-de --version
    if chroot "$ROOTFS" /bin/sh -c 'ldd /usr/bin/es-de /usr/lib/*/libretro/*.so | grep -q "not found"'; then
      chroot "$ROOTFS" /bin/sh -c 'ldd /usr/bin/es-de /usr/lib/*/libretro/*.so | grep "not found"'
      die "ES-DE or a core is missing runtime libraries after the purge"
    fi
    printf '%s\n' "$ES_DE_VER" > "$ROOTFS/etc/rg35xx-es-de.version"
  fi

  log "es_systems.xml: ports through rg35xx-run-sh, arcade through FinalBurn Neo"
  # ES-DE picks resources/systems/<platform>/ at runtime: linuxarm on AArch64 (SystemData.cpp).
  # The generic linux/ directory is for x86-64 machines and is not what this image loads.
  systems=$ROOTFS/usr/share/es-de/resources/systems/linuxarm/es_systems.xml
  [ -s "$systems" ] || systems=$(find "$ROOTFS/usr/share/es-de" -path '*/systems/linuxarm/es_systems.xml' | head -1)
  [ -n "$systems" ] && [ -s "$systems" ] || die "linuxarm es_systems.xml not found under $ROOTFS/usr/share/es-de"
  python3 - "$systems" <<'PY'
import sys

# ES-DE runs a `ports` entry itself, which means the frontend keeps the DRM device and ~150 MiB
# while the port runs. Hand the entry to rg35xx-run-sh instead: it parks the argv and switches to
# rg35xx-game.service, so the port starts with the frontend stopped.
PORT_COMMAND = '%ENABLESHORTCUTS% %EMULATOR_OS-SHELL% %ROM%'
REPLACEMENT = '<command label="Shortcut or script">/usr/local/bin/rg35xx-run-sh %ROM%</command>'
# The image ships no MAME core (112 MiB); FinalBurn Neo is the only arcade core available, so it
# has to be the default choice for arcade and the CPS systems.
FBNEO_SYSTEMS = ('arcade', 'cps', 'cps1', 'cps2', 'cps3')

path = sys.argv[1]


def system_name(block):
    for line in block:
        stripped = line.strip()
        if stripped.startswith('<name>'):
            return stripped[len('<name>'):-len('</name>')]
    return ''


def fix_block(block, name):
    if name == 'ports':
        for i, line in enumerate(block):
            if '<command ' in line and PORT_COMMAND in line:
                indent = line[:len(line) - len(line.lstrip())]
                block[i] = indent + REPLACEMENT
                break
    if name in FBNEO_SYSTEMS:
        commands = [i for i, line in enumerate(block) if '<command ' in line]
        fbneo = [i for i in commands if 'fbneo_libretro.so' in block[i]]
        if fbneo and commands[0] != fbneo[0]:
            block.insert(commands[0], block.pop(fbneo[0]))
    return block


with open(path, encoding='utf-8') as handle:
    lines = handle.read().splitlines()

result = []
i = 0
while i < len(lines):
    if lines[i].strip() == '<system>':
        end = i + 1
        while end < len(lines) and lines[end].strip() != '</system>':
            end += 1
        block = fix_block(lines[i:end + 1], system_name(lines[i:end + 1]))
        result.extend(block)
        i = end + 1
        continue
    result.append(lines[i])
    i += 1

with open(path, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(result) + '\n')
PY
  grep -A8 '<name>ports</name>' "$systems" | grep -q 'rg35xx-run-sh' ||
    die "ports system was not patched to rg35xx-run-sh"
  for s in arcade cps cps1 cps2 cps3; do
    awk -v s="<name>$s</name>" 'index($0, s) { found = 1 } found && /<command / { print; exit }' "$systems" |
      grep -q 'fbneo_libretro.so' || die "$s still prefers a core the image does not ship"
  done

  # ES-DE resolves %CORE_RETROARCH% through es_find_rules.xml. The linuxarm variant already lists
  # /usr/lib/aarch64-linux-gnu/libretro, which is where this image keeps the cores; the x86-64
  # linux/ variant does not and is irrelevant here. Fail loudly if a future ES-DE drops the entry:
  # without it no core is ever found and every game launch fails.
  rules=$ROOTFS/usr/share/es-de/resources/systems/linuxarm/es_find_rules.xml
  [ -s "$rules" ] || rules=$(find "$ROOTFS/usr/share/es-de" -path '*/systems/linuxarm/es_find_rules.xml' | head -1)
  grep -q '<entry>/usr/lib/aarch64-linux-gnu/libretro</entry>' "$rules" 2>/dev/null ||
    die "es_find_rules.xml (linuxarm) does not list /usr/lib/aarch64-linux-gnu/libretro"

  log "PortMaster $PM_VER"
  if [ "$(cat "$ROOTFS/etc/rg35xx-portmaster.version" 2>/dev/null || true)" != "$PM_VER" ]; then
    fetch "$PM_URL" "$PM_SHA256" "$BUILD_DIR/PortMaster-$PM_VER.zip"
    unzip -q -o "$BUILD_DIR/PortMaster-$PM_VER.zip" -d "$ROOTFS/roms/ports"
    printf '%s\n' "$PM_VER" > "$ROOTFS/etc/rg35xx-portmaster.version"
  fi
  # The release ships its own controller DB without the H700 line, so PortMaster's
  # SDL_GAMECONTROLLERCONFIG lookup would come up empty. Keep the overlay's copy on top.
  install -m 0644 "$CFG/rootfs/roms/ports/PortMaster/gamecontrollerdb.txt" \
    "$ROOTFS/roms/ports/PortMaster/gamecontrollerdb.txt"
  find "$ROOTFS/roms/ports" -name '*.sh' -exec chmod 0755 {} +
  chown -R 1000:1000 "$ROOTFS/roms" "$ROOTFS/home/gamer"

  log "frontend cleanup"
  rm -rf "$ROOTFS/tmp/es-de-src" "$ROOTFS/tmp/es-de-build"
  rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
  rm -rf "$ROOTFS"/var/lib/apt/lists/*
  du -sh "$ROOTFS"
}

# ---------------------------------------------------------------- image
stage_image() {
  log "boot.scr + image assembly"
  mkdir -p "$OUT"
  cat > "$OUT/boot.cmd" <<'EOF'
setenv bootargs root=/dev/mmcblk0p2 rootwait rw console=tty0 console=ttyS0,115200 cma=64M loglevel=7 panic=10 pstore.backend=ramoops
fatload mmc 0:1 ${kernel_addr_r} /Image
fatload mmc 0:1 ${fdt_addr_r} /sun50i-h700-anbernic-rg35xx-pro.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
EOF
  cat > "$OUT/extlinux.conf" <<'EOF'
DEFAULT debian
TIMEOUT 0
LABEL debian
  LINUX /Image
  FDT /sun50i-h700-anbernic-rg35xx-pro.dtb
  APPEND root=/dev/mmcblk0p2 rootwait rw console=tty0 console=ttyS0,115200 cma=64M loglevel=7 panic=10 pstore.backend=ramoops
EOF
  mkimage -A arm64 -O linux -T script -C none -n "RG35XX Pro boot" -d "$OUT/boot.cmd" "$OUT/boot.scr" >/dev/null

  local img=$BUILD_DIR/$IMG_NAME
  rm -f "$img" "$BUILD_DIR/boot.img" "$BUILD_DIR/root.img"

  log "boot partition (512 MiB FAT32 @ 16 MiB)"
  truncate -s 512M "$BUILD_DIR/boot.img"
  mkfs.vfat -F 32 -n BOOT "$BUILD_DIR/boot.img" >/dev/null
  mmd -i "$BUILD_DIR/boot.img" ::/extlinux
  mcopy -i "$BUILD_DIR/boot.img" "$OUT/Image" ::/Image
  mcopy -i "$BUILD_DIR/boot.img" "$OUT/sun50i-h700-anbernic-rg35xx-pro.dtb" ::/
  mcopy -i "$BUILD_DIR/boot.img" "$OUT/extlinux.conf" ::/extlinux/extlinux.conf
  mcopy -i "$BUILD_DIR/boot.img" "$OUT/boot.scr" ::/boot.scr
  load_wifi
  if wifi_configured; then
    printf 'WIFI_SSID="%s"\nWIFI_PSK="%s"\nWIFI_COUNTRY=%s\n' \
      "$(sh_dquote "$WIFI_SSID")" "$(sh_dquote "$WIFI_PSK")" "$WIFI_COUNTRY" > "$BUILD_DIR/wifi.conf"
    mcopy -i "$BUILD_DIR/boot.img" "$BUILD_DIR/wifi.conf" ::/wifi.conf
  fi
  mdir -i "$BUILD_DIR/boot.img" ::/

  log "root partition (ext4)"
  truncate -s $(( (16777216 - 1081344) * 512 )) "$BUILD_DIR/root.img"
  mkfs.ext4 -F -L ROOT -d "$ROOTFS" "$BUILD_DIR/root.img" >/dev/null 2>&1
  e2fsck -fn "$BUILD_DIR/root.img" >/dev/null && echo "ext4 clean"

  log "assemble 8 GiB image"
  truncate -s 8G "$img"
  sfdisk --force --no-reread "$img" >/dev/null <<'EOF'
label: dos
unit: sectors
start=32768, size=1048576, type=c
start=1081344, type=83
EOF
  dd if="$OUT/u-boot-sunxi-with-spl.bin" of="$img" bs=1024 seek=8 conv=notrunc status=none
  dd if="$BUILD_DIR/boot.img" of="$img" bs=1M seek=16 conv=notrunc status=none
  dd if="$BUILD_DIR/root.img" of="$img" bs=1M seek=528 conv=notrunc status=none
  cp --sparse=always "$img" "$OUT/$IMG_NAME"

  log "result"
  sfdisk -l "$OUT/$IMG_NAME"
  ( cd "$OUT" && sha256sum "$IMG_NAME" ) | tee "$OUT/$IMG_NAME.sha256"
  ls -l "$OUT"
}

# ---------------------------------------------------------------- main
STAGES=()
for a in "$@"; do
  case "$a" in
    --deps|deps) STAGES+=(deps) ;;
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
    sources|atf|uboot|kernel|rootfs|frontend|image) STAGES+=("$a") ;;
    *) die "unknown stage: $a" ;;
  esac
done
[ ${#STAGES[@]} -gt 0 ] || STAGES=(deps sources atf uboot kernel rootfs frontend image)

for s in "${STAGES[@]}"; do
  "stage_$s"
done
log "done"
