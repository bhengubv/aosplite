#!/usr/bin/env bash
# check-image.sh <your-system.img> [reference-system.img]
#
#   tools/check-image.sh out/target/product/generic_arm64/system.img \
#                        ~/gsi/system.img
#
# Compares a built system image against a reference GSI - one you know
# boots on the device you are targeting - and reports what yours is
# missing.
#
# Why this exists: a GSI that boots under QEMU against a vendor from the
# same build can still bootloop on a phone, and the phone tells you almost
# nothing. The kernel log that says why lives in RAM, survives a reboot,
# and is destroyed by the userspace fastboot you need in order to recover
# the phone. So you get one look per flash, and a flash costs a wipe.
#
# Everything checked below was found the expensive way - by flashing,
# failing, restoring the phone, and losing the log. Getting Google's GSI
# for the same Android release and diffing against it takes two minutes.
#
#   https://developer.android.com/topic/generic-system-image/releases
#
# Needs debugfs (e2fsprogs). Does not mount anything and does not need
# root - it reads the ext4 image directly.

set -eo pipefail

IMG="${1:?usage: check-image.sh <your-system.img> [reference.img]}"
REF="${2:-}"

command -v debugfs >/dev/null 2>&1 || {
    echo "debugfs not found - install e2fsprogs" >&2; exit 2; }
[ -f "$IMG" ] || { echo "no image at $IMG" >&2; exit 2; }

fail=0; warn=0
say()  { printf '  %-9s %s\n' "$1" "$2"; }
bad()  { say "FAIL" "$1"; fail=$((fail+1)); }
soft() { say "WARN" "$1"; warn=$((warn+1)); }
ok()   { say "ok" "$1"; }

# debugfs writes its banner to stderr; keep only the answer.
dbg() { debugfs -R "$2" "$1" 2>/dev/null; }

exists() { dbg "$1" "stat $2" | grep -q "Inode:"; }

typeof() {
    dbg "$1" "stat $2" | grep -oE "Type: [a-z]+" | head -1 | awk '{print $2}'
}

linkdest() {
    dbg "$1" "stat $2" | grep -oE 'Fast link dest: "[^"]*"' | head -1 |
        sed 's/.*"\(.*\)"/\1/'
}

prop() {
    local tmp; tmp=$(mktemp)
    dbg "$1" "dump /system/build.prop $tmp" >/dev/null 2>&1 || true
    [ -s "$tmp" ] || dbg "$1" "dump /build.prop $tmp" >/dev/null 2>&1 || true
    grep -m1 "^$2=" "$tmp" 2>/dev/null | cut -d= -f2-
    rm -f "$tmp"
}

echo "image     : $IMG ($(du -h "$IMG" | cut -f1))"
[ -n "$REF" ] && echo "reference : $REF"
echo

echo "=== release identity ==="
# A build made with an in-development release config stamps itself as
# pre-release. It boots on Cuttlefish and bootloops on a retail device, so
# nothing before this point catches it.
codename=$(prop "$IMG" ro.build.version.codename)
preview=$(prop "$IMG" ro.build.version.preview_sdk)
llndk=$(prop "$IMG" ro.llndk.api_level)
sdk=$(prop "$IMG" ro.build.version.sdk)

say "sdk" "${sdk:-?}"
say "codename" "${codename:-?}"
say "preview" "${preview:-?}"
say "llndk" "${llndk:-?}"

[ "$codename" = "REL" ] && ok "released build" || {
    bad "codename is '$codename', not REL - this is a pre-release image"
    say "" "Built with trunk_staging or another in-development release"
    say "" "config. A retail device refuses it. Rebuild with a released"
    say "" "config; no amount of patching the image fixes it, because every"
    say "" "library underneath is still a staging build."
}
[ "${preview:-0}" = "0" ] || bad "preview_sdk=$preview - still a preview image"

if [ -n "$REF" ] && [ -f "$REF" ]; then
    ref_llndk=$(prop "$REF" ro.llndk.api_level)
    ref_sdk=$(prop "$REF" ro.build.version.sdk)
    [ "$sdk" = "$ref_sdk" ] && ok "sdk matches reference ($sdk)" \
        || soft "sdk $sdk vs reference $ref_sdk"
    [ "$llndk" = "$ref_llndk" ] && ok "llndk matches reference ($llndk)" \
        || bad "llndk $llndk vs reference $ref_llndk - a release apart"
fi

echo
echo "=== mount points the device needs ==="
# A GSI ships these as symlinks into the vendor partition. Ours had none of
# them, and a missing mount point fails the same way a bad one does: init
# cannot mount, and the kernel panics with "Attempted to kill init".
# Getting this wrong in the other direction is just as fatal - creating
# them as directories rather than symlinks blocks the vendor mount.
for mp in persist firmware dsp; do
    if ! exists "$IMG" "/$mp"; then
        bad "/$mp missing"
        if [ -n "$REF" ] && [ -f "$REF" ] && exists "$REF" "/$mp"; then
            say "" "reference has it as a $(typeof "$REF" "/$mp") -> $(linkdest "$REF" "/$mp")"
        fi
    elif [ "$(typeof "$IMG" "/$mp")" != "symlink" ]; then
        bad "/$mp is a $(typeof "$IMG" "/$mp"), should be a symlink"
        say "" "A real directory here blocks the vendor mount."
    else
        ok "/$mp -> $(linkdest "$IMG" "/$mp")"
    fi
