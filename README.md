# RG35XX Pro (Allwinner H700): Debian 13 arm64 — building an image from scratch

> [!WARNING]
> **This image is experimental and not suitable for daily use.** It can break at any time and data
> can be lost. Keep backups, and keep known-good stock firmware or a spare SD card on hand so you
> can always restore the device.

This repository builds a bootable image for the Anbernic RG35XX Pro: U-Boot + Linux 7.1.2 + Debian 13
(trixie) arm64, MBR. The image has two partitions — BOOT and ROOT; the remaining space on the card
becomes a third partition `/roms` on first boot (FAT32, visible in Windows) for games, videos and
music. Boot finishes in EmulationStation (ES-DE 3.5.0) on the 640×480 panel through KMS/DRM; from
there you can open games (RetroArch + libretro cores), ports (PortMaster), the Desktop (labwc) and a
plain text terminal on `tty1`. All modes are mutually exclusive: exactly one of them lives on `tty1`
at any given time.

|Component|Version / artifact|
|---|---|
|Kernel|Linux 7.1.2 + `packages/linux/patches/default/*` + `devices/H700/patches/linux/*` (excluding `*.disabled`), `linux.aarch64.conf`|
|DTS|`sun50i-h700-anbernic-rg35xx-pro.dts` (inherit plus) + `reg_dcdc3 = 1.2 V`|
|U-Boot|v2026.01, `anbernic_rg35xx_h700_lpddr3_defconfig`, DDR3 patches, `BL31` inside|
|TF-A|v2.12.0, `PLAT=sun50i_h616`, patch `000-use-gcc-for-asm`|
|Rootfs|Debian 13.7 trixie, `minbase` + sshd/networkd/wpa_supplicant/avahi/mesa/kmscube, no initramfs|
|Frontend|ES-DE 3.5.0, built from source (`-DGLES=ON -DDEINIT_ON_LAUNCH=ON`), `/usr/bin/es-de`|
|Emulation|RetroArch 1.20.0 (Debian) + libretro buildbot aarch64 cores, `/usr/lib/aarch64-linux-gnu/libretro`|
|Ports|PortMaster, `/roms/ports/PortMaster`, armhf runtime for 32-bit ports|
|Desktop|labwc + waybar + pcmanfm + foot + fuzzel, application set (Firefox ESR, mpv/SMPlayer, Audacious, imv, mousepad, AntiMicroX, pavucontrol)|
|Firmware in kernel|`rtw88/rtw8821c_fw.bin`, `panels/anbernic,rg35xx-plus-panel.panel`, `regulatory.db(.p7s)`|

## Host requirements

- Debian 13 (trixie) or Ubuntu 24.04, x86-64. The build runs through `debootstrap` + `chroot`, so a
  Linux host with root is required.
- ~20 GiB free in `$BUILD_DIR` (default `/var/tmp/rg35xxpro-build`) and ~10 GiB in the repository
  directory for `out/`.
- Internet access: `build.sh` downloads the kernel, U-Boot, TF-A, ROCKNIX and Debian packages.
- Everything else `build.sh` installs itself (`gcc-aarch64-linux-gnu`, `debootstrap`, `qemu-user-static`,
  `mtools`, `u-boot-tools`, `wpasupplicant`, `linux-firmware`, …).

## Quick start

```sh
git clone <repository URL> debian-rg35xxpro
cd debian-rg35xxpro

# Optional: Wi-Fi that will already be provisioned in the image.
cp config/wifi.env.example config/wifi.conf
$EDITOR config/wifi.conf

sudo ./build.sh
```

A full build runs the stages `deps → sources → atf → uboot → kernel → rootfs → frontend → image`.
A note on time: `frontend` builds ES-DE under `qemu-user` (`-j2`), which is the longest step after
the kernel.
Result:

|File|What it is|
|---|---|
|`out/rg35xxpro-debian.img`|4624 MiB image for an SD card (the rest of the card becomes `/roms`)|
|`out/rg35xxpro-debian.img.sha256`|checksum|
|`out/Image`, `out/*.dtb`|kernel and DTB (for debugging/replacing on p1)|
|`out/u-boot-sunxi-with-spl.bin`|bootloader (already written into the image)|

`out/` is in `.gitignore`: the ready-made image is not part of the repository, everyone builds it
locally.

Checksum verification:

```sh
cd out && sha256sum -c rg35xxpro-debian.img.sha256
```

## Wi-Fi

The image contains no foreign networks. There are three ways to configure Wi-Fi.

### 1. At build time: `config/wifi.conf`

```sh
cp config/wifi.env.example config/wifi.conf
```

```sh
WIFI_COUNTRY=RU
WIFI_SSID_1="MyNetwork"
WIFI_PSK_1="my passphrase"
WIFI_SSID_2="MyNetwork-5G"
WIFI_PSK_2="my passphrase"
```

- Up to 8 networks, numbered from 1: home and the 5 GHz band of the same router, a phone hotspot,
  and so on. wpa_supplicant itself picks the visible network by signal level.
- `WIFI_PRIORITY_n` — optional: the higher the value, the more preferred the network when both are
  visible (for example `WIFI_PRIORITY_2=20` pulls the device towards 5 GHz).
- `WIFI_COUNTRY` — ISO 3166-1 alpha-2 or `00` (world regulatory domain).
- `WIFI_PSK_n` — a password of 8–63 characters (or 64 hex characters of a PSK).
- `config/wifi.conf` is in `.gitignore`: real passwords never enter the repository.
- If the file is missing or still contains placeholders, the image is built anyway: `wpa_supplicant`
  starts with a config that has no networks, and the network has to be added on the device.

The build renders the networks into `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` **as hashes
only** (`psk=<64 hex>`), so the password itself never enters the image. It is deliberately not
duplicated onto the FAT partition p1: that partition is plain text and travels with any copy of the
card or image. The format of `config/wifi.conf` and `/wifi.conf` is the same, and both are rendered
by one program, `/usr/local/sbin/wifi-config-gen`, so "set at build time" and "edited from a PC"
behave identically.

### Desktop: application menu and switching to ES-DE

|Problem|Cause|Fix|
|---|---|---|
|The application menu (fuzzel) is huge, wider than the screen|the 640×480 panel has a physical density of ~200 dpi, but the font size was specified in points (`size=9`): fuzzel drew ~25 px rows and the window went off-screen. In addition, the `[dmenu]` section contained `font/lines/width`, which fuzzel 1.12 does not accept and refuses to start with|`font=DejaVu Sans:pixelsize=12` (independent of DPI), `lines=6`, `width=30`; the extra keys were removed from `[dmenu]`|
|pcmanfm does not start, there are no icons on the desktop|`~/.config/labwc/environment` had `GDK_BACKEND=wayland`, while pcmanfm is GTK3 X11-only and crashes with a segfault on the Wayland backend|`GDK_BACKEND` was removed from the shared environment; in autostart pcmanfm starts with `GDK_BACKEND=x11` (XWayland)|
|ES-DE launched from the desktop menu did not close the desktop but ran in a window inside labwc|the menu showed `org.es_de.frontend.desktop` from the ES-DE installation with `Exec=es-de`, i.e. launching it as a client instead of switching modes|a custom `~/.local/share/applications/org.es_de.frontend.desktop` with `Exec=sudo -n /usr/local/bin/rg35xx-session es` — the entry is called "Games" and switches the session|
|Desktop icons were drawn in a decorated "pcmanfm" window in the corner|pcmanfm creates a window of type `DESKTOP`, and labwc under XWayland manages it like a normal one: frame, title, size to content|`~/.config/labwc/rc.xml`: window rule `type="desktop"` → `serverDecoration="no"`, `skipTaskbar`, `Maximize`|
|Mode switching sometimes failed (`status=15/TERM`, `1/HUP`) and left the unit `failed`|`Conflicts=` stops the old session in parallel with starting the new one: labwc managed to grab DRM while ES-DE still held it, and the start was cancelled. In addition, any unit holding tty1 caught SIGHUP from `vhangup()` when getty stopped|switching goes through the transient unit `rg35xx-session-apply` (`systemd-run`): first `stop` all other modes, then `start` the requested one, plus `reset-failed` for the stopped ones; sessions no longer hold tty1 (`TTYPath/TTYReset` removed), output goes to the journal|
|The desktop cursor was not controlled by the gamepad|the image shipped antimicro (Qt5 GUI: window, tray, ~100 MB RSS on 1 GB RAM). For "stick → cursor, A/B → clicks" it is overkill and also requires an already running display|`/usr/local/bin/rg35xx-stick-mouse` (stdlib python3, uinput): left stick → `REL_X/REL_Y` with a 16 % dead zone and a `speed*(1.6..)` curve, A (`BTN_EAST`) → left click, B (`BTN_SOUTH`) → right click. Started first in the desktop autostart, while the gamepad remains available to applications. Speed/zone are the `MAX_SPEED`, `DEADZONE`, `CURVE` constants at the top of the file|
|Exiting ES-DE did not return to the desktop|the quit script always switched to `terminal`|`rg35xx-session` remembers the previous mode in `/run/rg35xx/previous`, the quit script calls `rg35xx-session back`: from the desktop — back to the desktop, from boot — to the console|
|Switching desktop → ES failed with `status=1/HUP`|`TTYVHangup=yes` in the units: `vhangup()` on tty1 sent SIGHUP to the `ExecStartPre` of the next session, which had already opened the same tty|`TTYVHangup` removed from `rg35xx-es/desktop/game`; `TTYReset` remains|
|Occasionally ES did not stop in time and the desktop start was cancelled (`code=killed, status=15/TERM`)|ES-DE ignores the exit flag while a modal dialog is open; `TimeoutStopSec=10` was not enough|`TimeoutStopSec=25` in `rg35xx-es.service`|

