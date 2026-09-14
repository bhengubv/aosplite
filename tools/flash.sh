#!/usr/bin/env bash
# flash.sh - put a system image on a device, in one fixed order, never
#            without preflight.
#
#   tools/flash.sh --img out/.../system.img \
#                  --vbmeta ~/lynx/gsi-vbmeta.img \
#                  --serial 3B221JEHN16653
#
# Why this exists
# ---------------
# Every flash in this project used to be typed by hand. The order changed
# between attempts, the vbmeta changed between attempts, preflight got
# skipped when it was late, and nothing was written down. So when a boot
# failed there was no way to say what had actually been done to the device
# - which turned every failure into an argument instead of a datapoint.
#
# This script exists so that a flash is always the same flash.
#
# The two rules it enforces
# -------------------------
#   1. Preflight ALWAYS runs. It cannot be skipped, only overridden with
#      --force, which is recorded in the log and printed in the summary.
#   2. If preflight finds a blocking problem, NOTHING is written to the
#      device. The script exits non-zero before the first fastboot write.
#
# The order, and why it is this order
# -----------------------------------
#   reboot to fastbootd   - the bootloader cannot write a logical partition
#   erase system          - the partition is resized to fit; writing over a
#                           larger one leaves its tail behind
#   flash system          - the image itself
#   delete stock product/system_ext (optional) - a GSI carries its own
#   reboot to bootloader  - vbmeta is written from the bootloader
#   flash vbmeta          - LAST: it is the root of the boot chain, and
#                           writing it first means the rest of the flash
#                           invalidates what it describes
#   wipe userdata/metadata- required after the boot state changes
#   set_active + reboot   - restores the slot's retry count
#
# About vbmeta, because this cost a night
# ---------------------------------------
# Pass a vbmeta whose flags already disable verification - flags=2 or 3 in
# the file itself. Do not rely on fastboot's --disable-verity and
# --disable-verification: on a Pixel 7a they did not take effect, AVB
# reported "status: Success", a verity table was built for a system image
# that could not match it, DM_TABLE_LOAD failed, /system never mounted and
# init died. The same device booted fine with a vbmeta carrying flags=2.
# The flags are passed anyway - they cost nothing - but the file is what is
# trusted.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMG=""
VBMETA=""
REFERENCE=""
VENDOR=""
SERIAL="${SERIAL:-}"
FORCE=0
WIPE=1
DELETE_STOCK=0
BOOT_TIMEOUT=1800
LOG=""
NO_BOOT=0

BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; OFF=""
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[1;31m'
    GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; OFF=$'\033[0m'
fi

usage() {
    sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    cat <<'USAGE'

Options
  --img FILE         system image to flash (required)
  --vbmeta FILE      vbmeta to flash last. Use one with the disable bits
                     set in the FILE (flags=2 or 3), not one that depends
                     on fastboot honouring a command-line flag
  --reference FILE   known-good system image, passed to preflight
  --vendor FILE      factory vendor.img, passed to preflight
  --serial S         adb/fastboot serial; required if more than one device
  --delete-stock     also delete the stock product/system_ext logical
                     partitions. Irreversible without a factory flash
  --no-wipe          skip erasing userdata/metadata
  --no-boot          flash only; do not wait for or verify the boot
  --boot-timeout S   default 1800
  --force            flash even if preflight reports blocking problems.
                     Recorded in the log and in the summary
  --log FILE         default ./flash-<timestamp>.log
  -h, --help

Exit codes
  0  flashed, and booted if the boot phase ran
  1  preflight blocked the flash, or the flash failed
  2  bad arguments / missing tools
  3  flashed, but the device did not boot
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --img) IMG="$2"; shift ;;
        --vbmeta) VBMETA="$2"; shift ;;
        --reference) REFERENCE="$2"; shift ;;
        --vendor) VENDOR="$2"; shift ;;
        --serial) SERIAL="$2"; shift ;;
        --delete-stock) DELETE_STOCK=1 ;;
        --no-wipe) WIPE=0 ;;
        --no-boot) NO_BOOT=1 ;;
        --boot-timeout) BOOT_TIMEOUT="$2"; shift ;;
        --force) FORCE=1 ;;
        --log) LOG="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