done

echo
echo "=== skip_mount ==="
# Without this, init tries to mount /system_ext separately, fails, and
# panics. It is reached through a symlink at /system/etc/init/config, so
# both halves have to be right - the file alone is unreachable.
cfg=/system/system_ext/etc/init/config/skip_mount.cfg
link=/system/etc/init/config
if exists "$IMG" "$cfg"; then
    ok "skip_mount.cfg present"
else
    bad "$cfg missing"
    say "" "init mounts /system_ext separately, fails, and the kernel"
    say "" "panics with 'Attempted to kill init'."
fi
if [ "$(typeof "$IMG" "$link")" = "symlink" ]; then
    ok "$link -> $(linkdest "$IMG" "$link")"
elif exists "$IMG" "$link"; then
    bad "$link exists but is a $(typeof "$IMG" "$link"), not a symlink"
    say "" "init reads this path. A directory here means skip_mount.cfg is"
    say "" "never found, however correct the file itself is."
else
    bad "$link missing - skip_mount.cfg is unreachable"
fi

echo
echo "=== compatibility matrices ==="
have=$(dbg "$IMG" "ls /system/etc/vintf" | tr -s ' ' '\n' | grep -c "compatibility_matrix" || true)
say "count" "$have in /system/etc/vintf"
if [ -n "$REF" ] && [ -f "$REF" ]; then
    for f in $(dbg "$REF" "ls /system/etc/vintf" | tr -s ' ' '\n' | grep "compatibility_matrix"); do
        exists "$IMG" "/system/etc/vintf/$f" || {
            bad "missing $f"
            say "" "The device checks its own FCM version against these. With"
            say "" "none old enough, it refuses the image."
        }
    done
fi

if [ -z "$REF" ]; then
    echo
    soft "no reference image given - only the checks above were possible"
    say "" "Get the GSI for your Android release and pass it as the second"
    say "" "argument. Everything below needs it:"
    say "" "  https://developer.android.com/topic/generic-system-image/releases"
    echo
    [ "$fail" -gt 0 ] && exit 1 || exit 0
fi

echo
echo "=== files the reference has and this image does not ==="
# Everything else is whatever the reference carries that we do not. The
# interesting ones are libraries and apexes; framework and app differences
# are content, not boot failures.
list_img() {
    python3 - "$1" <<'PY'
import subprocess, sys, collections
img = sys.argv[1]
def ls(p):
    out = subprocess.run(["debugfs", "-R", "ls -l %s" % p, img],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 9:
            continue
        name = " ".join(parts[8:])
        if name in (".", ".."):
            continue
        yield name, parts[1].startswith("4")
q = collections.deque(["/"])
while q:
    d = q.popleft()
    for name, isdir in ls(d):
        full = d.rstrip("/") + "/" + name
        print(full + ("/" if isdir else ""))
        if isdir:
            q.append(full)
PY
}

a=$(mktemp); b=$(mktemp)
trap 'rm -f "$a" "$b"' EXIT
list_img "$IMG" | sort > "$a"
list_img "$REF" | sort > "$b"
only_ref=$(comm -13 "$a" "$b")

n_total=$(echo "$only_ref" | grep -c . || true)
say "total" "$n_total entries in the reference but not here"

for area in "/system/lib64/:libraries (64-bit)" "/system/lib/:libraries (32-bit)" \
            "/system/apex/:apex modules" "/system/bin/:binaries" \
            "/system/etc/:config"; do
    path="${area%%:*}"; label="${area##*:}"
    hits=$(echo "$only_ref" | grep "^$path" || true)
    n=$(echo "$hits" | grep -c . || true)
    [ "$n" = "0" ] && continue
    bad "$n missing $label"
    echo "$hits" | head -8 | sed 's|^|            |'
    [ "$n" -gt 8 ] && say "" "... and $((n - 8)) more"
done

for area in "/system/framework/" "/system/priv-app/" "/system/app/" "/system/product/"; do
    n=$(echo "$only_ref" | grep -c "^$area" || true)
    [ "$n" = "0" ] || say "note" "$n fewer under $area - content, not a boot failure"
done

echo
if [ "$fail" -gt 0 ]; then
    echo "$fail blocking, $warn advisory."
    echo
    echo "The blocking ones stop the device booting, and the device will not"
    echo "tell you which. Its kernel log lives in RAM: it survives a reboot"
    echo "but not a power-off, and the userspace fastboot you need to restore"
    echo "the phone runs its own kernel and overwrites it. One look per flash."
    exit 1
fi
echo "no blocking differences. $warn advisory."
exit 0
