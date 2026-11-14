# RG35XX Pro (Allwinner H700): Debian 13 arm64 — сборка образа с нуля

Репозиторий собирает загружаемый образ для Anbernic RG35XX Pro: U-Boot + Linux 7.1.2 + Debian 13
(trixie) arm64, MBR. В образе два раздела — BOOT и ROOT; остальное место карты при первом запуске
превращается в третий раздел `/roms` (FAT32, виден в Windows) под игры, видео и музыку. Загрузка заканчивается в EmulationStation (ES-DE 3.5.0) на панели
640×480 через KMS/DRM; из неё открываются игры (RetroArch + ядра libretro), порты (PortMaster),
Desktop (labwc) и обычный текстовый терминал на `tty1`. Все режимы взаимоисключающие: на `tty1`
одновременно живёт ровно один из них.

|Компонент|Версия / артефакт|
|---|---|
|Ядро|Linux 7.1.2 + `packages/linux/patches/default/*` + `devices/H700/patches/linux/*` (без `*.disabled`), `linux.aarch64.conf`|
|DTS|`sun50i-h700-anbernic-rg35xx-pro.dts` (inherit plus) + `reg_dcdc3 = 1.2 В`|
|U-Boot|v2026.01, `anbernic_rg35xx_h700_lpddr3_defconfig`, DDR3-патчи, `BL31` внутри|
|TF-A|v2.12.0, `PLAT=sun50i_h616`, патч `000-use-gcc-for-asm`|
|Rootfs|Debian 13.7 trixie, `minbase` + sshd/networkd/wpa_supplicant/avahi/mesa/kmscube, без initramfs|
|Фронтенд|ES-DE 3.5.0, собрана из исходников (`-DGLES=ON -DDEINIT_ON_LAUNCH=ON`), `/usr/bin/es-de`|
|Эмуляция|RetroArch 1.20.0 (Debian) + ядра libretro buildbot aarch64, `/usr/lib/aarch64-linux-gnu/libretro`|
|Порты|PortMaster, `/roms/ports/PortMaster`, armhf runtime для 32-битных портов|
|Desktop|labwc + waybar + pcmanfm + foot + fuzzel, набор приложений (Firefox ESR, mpv/SMPlayer, Audacious, imv, mousepad, AntiMicroX, pavucontrol)|
|Прошивки в ядре|`rtw88/rtw8821c_fw.bin`, `panels/anbernic,rg35xx-plus-panel.panel`, `regulatory.db(.p7s)`|

## Требования к хосту

- Debian 13 (trixie) или Ubuntu 24.04, x86-64. Сборка идёт через `debootstrap` + `chroot`, поэтому
  нужен Linux-хост с root.
- ~20 ГиБ свободно в `$BUILD_DIR` (по умолчанию `/var/tmp/rg35xxpro-build`) и ~10 ГиБ в каталоге
  репозитория для `out/`.
- Интернет: `build.sh` скачивает ядро, U-Boot, TF-A, ROCKNIX и пакеты Debian.
- Всё остальное `build.sh` ставит сам (`gcc-aarch64-linux-gnu`, `debootstrap`, `qemu-user-static`,
  `mtools`, `u-boot-tools`, `wpasupplicant`, `linux-firmware`, …).

## Быстрый старт

```sh
git clone <URL-репозитория> debian-rg35xxpro
cd debian-rg35xxpro

# Необязательно: Wi-Fi, который будет уже прописан в образе.
cp config/wifi.env.example config/wifi.conf
$EDITOR config/wifi.conf

sudo ./build.sh
```

Полная сборка выполняет стадии `deps → sources → atf → uboot → kernel → rootfs → frontend → image`.
Оговорка по времени: `frontend` собирает ES-DE под `qemu-user` (`-j2`), это самый долгий шаг
после ядра.
Результат:

|Файл|Что это|
|---|---|
|`out/rg35xxpro-debian.img`|образ 4624 МиБ для SD-карты (остаток карты станет `/roms`)|
|`out/rg35xxpro-debian.img.sha256`|контрольная сумма|
|`out/Image`, `out/*.dtb`|ядро и DTB (для отладки/замены на p1)|
|`out/u-boot-sunxi-with-spl.bin`|загрузчик (уже записан в образ)|

`out/` в `.gitignore`: готовый образ в репозиторий не входит, его собирает каждый у себя.

Проверка суммы:

```sh
cd out && sha256sum -c rg35xxpro-debian.img.sha256
```

## Wi-Fi

В образе нет чужих сетей. Есть три способа задать Wi-Fi.

### 1. При сборке: `config/wifi.conf`

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

- До 8 сетей, нумерация с 1: дом и 5 ГГц того же роутера, телефонная точка доступа и т.п.
  wpa_supplicant сам выбирает видимую сеть по уровню сигнала.
- `WIFI_PRIORITY_n` — необязательно: чем больше значение, тем предпочтительнее сеть, когда видны
  обе (например `WIFI_PRIORITY_2=20` притянет устройство к 5 ГГц).
- `WIFI_COUNTRY` — ISO 3166-1 alpha-2 или `00` (мировой regulatory domain).
- `WIFI_PSK_n` — пароль 8–63 символа (или 64 hex-символа PSK).
- `config/wifi.conf` в `.gitignore`: реальные пароли не попадают в репозиторий.
- Если файла нет или в нём остались плейсхолдеры, образ всё равно соберётся: `wpa_supplicant`
  запустится с конфигом без сетей, сеть нужно добавить на устройстве.

Сборка рендерит сети в `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` **только хэшами**
(`psk=<64 hex>`), сам пароль в образ не попадает. На FAT-раздел p1 он не дублируется сознательно:
этот раздел лежит открытым текстом и уезжает с любой копией карты или образа. Формат
`config/wifi.conf` и `/wifi.conf` — один и тот же, рендерит их одна программа
`/usr/local/sbin/wifi-config-gen`, так что «задал при сборке» и «поправил с ПК» ведут себя
одинаково.

### Desktop: меню приложений и переключение в ES-DE