### 2. Without reflashing: `wifi.conf` on p1

Mount the card's FAT partition on a PC (in the running system it is also `/boot/firmware`) and create
`wifi.conf` in its root — the same content as in `config/wifi.conf`:

```sh
WIFI_COUNTRY=RU
WIFI_SSID_1="MyNetwork"
WIFI_PSK_1="my passphrase"
WIFI_SSID_2="MyNetwork-5G"
WIFI_PSK_2="my passphrase"
```

`wifi-provision.service` runs before `wpa_supplicant@wlan0.service` and regenerates
`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`. It is enough to reboot the device or run:

```sh
systemctl restart wifi-provision.service
systemctl restart wpa_supplicant@wlan0.service
```

### 3. Manually on the device: `wpa_supplicant` / `wpa_cli`

First delete `/boot/firmware/wifi.conf`, otherwise `wifi-provision` overwrites the config at boot.
Then:

```sh
rfkill unblock wifi
NET=$(wpa_cli -i wlan0 add_network)
wpa_cli -i wlan0 set_network "$NET" ssid '"MyNetwork"'
wpa_cli -i wlan0 set_network "$NET" psk '"my passphrase"'
wpa_cli -i wlan0 enable_network "$NET"
wpa_cli -i wlan0 select_network "$NET"
wpa_cli -i wlan0 save_config
systemctl restart systemd-networkd
```

Verification:

```sh
iw dev wlan0 link
ip -4 addr show wlan0
ping -c 3 deb.debian.org
journalctl -u wpa_supplicant@wlan0 -u wifi-provision -b
```

`wpa_supplicant@wlan0.service` reads `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`; the address is
assigned by DHCP through `systemd-networkd` (`config/rootfs/etc/systemd/network/20-wlan0.network`).
On rtw88, 5 GHz is unstable — prefer 2.4 GHz; for dropouts see `rtw88_core.disable_lps_deep=1` in
the known issues section.

## Writing the image and first boot

1. Insert an SD card larger than the image (16 GiB and above is comfortable; all its contents will be
   erased). The image occupies 4624 MiB, and the rest becomes the `/roms` partition on first boot.
2. Write the image **bit for bit**, not by formatting:
   - Windows: Rufus 4.x, **DD Image** mode;
   - Linux/macOS: `sudo dd if=out/rg35xxpro-debian.img of=/dev/sdX bs=4M status=progress conv=fsync`
     (verify `of=` with `lsblk`/`diskutil list`);
   - or balenaEtcher.
3. Insert the card into the RG35XX Pro and power it on. Boot comes from p1 (`boot.scr` → `Image` + DTB),
   and after ~20 s ES-DE appears on the screen. On first boot `rg35xx-userdata.service` creates the
   `/roms` partition using all free space on the card and formats it as FAT32 (label `DATA`), while
   `rg35xx-userdata-seed.service` lays out PortMaster, the `desktop` entries and the system directories
   there. In Windows this partition appears as an ordinary flash drive — games, videos and music can be
   copied from a PC; re-insert the card after the first boot so that Windows sees the new partition.
4. Get to the console: in ES-DE `Quit` → `Terminal` (or "Terminal.sh" in the `desktop` system). Login:
   `root` / `root`; the second user for the audio session is `gamer` / `gamer`. Input on the device
   itself requires a USB keyboard (OTG) or UART `ttyS0,115200`; otherwise connect over SSH after
   configuring Wi-Fi. Change the passwords immediately: `passwd` and `passwd gamer`.
5. Check the network: `ip -br a`, `iw dev wlan0 link`. Once an IP appears you can log in over SSH:
   `ssh root@<ip>`.
6. Re-provisioning (packages, user, PipeWire, zram, suspend disabled, volume buttons, mixer
   calibration): copy `scripts/device-provision.sh` from the repository to the device
   (`scp`/USB) and run `sh device-provision.sh`. The script is idempotent. In the image it has already
   been run with `--offline`; manually it is only needed on an old image or after manual changes.

If something did not come up, remove the card and read `boot-report.txt` in the root of p1 — it
contains `uname`, `/proc/cmdline`, the network, `wpa_supplicant`, input devices and the last 300
journal lines (in ES both `System info` and `journalctl -u rg35xx-es` over SSH are available).

## User partition: `DATA` (p3) and `/roms`

The image contains only BOOT and ROOT; games, videos and music live on a separate partition that
appears on first boot:

- `rg35xx-userdata.service` takes the last used sector from the partition table, aligns the start to
  1 MiB and creates p3 up to the end of the card. Root is mounted at that point, so a full re-read of
  the table (`BLKRRPART`) would fail — it uses `sfdisk --append --no-tell-kernel` and
  `partx --add`, which add only the new partition;
- the partition is formatted as FAT32 with label `DATA` — Windows sees it as an ordinary flash drive;
- the partition itself is mounted at `/mnt/userdata` (`uid=gid=1000`, `fmask/dmask=0022`), and
  **inside it there is a single `roms/` directory, which is bind-mounted to `/roms`**. On a card
  opened in Windows, the partition root shows `roms` — like on stock Anbernic firmware — instead of
  the dozens of system directories that ES-DE creates;
- `rg35xx-userdata-seed.service` (starts after `mnt-userdata.mount`, before `roms.mount`) creates
  `roms/` and lays out the `desktop`, `ports` (PortMaster) entries and one directory per system.
  Only missing entries are copied, so PortMaster updates and user files survive reboots;
- if p3 does not exist (first boot, card exactly the image size), the chain `mnt-userdata.mount` →
  seed → `roms.mount` is skipped and `/roms` remains a normal directory on the rootfs: boot does not
  break.

### Power loss and `fsck`

Linux vfat sets the dirty bit in byte `0x41` of the boot sector on every RW mount and clears it only
on a clean unmount. After a power-off/reset during a write the bit remains; the kernel still mounts
the partition RW and only prints a warning, so without a check the next boot would write to a
potentially inconsistent FAT, and a structural error would leave `/roms` unmounted until the card is
taken to a PC.

`rg35xx-userdata-check.service` sits in `local-fs.target` **before** `mnt-userdata.mount`:

- reads byte `0x41`; if the dirty bit is not set, it exits immediately — there is no full scan on
  every clean boot;
- if it is set, it runs `fsck.fat -a` (lost chains are saved as `FSCK*.REC`), limits the run to
  300 seconds and writes the output to the journal and `/dev/tty0`;
