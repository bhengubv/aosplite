#!/usr/bin/env bash
# check-env.sh [tree] [lunch-target] [make-target]
#
#   tools/check-env.sh ~/android circle_arm64-bp4a-userdebug systemimage
#
# Everything here is a build that actually died. None of it is theoretical
# and none of it is about your source code - these are the ways an Android
# build is lost to its environment, hours in, with a message that does not
# say what happened.
#
# Exit 0 = go. Exit 1 = something will bite you. Exit 2 = cannot tell.

set -eo pipefail

TREE="${1:-$HOME/android}"
LUNCH="${2:-}"
TARGET="${3:-}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
warn=0
say()  { printf '  %-9s %s\n' "$1" "$2"; }
bad()  { say "FAIL" "$1"; fail=$((fail+1)); }
soft() { say "WARN" "$1"; warn=$((warn+1)); }
ok()   { say "ok" "$1"; }

echo "=== manifests ==="

# repo will not read a manifest that is not well-formed, and the easiest
# way to break one is a rule of hyphens in a comment - XML forbids "--"
# there. optional-formfactors.xml shipped broken for exactly this reason
# and nothing noticed, because nothing parsed it.
for f in "$SELF"/manifests/*.xml; do
    [ -e "$f" ] || continue
    if python3 -c "import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "$f" 2>/dev/null; then
        ok "$(basename "$f") parses"
    else
        bad "$(basename "$f") is not well-formed XML - repo cannot read it"
        python3 -c "import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "$f" 2>&1 | tail -1 | sed 's/^/            /'
    fi
done

# Same check on the local manifests actually in use, which is where a
# hand-edited comment goes wrong.
if [ -d "$TREE/.repo/local_manifests" ]; then
    for f in "$TREE"/.repo/local_manifests/*.xml; do
        [ -e "$f" ] || continue
        python3 -c "import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "$f" 2>/dev/null \
            || bad "in-tree $(basename "$f") is not well-formed XML"
    done
fi

echo
echo "=== lunch target ==="

if [ -z "$LUNCH" ]; then
    soft "no lunch target given - release config not checked"
else
    case "$LUNCH" in
        *-trunk_staging-*)
            # Correct for Cuttlefish, wrong for hardware, and the image
            # boots on Cuttlefish either way - so the mistake looks like
            # success until you flash a phone.
            soft "$LUNCH uses trunk_staging"
            say "" "That image reports codename=<codename> rather than REL and"
            say "" "preview_sdk=1. It boots on Cuttlefish and bootloops on a"
            say "" "retail device. Fine if the vendor half comes from this same"
            say "" "build; otherwise use a released config:"
            say "" "  ${LUNCH/trunk_staging/bp4a}"
            ;;
        *-*-*) ok "$LUNCH uses a released config" ;;
        *) bad "$LUNCH is not <product>-<release>-<variant>" ;;
    esac

    if [ -d "$TREE" ]; then
        rel=$(echo "$LUNCH" | cut -d- -f2)
        if [ -d "$TREE/build/release/flag_values/$rel" ] || [ "$rel" = "trunk_staging" ]; then
            ok "release config '$rel' exists in this tree"
        else
            bad "release config '$rel' not in $TREE/build/release/flag_values/"
            say "" "available: $(ls "$TREE/build/release/flag_values/" 2>/dev/null | tr '\n' ' ')"
        fi
    fi
fi

echo
echo "=== make target ==="

# A target that builds nothing is the quietest failure in AOSP: ninja says
# "no work to do", exits 0, and there is no image. Usually the product
# does not inherit generic_system.mk, so nothing declares a system image.
if [ -z "$TARGET" ]; then
    soft "no make target given"
else
    case "$TARGET" in
        systemimage|droid|nothing|dist|"")
            ok "'$TARGET' is a standard target" ;;
        *image|*.img)
            ok "'$TARGET' looks like an image target" ;;
        m|mm|mma|mmm)
            bad "'$TARGET' is a build *command*, not a target" ;;
        *)
            soft "'$TARGET' is a module name, not an image target"
            say "" "That builds one module. For an image use 'systemimage',"
            say "" "or 'droid' for everything. For a config-only check use"
            say "" "'nothing', which runs analysis and compiles nothing." ;;
    esac
fi

if [ -n "$LUNCH" ] && [ -d "$TREE" ] && [ "$TARGET" = "systemimage" ]; then
    product=$(echo "$LUNCH" | cut -d- -f1)
    # Spacing around := is arbitrary and usually aligned, so match on
    # whitespace rather than assuming one space.
    mk=$(grep -rlE "PRODUCT_NAME[[:space:]]*:=[[:space:]]*$product([[:space:]]|\$)" \
            "$TREE"/device "$TREE"/build "$TREE"/vendor \
            --include="*.mk" 2>/dev/null | head -1 || true)
    if [ -z "$mk" ]; then
        soft "could not find the makefile defining PRODUCT_NAME := $product"
        say "" "Cannot check whether it declares a system image."
    elif true; then
        if grep -qE "generic_system\.mk|generic_ramdisk\.mk|base_system\.mk" "$mk" 2>/dev/null; then
            ok "$product inherits a system-image base"
        else
            soft "$product does not obviously inherit generic_system.mk"
            say "" "in $(echo "$mk" | sed "s|$TREE/||")"
            say "" "If nothing declares a system image, 'm systemimage' exits 0"
            say "" "with no .img and no error. Check the inherit chain."
        fi
    fi
fi

echo
echo "=== memory ==="

ram_g=$(free -g | awk '/^Mem:/{print $2}')
swap_g=$(free -g | awk '/^Swap:/{print $2}')
say "ram" "${ram_g}G"
say "swap" "${swap_g}G"

# soong_build reads every build file in one process. Measured at 22 GB
# resident on a pruned Android 16 tree. Builds died repeatedly at 16 GB of
# swap, and survived at 40 and 64.
total=$((ram_g + swap_g))
if [ "$total" -lt 40 ]; then
    bad "${total}G ram+swap. soong_build peaks near 22G; below ~40G total"
    say "" "it gets OOM-killed or earlyoom takes it. On WSL raise swap in"
    say "" "C:\\Users\\<you>\\.wslconfig and wsl --shutdown."
elif [ "$total" -lt 56 ]; then
    soft "${total}G ram+swap is enough but not comfortable"
else
    ok "${total}G ram+swap"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active earlyoom >/dev/null 2>&1; then
    soft "earlyoom is running"
    say "" "It kills the largest process when RAM and swap are both low, and"
    say "" "soong_build is always the largest. --avoid does not exempt it -"
    say "" "it only lowers the score. Stop it for the build, or give the"
    say "" "machine enough swap that the threshold is never reached."
fi

echo
echo "=== disk ==="

avail_g=$(df -BG --output=avail "$TREE" 2>/dev/null | tail -1 | tr -dc '0-9')
say "free" "${avail_g:-?}G on $(df --output=target "$TREE" 2>/dev/null | tail -1)"
if [ -n "$avail_g" ]; then
    if [ "$avail_g" -lt 60 ]; then
        bad "${avail_g}G free. out/ needs 100-150G; the build dies partway"
        say "" "and nothing in out/ is salvageable."
    elif [ "$avail_g" -lt 150 ]; then
        soft "${avail_g}G free - enough to start, not enough for a full droid"
    else
        ok "${avail_g}G free"
    fi
fi

case "$(readlink -f "$TREE")" in
    /mnt/[a-z]/*)
        bad "tree is on a Windows drive ($TREE)"
        say "" "Every file access crosses the translation layer. AOSP touches"
        say "" "a million files. Move it into the WSL filesystem." ;;
esac

echo
echo "=== build environment ==="

# USE_CCACHE controls CC_WRAPPER, which is prepended to every C++ compile
# command. Changing it in either direction rewrites all ~100,000 of them
# and ninja rebuilds everything. Ninety minutes becomes days.
if [ -n "${USE_CCACHE:-}" ]; then
    stamp="$TREE/out/soong/soong.environment.used.build"
    if [ -f "$stamp" ] && grep -q '"USE_CCACHE"' "$stamp" 2>/dev/null; then
        was=$(grep -o '"USE_CCACHE"[^,]*,[^,}]*' "$stamp" | head -1 | grep -o '"[^"]*"$' | tr -d '"')
        if [ -n "$was" ] && [ "$was" != "${USE_CCACHE}" ]; then
            bad "USE_CCACHE is '${USE_CCACHE}' but out/ was built with '${was}'"
            say "" "That rewrites every compile command. ninja will rebuild the"
            say "" "whole tree. Put it back to '${was}' or accept a full build."
        else
            ok "USE_CCACHE matches what out/ was built with"
        fi
    else
        soft "USE_CCACHE is set ('${USE_CCACHE}') and out/ has no record yet"
        say "" "Whatever you choose now, do not change it later."
    fi
else
    ok "USE_CCACHE not set - the tree's own setting stands"
fi

if [ "${ALLOW_MISSING_DEPENDENCIES:-}" = "true" ]; then
    ok "ALLOW_MISSING_DEPENDENCIES=true"
elif [ -d "$TREE/.repo/local_manifests" ] &&
     ls "$TREE"/.repo/local_manifests/*.xml >/dev/null 2>&1; then
    bad "pruned tree without ALLOW_MISSING_DEPENDENCIES=true"
    say "" "Soong panics rather than skipping modules whose dependencies were"
    say "" "pruned - validate_bindings.go raises 'Fuzzer doesn't exist'."
fi

# Go and ccache write to GOCACHE / XDG_CACHE_HOME when those are set, and
# fall back to ~/.cache when they are not. On a default WSL install
# ~/.cache is owned by root, and the failure is "failed to initialize build
# cache: permission denied" before lunch even finishes.
gocache="${GOCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/go-build}"
xdg="${XDG_CACHE_HOME:-$HOME/.cache}"
cache_problem=0
for d in "$gocache" "$xdg"; do
    probe="$d"
    while [ -n "$probe" ] && [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
    [ -w "$probe" ] || { bad "cache directory not writable: $d (blocked at $probe)"; cache_problem=1; }
done
if [ "$cache_problem" = "0" ]; then
    ok "cache directories writable (GOCACHE=$gocache)"
else
    say "" "Set GOCACHE and XDG_CACHE_HOME somewhere you own, as"
    say "" "tools/build.sh does."
fi

if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] &&
   [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = "1" ] &&
   [ -x "$TREE/prebuilts/build-tools/linux-x86/bin/nsjail" ]; then
    soft "unprivileged user namespaces are restricted"
    say "" "Soong's nsjail sandbox needs them. On Ubuntu 24.04 this gets"
    say "" "switched on by a routine package upgrade, and the build fails"
    say "" "with a sandbox error that names neither AppArmor nor nsjail."
fi

echo
echo "=== host tools ==="

# Missing tools fail at the least useful moment. repo goes missing when a
# shell does not have ~/bin on PATH; debugfs is only needed for image
# checks but is absent from a minimal install.
for t in repo python3 git; do
    if command -v "$t" >/dev/null 2>&1; then
        ok "$t $(command -v "$t")"
    else
        bad "$t not on PATH"
    fi
done
command -v debugfs >/dev/null 2>&1     && ok "debugfs (needed by check-image.sh)"     || soft "debugfs missing - check-image.sh will not run (apt install e2fsprogs)"

echo
echo "=== the machine changing under you ==="

# This is the root of the worst cascade in this project's history. An
# unrelated "apt install fail2ban" pulled package upgrades with it, one of
# which switched on kernel.apparmor_restrict_unprivileged_userns. That
# broke nsjail, which broke Soong, and the error named neither. Nothing
# about the build had changed.
if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
    soft "unattended-upgrades is enabled"
    say "" "Package upgrades land mid-build and change the machine. One of"
    say "" "them switching on the AppArmor userns restriction broke Soong's"
    say "" "sandbox here, and the failure named neither AppArmor nor nsjail."
    say "" "Consider masking it while a long build runs."
else
    ok "unattended-upgrades not enabled"
fi

if [ -f /var/run/reboot-required ]; then
    soft "a reboot is pending"
    say "" "Packages have been upgraded since boot. The running kernel and"
    say "" "the installed one differ, which is how a sandbox that worked"
    say "" "yesterday stops working today."
fi

# Everything above audits the machine the build runs ON. Under WSL that is
# not the machine that decides whether the build SURVIVES - the Windows
# host is, and nothing here used to look at it.
#
# 2026-09-16: a build died at 24% after 2h40m. No error, no banner, no OOM,
# swap untouched - the log simply stopped. Windows Update had restarted the
# host:
#     06:37  last build progress line
#     06:44  MoUsoCoreWorker.exe initiated a restart
#     06:47  Windows booted
# check-env had passed that machine clean at 03:54 with five advisories,
# none of which was this. Active hours were 10:00-03:00, so 03:00-10:00 was
# a window Windows was free to reboot in, and the build was started at
# 03:54 - inside it.
#
# Windows may restart for updates ONLY outside active hours. So the whole
# question is: does this build run into that window.
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then

    if ! command -v reg.exe >/dev/null 2>&1; then
        soft "cannot reach the Windows host (no reg.exe on PATH)"
        say "" "Under WSL the host decides whether a long build survives, and"
        say "" "this check could not ask it. Treat the host as unchecked."
    else
        WU='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

        # reg.exe prints e.g.  ActiveHoursStart  REG_DWORD  0xa
        regdw() {
            local raw
            raw=$(reg.exe query "$1" /v "$2" 2>/dev/null | tr -d '\r' |
                  awk -v k="$2" '$1==k {print $NF}')
            raw="${raw#0x}"
            [ -n "$raw" ] && printf '%d' "$((16#$raw))" 2>/dev/null
        }

        ah_s=$(regdw "$WU" ActiveHoursStart)
        ah_e=$(regdw "$WU" ActiveHoursEnd)

        # A host carrying NoAutoRebootWithLoggedOnUsers=1 will not restart
        # itself for updates while a user is signed in, which turns the
        # verdict below from fatal into conditional.
        #
        # It is NOT a complete answer and must not be reported as one: the
        # policy is scoped to "with logged on users". Sign out, or let the
        # session end, and a scheduled restart is free to happen again -
        # which is the normal state of an overnight build nobody is sitting
        # at. So it lowers the severity and keeps the warning.
        AUK='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        no_reboot=$(regdw "$AUK" NoAutoRebootWithLoggedOnUsers)

        if [ -z "$ah_s" ] || [ -z "$ah_e" ]; then
            soft "Windows Update active hours are not set"
            say "" "With no active hours, Windows may restart for updates at any"
            say "" "time. A multi-hour build is at its mercy. Set them, or pause"
            say "" "updates for the duration."
        else
            now_h=$(date +%-H)
            # Free window is [ActiveHoursEnd, ActiveHoursStart) and it wraps.
            if [ "$ah_e" -le "$ah_s" ]; then
                in_free=$([ "$now_h" -ge "$ah_e" ] && [ "$now_h" -lt "$ah_s" ] && echo 1 || echo 0)
            else
                in_free=$([ "$now_h" -ge "$ah_e" ] || [ "$now_h" -lt "$ah_s" ] && echo 1 || echo 0)
            fi
            until_free=$(( (ah_e - now_h + 24) % 24 ))

            say "winupdate" "active $(printf '%02d:00-%02d:00' "$ah_s" "$ah_e"), so Windows may restart $(printf '%02d:00-%02d:00' "$ah_e" "$ah_s")"

            if [ "$in_free" = 1 ] && [ "${no_reboot:-0}" != 1 ]; then
                bad "it is $(date +%H:%M) - INSIDE the window Windows may restart in"
                say "" "A build started now can be killed by a Windows Update reboot"
                say "" "with no warning and no error in any log. This is exactly how"
                say "" "a 24%-complete build was lost on 2026-09-16."
                say "" "Pause updates (Settings > Windows Update > Pause), or set"
                say "" "NoAutoRebootWithLoggedOnUsers=1 under"
                say "" "  HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU"
            elif [ "$in_free" = 1 ]; then
                soft "it is $(date +%H:%M) - inside the restart window, but held off"
                say "" "NoAutoRebootWithLoggedOnUsers=1, so Windows will not restart"
                say "" "on its own WHILE YOU STAY SIGNED IN. That is the whole extent"
                say "" "of the protection - sign out or let the session end and a"
                say "" "scheduled restart can still take the build. For a run nobody"
                say "" "will be sitting at, pause updates as well."
            elif [ "$until_free" -le 6 ]; then
                soft "${until_free}h until Windows may restart ($(printf '%02d:00' "$ah_e"))"
                say "" "An AOSP build takes longer than that. It will still be"
                say "" "running when the window opens. Pause updates first."
            else
                ok "${until_free}h of protected time before the restart window opens"
            fi
        fi

        # A reboot already queued will be taken at the first opportunity,
        # which for a long build means during it.
        if reg.exe query \
           'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' \
           >/dev/null 2>&1; then
            bad "the Windows host has a reboot PENDING"
            say "" "It will be taken as soon as active hours allow, and that will"
            say "" "be during this build. Reboot the host first, deliberately."
        else
            ok "no reboot pending on the Windows host"
        fi

        # Sleep ends WSL too, and the idle timeout is separate from the
        # lid and power-button actions. 0 means never.
        if command -v powercfg.exe >/dev/null 2>&1; then
            ac_idle=$(powercfg.exe /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>/dev/null |
                      tr -d '\r' | awk '/Current AC Power Setting Index/{print $NF}')
            case "$ac_idle" in
                0x00000000|"") ok "Windows sleep-on-idle (AC) is Never" ;;
                *) mins=$(( $((16#${ac_idle#0x})) / 60 ))
                   bad "Windows sleeps after ${mins} min idle on AC"
                   say "" "WSL is shut down with the host and soong_ui dies with"
                   say "" "'Got signal: terminated'. Set it to Never for the build." ;;
            esac
        fi
    fi
fi

echo
echo "=== out/ ==="

# "Tried to lock out/.lock, but timed out" means another soong is running,
# or one died holding it. Either way the build will not start, and the
# message does not say which.
if [ -f "$TREE/out/.lock" ]; then
    holder=$(fuser "$TREE/out/.lock" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$holder" ]; then
        bad "out/.lock is held by pid $holder - another build is running"
        say "" "$(ps -o args= -p "$holder" 2>/dev/null | head -1 | cut -c1-70)"
    else
        ok "out/.lock present, not held"
    fi
else
    ok "no stale out/.lock"
fi

# ccache living outside the paths Soong's sandbox can write to is silent:
# every compile misses, the cache never fills, and nothing says why. Only
# relevant while nsjail is in play.
if [ -n "${CCACHE_DIR:-}" ]; then
    case "$(readlink -f "${CCACHE_DIR}")" in
        "$(readlink -f "$TREE")"/*|/tmp/*) ok "CCACHE_DIR is inside a writable mount" ;;
        *) soft "CCACHE_DIR=$CCACHE_DIR is outside the tree and /tmp"
           say "" "Soong's nsjail sandbox mounts / read-only and only makes the"
           say "" "tree and /tmp writable. A cache outside those misses every"
           say "" "time and never fills, silently." ;;
    esac
fi

echo
echo "=== local modifications ==="

# A patched build system is invisible and changes everything. On one
# machine build/soong carried "Enabled: false" against nsjail's sandbox
# for weeks - a deliberate local fix, recorded nowhere, that made that
# tree behave unlike every other checkout. Anyone comparing results
# against it is comparing against something else.
for proj in build/soong build/make build/blueprint; do
    d="$TREE/$proj"
    [ -d "$d/.git" ] || continue
    n=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        soft "$proj has $n uncommitted change(s)"
        (cd "$d" && git status --porcelain 2>/dev/null | head -5 | sed 's/^/            /')
        say "" "The build system itself is modified. Results from this tree"
        say "" "will not match a clean checkout. Record why, or revert it."
    else
        ok "$proj clean"
    fi
done

# A backup file left beside the thing it backs up is read as source. It
# has happened twice here: a .orig inside res/values made aapt2 fail with
# "invalid file path", and a saved .rc in /system/etc/init was parsed as
# an init script. Keep backups outside the tree.
strays=$(find "$TREE/vendor" "$TREE/device" -maxdepth 6             \( -name "*.orig" -o -name "*.orig-*" -o -name "*.bak"                -o -name "*~" -o -name "*.save" \) 2>/dev/null | head -10)
if [ -n "$strays" ]; then
    soft "backup files inside the source tree"
    echo "$strays" | sed "s|$TREE/||" | sed 's/^/            /'
    say "" "aapt2 and init read whatever is in the directory. Move these"
    say "" "somewhere outside the tree."
else
    ok "no stray backup files under vendor/ or device/"
fi

echo
echo "=== power ==="

# Suspending sends SIGTERM to soong_ui. The log says "Got signal:
# terminated" and nothing else. Five hours passed once before anyone
# noticed the build had died at 00:58.
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    soft "running under WSL - the Windows host's sleep ends the build"
    say "" "WSL is shut down when Windows suspends, which kills soong_ui with"
    say "" "'Got signal: terminated' and nothing else. Closing the lid is"
    say "" "enough. Set Windows sleep to never for the duration."
elif command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled sleep.target 2>/dev/null | grep -q masked; then
        ok "sleep.target is masked - this machine will not suspend"
    else
        soft "this machine can suspend"
        say "" "Suspending kills the build with 'Got signal: terminated' and"
        say "" "no further explanation. Disable sleep for the duration."
    fi
else
    soft "cannot tell whether this machine will suspend"
fi

echo
if [ "$fail" -gt 0 ]; then
    echo "$fail blocking, $warn advisory. Fix the blocking ones."
    exit 1
fi
echo "no blocking problems. $warn advisory."
exit 0