|Проблема|Причина|Исправление|
|---|---|---|
|Меню приложений (fuzzel) огромное, шире экрана|у панели 640×480 физическая плотность ~200 dpi, а размер шрифта был задан в пунктах (`size=9`): fuzzel рисовал строки ~25 px и окно уезжало за экран. Плюс секция `[dmenu]` содержала `font/lines/width`, которые fuzzel 1.12 не принимает и отказывается стартовать|`font=DejaVu Sans:pixelsize=12` (не зависит от DPI), `lines=6`, `width=30`; из `[dmenu]` лишние ключи убраны|
|pcmanfm не запускается, на десктопе нет иконок|в `~/.config/labwc/environment` стоял `GDK_BACKEND=wayland`, а pcmanfm — GTK3 X11-only и на Wayland-бэкенде падает с segfault|`GDK_BACKEND` из общего окружения убран; в autostart pcmanfm стартует с `GDK_BACKEND=x11` (XWayland)|
|ES-DE, запущенная из меню десктопа, не закрывала десктоп, а работала окном внутри labwc|меню показывало `org.es_de.frontend.desktop` из установки ES-DE с `Exec=es-de`, то есть запуск клиентом, а не переключение режима|свой `~/.local/share/applications/org.es_de.frontend.desktop` с `Exec=sudo -n /usr/local/bin/rg35xx-session es` — пункт называется «Games» и переключает сессию|
|Иконки рабочего стола рисовались в декорированном окне «pcmanfm» в углу|pcmanfm создаёт окно типа `DESKTOP`, а labwc под XWayland управляет им как обычным: рамка, заголовок, размер по содержимому|`~/.config/labwc/rc.xml`: window rule `type="desktop"` → `serverDecoration="no"`, `skipTaskbar`, `Maximize`|
|Переключение режимов иногда падало (`status=15/TERM`, `1/HUP`) и оставляло `failed`|`Conflicts=` останавливает старую сессию параллельно со стартом новой: labwc успевал взять DRM, пока ES-DE её ещё держала, а старт отменялся. Плюс любой юнит, держащий tty1, ловил SIGHUP от `vhangup()` при остановке getty|переключение идёт через транзиентный юнит `rg35xx-session-apply` (`systemd-run`): сначала `stop` всех остальных режимов, затем `start` нужного, плюс `reset-failed` для остановленных; сессии больше не держат tty1 (`TTYPath/TTYReset` убраны), вывод — в журнал|
|Курсор в десктопе не управлялся геймпадом|в образе стоял antimicro (Qt5 GUI: окно, трей, ~100 МБ RSS на 1 ГБ RAM). Для «стик → курсор, A/B → клики» он избыточен и вдобавок требует уже поднятого дисплея|`/usr/local/bin/rg35xx-stick-mouse` (stdlib python3, uinput): левый стик → `REL_X/REL_Y` с мёртвой зоной 16 % и кривой `speed*(1.6..)`, A (`BTN_EAST`) → левый клик, B (`BTN_SOUTH`) → правый. Запускается первым в autostart десктопа, геймпад при этом остаётся доступен приложениям. Скорость/зона — константы `MAX_SPEED`, `DEADZONE`, `CURVE` в начале файла|
|Выход из ES-DE не возвращал в десктоп|quit-скрипт всегда переключал в `terminal`|`rg35xx-session` запоминает предыдущий режим в `/run/rg35xx/previous`, quit-скрипт вызывает `rg35xx-session back`: из десктопа — обратно в десктоп, из загрузки — в консоль|
|Переключение desktop → ES падало с `status=1/HUP`|`TTYVHangup=yes` в юнитах: `vhangup()` на tty1 слал SIGHUP в `ExecStartPre` следующей сессии, который уже успевал открыть тот же tty|`TTYVHangup` убран из `rg35xx-es/desktop/game`; остаётся `TTYReset`|
|Изредка ES не успевала остановиться, и старт десктопа отменялся (`code=killed, status=15/TERM`)|ES-DE игнорирует флаг выхода, пока открыт модальный диалог; `TimeoutStopSec=10` не хватало|`TimeoutStopSec=25` у `rg35xx-es.service`|

### 2. Без перепрошивки: `wifi.conf` на p1

Смонтируйте FAT-раздел карты на ПК (в системе он же `/boot/firmware`) и создайте в корне
`wifi.conf` — то же содержимое, что и в `config/wifi.conf`:

```sh
WIFI_COUNTRY=RU
WIFI_SSID_1="MyNetwork"
WIFI_PSK_1="my passphrase"
WIFI_SSID_2="MyNetwork-5G"
WIFI_PSK_2="my passphrase"
```

`wifi-provision.service` выполняется до `wpa_supplicant@wlan0.service` и перегенерирует
`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`. Достаточно перезагрузить устройство или выполнить:

```sh
systemctl restart wifi-provision.service
systemctl restart wpa_supplicant@wlan0.service
```

### 3. Вручную на устройстве: `wpa_supplicant` / `wpa_cli`

Сначала удалите `/boot/firmware/wifi.conf`, иначе `wifi-provision` перезапишет конфиг при загрузке.
Затем:

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

Проверка:

```sh
iw dev wlan0 link
ip -4 addr show wlan0
ping -c 3 deb.debian.org
journalctl -u wpa_supplicant@wlan0 -u wifi-provision -b
```

`wpa_supplicant@wlan0.service` читает `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`; адрес
выдаётся по DHCP через `systemd-networkd` (`config/rootfs/etc/systemd/network/20-wlan0.network`).
На rtw88 5 ГГц работает нестабильно — предпочитайте 2.4 ГГц; при обрывах см.
`rtw88_core.disable_lps_deep=1` в разделе известных проблем.

## Запись образа и первый запуск

1. Вставьте SD-карту объёмом больше образа (16 ГиБ и выше — комфортно; всё содержимое будет
   стёрто). Образ занимает 4624 МиБ, остальное при первом запуске станет разделом `/roms`.
2. Запишите образ **побитово**, не форматированием:
   - Windows: Rufus 4.x, режим **DD Image**;
   - Linux/macOS: `sudo dd if=out/rg35xxpro-debian.img of=/dev/sdX bs=4M status=progress conv=fsync`
     (проверьте `of=` через `lsblk`/`diskutil list`);
   - либо balenaEtcher.
3. Вставьте карту в RG35XX Pro и включите питание. Загрузка идёт с p1 (`boot.scr` → `Image` + DTB),
   через ~20 с на экране появляется ES-DE. При первом запуске `rg35xx-userdata.service` создаёт
   раздел `/roms` на всё свободное место карты и форматирует его в FAT32 (метка `DATA`), а
   `rg35xx-userdata-seed.service` раскладывает туда PortMaster, записи `desktop` и каталоги систем.
   В Windows этот раздел появится как обычная флешка — игры, видео и музыку можно копировать с ПК;
   переставьте карту после первой загрузки, чтобы Windows увидела новый раздел.
4. Выйти в консоль: в ES-DE `Quit` → `Terminal` (или «Terminal.sh» в системе `desktop`). Логин:
   `root` / `root`; второй пользователь для аудиосессии — `gamer` / `gamer`. Для ввода на самом
   устройстве нужна USB-клавиатура (OTG) либо UART `ttyS0,115200`; иначе подключайтесь по SSH
   после настройки Wi-Fi. Сразу смените пароли: `passwd` и `passwd gamer`.
5. Проверьте сеть: `ip -br a`, `iw dev wlan0 link`. После появления IP можно зайти по SSH:
   `ssh root@<ip>`.
6. Повторный провижининг (пакеты, пользователь, PipeWire, zram, запрет suspend, кнопки громкости,
   калибровка микшера): скопируйте `scripts/device-provision.sh` из репозитория на устройство
   (`scp`/USB) и запустите `sh device-provision.sh`. Скрипт идемпотентен. В образе он уже выполнен
   с `--offline`; вручную нужен только на старом образе или после ручных изменений.

Если что-то не поднялось, выньте карту и прочитайте `boot-report.txt` в корне p1 — там `uname`,
`/proc/cmdline`, сеть, `wpa_supplicant`, input-устройства и последние 300 строк журнала (в ES
доступен и `System info`, и `journalctl -u rg35xx-es` через SSH).

## Пользовательский раздел: `DATA` (p3) и `/roms`

Образ содержит только BOOT и ROOT; игры, видео и музыка живут на отдельном разделе, который
появляется при первом запуске:

- `rg35xx-userdata.service` берёт из таблицы разделов последний занятый сектор, выравнивает начало
  по 1 МиБ и создаёт p3 до конца карты. Root в этот момент смонтирован, поэтому полная перечитка
  таблицы (`BLKRRPART`) отвалилась бы — используется `sfdisk --append --no-tell-kernel` и
  `partx --add`, которые добавляют только новый раздел;
- раздел форматируется в FAT32 с меткой `DATA` — Windows видит его как обычную флешку;
- сам раздел монтируется в `/mnt/userdata` (`uid=gid=1000`, `fmask/dmask=0022`), а **внутри него
  лежит один каталог `roms/`, который bind-монтируется в `/roms`**. На карте, открытой в Windows,
  в корне раздела виден `roms` — как на стоковых прошивках Anbernic, — а не десятки системных
  каталогов, которые создаёт ES-DE;
- `rg35xx-userdata-seed.service` (стартует после `mnt-userdata.mount`, до `roms.mount`) создаёт
  `roms/` и раскладывает туда записи `desktop`, `ports` (PortMaster) и по каталогу на каждую
  систему. Копируются только отсутствующие записи, поэтому обновления PortMaster и файлы
  пользователя переживают перезагрузки;
- если p3 нет (первый запуск, карта ровно по размеру образа), цепочка `mnt-userdata.mount` →
  seed → `roms.mount` скипается, и `/roms` остаётся обычным каталогом на rootfs: загрузка не
  ломается.