- after the check systemd still tries to mount the partition (`nofail`), and the result remains in
  `journalctl -b -u rg35xx-userdata-check` and in `boot-report.txt`.

In addition, p3 is mounted with `flush`: data is flushed when a file is closed, which makes the loss
window on a disconnect smaller (as in Batocera/Knulli). This does not replace `fsck`, but it reduces
the chance of corruption.

`rg35xx-userdata` detects the presence of p3 from the partition table (`sfdisk -d`), not from
`blkid`: a damaged boot sector would otherwise look like "there is no partition", and the script
would add a new partition on every boot instead of handing p3 over for recovery.

On first boot the partition is created, but it is mounted only on the next boot — this is how the
`local-fs.target` transaction works. After the first power-on it is enough to power the device off and
on, and `roms/` will appear.

FAT32 limitations: a file larger than 4 GiB cannot be placed on the partition, and there are no
symlinks or permissions. Reformatting p3 as exFAT is possible, but then `vfat` must be changed to
`exfat` in both `/etc/fstab` lines.

On-device checks:

```sh
sfdisk -d /dev/mmcblk0 | grep mmcblk0p          # three partitions, p3 to the end of the card
findmnt /mnt/userdata /roms                     # vfat and bind /dev/mmcblk0p3[/roms]
ls /mnt/userdata                                # roms (plus System Volume Information from Windows)
journalctl -b -u rg35xx-userdata -u rg35xx-userdata-check -u rg35xx-userdata-seed -u roms.mount
cat /run/rg35xx-userdata-fsck.log 2>/dev/null   # output of the last fsck.fat -a
od -An -tx1 -j65 -N1 /dev/mmcblk0p3            # dirty bit; 01 — the partition was mounted/crashed
```

Copying games/videos from a PC: power the device off, insert the card, open the `DATA` partition in
Windows, enter `roms` and put the files into the right directories (`roms/nes`, `roms/psx`, …). ES-DE
reads `ROMDirectory` from `es_settings.xml` — it points to `/roms`.

## Operating modes

Exactly one session lives on `tty1` at a time; switching is done by the root helper
`/usr/local/bin/rg35xx-session` (`gamer` has `NOPASSWD` sudo — otherwise PortMaster, which itself
calls `sudo` for `chmod /dev/tty0`, `/dev/uinput`, bind mounts and port installations, could not
work; the device already boots with `root/root` and root SSH login, so the security boundary does not
change).

|Mode|Unit|How to get there|
|---|---|---|
|ES-DE (default)|`rg35xx-es.service`|boot; `sudo rg35xx-session es`|
|Game/port (without ES)|`rg35xx-game.service`|launching a game or port from ES — automatically|
|Desktop (labwc)|`rg35xx-desktop.service`|ES → `desktop` → `Desktop Mode.sh`; `sudo rg35xx-session desktop`|
|Terminal|`rg35xx-terminal.service`|ES → `Quit` → `Terminal`; `sudo rg35xx-session terminal`|
|Power off/reboot|—|ES → `Quit` → `Power Off` / `Reboot`; `sudo rg35xx-session poweroff|reboot`|

`getty@tty1` is removed from the image: it would take the VT and fight the DRM client. The `Terminal`
icon starts it temporarily, `Quit` in the console (`exit`) does not; to return to ES, type
`sudo rg35xx-session es` or simply power the device off.