LOG="${LOG:-$PWD/flash-$(date +%Y%m%d-%H%M%S).log}"
: > "$LOG" || { echo "cannot write $LOG" >&2; exit 2; }

say()  { printf '%s\n' "$*" | tee -a "$LOG" >/dev/null; printf '%s\n' "$*"; }
step() { say ""; say "${BOLD}== $* ==${OFF}"; }
info() { say "  $*"; }
note() { say "  ${DIM}$*${OFF}"; }
ok()   { say "  ${GRN}ok${OFF}   $*"; }
warn() { say "  ${YEL}WARN${OFF} $*"; }
die()  { say ""; say "  ${RED}$1${OFF}"; say "  log: $LOG"; exit "${2:-1}"; }

[ -n "$IMG" ] || { echo "--img is required" >&2; exit 2; }
[ -f "$IMG" ] || { echo "--img $IMG does not exist" >&2; exit 2; }

ADB="${ADB:-$(command -v adb 2>/dev/null)}"
FASTBOOT="${FASTBOOT:-$(command -v fastboot 2>/dev/null)}"
[ -n "$ADB" ] && [ -n "$FASTBOOT" ] || {
    echo "adb/fastboot not found. Under WSL they usually live on the Windows"
    echo "side; pass them as ADB=... FASTBOOT=... or run this from Windows." >&2
    exit 2
}

# Nothing here may block. fastboot waits forever for a device that is not
# in fastboot mode, and a flash script that hangs looks like a flash script
# that is working.
HAVE_DEBUGFS_LOCAL=0
command -v debugfs >/dev/null 2>&1 && HAVE_DEBUGFS_LOCAL=1

fb() { timeout 600 "$FASTBOOT" ${SERIAL:+-s "$SERIAL"} "$@" 2>&1; }
ad() { timeout 60  "$ADB"      ${SERIAL:+-s "$SERIAL"} "$@" 2>&1; }
gv() { fb getvar "$1" | grep -o "$1: .*" | head -1 | cut -d' ' -f2-; }

say "${BOLD}flash.sh${OFF}  $(date '+%Y-%m-%d %H:%M:%S')"
say "  image  : $IMG ($(du -h "$IMG" 2>/dev/null | cut -f1))"
say "  vbmeta : ${VBMETA:-none}"
say "  serial : ${SERIAL:-auto}"
say "  log    : $LOG"

# ====================================================== 1. PREFLIGHT
#
# Always. The one time this was skipped in practice, it was skipped
# because it was late and the image "had already been checked" - and the
# flash that followed went to a device whose slot had no boot attempts
# left, so it never even tried to boot. Twenty minutes to learn nothing.
step "preflight"
PF="$SELF_DIR/flash-preflight.sh"
[ -x "$PF" ] || [ -f "$PF" ] || die "flash-preflight.sh not found next to this script ($PF)" 2

# The two halves of preflight do not live on the same machine here.
# Reading an ext4 image needs debugfs, which is Linux. Talking to the phone
# needs USB, which WSL2 does not have at all - fastboot run from WSL simply
# reports "no device". So on Windows the image half is run through WSL and
# the device half locally, and BOTH must pass.
#
# Without this the choice was: run from Windows and have every image check
# skipped, or run from WSL and have every device check skipped. The first
# of those let a deliberately corrupt image reach a phone.
PF_IMAGE_RC=0
if [ "$HAVE_DEBUGFS_LOCAL" != 1 ] && command -v wsl.exe >/dev/null 2>&1; then
    info "no debugfs here; running the image checks through WSL"
    wslpath_of() { wsl.exe -e wslpath -a "$1" 2>/dev/null | tr -d ''; }
    w_img=$(wslpath_of "$IMG")
    w_pf=$(wslpath_of "$PF")
    w_log=$(wslpath_of "${LOG%.log}-preflight-image.log")
    w_args="--img '$w_img' --image-only --log '$w_log'"
    [ -n "$VBMETA" ]    && w_args="$w_args --vbmeta '$(wslpath_of "$VBMETA")'"
    [ -n "$REFERENCE" ] && w_args="$w_args --reference '$(wslpath_of "$REFERENCE")'"
    [ -n "$VENDOR" ]    && w_args="$w_args --vendor '$(wslpath_of "$VENDOR")'"
    wsl.exe -e bash -c "bash '$w_pf' $w_args" 2>&1 | tee -a "$LOG"
    PF_IMAGE_RC="${PIPESTATUS[0]}"
    [ "$PF_IMAGE_RC" = 0 ] && ok "image checks passed (via WSL)" ||
        warn "image checks FAILED via WSL (exit $PF_IMAGE_RC)"
    PF_LOCAL_SCOPE=(--device-only)
