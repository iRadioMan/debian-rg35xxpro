#!/bin/bash
# RG35XX Pro (Allwinner H700): full image build from sources.
#
#   sudo ./build.sh              # everything
#   sudo ./build.sh --deps       # only install host packages
#   sudo ./build.sh kernel image # run/re-run selected stages
#
# Stages: deps sources atf uboot kernel rootfs image
# Work happens in $BUILD_DIR (default /var/tmp/rg35xxpro-build); artifacts land in ./out.
#
# Everything the device needs comes from four pinned upstreams plus this repository:
#   Linux 7.1.2, U-Boot v2026.01, TF-A v2.12.0 + ROCKNIX PSCI-suspend patch, the H700 SRAM
#   suspend stub, ROCKNIX tag 20261101 (DTS + patches), Debian 13 (trixie) arm64 rootfs, and
#   config/ (our DTS, our patches, rootfs overlay).
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
    wget curl xz-utils git ca-certificates file zstd \
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

  fetch() { # url sha256 file
    [ -s "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] && { echo "ok $3"; return; }
    echo "fetch $1"; curl -fL --retry 3 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c - || die "checksum mismatch for $3"
  }
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
    pulseaudio-utils rtkit triggerhappy zram-tools

  log "base configuration"
  echo "rg35xxpro" > "$ROOTFS/etc/hostname"
  printf '127.0.0.1\tlocalhost\n127.0.1.1\trg35xxpro\n' > "$ROOTFS/etc/hosts"
  printf '/dev/mmcblk0p2\t/\text4\tdefaults,noatime\t0 1\n/dev/mmcblk0p1\t/boot/firmware\tvfat\tdefaults,nofail\t0 2\n' \
    > "$ROOTFS/etc/fstab"
  echo 'root:root' | chroot "$ROOTFS" chpasswd

  log "repository rootfs overlay"
  ( cd "$CFG/rootfs" && find . -type f -print0 | while IFS= read -r -d '' f; do
      install -D -m 0644 "./$f" "$ROOTFS/${f#./}"
    done )
  chmod 0755 "$ROOTFS/usr/local/sbin/boot-report" "$ROOTFS/usr/local/sbin/wifi-provision"

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

  log "enable units"
  for u in ssh.service systemd-networkd.service systemd-resolved.service \
           wpa_supplicant@wlan0.service wifi-provision.service wifi-powersave-off.service \
           boot-report.timer avahi-daemon.service triggerhappy.service zramswap.service \
           rg35xx-codec-defaults.service getty@tty1.service; do
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
    sources|atf|uboot|kernel|rootfs|image) STAGES+=("$a") ;;
    *) die "unknown stage: $a" ;;
  esac
done
[ ${#STAGES[@]} -gt 0 ] || STAGES=(deps sources atf uboot kernel rootfs image)

for s in "${STAGES[@]}"; do
  "stage_$s"
done
log "done"