ES-DE starts in 640×480 mode without `--resolution` (the panel's only mode). The theme is
`linear-es-de` (MIT, installed together with ES-DE; the `frontend` stage deletes `modern-es-de` and
`slate-es-de`, which is 53 MiB with no benefit for 640×480). The settings pin `ThemeAspectRatio=4:3`,
so the 4:3 variant of the theme is used (`aspect-ratio-4-3.xml`) instead of the stretched 16:9 one.
The `Quit` menu is enabled (`ShowQuitMenu`, `CustomEventScripts`), and the exit scripts are in
`~/ES-DE/scripts/{quit,poweroff,reboot}/`.

Why it is done this way: 1 GiB of RAM is not enough for ES (~150 MB) plus an emulator/browser at the
same time. That is why a game always goes through `rg35xx-game.service`: ES is stopped (`Conflicts=`),
`sync` + `drop_caches` frees the page cache, `boot-report.timer` is disabled for the duration of the
game, and ES is started again after exit. From inside ES the launch is intercepted by
`/usr/local/bin/rg35xx-run-sh` (the `ports` system is patched to it in `es_systems.xml`) and by the
`/usr/local/bin/retroarch` shim: it puts argv into `/run/rg35xx/game.args` and switches modes instead
of trying to take DRM away from ES. After exit the game is closed through `rg35xx-session-after-game`
→ `rg35xx-session-apply es`: the helper waits until the session cgroup is empty (children of a port
may still hold DRM), clears `failed`, and only then brings ES-DE up. The ES-DE exit script stays silent
if a game launch has already requested a switch — otherwise `back` would cancel the launch.

### Games: RetroArch and cores

- `retroarch.cfg` (in `/home/gamer/.config/retroarch/`): `video_driver = "gl"` +
  `video_context_driver = "kms"`, 640×480, `audio_driver = "pulse"`. Debian builds RetroArch with
  KMS autodetection (`HAVE_KMS=auto`), so a separate `kmsdrm` is not needed. On-device check:
  `retroarch --features` must contain `KMS/EGL context support: yes`.
- Cores come from the libretro buildbot, not from Debian: the packaged cores in trixie are older, and
  the MAME core (112 MB) is not included in the image. The full list and sha256 are in
  `config/retroarch-cores.sha256`; for the `arcade`, `cps`, `cps1..3` systems in `es_systems.xml`,
  FinalBurn Neo is first by default.
- ES-DE takes the system config from `resources/systems/linuxarm/` (on AArch64; `linux/` is for
  x86-64) and finds cores via `es_find_rules.xml`. The linuxarm variant already lists
  `/usr/lib/aarch64-linux-gnu/libretro`, so it is enough that the cores live in exactly that
  directory; the `frontend` stage checks this and fails if upstream removes the line.
- `video_threaded = "false"`: an extra thread at 640×480 and 1 GiB of RAM only wastes memory.

### If ES-DE does not come up

|Symptom|What to check|
|---|---|
|Black screen / `KMS` errors in `journalctl -u rg35xx-es`|`SDL_VIDEODRIVER=kmsdrm`, `SDL_VIDEO_EGL_DRIVER=libEGL.so.1`, `kmscube -D /dev/dri/card1`; the modeset card is `card1` (`sun4i-drm`), `card0` is render-only Panfrost|
|ES-DE does not create a GLES context|as an emergency option, run it through `cage`: `ExecStart=/usr/bin/cage -- /usr/bin/es-de --home /home/gamer --no-splash` (edit `ExecStart` only); games still run in a separate unit with KMS|
|The gamepad is not visible in ES|read the actual GUID (`SDL_JoystickGetDeviceGUID`, ES-DE log) and replace the line in `session.env`/`gamecontrollerdb.txt`|
|`Configured theme ... does not exist`|check `/usr/share/es-de/themes/linear-es-de/theme.xml` and `capabilities.xml` (without the latter ES-DE ignores the theme)|
|A port does not start (`Exec format error`)|armhf port: `/lib/ld-linux-armhf.so.3`, the port's `LD_LIBRARY_PATH`; if the system is incompatible, aarch64 ports remain available and arm64 sessions are unchanged|

### Gamepad

The driver (`rocknix-singleadc-joypad`, ROCKNIX DTS) provides the `H700 Gamepad` device, vendor
`0x484B`, product `0x14DF`, bus `HOST`; the SDL GUID is
`1900f6a24b480000df14000000010000`. On this board the DTS names the east button `A`
(`BTN_EAST`) and the south one `B` (`BTN_SOUTH`), therefore:

- SDL (`ES-DE`): `a:b1, b:b0, x:b3, y:b2` — the same line as in
  `/etc/rg35xx/session.env`, `~/.config/SDL-GameControllerDB/gamecontrollerdb.txt` and
  `/roms/ports/PortMaster/gamecontrollerdb.txt`;
- RetroArch (`~/.config/retroarch/autoconfig/udev/H700 Gamepad.cfg`): `input_a_btn = "1"`,
  `input_b_btn = "0"`, and the remaining buttons follow the evdev order (`BTN_SOUTH`, `BTN_EAST`, …).

If ES-DE does not see the gamepad, read the actual GUID via SDL2 on the device (ES-DE log or
`SDL_JoystickGetDeviceGUID`) and replace the line in both files; the name/vendor/product do not need
to be changed.

### Ports: PortMaster

PortMaster lives in `/roms/ports/PortMaster` (launch with `PortMaster.sh` in `/roms/ports`), reads
`gamecontrollerdb.txt` from there and gets its environment from `/etc/rg35xx/{session,kms}.env`.
PortMaster launches `pugwash` through `sudo`, and `sudo` wipes the environment and keeps only
`SDL_GAMECONTROLLERCONFIG_FILE` (which its `control.txt` fills from its own device table; the
upstream branch for `platform-rocknix-singleadc-joypad` does not exist). The build appends a branch
with GUID `1900f6a24b480000df14000000010000` to `control.txt`, so `/tmp/gamecontrollerdb.txt` receives
our line. In addition, `/etc/sudoers.d/10-rg35xx` adds
`Defaults env_keep += "SDL_GAMECONTROLLERCONFIG"`: without it SDL loses the line from `session.env`
when entering `sudo` and takes the built-in Xbox mapping `a:b0, b:b1`, which swaps A and B.
`env_keep` also guards against PortMaster updates that may replace `control.txt`.

The current port index returns `attr.runtime` as a list (empty or containing several runtimes), while
PortMaster 8.6.1 in places expects a string: selecting any port crashed with
`AttributeError: 'list' object has no attribute 'startswith'`. The build applies
`config/portmaster/portmaster-runtime-list.patch`: the port card, download size, installation,
filters and the runtime manager iterate over the list and check each runtime. Without the patch both
"Ready to run ports" and "All ports" crash.

The same patch sets `PORTMASTER_NO_SELF_UPDATE = True`: the PortMaster stable channel still offers
GUI `2024.03.10-0841`, and `version_parse()` considers the date `2024...` newer than `8.6.1` and
replaces the working build with the old, incompatible one. Updating the port catalogue and sources
works as before; only the GUI self-update is blocked. The acceptance check watches both markers.
`armhf` was added (`dpkg --add-architecture armhf`) along with 32-bit SDL2/OpenAL/GL/ALSA/X11: part
of the PortMaster catalogue is built for armhf, and the kernel supports `CONFIG_COMPAT=y`. If a
specific armhf port still does not start, check `/lib/ld-linux-armhf.so.3` and the port's
`LD_LIBRARY_PATH`; global aarch64 sessions are unaffected.

### Desktop: labwc

Started by `rg35xx-desktop.service` (labwc, `WLR_BACKENDS=drm,libinput`,
`WLR_DRM_DEVICES=/dev/dri/card1`, `seatd` for the seat). Autostart is `~/.config/labwc/autostart`
(waybar, pcmanfm on the desktop, swaybg). The `Menu` button in waybar opens `fuzzel`
(application list), `Settings` opens the `rg35xx-settings` menu: Wi-Fi (`rg35xx-wifi` on `wpa_cli`),
Bluetooth (`bluetoothctl`), sound (`pavucontrol`), brightness (`brightnessctl`), system state,
exit to ES/terminal/reboot/power off. Exiting labwc (without an explicit switch) returns to ES.

The Bluetooth daemon is brought up only in Desktop (`Wants=bluetooth.service`); in ES, the console and
games it is stopped to save memory. AntiMicroX (`antimicro`) requires `/dev/uinput` — the module is
loaded by `modules-load.d`, device permissions are granted by `udev/rules.d/60-uinput.rules`
(`GROUP="input"`), and `gamer` is in the `input` group.

### SD card: moderate wear reduction

The "balanced" option was chosen: the journal stays on disk with a hard limit, `/tmp` lives in RAM.

|What|How|
|---|---|
|`/`|`noatime,commit=120,errors=remount-ro` — up to 120 s of writes are lost on a power failure|
|`/tmp`|tmpfs 256M, `nosuid,nodev`|
|`/var/log`|on disk; journald `SystemMaxUse=32M`, `MaxRetentionSec=1week`, `SyncIntervalSec=5m`|
|trim|`fstrim.timer` (weekly), no `discard` in fstab|
|page cache|`vm.dirty_writeback_centisecs=1500`, `dirty_expire_centisecs=3000`|
|core dumps|disabled (`coredump.conf.d/00-disable.conf`)|
|Wi-Fi|`wifi-provision` rewrites the config only when the content changes|
|boot-report|every 30 minutes instead of 5|
|Firefox|disk cache disabled, 32 MiB RAM cache|
|swap|zram only (50 %, zstd), no swap file|

## Build stages

Everything needed is in this repository: `build.sh` (host packages, sources, patches, build,
rootfs, image), `config/dts/` (board DTS), `config/patches/` (our patches on top of ROCKNIX),
`config/rootfs/` (files that are placed into the rootfs), `scripts/device-provision.sh` (device
setup; the same script is called during the rootfs build in the chroot with `--offline`).

|Stage|What it does|Result|
|---|---|---|
|`deps`|host apt packages|—|
|`sources`|downloads and sha256-verifies Linux 7.1.2, U-Boot v2026.01, TF-A v2.12.0, clones ROCKNIX `20261101`|`$BUILD_DIR`|
|`atf`|patch `000-use-gcc-for-asm`, `PLAT=sun50i_h616 bl31`|`bl31.bin`|
|`uboot`|DDR3 patches, `anbernic_rg35xx_h700_lpddr3_defconfig`, BL31 built in|`out/u-boot-sunxi-with-spl.bin`|
|`kernel`|ROCKNIX + our patches, our DTS, `linux.aarch64.conf` + tweaks, `Image dtbs modules`|`out/Image`, `out/*.dtb`|
|`rootfs`|debootstrap trixie arm64, packages, `config/rootfs`, `device-provision.sh --offline`, kernel modules|`$BUILD_DIR/rootfs`|
|`frontend`|ES-DE 3.5.0 from source under qemu-user (`GLES=ON`, `DEINIT_ON_LAUNCH=ON`), libretro cores by sha256, PortMaster, `es_systems.xml` patch|`/usr/bin/es-de`, `/usr/share/es-de`, cores, `/roms/ports/PortMaster`|
|`image`|`boot.scr` (`panic=10 pstore.backend=ramoops`), FAT32 p1, ext4 p2 (4096 MiB), MBR; the image ends at p2 — `/roms` is created on the card at first boot|`out/rg35xxpro-debian.img` + `.sha256`|

Individual stages can be rerun: `sudo ./build.sh kernel image`; the build directory is changed with
the `BUILD_DIR=/path` variable. Re-running is idempotent: downloaded archives are checksum-verified,
patches are marked with a marker file, apt/rootfs are resumed.

Build parameters that are easy to change: `LINUX_VER`, `UBOOT_VER`, `ATF_VER`, `ROCKNIX_TAG`, the
`SHA256` constants — at the top of `build.sh`; Wi-Fi (`config/wifi.conf`), DTS and patches — in
`config/`.

A full build from scratch was verified in an isolated copy of the repository on 2026-11-12:
`./build.sh` reaches `exit=0`, producing `Image`, `u-boot-sunxi-with-spl.bin`, the DTB and an image
(8 GiB at the time, a single ROOT partition to the end of the card). After the switch to a separate
`/roms` and the Wi-Fi rework, the full run has not been repeated: the modified scripts were checked
with `bash -n`/`sh -n`, and partition creation plus seed-tree layout were exercised on a loop device
with the same layout.

For the ES/Desktop modes the image has not been built end to end yet; it was verified piecewise:
ES-DE 3.5.0 builds natively with the same `cmake` flags and dependency list (`es-de --version`
= `ES-DE 3.5.0 (r52)`, `make install` installs `/usr/bin/es-de`, `/usr/share/es-de` and three
themes); the `es_systems.xml` patch was run against an actually installed
`resources/systems/linuxarm/es_systems.xml` (ports → `rg35xx-run-sh`, FinalBurn Neo first in
`arcade`/`cps*`, 195 systems, idempotent); all cores were downloaded from the buildbot and matched
`config/retroarch-cores.sha256`; the units passed `systemd-analyze verify`, and the mode scripts
passed a functional test with a fake `systemctl` (switches, guard on `/run/rg35xx/target`, argv
parsing via `game.args`, `euid` paths of the `retroarch` shim). `Image` is not byte-for-byte
reproducible: two builds of the same tree produce different sha256 values (the source is not
`KBUILD_BUILD_TIMESTAMP`, which is pinned), so verify the image by booting and acceptance rather than
by hash alone.

## Image layout

|Partition|Offset|Size|FS|
|---|---|---|---|
|U-Boot (`u-boot-sunxi-with-spl.bin`)|8 KiB|650,089 B|raw|
|p1 BOOT|16 MiB (sector 32768)|512 MiB|FAT32: `Image`, DTB, `boot.scr`, `extlinux/extlinux.conf`|
|p2 ROOT|528 MiB (sector 1081344)|4096 MiB|ext4, label `ROOT`, `/dev/mmcblk0p2`|
|p3 DATA|4624 MiB — end of card|rest of the card|FAT32, label `DATA`, created on first boot: mounted at `/mnt/userdata`, with its `roms/` at `/roms` (bind)|

The image ends at the p2 boundary: the card is always larger, and `rg35xx-userdata.service` gives all
remaining space to the user partition. The calculation lives in `build.sh`: `BOOT_OFFSET_MIB` /
`BOOT_MIB` / `ROOT_MIB`.

Boot: `boot.scr` (`fatload mmc 0:1` + `booti`) → `Image` + DTB; `extlinux.conf` is a fallback for
`bootflow scan`.

## Verified at build time

- `sha256sum` of the sources matched the pinned values (Linux, U-Boot, TF-A); ROCKNIX tag `20261101` = `cefc1433`.
- `e2fsck -fn` on root: clean; `fsck.fat` on p1: clean; `boot.scr` is a valid `AArch64 Linux Script`.
- The `/roms` partition was verified without rebuilding the image: `rg35xx-userdata` was run on a loop
  device with the same layout in 8 scenarios — creating p3 on a 12000 MiB card (start aligned to 1 MiB,
  end matching the end of the card), FAT32 with label `DATA`, `fsck.fat` clean, a repeated run doing
  nothing, mounting with the fstab options yielding `uid=1000` and 755 permissions, seeding laying out
  `desktop`/`ports`/system directories, user edits not being overwritten, and a card exactly the image
  size as well as a non-block device being handled without errors. `findmnt --verify` on the new fstab
  line — 0 parse errors; `systemd-fstab-generator` produces `roms.mount` with
  `Requires=`/`After=rg35xx-userdata.service`, and the unit lands in `local-fs.target.wants`.
- p3 power loss was verified on a live device with a hard reset (`echo b > /proc/sysrq-trigger`): on
  the next boot `rg35xx-userdata-check` saw the dirty bit, ran `fsck.fat -a` (727 files, 2358 clusters,
  no errors), cleared the bit and only then mounted p3; `fsck.fat` on 53.7 GiB took ~3 s. A repeated
  run on a mounted partition is correctly skipped.
- Desktop after the same reset: `/run/rg35xx` created as `root:gamer 0775`, `waybar`, `swaybg`,
  `pcmanfm` and `labwc` started, `desktop.log` is being written; acceptance — 0 FAIL.
- Smoke-boot of the image under `qemu-system-aarch64 -M virt` (disk via usb-storage): kernel 7.1.2 comes
  up, `EXT4-fs (sda2) mounted`, systemd reaches `multi-user.target`, `ssh.service` and `getty@tty1` are `active`.
- Built DTB: `mmc0 = mmc@4020000` (SD), panel `anbernic,rg35xx-plus-panel` + `panel-mipi-dpi-spi`,
  `dr_mode = "otg"` on musb, `dcdc3 = 1.2 V`.
- Kernel config compatibility: `PANFROST`, `DRM_SUN4I`, `DRM_PANEL_MIPI`, `PWM_SUN8I`, `RTW88_8821CS`,
  `USB_MUSB_DUAL_ROLE`, `EXT4_FS`, `MMC_SUNXI`, `USB_HID` — all `=y`.

## Build gotchas (verified in practice)

1. **Build host** — verified on WSL2 + Ubuntu 24.04 with systemd enabled; on plain Debian/Ubuntu the
   same stages run without WSL specifics.
2. **TF-A**: the stock `make` without `CC=` fails in TF-A 2.12 — `$(CC)` for the asm rule is not defined
   at macro evaluation time → `make: x: No such file`. Build with `CC=aarch64-linux-gnu-gcc` (plus a
   clean `build/`).
3. **U-Boot**: needs `python3-dev` (pylibfdt) — it was missing from the original package list.
4. **debootstrap**: hits usr-merge (`tar: ./lib: Cannot create symlink to 'usr/lib': File exists`).
   Fix: `/lib` → symlink to `usr/lib`, re-extract all `.deb` files, then `dpkg --unpack` +
   `dpkg --configure -a` in the chroot (the stock `--second-stage` does not start without
   `/debootstrap/mirror`).
5. **WSL network**: an MTU black hole — some Debian downloads hung for 2 min (`Connection timed out`).
   After `ip link set eth0 mtu 1400` the speed is normal. `security.debian.org` was unreachable during
   the build (W: in apt), so security updates did not make it into the rootfs — update on the device
   after the first boot.
6. **`iw` path** — `/usr/sbin/iw`, not `/usr/bin/iw`.
7. **Boot check** — the kernel is built without `VIRTIO_PCI`, so the smoke-boot goes through `usb-ehci` +
   `usb-storage`, root `/dev/sda2`. The `dev-mmcblk0p1`, `wlan0`, `ttyAMA0` timeouts expected in QEMU
   are a consequence of emulation; on hardware these devices are absent or different.
8. **DRAM**: on the device `dram_type=7`, `dram_clk=0x2a0` (672 MHz), `dram_zq=0x06060606`,
   `dram_odt_en=0x0d0d0d0d`, `dram_para1=0x1919`, `dram_para2=0x9988eeee` — this is the ROCKNIX LPDDR3
   profile (`dram_dx_odt/dx_dri/ca_dri` from the BSP DT are other fields and do not disprove LPDDR3:
   a build with `lpddr4_defconfig` (DCDC3 = 1.1 V) does not boot at all, while LPDDR3 does).

## Found and fixed on real hardware

1. **Dark screen = DE2 does not come up.** In the device's `boot.log`:
   `sun50i-de2-bus 1000000.bus: error -EINVAL: Couldn't map SRAM to device` →
   `probe with driver sun50i-de2-bus failed`. The ROCKNIX patch `0002-rg35xx-enable-HDMI-LCD` adds the
   DE2 bus as `allwinner,sram = <&sram_c 1>`, while `sunxi_sram_claim()` looks up the SRAM section node
   by phandle with a compatible from `sunxi_sram_dt_ids`; `sram_c` is an `mmio-sram` container (H616 has
   no section, unlike H6/A64). Fix in `sun50i-h700-anbernic-rg35xx-pro.dts`:
   ```dts
   &sram_c {
       de2_sram: sram-section@0 {
           compatible = "allwinner,sun50i-h6-sram-c", "allwinner,sun50i-a64-sram-c";
           reg = <0x0 0x30000>;
       };
   };
   &{/soc/bus@1000000} { allwinner,sram = <&de2_sram 1>; };
   ```
   After that DE2/mixer/TCON/panel come up, the backlight turns on, and fbcon appears.
2. **`wifi-provision` created a systemd transaction cycle** (a unit with `Before=wpa_supplicant@wlan0`
   called `systemctl restart wpa_supplicant@wlan0`) — that line was removed from ExecStart; the unit
   already starts after provisioning. In addition, `systemd-networkd-wait-online.service` is disabled
   (it delayed login).
3. **5 GHz on rtw88 is unstable** (also on Knulli — it uses a vendor BSP driver there): all networks
   listed in `config/wifi.conf` end up in the image, but wpa_supplicant selects by signal level. If
   5 GHz gives trouble, keep only 2.4 GHz or restrict the channels with
   `scan_freq=2412 2437 2462 2472` in the `network` block. Specific SSIDs do not enter the repository.
4. **Diagnostics removed from the final image**: no `init=/usr/local/sbin/early-init`, no
   `boot-marker.service`, no markers in `boot.scr`; `boot.scr` and `extlinux.conf` are ordinary.
5. Verified on the device: `panfrost 1800000.gpu: mali-g31 id 0x7093`,
   `[drm] Initialized panfrost 1.6.0`, `rtw88_8821cs ... Firmware version 24.11.0`,
   systemd reaches `multi-user.target`, the console on the 640x480 panel works.
6. **`udev` was not installed** — `debootstrap --variant=minbase` + `apt-get --no-install-recommends`
   did not pull it in. The symptoms were exactly what was seen on hardware:
   `wlan0` in state `DOWN`, `Dependency failed for wpa_supplicant@wlan0.service`
   (the unit has `Requires=sys-subsystem-net-devices-wlan0.device`, and without udev there are no such
   device units), and a login prompt after ~90 s — the timeout waiting for that same device unit.
   Fix: `apt-get install udev` (257.13-1~deb13u1); in the image it was verified that
   `/usr/lib/systemd/system/sysinit.target.wants/systemd-udevd.service` and `…-udev-trigger.service`
   are present, `/usr/bin/udevadm` exists, and `/etc/udev/{rules.d,hwdb.d}` are created.
7. **DNS in the image came from WSL.** The rootfs contained a WSL-generated `/etc/resolv.conf` with
   `nameserver 10.255.255.254` — the device has no such address, so `getent hosts` and `apt` failed
   ("Temporary failure resolving"). Fix: `/etc/resolv.conf` → symlink to
   `/run/systemd/resolve/stub-resolv.conf` (in the rootfs and on the device). `resolvectl` always
   worked — only the glibc resolver was broken.
8. **Headphones were silent although the speaker played.** The amplifier (`allwinner,pa-gpios` = PI5) in
   this circuit is not "on the speaker" but in the `LINEOUT` break before the 74HC4052 analog
   multiplexer, which routes the signal to the speaker and to the jack. ROCKNIX patch `0163` enables it
   with the DAPM event of the `Speaker` pin, and DAPM mutes the `Speaker` pin when headphones are
   inserted (the `Headphone` pin is active) — so the signal simply does not reach the jack. Fix in
   patch `9001`: the amplifier is moved into a separate widget `Speaker Amp` (`SND_SOC_DAPM_PGA_E` with
   the same event) and connected in series with `LINEOUT`, so it follows playback rather than the pin
   state.
9. **`EIO` on any playback after a failed resume.** `sun4i_codec_startup()` returned
   `-EIO` if the `clocks_suspended` flag remained (patch `0163`). One failed `resume_early` — and sound
   is dead until reboot. In patch `9001` `startup()` raises the clocks itself via
   `sun4i_codec_resume_early()`.
10. **Suspend without the TF-A patch = hang.** `systemd-logind` allowed sleep, but `mem` sleep on H700
    without `001-allwinner-h616-psci-system-suspend` and `h700-suspend-stub` hangs the SoC. Until
    phase 5 is closed, sleep is disabled at all levels:
    `/etc/systemd/logind.conf.d/50-rg35xxpro-nosleep.conf` (`AllowSuspend=no`,
    `HandleSuspendKey=ignore`, `HandlePowerKey=poweroff`) and a mask on
    `suspend/hibernate/hybrid-sleep/suspend-then-hibernate.target`. Check: `CanSuspend` = `no`.
11. **PipeWire does not work under root.** Debian units contain `ConditionUser=!root` — the services are
    silently skipped, and `speaker-test -D default` fails with `-112 Host is down`. A regular user is
    needed: `gamer` was created (uid 1000, groups `video render input audio netdev plugdev`),
    `loginctl enable-linger gamer`, and the `pipewire.socket`/`pipewire-pulse.socket`/`wireplumber`
    units are enabled in its session. Plus `rtkit` for real audio stream priority.
12. **Launching a game or port dropped to the console.** ES-DE always runs its quit scripts on stop,
    including when the mode switcher stops it. The script called `rg35xx-session back`, `back` wrote
    `terminal` to `/run/rg35xx/target` and started the console — on top of the just-requested game.
    Fix: the script exits silently if `/run/rg35xx/target` does not say `es`. Symptom in the journal:
    `sudo rg35xx-session game` and a second later `sudo rg35xx-session back`.
13. **PortMaster did not start: `ImportError: found ['libSDL2_mixer-2.0.so.0'], but it's not usable`.**
    The image had only 32-bit `libsdl2-mixer`/`libsdl2-image` (for armhf ports), while `pugwash`
    is 64-bit python and loads native libraries. Added `libsdl2-image-2.0-0` and
    `libsdl2-mixer-2.0-0` for arm64.
14. **ES-DE crashed with `Couldn't initialize SDL: kmsdrm not available` after exiting a port.** Port
    children outlive its main process (`PortMaster` restarts itself via `sudo`, which ignores SIGTERM),
    systemd kills them only after `TimeoutStopSec`, and all that time they hold
    `/dev/dri/card1`. Now `rg35xx-session-apply` kills the cgroup of the already stopped session
    (`systemctl kill -s SIGKILL`, only for `deactivating`/`failed`) and only then starts the new one,
    and exiting a game goes through the same helper instead of a direct `systemctl start`.
15. **Games were in the root of a large partition.** The partition was mounted directly at `/roms`, so
    Windows showed not `roms` but dozens of ES-DE system directories. Now p3 is mounted at
    `/mnt/userdata`, and its `roms/` is a bind mount at `/roms`.

## What is already working in hardware/kernel (for the next phases)

|Subsystem|State in the current image|
|---|---|
|SD slot 2|`mmc@4022000` = alias `mmc1` → `/dev/mmcblk1`: works (verified on a 32 GB card, high-speed 4-bit 50 MHz, read 23.9 MB/s, write 8–9 MB/s, exfat and vfat mount)|
|SD slot 1|`mmc@4020000` = `mmc0` → `/dev/mmcblk0` (root)|
|Wi-Fi|`mmc@4021000` = `mmc2`, `non-removable`, pwrseq, SDIO RTL8821CS|
|Gamepad|Driver `rocknix-singleadc-joypad` (vendored in `config/kernel/joypad`, `CONFIG_JOYSTICK_ROCKNIX_SINGLEADC=y`): buttons are GPIO, sticks go through the PI1/PI2 analog multiplexer to `gpadc` channel 0 (`amux-count = <4>`, `amux-channel-mapping = <0 2 1 3>`). Verified: `js0` reports `ABS_X/Y/RX/RY` with full ±32767 travel (raw 1987/2050/2042/2077 at rest, PI1/PI2 = 11/10/01/00), ADC polling ~300 Hz. The `pwms`/`pwm-names` properties were removed from the node: the vibration motor is untested, and a failed `devm_pwm_get()` takes down the whole probe|
|Volume buttons|`gpio-keys-volume`: `KEY_VOLUMEUP` (115), `KEY_VOLUMEDOWN` (114) → `triggerhappy` → `wpctl` (verified)|
|Sound|ASoC card `h616-audio-codec` (`sun4i-codec`): `allwinner,pa-gpios` = PI5 (amplifier), `allwinner,pa-supply` = `cldo1` (`vcc-spkr-amp`), `hp-det-gpios` = PI3 (headphone detect). The speaker plays, and headphones play after patch `9001`|
|Battery/charging|PMIC **AXP717** (not AXP2202 — verified via `axp20x-i2c 0-0034: AXP20x variant AXP717 found` and `compatible = "x-powers,axp717"`): `axp20x-usb-power` + `axp20x-battery-power-supply`, regulators `DCDC1..4`, `ALDO1..4`, `BLDO1..2`, `CLDO1` in the DTS|
|RTC|`pcf8563` on `r_i2c` (patch `0156`), `CONFIG_RTC_HCTOSYS=y` + `hctosys=rtc0` — time survives a reboot; `systemd-timesyncd` is enabled, `System clock synchronized: yes`|
|Bluetooth|RTL8821CS on `hci_uart`+`btrtl`; the firmware is compiled into `Image` via `EXTRA_FIRMWARE` (`rtl_bt/rtl8821cs_fw.bin` 56 KB + `rtl_bt/rtl8821cs_config.bin` 25 B from `config/firmware`): `hci0: RTL: fw version 0x75b8f098`; without it dmesg had `Direct firmware load ... failed with error -2`|
|CPU/GPU OPP|patches `0200-h700-update-opps`, `0210-…-suspend-opp`, `0007-rg35xx-add-GPU-opp`|
|Build from scratch|Verified 2026-11-12 in an isolated copy of the repository (`rsync --exclude=out`, own `BUILD_DIR`): `./build.sh` completes, exit=0, producing `Image` 30,431,240 B, `u-boot-sunxi-with-spl.bin` 650,089 B (with BL31 incl. the stub) and `rg35xxpro-debian.img` 8 GiB. The DTB matched the incremental build byte for byte (`3263ee6e…`). `KBUILD_BUILD_TIMESTAMP` is pinned in `build.sh` (`2026-11-01 00:00:00 UTC`), so `uname -v` no longer "drifts", but **`Image` is not byte-for-byte reproducible**: two builds of the same tree give different sha256 values — the source is not the build time but something else (not localized)|
|DRM WARNING|Boot used to have two `WARNING`s (`drm_mode_object.c:46`/`:246`): panel-mipi set `panel_orientation` from `get_modes()`, i.e. after `drm_dev_register()`. Patch `0030`: `sun4i_rgb` calls `drm_connector_set_orientation_from_panel()` right after `drm_connector_init()`, and the late call from the panel is removed. Verified: `dmesg | grep -c WARNING` went from 2 to 0|
|Graphics|Wayland and KMS work through Panfrost (Mesa 25.0.7, GLES 3.1, `Mali-G31`): `glmark2-es2-wayland` under `cage` — score 372. By default ES-DE boots on KMS (`rg35xx-es.service`); Desktop is a separate labwc session, and the terminal is `getty@tty1`, which is no longer enabled in the image but starts on demand (`rg35xx-terminal.service`). `cage` remains only as an emergency fallback for ES|
|Memory|zram 512 MiB (50 %, zstd) with `vm.swappiness=100`; `earlyoom` (`-m 10 -s 5`, spares systemd/sshd/PipeWire/labwc/waybar, kills the emulator or browser first) instead of a late kernel OOM. ES and Desktop never run at the same time, and a game runs only with the frontend stopped (`rg35xx-game.service`)|
|Thermals/frequencies|`schedutil` instead of the hardcoded `performance` (480–1416 MHz, `rg35xx-cpu-governor.service`); GPU `simple_ondemand` 420–648 MHz. In `sun50i-h616.dtsi` the 60/70 °C passive trips **have no `cooling-maps`** — they were dead: under 4-core load the frequency stayed at 1416 MHz at 61–62 °C. Our DTS adds `map0/map1` on `cpu0` + `hysteresis = <2000>`; verified: 60.4 °C → `cdev0=3`, `scaling_max_freq` 1200 MHz|
|SD wear|root is mounted `noatime,commit=120`, `/tmp` is tmpfs 256M; the journal is limited to `SystemMaxUse=32M`/1 week (`journald.conf.d/00-size.conf`), `fstrim.timer` is enabled, core dumps are off, `wifi-provision` does not rewrite an unchanged config, and `boot-report` writes every 30 minutes|
|Suspend|TF-A **2.12.0** + ROCKNIX `001-allwinner-h616-psci-system-suspend.patch` + SRAM stub `h700-suspend-stub` (`712653d`, LPDDR3, 18,872 B) compiled into BL31 (`SUNXI_SYSTEM_SUSPEND=1 SUNXI_SUSPEND_STUB=...`); BL31 65,641 B, U-Boot rebuilt, `strings bl31.bin` contains `PSCI: System suspend available (SRAM stub %zu bytes, DRAM type %u @ %u MHz)`. Upgrading to 2.15.0 is **impossible without porting the patch**: 2.15 removed `plat_psci_ops::pwr_domain_pwr_down_wfi`/`psci_power_down_wfi`, which it relies on — that is why ROCKNIX pins 2.12.0|

Device provisioning (DNS, packages, the `gamer` user, PipeWire, zram, suspend disabled, power save
off, volume buttons, mixer calibration) is a single idempotent script from the repository directory;
it works both on a live device (the script has to be copied there) and in the image chroot:
`sh scripts/device-provision.sh` / `sh scripts/device-provision.sh --offline`.

## Field diagnostics (without keyboard or network)

`boot-report.service` (+ timer) writes `boot-report.txt` to the root of p1: `uname`, `/proc/cmdline`,
`ip -br a`, `iw dev`, `iw dev wlan0 link`, `rfkill`, `networkctl status wlan0`, `wpa_cli status`,
the `wpa_supplicant@wlan0`/`wifi-provision`/`rg35xx-wifi-unblock` journals, `iw reg get`, unit states,
the `wpa_supplicant` config, the state of `/roms`, `lsusb`, the list of input devices and the last
300 lines of `journalctl -b`. Three logs that did not exist before are included separately:

|File|Contents|
|---|---|
|`/run/rg35xx/desktop.log`|how waybar/swaybg/pcmanfm came up, their stderr and which of them survived after 3 s (on `/run/rg35xx` problems — `$XDG_RUNTIME_DIR/rg35xx-desktop.log`)|
|`/run/rg35xx/game.log`|argv of the launched port/game, stdout and stderr (otherwise tty1 eats them)|
|`/run/rg35xx-userdata-fsck.log`|output of the last `fsck.fat -a` after an unclean shutdown|
|`/roms/ports/PortMaster/log.txt`|PortMaster's own log: `pugwash` output, Python tracebacks|

It is updated 60 s after boot, then every 5 minutes and on shutdown. It is enough to remove the card
and read the file on a PC — no UART needed.

The checksum is written next to the image: `out/rg35xxpro-debian.img.sha256`. Check:
`cd out && sha256sum -c rg35xxpro-debian.img.sha256`.

### Panic capture

`panic=10 pstore.backend=ramoops` in `boot.cmd`/`extlinux.conf` + the `ramoops@48000000` node (1 MiB in
`config/dts/…-pro.dts`, `CONFIG_PSTORE_RAM/CONSOLE/PMSG=y`). After a panic/hang with an oops, the
console text sits in `/sys/fs/pstore/` and survives a reboot; previously `console=tty0` without UART
left nothing behind, and `panic=0` hung the SoC instead of rebooting.

### Our patches on top of ROCKNIX

|File|What it does|
|---|---|
|`config/dts/sun50i-h700-anbernic-rg35xx-pro.dts`|board DTS: DE2/SRAM, LPDDR3 1.2 V, `gpio-keys` on `&joypad`, `ramoops`|
|`config/patches/9001-asoc-sun4i-codec-h700-audio-fixes.patch`|1) `sun4i_codec_startup()` raises the clocks itself after a failed resume instead of `-EIO`; 2) the `Speaker Amp` amplifier in series with `LINEOUT`, so headphones work with the jack inserted|