else
    PF_LOCAL_SCOPE=()
fi

pf_args=(--img "$IMG" --log "${LOG%.log}-preflight.log" "${PF_LOCAL_SCOPE[@]+"${PF_LOCAL_SCOPE[@]}"}")
[ -n "$VBMETA" ]    && pf_args+=(--vbmeta "$VBMETA")
[ -n "$REFERENCE" ] && pf_args+=(--reference "$REFERENCE")
[ -n "$VENDOR" ]    && pf_args+=(--vendor "$VENDOR")
[ -n "$SERIAL" ]    && pf_args+=(--serial "$SERIAL")

ADB="$ADB" FASTBOOT="$FASTBOOT" bash "$PF" "${pf_args[@]}" 2>&1 | tee -a "$LOG"
PF_RC="${PIPESTATUS[0]}"
# Either half failing blocks the flash. A pass on one is not a pass.
[ "$PF_IMAGE_RC" != 0 ] && PF_RC="$PF_IMAGE_RC"

if [ "$PF_RC" != 0 ]; then
    if [ "$FORCE" = 1 ]; then
        warn "preflight reported blocking problems (exit $PF_RC)."
        warn "--force was given, so flashing anyway. This is recorded here and"
        warn "in the summary; if the boot fails, that decision is part of the"
        warn "evidence."
        FORCED_PAST_PREFLIGHT=1
    else
        die "preflight found blocking problems (exit $PF_RC).
  NOTHING has been written to the device.
  Fix them, or re-run with --force if you have a reason to proceed.
  preflight log: ${LOG%.log}-preflight.log" 1
    fi
else
    ok "preflight clean"
fi

# ====================================================== 2. REACH fastbootd
step "device"
state=""
if fb devices | grep -q fastboot; then state=fastboot
elif ad get-state 2>/dev/null | grep -q device; then state=adb
fi
case "$state" in
    "") die "no device found. Connect it and make sure the bootloader is
  unlocked. If more than one is attached, pass --serial." 2 ;;
    adb) info "device is in Android - rebooting to fastboot"
         ad reboot bootloader >/dev/null 2>&1 || true
         sleep 22 ;;
esac

# A logical partition inside super can only be written by USERSPACE
# fastboot. Bootloader fastboot refuses in a way that reads like a driver
# problem, which is how an evening disappears.
us=$(gv is-userspace)
if [ "$us" != yes ]; then
    info "entering userspace fastboot (fastbootd)"
    fb reboot fastboot >/dev/null 2>&1 || true
    sleep 25
    us=$(gv is-userspace)
fi
[ "$us" = yes ] || die "could not reach userspace fastboot. The system partition
  cannot be written from bootloader fastboot."

SLOT=$(gv current-slot); SLOT="${SLOT:-a}"
ok "userspace fastboot, slot $SLOT"

# ====================================================== 3. WRITE
step "flash"

info "erasing system"
fb erase system | tail -1 | sed 's/^/    /'

info "flashing system ($(du -h "$IMG" | cut -f1))"
if ! fb flash system "$IMG" | tail -2 | sed 's/^/    /'; then
    die "fastboot flash system failed"