На первом запуске раздел создаётся, но монтируется уже в следующей загрузке — так устроена
транзакция `local-fs.target`. После первого включения достаточно выключить и включить устройство,
и `roms/` появится.

Ограничения FAT32: файл больше 4 ГиБ на раздел не поместить, симлинков и прав нет. Переформатировать
p3 в exFAT можно, но тогда нужно поправить `vfat` на `exfat` в обеих строках `/etc/fstab`.

Проверка на устройстве:

```sh
sfdisk -d /dev/mmcblk0 | grep mmcblk0p          # три раздела, p3 до конца карты
findmnt /mnt/userdata /roms                     # vfat и bind /dev/mmcblk0p3[/roms]
ls /mnt/userdata                                # roms (плюс System Volume Information от Windows)
journalctl -b -u rg35xx-userdata -u rg35xx-userdata-seed -u roms.mount
```

Скопировать игры/видео с ПК: выключить устройство, вставить карту, открыть в Windows раздел `DATA`,
зайти в `roms` и положить файлы в нужные каталоги (`roms/nes`, `roms/psx`, …). ES-DE читает
`ROMDirectory` из `es_settings.xml` — там `/roms`.

## Режимы работы

На `tty1` одновременно живёт ровно один сеанс; переключение делает root-помощник
`/usr/local/bin/rg35xx-session` (у `gamer` есть `NOPASSWD` sudo — иначе PortMaster, который сам
вызывает `sudo` для `chmod /dev/tty0`, `/dev/uinput`, bind-mount и установки портов, работать не
сможет; устройство и так грузится с `root/root` и SSH root-логином, так что граница безопасности
не меняется).

|Режим|Юнит|Как попасть|
|---|---|---|
|ES-DE (по умолчанию)|`rg35xx-es.service`|загрузка; `sudo rg35xx-session es`|
|Игра/порт (без ES)|`rg35xx-game.service`|запуск игры или порта из ES — автоматически|
|Desktop (labwc)|`rg35xx-desktop.service`|ES → `desktop` → `Desktop Mode.sh`; `sudo rg35xx-session desktop`|
|Терминал|`rg35xx-terminal.service`|ES → `Quit` → `Terminal`; `sudo rg35xx-session terminal`|
|Выключение/перезагрузка|—|ES → `Quit` → `Power Off` / `Reboot`; `sudo rg35xx-session poweroff|reboot`|

`getty@tty1` из образа удалён: он бы занял VT и подрался с DRM-клиентом. Значок `Terminal`
запускает его на время, `Quit` в консоли (`exit`) — нет; чтобы вернуться в ES, наберите
`sudo rg35xx-session es` или просто выключите питание.

ES-DE запускается в режиме 640×480 без `--resolution` (единственный режим панели). Тема —
`linear-es-de` (MIT, ставится вместе с ES-DE; `modern-es-de` и `slate-es-de` стадия `frontend`
удаляет, это 53 МиБ без пользы для 640×480). В настройках закреплён `ThemeAspectRatio=4:3`,
поэтому берётся 4:3-вариант темы (`aspect-ratio-4-3.xml`), а не растянутый 16:9.
Меню `Quit` включено (`ShowQuitMenu`, `CustomEventScripts`), скрипты выхода —
`~/ES-DE/scripts/{quit,poweroff,reboot}/`.

Почему так: 1 ГиБ RAM не хватает на ES (~150 МБ) плюс эмулятор/браузер одновременно. Поэтому
игра всегда идёт через `rg35xx-game.service`: ES останавливается (`Conflicts=`), `sync` +
`drop_caches` освобождает кэш страниц, `boot-report.timer` на время игры выключается, а после
выхода ES стартует заново. Изнутри ES запуск перехватывают `/usr/local/bin/rg35xx-run-sh`
(система `ports` пропатчена на него в `es_systems.xml`) и шим `/usr/local/bin/retroarch`:
он кладёт argv в `/run/rg35xx/game.args` и переключает режим, а не пытается отобрать DRM у ES.
После выхода игра закрывается через `rg35xx-session-after-game` → `rg35xx-session-apply es`:
helper ждёт, пока cgroup сессии опустеет (дети порта могут держать DRM), снимает `failed`, и только
потом поднимает ES-DE. Скрипт выхода ES-DE при этом молчит, если запуск игры уже запросил
переключение — иначе `back` отменял бы запуск.

### Игры: RetroArch и ядра

- `retroarch.cfg` (в `/home/gamer/.config/retroarch/`): `video_driver = "gl"` +
  `video_context_driver = "kms"`, 640×480, `audio_driver = "pulse"`. Debian собирает RetroArch с
  автоопределением KMS (`HAVE_KMS=auto`), поэтому отдельный `kmsdrm` не нужен. Проверка на
  устройстве: `retroarch --features` должен содержать `KMS/EGL context support: yes`.
- Ядра — с libretro buildbot, не из Debian: пакетные ядра в trixie старее, а MAME-ядро (112 МБ)
  в образ не входит. Полный список и sha256 — `config/retroarch-cores.sha256`; для систем
  `arcade`, `cps`, `cps1..3` в `es_systems.xml` первым по умолчанию стоит FinalBurn Neo.
- ES-DE берёт системный конфиг из `resources/systems/linuxarm/` (на AArch64; `linux/` — для x86-64)
  и находит ядра по `es_find_rules.xml`. В linuxarm-варианте каталог
  `/usr/lib/aarch64-linux-gnu/libretro` уже перечислен, поэтому хватает того, что ядра лежат
  именно там; стадия `frontend` это проверяет и падает, если upstream уберёт строку.
- `video_threaded = "false"`: лишний поток под 640×480 и 1 ГиБ RAM только отнимает память.

### Если ES-DE не поднимается

|Симптом|Что проверить|
|---|---|
|Чёрный экран / `KMS` ошибки в `journalctl -u rg35xx-es`|`SDL_VIDEODRIVER=kmsdrm`, `SDL_VIDEO_EGL_DRIVER=libEGL.so.1`, `kmscube -D /dev/dri/card1`; modeset-карта — `card1` (`sun4i-drm`), `card0` — render-only Panfrost|
|ES-DE не создаёт GLES-контекст|как аварийный вариант — запустить через `cage`: `ExecStart=/usr/bin/cage -- /usr/bin/es-de --home /home/gamer --no-splash` (правка только `ExecStart`); игры всё равно идут отдельным юнитом с KMS|
|Геймпад не виден в ES|снять фактический GUID (`SDL_JoystickGetDeviceGUID`, лог ES-DE) и заменить строку в `session.env`/`gamecontrollerdb.txt`|
|`Configured theme ... does not exist`|проверить `/usr/share/es-de/themes/linear-es-de/theme.xml` и `capabilities.xml` (без второго ES-DE игнорирует тему)|
|Порт не стартует (`Exec format error`)|armhf-порт: `/lib/ld-linux-armhf.so.3`, `LD_LIBRARY_PATH` порта; при системной несовместимости остаются aarch64-порты, arm64-сеансы не меняются|

### Геймпад

Драйвер (`rocknix-singleadc-joypad`, DTS ROCKNIX) даёт устройство `H700 Gamepad`,
vendor `0x484B`, product `0x14DF`, bus `HOST`; SDL GUID —
`1900f6a24b480000df14000000010000`. На этой плате DTS называет восточную кнопку `A`
(`BTN_EAST`), а южную `B` (`BTN_SOUTH`), поэтому:

- SDL (`ES-DE`): `a:b1, b:b0, x:b3, y:b2` — та же строка, что лежит в
  `/etc/rg35xx/session.env`, `~/.config/SDL-GameControllerDB/gamecontrollerdb.txt` и
  `/roms/ports/PortMaster/gamecontrollerdb.txt`;
- RetroArch (`~/.config/retroarch/autoconfig/udev/H700 Gamepad.cfg`): `input_a_btn = "1"`,
  `input_b_btn = "0"`, остальные кнопки — по порядку evdev (`BTN_SOUTH`, `BTN_EAST`, …).