Kernel settings that differ from the ROCKNIX config: `CONFIG_JOYSTICK_SINGLEADC_JOYPAD` is disabled
(the driver is only for Qualcomm SM4450 and does not build on arm64/Allwinner), and
`CONFIG_PSTORE_RAM/CONSOLE/PMSG` are enabled.

## Gamepad

The image builds the ROCKNIX `rocknix-singleadc-joypad` driver (`config/kernel/joypad/`, enabled by
patch `0020-joypad-kconfig.patch` as `CONFIG_JOYSTICK_ROCKNIX_SINGLEADC`). The `&joypad` node from
ROCKNIX patch `0140` describes the buttons as GPIO nodes and the sticks as one `gpadc` channel
(channel 0) through the `amux` analog multiplexer; our change in `config/dts/` raises
`amux-count` to 4, because the Pro has two pairs of axes instead of zero.

|Device|Codes|
|---|---|
|A, B, X, Y|`BTN_EAST`, `BTN_SOUTH`, `BTN_NORTH`, `BTN_WEST`|
|L1, R1, L2, R2|`BTN_TL/TR/TL2/TR2`|
|Select, Start, Menu|`BTN_SELECT/START/MODE`|
|Stick presses|`BTN_THUMBL/THUMBR`|
|D-Pad|`BTN_DPAD_UP/DOWN/LEFT/RIGHT`|
|Sticks|`ABS_X/ABS_Y` (left), `ABS_RX/ABS_RY` (right)|

