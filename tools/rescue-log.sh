#!/usr/bin/env bash
# rescue-log.sh [factory-image-dir] [serial]
#
#   tools/rescue-log.sh ~/lynx-cp1a.260405.005
#
# Recovers the kernel log from a device that just failed to boot, WITHOUT
# destroying it on the way.
#
# Why this is delicate
# --------------------
# When a build fails to boot, the reason is in the kernel's RAM console
# (pstore/ramoops). Three facts decide everything:
#
#   1. It survives a REBOOT. It does not survive a POWER-OFF. Holding the
#      power button for ten seconds to reset a stuck USB port erases the
#      only explanation you have.
#   2. Reading it needs a booted Android - dumpsys reads the buffer on the
#      next boot and writes it into /data, which is why a userdata wipe
#      does not lose it.
#   3. Userspace fastboot (fastbootd) boots a recovery kernel, and that
#      overwrites the buffer. So anything that reboots into fastbootd to
#      restore the device destroys the log first.
#
#   bootloader fastboot -> flash-all -> stock boots -> dumpsys dropbox
#
# HONEST WARNING: on a Pixel 7a this did not reproduce. The log was
# recovered once this way and lost the next two times, and the likely
# reason is that flash-all itself reboots into userspace fastboot to write
# the logical partitions inside super - so the recovery kernel overwrites
# the buffer before stock ever boots. If that is right, the log cannot be
# recovered on that device once the boot has failed, and no ordering
# helps.
#
# Try it anyway - it costs one restore you were going to do regardless -
# but do not plan around it, and do not let it stop you acting on evidence
# you already have.
#
# What definitely destroys it, each learned by doing it:
#
#   - powering the device off, for any reason, including to reset a stuck
#     USB port
#   - rebooting into fastbootd first
#   - rebooting more than once; the buffer holds the PREVIOUS boot only
#
# Get the factory image for your device from
# https://developers.google.com/android/images and unzip it.

set -eo pipefail

DIR="${1:-}"
SERIAL="${2:-}"
OUT="${OUT:-$PWD/last_kmsg-$(date +%Y%m%d-%H%M%S).txt}"

fb() { fastboot ${SERIAL:+-s "$SERIAL"} "$@"; }
ad() { adb ${SERIAL:+-s "$SERIAL"} "$@"; }

say() { printf '  %s\n' "$1"; }
die() { printf '\n  %s\n' "$1" >&2; exit 1; }

command -v fastboot >/dev/null 2>&1 || die "fastboot not on PATH"
command -v adb >/dev/null 2>&1 || die "adb not on PATH"

echo "=== state ==="
if ! fb devices 2>/dev/null | grep -q .; then
    if ad get-state 2>/dev/null | grep -q device; then
        die "The device is booted. Either it did not fail, or it has already
  been recovered - and in that case the log is gone. Read it now with:
      adb shell dumpsys dropbox --print SYSTEM_LAST_KMSG"
    fi
    die "No device. If it is powered off, the log is already lost: the RAM
  console does not survive a power cycle. Nothing here will help."
fi

userspace=$(fb getvar is-userspace 2>&1 | grep -oE 'is-userspace: *[a-z]+' |
            awk '{print $2}')
say "fastboot: $([ "$userspace" = yes ] && echo 'USERSPACE (fastbootd)' || echo bootloader)"

if [ "$userspace" = yes ]; then
    cat >&2 <<'LOST'

  The device is in USERSPACE fastboot. Getting here boots a recovery
  kernel, which has already overwritten the RAM console - the log from the
  failed boot is gone.

  Nothing can recover it now. Restore the device however you like, and
  next time go straight from bootloader fastboot to flash-all without
  rebooting into fastbootd first.
LOST
    exit 1
fi

[ -n "$DIR" ] || die "give the unzipped factory image directory:
      tools/rescue-log.sh ~/lynx-cp1a.260405.005"
[ -f "$DIR/flash-all.sh" ] || [ -f "$DIR/flash-all.bat" ] ||
    die "no flash-all script in $DIR - is that the unzipped factory image?"

echo
echo "=== restoring stock ==="
say "This reboots the device once. It does NOT power it off, which is what"
say "keeps the RAM console intact."
( cd "$DIR"
  if [ -f flash-all.sh ]; then bash ./flash-all.sh; else cmd.exe /c ".\\flash-all.bat"; fi
) 2>&1 | tail -5 | sed 's/^/    /'

echo
echo "=== waiting for stock to boot ==="
for i in $(seq 1 40); do
    b=$(ad shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ "$b" = 1 ] && break
    printf '  %s  waiting\n' "$(date +%H:%M:%S)"
    sleep 30
done
[ "$b" = 1 ] || die "stock did not boot within 20 minutes"
say "booted"

echo
echo "=== reading the log ==="
# dumpsys reads the RAM console on this first boot and files it in
# /data/system/dropbox. This is the only moment it is available.
ad shell dumpsys dropbox --print SYSTEM_LAST_KMSG > "$OUT" 2>/dev/null || true

if [ ! -s "$OUT" ]; then
    die "dropbox has no SYSTEM_LAST_KMSG.

  Either the device was powered off at some point, or it rebooted more
  than once before this - the buffer holds the previous boot only."
fi

say "saved: $OUT  ($(wc -l < "$OUT") lines)"

echo
echo "=== what it says ==="
grep -iE "failed to mount|cannot mount|Attempted to kill init|Kernel PANIC|\
avb_ret|Failed to verify|init: .*Failed|no such|selinux.*denied" "$OUT" |
    head -20 | sed 's/^/    /' ||
    say "no obvious failure lines - read $OUT in full"

echo
say "Full log: $OUT"