Если ES-DE не видит геймпад, снимите фактический GUID через SDL2 на устройстве (лог ES-DE или
`SDL_JoystickGetDeviceGUID`) и замените строку в обоих файлах; имя/vendor/product менять не нужно.

### Порты: PortMaster

PortMaster лежит в `/roms/ports/PortMaster` (запуск — `PortMaster.sh` в `/roms/ports`), читает
`gamecontrollerdb.txt` оттуда же и получает окружение из `/etc/rg35xx/{session,kms}.env`.
Добавлен `armhf` (`dpkg --add-architecture armhf`) и 32-битные SDL2/OpenAL/GL/ALSA/X11: часть
каталога PortMaster собрана под armhf, ядро поддерживает `CONFIG_COMPAT=y`. Если конкретный
armhf-порт всё равно не стартует, проверьте `/lib/ld-linux-armhf.so.3` и `LD_LIBRARY_PATH`
порта; глобальные aarch64-сеансы при этом не меняются.

### Desktop: labwc

Запускается `rg35xx-desktop.service` (labwc, `WLR_BACKENDS=drm,libinput`,
`WLR_DRM_DEVICES=/dev/dri/card1`, `seatd` для seat). Автозапуск — `~/.config/labwc/autostart`
(waybar, pcmanfm на рабочем столе, swaybg). Кнопка `Menu` в waybar открывает `fuzzel`
(список приложений), `Settings` — меню `rg35xx-settings`: Wi-Fi (`rg35xx-wifi` на `wpa_cli`),
Bluetooth (`bluetoothctl`), звук (`pavucontrol`), яркость (`brightnessctl`), состояние системы,
выход в ES/терминал/перезагрузка/выключение. Выход из labwc (без явного переключения) возвращает
в ES.

Bluetooth-демон поднимается только в Desktop (`Wants=bluetooth.service`); в ES, консоли и игре он
остановлен, чтобы не занимать память. AntiMicroX (`antimicro`) требует `/dev/uinput` — модуль
грузят `modules-load.d`, права на устройство даёт `udev/rules.d/60-uinput.rules`
(`GROUP="input"`), `gamer` в группе `input`.

### SD-карта: умеренная экономия

Выбран вариант «balanced»: журнал остаётся на диске с жёстким лимитом, `/tmp` — в RAM.

|Что|Как|
|---|---|
|`/`|`noatime,commit=120,errors=remount-ro` — при сбое питания теряется до 120 с записей|
|`/tmp`|tmpfs 256M, `nosuid,nodev`|
|`/var/log`|на диске; journald `SystemMaxUse=32M`, `MaxRetentionSec=1week`, `SyncIntervalSec=5m`|
|trim|`fstrim.timer` (еженедельно), без `discard` в fstab|
|кэш страниц|`vm.dirty_writeback_centisecs=1500`, `dirty_expire_centisecs=3000`|
|core dumps|выключены (`coredump.conf.d/00-disable.conf`)|
|Wi-Fi|`wifi-provision` перезаписывает конфиг только при изменении содержимого|
|boot-report|раз в 30 минут вместо 5|
|Firefox|дисковый кэш выключен, кэш в RAM 32 МиБ|
|swap|только zram (50 %, zstd), swap-файла нет|

## Стадии сборки

Всё, что нужно, лежит в этом репозитории: `build.sh` (хостовые пакеты, исходники, патчи, сборка,
rootfs, образ), `config/dts/` (DTS платы), `config/patches/` (наши патчи поверх ROCKNIX),
`config/rootfs/` (файлы, которые кладутся в rootfs), `scripts/device-provision.sh` (настройка
устройства; тот же скрипт вызывается при сборке rootfs в chroot с `--offline`).

|Стадия|Что делает|Результат|
|---|---|---|
|`deps`|apt-пакеты хоста|—|
|`sources`|качает и проверяет по sha256 Linux 7.1.2, U-Boot v2026.01, TF-A v2.12.0, клонирует ROCKNIX `20261101`|`$BUILD_DIR`|
|`atf`|патч `000-use-gcc-for-asm`, `PLAT=sun50i_h616 bl31`|`bl31.bin`|
|`uboot`|DDR3-патчи, `anbernic_rg35xx_h700_lpddr3_defconfig`, BL31 внутрь|`out/u-boot-sunxi-with-spl.bin`|
|`kernel`|патчи ROCKNIX + наши, наш DTS, `linux.aarch64.conf` + правки, `Image dtbs modules`|`out/Image`, `out/*.dtb`|
|`rootfs`|debootstrap trixie arm64, пакеты, `config/rootfs`, `device-provision.sh --offline`, модули ядра|`$BUILD_DIR/rootfs`|
|`frontend`|ES-DE 3.5.0 из исходников под qemu-user (`GLES=ON`, `DEINIT_ON_LAUNCH=ON`), ядра libretro по sha256, PortMaster, патч `es_systems.xml`|`/usr/bin/es-de`, `/usr/share/es-de`, ядра, `/roms/ports/PortMaster`|
|`image`|`boot.scr` (`panic=10 pstore.backend=ramoops`), FAT32 p1, ext4 p2 (4096 МиБ), MBR; образ кончается на p2 — `/roms` создаётся на карте при первом запуске|`out/rg35xxpro-debian.img` + `.sha256`|

Можно перезапускать по одной стадии: `sudo ./build.sh kernel image`; каталог сборки меняется
переменной `BUILD_DIR=/путь`. Повторный запуск идемпотентен: скачанные архивы проверяются по
контрольной сумме, патчи помечаются файлом-маркером, apt/rootfs докачиваются.

Параметры сборки, которые легко поменять: `LINUX_VER`, `UBOOT_VER`, `ATF_VER`, `ROCKNIX_TAG`,
`SHA256`-константы — в начале `build.sh`; Wi-Fi (`config/wifi.conf`), DTS и патчи — в `config/`.

Полная сборка с нуля проверена в изолированной копии репозитория 2026-11-12: `./build.sh`
доходит до `exit=0`, на выходе `Image`, `u-boot-sunxi-with-spl.bin`, DTB и образ (тогда — 8 ГиБ,
одним разделом ROOT до конца карты). После перехода на отдельный `/roms` и переработки Wi-Fi полный
прогон не повторялся: изменённые скрипты проверены `bash -n`/`sh -n`, а создание раздела и раскладка
seed-дерева прогнаны на loop-устройстве с той же разметкой.

Для режимов ES/Desktop образ целиком ещё не собирался; проверено по частям:
ES-DE 3.5.0 собирается нативно теми же `cmake`-флагами и списком зависимостей (`es-de --version`
= `ES-DE 3.5.0 (r52)`, `make install` кладёт `/usr/bin/es-de`, `/usr/share/es-de`, три темы);
патч `es_systems.xml` прогнан на реально установленном `resources/systems/linuxarm/es_systems.xml`
(порты → `rg35xx-run-sh`, FinalBurn Neo первым в `arcade`/`cps*`, 195 систем, идемпотентно); все
ядра скачаны с buildbot и совпали с `config/retroarch-cores.sha256`; юниты прошли
`systemd-analyze verify`, а скрипты режимов — функциональный тест с фиктивным `systemctl`
(переключения, guard по `/run/rg35xx/target`, разбор argv через `game.args`, `euid`-пути шима
`retroarch`). Побайтовой воспроизводимости `Image` нет: две сборки одного дерева дают разный
sha256 (источник не `KBUILD_BUILD_TIMESTAMP`, он закреплён), поэтому сверяйте образ по факту
загрузки и приёмке, а не только по хешу.

## Разметка образа