Important: the DTS names the east button `A` (`BTN_EAST`) and the south one `B` (`BTN_SOUTH`), so in
SDL it is `a:b1, b:b0`, and in RetroArch `input_a_btn = "1"`, `input_b_btn = "0"`. Both lines and the
SDL GUID (`1900f6a24b480000df14000000010000`) are fixed in `/etc/rg35xx/session.env`,
`~/.config/retroarch/autoconfig/udev/H700 Gamepad.cfg` and `gamecontrollerdb.txt`; details are in the
"Operating modes → Gamepad" section.

Vibration is not wired up: in the Pro DTS `pwms`/`pwm-names` were removed, otherwise a failed
`devm_pwm_get()` brings down the whole probe together with the buttons.

## Known issues and next steps

|Problem|Diagnosis|Next step|
|---|---|---|
|Analog sticks do not work|no driver for Allwinner (see above)|a dedicated IIO driver: `amux-*` GPIO → `gpadc` channel → `ABS_*`, calibration via `abs_*-tuning`|
|Two DRM `WARNING`s at boot|`panel_mipi_get_modes()` calls `drm_connector_set_panel_orientation()`, and the DRM core does it again via `.get_orientation` → the property is created twice (`drm_mode_object.c:46`, `:246`). Cosmetic, but it dirties `dmesg` and sets taint `W`|remove the call from the driver (not guard it, remove it) and verify that the console rotation has not changed|
|Wi-Fi: 20 min of continuous ping verified|300 pings, no loss (the only 5 in a row — device reboot); `wifi-powersave-off.service` keeps power save off|a load test with active traffic; on dropouts — `rtw88_core.disable_lps_deep=1`|
|Suspend disabled|without TF-A `001-allwinner-h616-psci-system-suspend` + `h700-suspend-stub`, sleep hangs the SoC|phase 5: rebuild TF-A 2.15.0 + the stub for lpddr3|
|Wi-Fi did not come up at all although the config was correct|the global config section contained `powersave=0`. This is not a global wpa_supplicant field: the daemon wrote `Line 4: unknown global field 'powersave=0'`, refused to read the file and died with `status=255`, systemd restarted it three times and gave up. It is immediately visible in the journal|the line was removed from `wifi-config-gen`; rtw88 LPS is suppressed at the driver level (`wifi-powersave-off.service`). Verified on a live journal from the card|
|The `/roms` partition was not created on first boot|`sfdisk --append` refuses to modify the partition table of a disk whose partitions are mounted ("This disk is currently in use"), and root is mounted on the device — the command failed and p3 did not appear. The loop test without mounting passed, which is why the check missed it|`sfdisk --force --no-tell-kernel --append` + `partx --add`; the "root mounted" scenario was added to the check|
|ES-DE: "cannot create /ports"|when p3 is not created, `/roms` remained a `root:root 0755` directory and `gamer` could not create system directories in it|tmpfiles creates `/roms 0775 root gamer`; with the partition mounted, permissions come from `uid=1000,gid=1000`|
|`user@1000` does not start → no PipeWire|the journal shows `systemd[402]: Failed to allocate manager object: Permission denied` right after `pam_unix(systemd-user:session)`. The user manager comes up via linger before `XDG_RUNTIME_DIR` exists|tmpfiles creates `/run/user/1000 0700 gamer gamer`; `boot-report.txt` now prints the `user@1000` status, `/run/user` permissions, cgroup mounts and the state of `pipewire`/`wireplumber` in the user session|
|Wi-Fi does not come up with a correct `wifi.conf`|`wpa_supplicant@wlan0` started before rtw88 created `wlan0` (firmware loads after multi-user), failed with "Failed to initialize interface", and nobody restarted it; on top of that the radio could be soft-blocked|fixed: a drop-in `wpa_supplicant@wlan0.service.d/10-rg35xx.conf` with `After=sys-subsystem-net-devices-wlan0.device`, `Restart=on-failure`, and the `rg35xx-wifi-unblock` unit (`rfkill unblock all`). Diagnostics — `rfkill list` and the journal in `boot-report.txt`|
|PortMaster exits immediately|`pugwash` output went to tty1 and was lost|logs now go to `/roms/ports/PortMaster/log.txt` (FAT, readable from a PC) and `/run/rg35xx/game.log`, both duplicated into `boot-report.txt`; `/dev/tty0` is opened for writing (udev rule), and PortMaster no longer trips over its own `printf` to the console|
|Desktop: only the cursor and the labwc menu|two causes. First: autostart clients started without logs and could get `SIGTTIN` (stdin is tty1), and also before the Wayland socket was ready. Second: `rg35xx-userdata-seed.service` with default dependencies landed after `basic.target`, while `roms.mount` was before `local-fs.target`; systemd broke the cycle by dropping `systemd-tmpfiles-setup.service`, so `/run/rg35xx` remained `root:root 0755`, autostart could not create `desktop.log` and started neither waybar nor pcmanfm|`rg35xx-desktop-autostart` waits for the socket, starts clients with `</dev/null`, writes `desktop.log` and the state after 3 s. The seed unit was switched to `DefaultDependencies=no` and `local-fs.target`; `rg35xx-session-prepare` additionally does `install -d -o root -g gamer -m 0775 /run/rg35xx`, and autostart writes the log to `$XDG_RUNTIME_DIR` on failure|
|Volume: the ceiling is average|`DAC` is already at 0 dB; the rest is `Line Out`, controlled by WirePlumber from the sink volume (100 % = 31 = 0 dB)|if it is too quiet — sink at 100 %; there is no more headroom, only an external headphone amplifier|