fi
ok "system written"

if [ "$DELETE_STOCK" = 1 ]; then
    for p in product system_ext; do
        info "deleting stock ${p}_${SLOT}"
        fb delete-logical-partition "${p}_${SLOT}" | tail -1 | sed 's/^/    /'
    done
fi

# vbmeta from the BOOTLOADER, and last. See the header.
if [ -n "$VBMETA" ] && [ -f "$VBMETA" ]; then
    info "returning to bootloader fastboot for vbmeta"
    fb reboot bootloader >/dev/null 2>&1 || true
    sleep 22
    info "flashing vbmeta"
    if ! fb --disable-verity --disable-verification flash vbmeta "$VBMETA" |
         tail -1 | sed 's/^/    /'; then
        die "vbmeta flash failed"
    fi
    ok "vbmeta written"
else
    warn "no --vbmeta given. A self-built system needs verity off; without it
        the device is likely to refuse the image or fail to mount /system."
fi

if [ "$WIPE" = 1 ]; then
    info "wiping userdata and metadata (required after the boot state changes)"
    fb erase userdata >/dev/null 2>&1 || true
    fb erase metadata >/dev/null 2>&1 || true
fi

# set_active restores the slot's retry count. Without it a slot that has
# already failed three times will not be tried at all, and the device
# returns to fastboot without ever attempting to boot - which looks
# identical to the image failing.
fb set_active "$SLOT" >/dev/null 2>&1 || true
ok "slot $SLOT active, retries $(gv "slot-retry-count:$SLOT")"

if [ "$NO_BOOT" = 1 ]; then
    step "done"
    say "  flashed, boot not attempted (--no-boot)"
    say "  log: $LOG"
    exit 0
fi

# ====================================================== 4. BOOT
#
# A flash that is not followed by a boot proves nothing. This waits for one
# of three definite answers - booted, fell back to fastboot, or timed out -
# and never exits silently claiming success.
step "boot"
fb reboot >/dev/null 2>&1 || true
start=$SECONDS
VERDICT=""
while [ $(( SECONDS - start )) -lt "$BOOT_TIMEOUT" ]; do
    t=$(( SECONDS - start ))
    if ad devices 2>/dev/null | grep -qE "(device|unauthorized)$"; then
        VERDICT="BOOTED after ${t}s"; break
    fi
    if [ "$t" -gt 25 ] && fb devices 2>/dev/null | grep -q fastboot; then
        VERDICT="FAILED - back in fastboot after ${t}s"; break
    fi
    [ $(( t % 60 )) -lt 5 ] && note "$((t/60)) min - still booting"
    sleep 5
done
[ -n "$VERDICT" ] || VERDICT="TIMEOUT after $(( BOOT_TIMEOUT / 60 )) min - neither adb nor fastboot"

step "result"
say "  $VERDICT"
case "$VERDICT" in
    BOOTED*)
        say "  fingerprint: $(ad shell getprop ro.build.fingerprint | tr -d '\r')"
        say "  boot_completed: $(ad shell getprop sys.boot_completed | tr -d '\r')" ;;
    *)
        # The reason lives in the kernel log of the boot that just failed,
        # it holds ONE boot, and every extra reboot costs it. Say so here
        # rather than leaving someone to rediscover it at 3am.
        say ""
        say "  The reason is in the kernel log of the boot that just failed."
        say "  It holds one boot only. To read it:"
        say "      tools/rescue-log.sh <unzipped-factory-image-dir>"
        say "  then, once stock is up:"
        say "      adb shell dumpsys dropbox --print SYSTEM_LAST_KMSG"
        say "  That is the fastest route to an actual answer - it named a"
        say "  verity failure in one line after a night of theories." ;;
esac
[ "${FORCED_PAST_PREFLIGHT:-0}" = 1 ] &&
    say "  NOTE: preflight was overridden with --force for this flash."
say "  log: $LOG"

case "$VERDICT" in BOOTED*) exit 0 ;; *) exit 3 ;; esac