|Раздел|Смещение|Размер|ФС|
|---|---|---|---|
|U-Boot (`u-boot-sunxi-with-spl.bin`)|8 КиБ|650 089 Б|raw|
|p1 BOOT|16 МиБ (сектор 32768)|512 МиБ|FAT32: `Image`, DTB, `boot.scr`, `extlinux/extlinux.conf`|
|p2 ROOT|528 МиБ (сектор 1081344)|4096 МиБ|ext4, метка `ROOT`, `/dev/mmcblk0p2`|
|p3 DATA|4624 МиБ — конец карты|остаток карты|FAT32, метка `DATA`, создаётся при первом запуске: монтируется в `/mnt/userdata`, её `roms/` — в `/roms` (bind)|

Образ заканчивается на границе p2: карта всегда больше, и `rg35xx-userdata.service` отдаёт всё
оставшееся место под пользовательский раздел. Расчёт в `build.sh`: `BOOT_OFFSET_MIB` / `BOOT_MIB` / `ROOT_MIB`.

Загрузка: `boot.scr` (`fatload mmc 0:1` + `booti`) → `Image` + DTB; `extlinux.conf` — резерв для `bootflow scan`.

## Проверено при сборке

- `sha256sum` исходников совпали с закреплёнными значениями (Linux, U-Boot, TF-A); ROCKNIX tag `20261101` = `cefc1433`.
- `e2fsck -fn` по root: чисто; `fsck.fat` по p1: чисто; `boot.scr` — валидный `AArch64 Linux Script`.
- Раздел `/roms` проверен без пересборки образа: `rg35xx-userdata` прогнан на loop-устройстве с той
  же разметкой в 8 сценариях — создание p3 на карте 12000 МиБ (начало выровнено по 1 МиБ, конец
  совпадает с концом карты), FAT32 с меткой `DATA`, `fsck.fat` чист, повторный запуск ничего не
  делает, монтирование с опциями из fstab даёт `uid=1000` и права 755, сидирование раскладывает
  `desktop`/`ports`/каталоги систем, правки пользователя не затираются, карта ровно по размеру
  образа и не-блочное устройство обрабатываются без ошибок. `findmnt --verify` по новой строке
  fstab — 0 ошибок разбора; `systemd-fstab-generator` даёт `roms.mount` с
  `Requires=`/`After=rg35xx-userdata.service`, юнит попадает в `local-fs.target.wants`.
- Smoke-boot образа под `qemu-system-aarch64 -M virt` (диск через usb-storage): ядро 7.1.2 поднимается,
  `EXT4-fs (sda2) mounted`, systemd доходит до `multi-user.target`, `ssh.service` и `getty@tty1` — `active`.
- Собранный DTB: `mmc0 = mmc@4020000` (SD), панель `anbernic,rg35xx-plus-panel` + `panel-mipi-dpi-spi`,
  `dr_mode = "otg"` у musb, `dcdc3 = 1.2 В`.
- Совместимость конфига ядра: `PANFROST`, `DRM_SUN4I`, `DRM_PANEL_MIPI`, `PWM_SUN8I`, `RTW88_8821CS`,
  `USB_MUSB_DUAL_ROLE`, `EXT4_FS`, `MMC_SUNXI`, `USB_HID` — все `=y`.

## Особенности сборки (грабли, проверенные на практике)

1. **Хост сборки** — проверено на WSL2 + Ubuntu 24.04 с включённым systemd; на обычном Debian/Ubuntu
   те же стадии выполняются без WSL-специфики.
2. **TF-A**: штатный `make` без `CC=` падает в TF-A 2.12 — `$(CC)` для asm-правила не определён на момент
   вычисления макроса → `make: x: No such file`. Собираем с `CC=aarch64-linux-gnu-gcc` (плюс чистый `build/`).
3. **U-Boot**: нужен `python3-dev` (pylibfdt) — в исходном списке пакетов его не было.
4. **debootstrap**: упирается в usr-merge (`tar: ./lib: Cannot create symlink to 'usr/lib': File exists`).
   Лечение: `/lib` → симлинк на `usr/lib`, повторное извлечение всех `.deb`, затем `dpkg --unpack` +
   `dpkg --configure -a` в chroot (штатный `--second-stage` не запускается без `/debootstrap/mirror`).
5. **Сеть WSL**: чёрная дыра MTU — часть загрузок Debian висела по 2 мин (`Connection timed out`).
   После `ip link set eth0 mtu 1400` скорость нормальная. `security.debian.org` при сборке был недоступен
   (W: в apt), поэтому security-обновления в rootfs не попали — обновить на устройстве после первого запуска.
6. **Путь `iw`** — `/usr/sbin/iw`, а не `/usr/bin/iw`.
7. **Проверка загрузки** — ядро собрано без `VIRTIO_PCI`, поэтому smoke-boot идёт через `usb-ehci` +
   `usb-storage`, root `/dev/sda2`. Ожидаемые в QEMU таймауты `dev-mmcblk0p1`, `wlan0`, `ttyAMA0` —
   следствие эмуляции, на железе этих устройств нет/они другие.
8. **DRAM**: на устройстве `dram_type=7`, `dram_clk=0x2a0` (672 МГц), `dram_zq=0x06060606`,
   `dram_odt_en=0x0d0d0d0d`, `dram_para1=0x1919`, `dram_para2=0x9988eeee` — это LPDDR3-профиль ROCKNIX
   (`dram_dx_odt/dx_dri/ca_dri` из BSP-DT — другие поля, они не опровергают LPDDR3: сборка с
   `lpddr4_defconfig` (DCDC3 = 1.1 В) вообще не запускается, с LPDDR3 — запускается).

## Найдено и исправлено на живом устройстве

1. **Тёмный экран = DE2 не поднимается.** В `boot.log` устройства:
   `sun50i-de2-bus 1000000.bus: error -EINVAL: Couldn't map SRAM to device` →
   `probe with driver sun50i-de2-bus failed`. Патч ROCKNIX `0002-rg35xx-enable-HDMI-LCD` добавляет шину DE2
   как `allwinner,sram = <&sram_c 1>`, а `sunxi_sram_claim()` ищет по phandle узел-секцию SRAM с compatible
   из `sunxi_sram_dt_ids`; `sram_c` — контейнер `mmio-sram` (в H616 нет секции, в отличие от H6/A64).
   Лечение в `sun50i-h700-anbernic-rg35xx-pro.dts`:
   ```dts
   &sram_c {
       de2_sram: sram-section@0 {
           compatible = "allwinner,sun50i-h6-sram-c", "allwinner,sun50i-a64-sram-c";
           reg = <0x0 0x30000>;
       };
   };
   &{/soc/bus@1000000} { allwinner,sram = <&de2_sram 1>; };
   ```
   После этого DE2/mixer/TCON/панель поднимаются, включается подсветка, появляется fbcon.
2. **`wifi-provision` создавал цикл в транзакции systemd** (юнит с `Before=wpa_supplicant@wlan0` вызывал
   `systemctl restart wpa_supplicant@wlan0`) — из ExecStart эта строка убрана; юнит и так стартует после
   провижининга. Дополнительно отключён `systemd-networkd-wait-online.service` (он задерживал вход).
3. **5 ГГц на rtw88 нестабильно** (и на Knulli тоже — там вендорский BSP-драйвер): из
   `config/wifi.conf` в образ попадают все перечисленные сети, но wpa_supplicant выбирает по
   уровню сигнала. При проблемах с 5 ГГц оставьте только 2.4 ГГц либо ограничьте каналы через
   `scan_freq=2412 2437 2462 2472` в блоке `network`. Конкретные SSID в репозиторий не входят.
4. **Диагностика убрана из финального образа**: нет `init=/usr/local/sbin/early-init`, нет
   `boot-marker.service`, нет маркеров в `boot.scr`; `boot.scr` и `extlinux.conf` — обычные.
5. Проверено на устройстве: `panfrost 1800000.gpu: mali-g31 id 0x7093`,
   `[drm] Initialized panfrost 1.6.0`, `rtw88_8821cs ... Firmware version 24.11.0`,
   systemd доходит до `multi-user.target`, консоль на панели 640x480 работает.