## Audio: what was verified on hardware

|Check|Result|
|---|---|
|Card|`h616-audio-codec` (`sun4i-codec`), PCM `hw:0,0`, 48 kHz S16_LE stereo|
|Speaker|plays; during playback `gpio-261` (PI5) = high, `vcc-spkr-amp` = enabled|
|Headphones|play after patch `9001`; the `hp-det` detect (PI3) gives `SW_HEADPHONE_INSERT=1` and `Headphone Jack = on`|
|Speaker with the jack inserted|silent (the multiplexer switches, the amplifier stays on — that is how the circuit is designed)|
|Volume buttons|`triggerhappy` (thd, as root) → `rg35-volume` → `wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%±`, verified 0.80 → 0.90 → 0.85|
|Calibration|`DAC` 63/63 = 0 dB — a hard ceiling. WirePlumber keeps `Line Out` (0..31 = −43.5..0 dB) in line with the sink volume: 100 % → 31, 80 % → 28, 50 % → 19, 0 % → 0. Default sink 80 % (−1.5 dB), maximum 100 %|
|Clicks in VVVVVV (~3/s)|The default Pulse client asks for a 128-frame quantum (2.7 ms), while the game's FAudio/SDL2 mixer works in blocks of 1024 frames. At that quantum the mixer periodically falls behind and gaps appear in the stream|`/etc/pipewire/pipewire.conf.d/50-rg35xx-quantum.conf`: `default.clock.min-quantum = 1024` (21 ms). On a live device the same without a restart: `pw-metadata -n settings 0 clock.min-quantum 1024`|

The signal path on this board: `DAC → Line Out Ramp → amplifier (PI5 + CLDO1) → 74HC4052 (speaker/jack
multiplexer)`. Hence two conclusions that are also baked into patch `9001`: the amplifier must turn on
for any playback (not only when the `Speaker` DAPM pin is active), and it also feeds the jack.
