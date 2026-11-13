#!/bin/sh
# Capture and summarise input events from the handheld's own controls (gamepad + volume keys).
# Read-only: uses evtest, changes nothing on the system.
#
#   sh device-input-capture.sh            # show devices and their capabilities
#   sh device-input-capture.sh 20         # record 20 s of events from each device, print a summary
#
# Buttons to press while recording: A B X Y, Menu, Select, Start, L1 L2 R1 R2,
# every D-Pad direction, both sticks to the extremes, and Volume Up/Down.
set -u
DUR=${1:-0}
OUT=/tmp/input-capture
mkdir -p "$OUT"

find_dev() { # $1 = name pattern
  awk -v pat="$1" '
    /^I: Bus=/ { dev=$0 }
    /^N: Name=/ { name=$0 }
    /^H: Handlers=/ && name ~ pat { for (i=1;i<=NF;i++) if ($i ~ /^event/) print "/dev/input/" $i }
  ' /proc/bus/input/devices
}

echo "=== input devices ==="
grep -E '^N: Name=|^H: Handlers=' /proc/bus/input/devices | paste - - | sed 's/\t/  /'

JOY=$(find_dev "joypad|rocknix" | head -1)
VOL=$(find_dev "gpio-keys|Volume|volume" | head -1)
KBD=$(find_dev "Keyboard|keyboard" | head -1)
echo
echo "joypad device : ${JOY:-not found}"
echo "volume device : ${VOL:-not found}"
echo "keyboard      : ${KBD:-not found}"

if [ "$DUR" -le 0 ]; then
  echo
  echo "Run with a duration to record, e.g.: sh $0 20"
  exit 0
fi

for pair in "joypad:$JOY" "volume:$VOL"; do
  kind=${pair%%:*}; dev=${pair#*:}
  [ -n "$dev" ] && [ -e "$dev" ] || { echo "-- $kind: no device, skipped"; continue; }
  echo
  echo "=== recording $kind ($dev) for ${DUR}s — press the buttons now ==="
  timeout "$DUR" evtest "$dev" > "$OUT/$kind.log" 2>&1 || true
  echo "--- unique events ($kind) ---"
  awk -F'[()]' '/^Event:/{print $2}' "$OUT/$kind.log" | sed 's/^ *//' | sort | uniq -c | sort -k2 | head -60
  echo "--- ABS ranges ($kind) ---"
  awk '/code [0-9]+, value/ {print $0}' "$OUT/$kind.log" | grep -i 'ABS' | sed 's/^ *//' | sort -u | head -20
done

echo
echo "raw logs: $OUT/*.log"