6. **`udev` не был установлен** — `debootstrap --variant=minbase` + `apt-get --no-install-recommends`
   его не притащили. Симптомы ровно те, что виделись на железе:
   `wlan0` в состоянии `DOWN`, `Dependency failed for wpa_supplicant@wlan0.service`
   (юнит `Requires=sys-subsystem-net-devices-wlan0.device`, а без udev таких device-юнитов нет),
   и приглашение входа через ~90 с — это таймаут ожидания того же device-юнита.
   Лечение: `apt-get install udev` (257.13-1~deb13u1); в образе проверено, что
   `/usr/lib/systemd/system/sysinit.target.wants/systemd-udevd.service` и `…-udev-trigger.service`
   на месте, `/usr/bin/udevadm` присутствует, `/etc/udev/{rules.d,hwdb.d}` созданы.
7. **DNS в образе был из WSL.** В rootfs лежал сгенерированный WSL `/etc/resolv.conf` с
   `nameserver 10.255.255.254` — на устройстве такого адреса нет, `getent hosts` и `apt` падали
   («Temporary failure resolving»). Лечение: `/etc/resolv.conf` → симлинк на
   `/run/systemd/resolve/stub-resolv.conf` (в rootfs и на устройстве). `resolvectl` при этом работал
   всегда — ломался только glibc-резолвер.
8. **Наушники молчали, хотя динамик играл.** Усилитель (`allwinner,pa-gpios` = PI5) в этой схеме
   стоит не «на динамике», а в разрыве `LINEOUT` перед аналоговым мультиплексором 74HC4052, который
   разводит сигнал на динамик и на джек. Патч ROCKNIX `0163` включает его DAPM-событием пина
   `Speaker`, а пин `Speaker` DAPM гасит, когда вставлены наушники (работает пин `Headphone`) —
   сигнал просто не доходит до джека. Лечение в патче `9001`: усилитель вынесен в отдельный виджет
   `Speaker Amp` (`SND_SOC_DAPM_PGA_E` с тем же событием) и включён последовательно с `LINEOUT`,
   поэтому он следует за воспроизведением, а не за состоянием пина.
9. **`EIO` на любом воспроизведении после неудачного resume.** `sun4i_codec_startup()` возвращал
   `-EIO`, если остался флаг `clocks_suspended` (патч `0163`). Один неудачный `resume_early` — и звук
   мёртв до перезагрузки. В патче `9001` `startup()` сам поднимает часы через
   `sun4i_codec_resume_early()`.
10. **Suspend без TF-A-патча = зависание.** `systemd-logind` разрешал сон, а `mem`-сон на H700 без
    `001-allwinner-h616-psci-system-suspend` и `h700-suspend-stub` вешает SoC. Пока фаза 5 не закрыта,
    сон выключен на всех уровнях: `/etc/systemd/logind.conf.d/50-rg35xxpro-nosleep.conf`
    (`AllowSuspend=no`, `HandleSuspendKey=ignore`, `HandlePowerKey=poweroff`) и маска
    `suspend/hibernate/hybrid-sleep/suspend-then-hibernate.target`. Проверка: `CanSuspend` = `no`.
11. **PipeWire не работает под root.** В юнитах Debian стоит `ConditionUser=!root` — сервисы
    молча скипаются, `speaker-test -D default` падает с `-112 Host is down`. Нужен обычный
    пользователь: создан `gamer` (uid 1000, группы `video render input audio netdev plugdev`),
    `loginctl enable-linger gamer`, юниты `pipewire.socket`/`pipewire-pulse.socket`/`wireplumber`
    включены в его сессии. Плюс `rtkit` для реального приоритета аудиопотоков.
12. **Запуск игры или порта выпадал в консоль.** ES-DE при остановке всегда выполняет свои quit-скрипты,
    в том числе когда его останавливает переключатель режимов. Скрипт вызывал `rg35xx-session back`,
    `back` писал `terminal` в `/run/rg35xx/target` и запускал консоль — поверх только что
    запрошенной игры. Лечение: скрипт выходит молча, если в `target` лежит не `es`. Симптом в
    журнале: `sudo rg35xx-session game` и через секунду `sudo rg35xx-session back`.
13. **PortMaster не стартовал: `ImportError: found ['libSDL2_mixer-2.0.so.0'], but it's not usable`.**
    В образе были только 32-битные `libsdl2-mixer`/`libsdl2-image` (для armhf-портов), а `pugwash`
    — 64-битный python и грузит нативные библиотеки. Добавлены `libsdl2-image-2.0-0` и
    `libsdl2-mixer-2.0-0` для arm64.
14. **ES-DE падал с `Couldn't initialize SDL: kmsdrm not available` после выхода из порта.** Дети
    порта живут дольше его main-процесса (`PortMaster` перезапускает себя через `sudo`, а тот
    игнорирует SIGTERM), systemd добивает их только по `TimeoutStopSec`, и всё это время они держат
    `/dev/dri/card1`. Теперь `rg35xx-session-apply` добивает cgroup уже остановленной сессии
    (`systemctl kill -s SIGKILL`, только для `deactivating`/`failed`) и только потом стартует новую,
    а выход из игры идёт через тот же helper, а не прямым `systemctl start`.
15. **Игры лежали в корне большого раздела.** Раздел монтировался прямо в `/roms`, поэтому в Windows
    был виден не `roms`, а десятки системных каталогов ES-DE. Теперь p3 монтируется в
    `/mnt/userdata`, а её `roms/` — bind в `/roms`.

## Что уже разведено в железе/ядре (для следующих фаз)

