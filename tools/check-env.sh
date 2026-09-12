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