|Подсистема|Состояние в текущем образе|
|---|---|
|Слот SD 2|`mmc@4022000` = alias `mmc1` → `/dev/mmcblk1`: работает (проверено на карте 32 ГБ, high-speed 4 бита 50 МГц, чтение 23.9 МБ/с, запись 8–9 МБ/с, exfat и vfat монтируются)|
|Слот SD 1|`mmc@4020000` = `mmc0` → `/dev/mmcblk0` (корень)|
|Wi-Fi|`mmc@4021000` = `mmc2`, `non-removable`, pwrseq, SDIO RTL8821CS|
|Геймпад|Драйвер `rocknix-singleadc-joypad` (вендорен в `config/kernel/joypad`, `CONFIG_JOYSTICK_ROCKNIX_SINGLEADC=y`): кнопки — GPIO, стики — через аналоговый мультиплексор PI1/PI2 на канал 0 `gpadc` (`amux-count = <4>`, `amux-channel-mapping = <0 2 1 3>`). Проверено: `js0` даёт `ABS_X/Y/RX/RY` с полным ходом ±32767 (сырые 1987/2050/2042/2077 при покое, PI1/PI2 = 11/10/01/00), опрос ADC ~300 Гц. Свойства `pwms`/`pwm-names` в узле удалены: вибромотор не проверен, а неудачный `devm_pwm_get()` валит весь проб|
|Кнопки громкости|`gpio-keys-volume`: `KEY_VOLUMEUP` (115), `KEY_VOLUMEDOWN` (114) → `triggerhappy` → `wpctl` (проверено)|
|Звук|ASoC-карта `h616-audio-codec` (`sun4i-codec`): `allwinner,pa-gpios` = PI5 (усилитель), `allwinner,pa-supply` = `cldo1` (`vcc-spkr-amp`), `hp-det-gpios` = PI3 (детект наушников). Динамик играет, наушники играют после патча `9001`|
|Батарея/заряд|PMIC **AXP717** (не AXP2202 — проверено по `axp20x-i2c 0-0034: AXP20x variant AXP717 found` и `compatible = "x-powers,axp717"`): `axp20x-usb-power` + `axp20x-battery-power-supply`, регистраторы `DCDC1..4`, `ALDO1..4`, `BLDO1..2`, `CLDO1` в DTS|
|RTC|`pcf8563` на `r_i2c` (патч `0156`), `CONFIG_RTC_HCTOSYS=y` + `hctosys=rtc0` — время переживает перезагрузку; `systemd-timesyncd` включён, `System clock synchronized: yes`|
|Bluetooth|RTL8821CS на `hci_uart`+`btrtl`; прошивка вкомпилирована в `Image` через `EXTRA_FIRMWARE` (`rtl_bt/rtl8821cs_fw.bin` 56 КБ + `rtl_bt/rtl8821cs_config.bin` 25 Б из `config/firmware`): `hci0: RTL: fw version 0x75b8f098`, без нее в dmesg было `Direct firmware load ... failed with error -2`|
|CPU/GPU OPP|патчи `0200-h700-update-opps`, `0210-…-suspend-opp`, `0007-rg35xx-add-GPU-opp`|
|Сборка с нуля|Проверена 2026-11-12 в изолированной копии репозитория (`rsync --exclude=out`, свой `BUILD_DIR`): `./build.sh` доходит до конца, exit=0, на выходе `Image` 30 431 240 Б, `u-boot-sunxi-with-spl.bin` 650 089 Б (внутри BL31 со stub), `rg35xxpro-debian.img` 8 ГиБ. DTB побайтово совпал с инкрементальной сборкой (`3263ee6e…`). `KBUILD_BUILD_TIMESTAMP` закреплён в `build.sh` (`2026-11-01 00:00:00 UTC`), поэтому `uname -v` больше не «плывёт», но **побайтовой воспроизводимости `Image` нет**: две сборки одного дерева дают разный sha256 — источник не время сборки, а что-то ещё (не локализовано)|
|DRM WARNING|В загрузке было два `WARNING` (`drm_mode_object.c:46`/`:246`): panel-mipi ставил `panel_orientation` из `get_modes()`, то есть после `drm_dev_register()`. Патч `0030`: `sun4i_rgb` вызывает `drm_connector_set_orientation_from_panel()` сразу после `drm_connector_init()`, поздний вызов из панели удалён. Проверено: `dmesg | grep -c WARNING` было 2 → стало 0|
|Графика|Wayland и KMS работают через Panfrost (Mesa 25.0.7, GLES 3.1, `Mali-G31`): `glmark2-es2-wayland` под `cage` — score 372. По умолчанию грузится ES-DE на KMS (`rg35xx-es.service`); Desktop — отдельный сеанс labwc, терминал — `getty@tty1`, который в образе больше не включён, а стартует по требованию (`rg35xx-terminal.service`). `cage` остаётся только аварийным фолбэком для ES|
|Память|zram 512 МиБ (50 %, zstd) с `vm.swappiness=100`; `earlyoom` (`-m 10 -s 5`, щадит systemd/sshd/PipeWire/labwc/waybar, первым убивает эмулятор или браузер) вместо позднего kernel OOM. ES и Desktop никогда не работают одновременно, игра запускается только с остановленным фронтендом (`rg35xx-game.service`)|
|Термо/частоты|`schedutil` вместо зашитого `performance` (480–1416 МГц, `rg35xx-cpu-governor.service`); GPU `simple_ondemand` 420–648 МГц. В `sun50i-h616.dtsi` у passive-трипов 60/70 °C **нет `cooling-maps`** — они были мертвы: под 4-ядерной нагрузкой частота держалась 1416 МГц при 61–62 °C. В нашем DTS добавлены `map0/map1` на `cpu0` + `hysteresis = <2000>`; проверено: 60.4 °C → `cdev0=3`, `scaling_max_freq` 1200 МГц|
|SD-износ|корень монтируется `noatime,commit=120`, `/tmp` — tmpfs 256M; журнал ограничен `SystemMaxUse=32M`/1 неделя (`journald.conf.d/00-size.conf`), `fstrim.timer` включён, core dumps выключены, `wifi-provision` не перезаписывает неизменённый конфиг, `boot-report` пишет раз в 30 минут|
|Suspend|TF-A **2.12.0** + ROCKNIX `001-allwinner-h616-psci-system-suspend.patch` + SRAM-заглушка `h700-suspend-stub` (`712653d`, LPDDR3, 18 872 Б) вкомпилирована в BL31 (`SUNXI_SYSTEM_SUSPEND=1 SUNXI_SUSPEND_STUB=...`); BL31 65 641 Б, U-Boot пересобран, `strings bl31.bin` содержит `PSCI: System suspend available (SRAM stub %zu bytes, DRAM type %u @ %u MHz)`. Обновление до 2.15.0 **невозможно без портирования патча**: в 2.15 удалён `plat_psci_ops::pwr_domain_pwr_down_wfi`/`psci_power_down_wfi`, на которых он держится — ROCKNIX поэтому и пинит 2.12.0|

Провижининг устройства (DNS, пакеты, пользователь `gamer`, PipeWire, zram, запрет suspend,
power save off, кнопки громкости, калибровка микшера) — один идемпотентный скрипт из каталога
репозитория; он работает и на живом устройстве (скрипт нужно туда скопировать), и в chroot образа:
`sh scripts/device-provision.sh` / `sh scripts/device-provision.sh --offline`.

## Полевая диагностика (без клавиатуры и сети)

`boot-report.service` (+ таймер) пишет в корень p1 `boot-report.txt`: `uname`, `/proc/cmdline`,
`ip -br a`, `iw dev`, `iw dev wlan0 link`, `rfkill`, `networkctl status wlan0`, `wpa_cli status`,
журнал `wpa_supplicant@wlan0`/`wifi-provision`/`rg35xx-wifi-unblock`, `iw reg get`, состояние
юнитов, конфиг `wpa_supplicant`, состояние `/roms`, `lsusb`, список input-устройств и последние
300 строк `journalctl -b`. Отдельно в него попадают три журнала, которых раньше не было:

|Файл|Что содержит|
|---|---|
|`/run/rg35xx/desktop.log`|как поднялись waybar/swaybg/pcmanfm, их stderr и кто из них выжил через 3 с|
|`/run/rg35xx/game.log`|argv запущенного порта/игры, stdout и stderr (иначе tty1 их съедает)|
|`/roms/ports/PortMaster/log.txt`|собственный лог PortMaster: вывод `pugwash`, трейсбеки Python|

Обновляется через 60 с после загрузки, далее каждые 5 минут и при выключении. Достаточно вынуть
карту и прочитать файл с ПК — UART не нужен.

Контрольная сумма пишется рядом с образом: `out/rg35xxpro-debian.img.sha256`. Проверка:
`cd out && sha256sum -c rg35xxpro-debian.img.sha256`.

### Перехват паники

`panic=10 pstore.backend=ramoops` в `boot.cmd`/`extlinux.conf` + узел `ramoops@48000000` (1 МиБ в
`config/dts/…-pro.dts`, `CONFIG_PSTORE_RAM/CONSOLE/PMSG=y`). После паники/зависания с oops текст
консоли лежит в `/sys/fs/pstore/` и переживает перезагрузку; раньше `console=tty0` без UART не
оставлял ничего, а `panic=0` вешал SoC вместо перезагрузки.

### Наши правки поверх ROCKNIX

|Файл|Что делает|
|---|---|
|`config/dts/sun50i-h700-anbernic-rg35xx-pro.dts`|DTS платы: DE2/SRAM, LPDDR3 1.2 В, `gpio-keys` на `&joypad`, `ramoops`|
|`config/patches/9001-asoc-sun4i-codec-h700-audio-fixes.patch`|1) `sun4i_codec_startup()` сам поднимает часы после неудачного resume вместо `-EIO`; 2) усилитель `Speaker Amp` последовательно с `LINEOUT`, чтобы наушники работали при вставленном джеке|

Настройки ядра, отличающиеся от ROCKNIX-конфига: `CONFIG_JOYSTICK_SINGLEADC_JOYPAD` выключен
(драйвер только для Qualcomm SM4450 и не собирается на arm64/Allwinner), включены
`CONFIG_PSTORE_RAM/CONSOLE/PMSG`.

## Геймпад

В образе собран драйвер ROCKNIX `rocknix-singleadc-joypad` (`config/kernel/joypad/`, включается
патчем `0020-joypad-kconfig.patch` как `CONFIG_JOYSTICK_ROCKNIX_SINGLEADC`). Узел `&joypad` из
патча ROCKNIX `0140` описывает кнопки как GPIO-узлы, а стики — как один канал `gpadc` (канал 0)
через аналоговый мультиплексор `amux`; наша правка в `config/dts/` поднимает `amux-count` до 4,
потому что у Pro две пары осей вместо нуля.

|Устройство|Коды|
|---|---|
|A, B, X, Y|`BTN_EAST`, `BTN_SOUTH`, `BTN_NORTH`, `BTN_WEST`|
|L1, R1, L2, R2|`BTN_TL/TR/TL2/TR2`|
|Select, Start, Menu|`BTN_SELECT/START/MODE`|
|Нажатия стиков|`BTN_THUMBL/THUMBR`|
|D-Pad|`BTN_DPAD_UP/DOWN/LEFT/RIGHT`|
|Стики|`ABS_X/ABS_Y` (левый), `ABS_RX/ABS_RY` (правый)|

Важно: DTS называет восточную кнопку `A` (`BTN_EAST`), а южную — `B` (`BTN_SOUTH`), поэтому в SDL
это `a:b1, b:b0`, а в RetroArch `input_a_btn = "1"`, `input_b_btn = "0"`. Обе строки и SDL GUID
(`1900f6a24b480000df14000000010000`) зафиксированы в `/etc/rg35xx/session.env`,
`~/.config/retroarch/autoconfig/udev/H700 Gamepad.cfg` и `gamecontrollerdb.txt`; подробности — в
разделе «Режимы работы → Геймпад».

Вибрация не подключена: в DTS Pro сняты `pwms`/`pwm-names`, иначе неудачный `devm_pwm_get()`
роняет весь probe вместе с кнопками.

## Известные проблемы и что дальше

|Проблема|Диагноз|Следующий шаг|
|---|---|---|
|Аналоговые стики не работают|нет драйвера под Allwinner (см. выше)|свой IIO-драйвер: `amux-*` GPIO → `gpadc` канал → `ABS_*`, калибровка по `abs_*-tuning`|
|Два `WARNING` DRM при загрузке|`panel_mipi_get_modes()` вызывает `drm_connector_set_panel_orientation()`, а DRM core делает это ещё раз через `.get_orientation` → свойство создаётся дважды (`drm_mode_object.c:46`, `:246`). Косметика, но пачкает `dmesg` и ставит taint `W`|убрать вызов из драйвера (не guard, а именно убрать) и проверить, что поворот консоли не поменялся|
|Wi-Fi: проверено 20 мин непрерывного пинга|300 пингов, потерь нет (единственные 5 подряд — перезагрузка устройства); `wifi-powersave-off.service` держит power save выключенным|нагрузочный тест при активном трафике; при обрывах — `rtw88_core.disable_lps_deep=1`|
|Suspend выключен|без TF-A `001-allwinner-h616-psci-system-suspend` + `h700-suspend-stub` сон вешает SoC|фаза 5: пересборка TF-A 2.15.0 + заглушка под lpddr3|
|Wi-Fi не поднимался вообще, хотя конфиг верный|в глобальной секции конфига стоял `powersave=0`. Это не глобальное поле wpa_supplicant: демон писал `Line 4: unknown global field 'powersave=0'`, отказывался читать файл и падал с `status=255`, systemd перезапускал его три раза и сдавался. В журнале это видно сразу|строка убрана из `wifi-config-gen`; LPS rtw88 гасится на уровне драйвера (`wifi-powersave-off.service`). Проверено на живом журнале с карты|
|Раздел `/roms` не создавался при первом запуске|`sfdisk --append` отказывается менять таблицу диска, разделы которого смонтированы («This disk is currently in use»), а на устройстве смонтирован root — команда падала, p3 не появлялся. На loop-тесте без монтирования проходило, поэтому проверка этого не поймала|`sfdisk --force --no-tell-kernel --append` + `partx --add`; сценарий «root смонтирован» добавлен в проверку|
|ES-DE: «не может создать /ports»|когда p3 не создан, `/roms` оставался каталогом `root:root 0755`, и `gamer` не мог создать в нём каталоги систем|tmpfiles создаёт `/roms 0775 root gamer`; при смонтированном разделе права даёт `uid=1000,gid=1000`|
|`user@1000` не стартует → нет PipeWire|в журнале `systemd[402]: Failed to allocate manager object: Permission denied` сразу после `pam_unix(systemd-user:session)`. Пользовательский менеджер поднимается по linger до того, как появился `XDG_RUNTIME_DIR`|tmpfiles создаёт `/run/user/1000 0700 gamer gamer`; `boot-report.txt` теперь печатает статус `user@1000`, права `/run/user`, монтирования cgroup и состояние `pipewire`/`wireplumber` в пользовательской сессии|
|Wi-Fi не поднимается при верном `wifi.conf`|`wpa_supplicant@wlan0` стартовал раньше, чем rtw88 создавал `wlan0` (firmware грузится позже multi-user), падал с «Failed to initialize interface» и никто его не перезапускал; вдобавок радио могло быть soft-blocked|исправлено: drop-in `wpa_supplicant@wlan0.service.d/10-rg35xx.conf` с `After=sys-subsystem-net-devices-wlan0.device`, `Restart=on-failure` и юнит `rg35xx-wifi-unblock` (`rfkill unblock all`). Диагностика — `rfkill list` и журнал в `boot-report.txt`|
|PortMaster закрывается сразу|вывод `pugwash` уходил в tty1 и терялся|логи теперь в `/roms/ports/PortMaster/log.txt` (FAT, читается с ПК) и `/run/rg35xx/game.log`, оба дублируются в `boot-report.txt`; `/dev/tty0` открыт на запись (udev-правило), PortMaster больше не спотыкается о свой `printf` в консоль|
|Desktop: только курсор и меню labwc|клиенты autostart'а стартовали без логов и могли получить `SIGTTIN` (stdin — tty1), а также раньше готового Wayland-сокета|`rg35xx-desktop-autostart` ждёт сокет, запускает клиентов с `</dev/null`, пишет `desktop.log` и состояние через 3 с|
|Громкость: потолок средний|`DAC` уже на 0 дБ; остальное — `Line Out`, которым управляет WirePlumber из громкости sink (100 % = 31 = 0 дБ)|если мало — sink на 100 %; больше запаса нет, только внешний усилитель наушников|

## Звук: что проверено на железе

|Проверка|Результат|
|---|---|
|Карта|`h616-audio-codec` (`sun4i-codec`), PCM `hw:0,0`, 48 кГц S16_LE стерео|
|Динамик|играет; при воспроизведении `gpio-261` (PI5) = high, `vcc-spkr-amp` = enabled|
|Наушники|играют после патча `9001`; детект `hp-det` (PI3) даёт `SW_HEADPHONE_INSERT=1` и `Headphone Jack = on`|
|Динамик при вставленном jack|молчит (мультиплексор переключается, усилитель остаётся включённым — так и задумано схемой)|
|Кнопки громкости|`triggerhappy` (thd, под root) → `rg35-volume` → `wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%±`, проверено 0.80 → 0.90 → 0.85|
|Калибровка|`DAC` 63/63 = 0 дБ — жёсткий потолок. WirePlumber держит `Line Out` (0..31 = −43.5..0 дБ) в соответствии с громкостью sink: 100 % → 31, 80 % → 28, 50 % → 19, 0 % → 0. Дефолт sink 80 % (−1.5 дБ), максимум 100 %|

Маршрут сигнала на этой плате: `DAC → Line Out Ramp → усилитель (PI5 + CLDO1) → 74HC4052 (мультиплексор
динамик/джек)`. Отсюда два вывода, которые и зашиты в патч `9001`: усилитель обязан включаться при
любом воспроизведении (а не только когда активен DAPM-пин `Speaker`), и он же питает джек.
