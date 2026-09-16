#!/usr/bin/env bash
# flash-preflight.sh - decide whether an image can boot BEFORE you flash it.
#
#   tools/flash-preflight.sh --img out/.../system.img \
#                            --reference ~/lynx/stockimg/system.img \
#                            --vendor ~/lynx/stockimg/vendor.img \
#                            --vbmeta ~/lynx/stockimg/vbmeta.img
#
# Why this exists
# ---------------
# Flashing a system image to a phone and watching it fail costs about twenty
# minutes: flash, reboot, wait, fail, read the bootloader log, recover. Doing
# that eleven times in one night teaches you almost nothing, because a failed
# boot reports a number, not a reason.
#
# Every check here reads a file instead. If a check can be answered from the
# image, the vendor image or the device's own state, it is answered here and
# the flash is either allowed or stopped with a reason.
#
# What this is NOT
# ----------------
# It is not proof that an image boots. It is proof that a known class of
# failure is absent. The distinction matters: an earlier version of these
# checks passed cleanly on an image that was already known not to boot,
# because it tested for the presence of files rather than for anything that
# decides a boot. Each check below therefore states what it proves and what
# it does not, and checks that cannot distinguish a good image from a bad one
# are marked advisory rather than blocking.
#
# detect -> log -> fix
# --------------------
# Everything found is printed and written to a log. Problems that have a safe,
# reversible remedy are fixed automatically (--no-fix to disable); problems
# that would destroy data are reported with the exact command and left alone.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMG=""
REFERENCE=""        # a system image known to boot on this device
VENDOR=""           # the factory vendor.img - what the GSI must be compatible with
VBMETA=""
TREE="${TREE:-$HOME/android}"
SERIAL="${SERIAL:-}"
FIX=1
LOG=""
SCOPE="all"         # all | image | device

BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; OFF=""
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[1;31m'
    YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; OFF=$'\033[0m'
fi

usage() {
    sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    cat <<'USAGE'

Options
  --img FILE           system image to check (required)
  --reference FILE     a system image KNOWN to boot on this device. Every
                       structural check is far stronger as a comparison
                       against something that works than as an absolute
  --vendor FILE        the device's factory vendor.img. Needed for the
                       compatibility checks - sepolicy version and VINTF -
                       which are the ones that decide whether a GSI boots
                       on THIS device rather than in general
  --vbmeta FILE        vbmeta that will be flashed
  --tree DIR           AOSP tree, for building/finding checkvintf
  --serial S           adb/fastboot serial
  --image-only         skip the device checks
  --device-only        skip the image checks
  --no-fix             report problems, change nothing
  --log FILE           default: ./flash-preflight-<timestamp>.log
  -h, --help

Exit codes
  0  no blocking problems
  1  at least one blocking problem
  2  could not run (bad arguments, missing tools)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --img) IMG="$2"; shift ;;
        --reference) REFERENCE="$2"; shift ;;
        --vendor) VENDOR="$2"; shift ;;
        --vbmeta) VBMETA="$2"; shift ;;
        --tree) TREE="$2"; shift ;;
        --serial) SERIAL="$2"; shift ;;
        --image-only) SCOPE=image ;;
        --device-only) SCOPE=device ;;
        --no-fix) FIX=0 ;;
        --log) LOG="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

LOG="${LOG:-$PWD/flash-preflight-$(date +%Y%m%d-%H%M%S).log}"
: > "$LOG" || { echo "cannot write $LOG" >&2; exit 2; }

FAILS=0; WARNS=0; FIXED=0; IMAGE_UNVERIFIED=0

# Every line goes to the terminal and to the log. A preflight whose output
# scrolls away is a preflight nobody can quote back at you afterwards.
say()  { printf '%s\n' "$*" | tee -a "$LOG" >/dev/null; printf '%s\n' "$*"; }
head_() { say ""; say "${BOLD}== $* ==${OFF}"; }
ok()   { say "  ${GRN}ok  ${OFF} $*"; }
info() { say "  ${DIM}info${OFF} $*"; }
warn() { say "  ${YEL}WARN${OFF} $*"; WARNS=$((WARNS+1)); }
bad()  { say "  ${RED}FAIL${OFF} $*"; FAILS=$((FAILS+1)); }
fixed(){ say "  ${GRN}FIXED${OFF} $*"; FIXED=$((FIXED+1)); }
# What a check does and does not establish. Stated per section, because a
# check whose limits are not written down gets trusted beyond them.
proves() { say "  ${DIM}proves: $*${OFF}"; }

[ -n "$IMG" ] || { echo "--img is required" >&2; exit 2; }
[ -f "$IMG" ] || { echo "--img $IMG does not exist" >&2; exit 2; }

say "${BOLD}flash-preflight${OFF}  $(date '+%Y-%m-%d %H:%M:%S')"
say "  image    : $IMG ($(du -h "$IMG" 2>/dev/null | cut -f1))"
[ -n "$REFERENCE" ] && say "  reference: $REFERENCE"
[ -n "$VENDOR" ]    && say "  vendor   : $VENDOR"
[ -n "$VBMETA" ]    && say "  vbmeta   : $VBMETA"
say "  log      : $LOG"
say "  fixing   : $([ "$FIX" = 1 ] && echo enabled || echo disabled)"

# ---------------------------------------------------------------- image I/O
#
# debugfs reads an ext4 image without mounting it, which means no root, no
# loop device, and no chance of modifying the thing being inspected.
HAVE_DEBUGFS=0
command -v debugfs >/dev/null 2>&1 && HAVE_DEBUGFS=1

CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

img_has() { debugfs -R "stat $2" "$1" 2>/dev/null | grep -q "Inode:"; }

img_size() {
    debugfs -R "stat $2" "$1" 2>/dev/null |
        sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1
}

img_ls() {
    debugfs -R "ls -l $2" "$1" 2>/dev/null | awk '{print $NF}' |
        grep -vE '^(\.|\.\.)$' | grep -v '^$' | sort -u
}

# Extract once, reuse. The dependency walk below asks for the same library
# many times and each debugfs call is a process.
img_get() {
    local image="$1" path="$2"
    local key; key=$(printf '%s' "$image$path" | md5sum | cut -d' ' -f1)
    local dest="$CACHE/$key"
    [ -f "$dest" ] && { printf '%s' "$dest"; return 0; }
    debugfs -R "dump $path $dest" "$image" >/dev/null 2>&1
    [ -s "$dest" ] || return 1
    printf '%s' "$dest"
}

run_image_checks() {
    [ "$SCOPE" = device ] && return 0

    if [ "$HAVE_DEBUGFS" != 1 ]; then
        head_ "image checks"
        # "Could not check" must never read as "checked and fine". The first
        # version of this returned success here, and flash.sh duly wrote a
        # deliberately corrupt 100KB file to a phone: every image check had
        # been skipped for want of debugfs and the summary still said zero
        # blocking problems. Unverifiable is a blocking state.
        bad "debugfs not installed, so NONE of the image checks could run.
        This is reported as BLOCKING rather than clean - an unchecked
        image is not a checked one. Install it on this machine:
            sudo apt install e2fsprogs
        or run the image checks on the build machine and this half with
        --device-only."
        IMAGE_UNVERIFIED=1
        return 0
    fi

    # ------------------------------------------------------- 1. identity
    head_ "1. image identity"
    proves "the image is built from a released config for the right architecture.
          Does NOT prove it is compatible with any particular device."
    local bp
    if bp=$(img_get "$IMG" /system/build.prop); then
        local cn ps ll pn bt
        cn=$(grep -m1 '^ro.build.version.codename=' "$bp" | cut -d= -f2)
        ps=$(grep -m1 '^ro.build.version.preview_sdk=' "$bp" | cut -d= -f2)
        ll=$(grep -m1 '^ro.llndk.api_level=' "$bp" | cut -d= -f2)
        pn=$(grep -m1 '^ro.product.system.name=' "$bp" | cut -d= -f2)
        bt=$(grep -m1 '^ro.build.type=' "$bp" | cut -d= -f2)
        info "product=$pn type=$bt llndk=$ll"
        # A staging build boots under emulation and bootloops on retail
        # hardware. The visible difference is these two properties, and it
        # cost twenty-eight hours to find that out the first time.
        if [ "$cn" = REL ] && [ "$ps" = 0 ]; then
            ok "released config (codename=$cn preview_sdk=$ps)"
        else
            bad "STAGING build: codename=$cn preview_sdk=$ps
        Rebuild with a released config (-bp4a-), not -trunk_staging-."
        fi
    else
        bad "cannot read /system/build.prop - is this an ext4 system image?"
    fi

    # -------------------------------------------------- 2. can init run?
    head_ "2. can init actually load?"
    proves "init's ENTIRE shared-library graph resolves inside this image.
          A missing library here makes init exit 127 before any logging
          exists, which the kernel reports only as
          'Attempted to kill init! exitcode=0x00007f00'.
          Does NOT prove init will succeed - only that it can start."

    if ! command -v readelf >/dev/null 2>&1; then
        warn "readelf not installed (binutils) - skipping the dependency walk,
        which is the single most valuable check in this file."
    elif ! img_has "$IMG" /system/bin/init; then
        bad "/system/bin/init is not in the image"
    else
        local initbin interp
        initbin=$(img_get "$IMG" /system/bin/init)
        interp=$(readelf -lW "$initbin" 2>/dev/null |
                 grep -o 'interpreter: [^]]*' | head -1 | cut -d' ' -f2)
        if [ -n "$interp" ]; then
            if img_has "$IMG" "$interp"; then
                ok "interpreter present: $interp"
            else
                bad "init's interpreter $interp is missing - nothing can start it"
            fi
        fi

        # Walk the whole graph, not just init's direct dependencies.
        #
        # Checking only the first level is how this check passed on an image
        # that did not boot: every direct dependency was present, and a
        # library one level down could still have been absent. The loader
        # resolves the transitive closure before main() runs, so that is
        # what has to be checked.
        #
        # Search order matches the bootstrap linker: /system/lib64/bootstrap
        # first (it exists precisely because /apex is not mounted this
        # early), then /system/lib64.
        local -a queue=() seen=() missing=()
        local resolved=0
        while read -r l; do queue+=("$l"); done < <(
            readelf -dW "$initbin" 2>/dev/null |
            grep -o 'Shared library: \[[^]]*\]' | sed 's/.*\[\(.*\)\]/\1/')

        local i=0
        while [ "$i" -lt "${#queue[@]}" ]; do
            local lib="${queue[$i]}"; i=$((i+1))
            case " ${seen[*]-} " in *" $lib "*) continue ;; esac
            seen+=("$lib")

            local found=""
            for d in /system/lib64/bootstrap /system/lib64; do
                if img_has "$IMG" "$d/$lib"; then found="$d/$lib"; break; fi
            done
            if [ -z "$found" ]; then
                missing+=("$lib")
                continue
            fi
            resolved=$((resolved+1))

            local f
            if f=$(img_get "$IMG" "$found"); then
                while read -r n; do
                    [ -n "$n" ] && queue+=("$n")
                done < <(readelf -dW "$f" 2>/dev/null |
                         grep -o 'Shared library: \[[^]]*\]' |
                         sed 's/.*\[\(.*\)\]/\1/')
            fi
        done

        if [ "${#missing[@]}" -eq 0 ]; then
            ok "init's full dependency graph resolves: $resolved libraries, ${#seen[@]} names"
        else
            bad "${#missing[@]} librar(y/ies) in init's dependency graph are NOT in
        the image. init cannot start, and the failure is silent:
        $(printf '%s ' "${missing[@]}")"
        fi
    fi

    # --------------------------------------------------- 3. GSI markers
    head_ "3. GSI markers"
    proves "the image carries the GSI-specific init files. ADVISORY ONLY:
          these arrive via generic_system.mk, so an image can have every
          one of them and still not boot. An earlier version of this
          check reported such an image as clean."
    local m
    for m in /system/system_ext/etc/init/config/skip_mount.cfg \
             /system/system_ext/etc/init/init.gsi.rc \
             /system/system_ext/etc/gsi/init.vndk-nodef.rc; do
        if img_has "$IMG" "$m"; then info "present $(basename "$m")"
        else warn "missing $m - the image may not be a GSI"; fi
    done

    # ------------------------------- 3b. privileged app permission allowlist
    head_ "3b. privileged app permissions"
    proves "every signature|privileged permission requested by an app in
          /system/priv-app is allowlisted. A single missing entry is FATAL:
          PackageManagerService.systemReady() throws IllegalStateException,
          system_server dies, and the device boot-loops on the boot
          animation with no other symptom. Needs aapt2 to read the APKs."
    #
    # This is what a real failure looked like, after everything else in
    # this file already passed:
    #
    #   FATAL EXCEPTION IN SYSTEM PROCESS: main
    #   java.lang.IllegalStateException: Signature|privileged permissions
    #   not in privileged permission allowlist: {com.google.android.gms
    #   (/system/priv-app/GmsCore): android.permission.MANAGE_USB, ...}
    #       at AppIdPermissionPolicy.onSystemReady
    #       at PackageManagerService.systemReady
    #
    # The device booted, reached 204 services, then died. Adding an app to
    # priv-app without updating an allowlist is all it takes.
    pf_aapt=""
    for c in "$TREE/out/host/linux-x86/bin/aapt2" "$(command -v aapt2 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { pf_aapt="$c"; break; }
    done
    if [ -z "$pf_aapt" ]; then
        warn "aapt2 not found, so priv-app permissions were NOT checked. This
        is the check that catches a boot-loop which every other check
        here passes. Build it:  m aapt2"
    else
        # Collect the allowlist from every permissions XML in the image.
        pf_alw="$CACHE/allow.txt"; : > "$pf_alw"
        for x in $(img_ls "$IMG" /system/etc/permissions); do
            case "$x" in *.xml) ;; *) continue ;; esac
            f=$(img_get "$IMG" "/system/etc/permissions/$x") || continue
            python3 - "$f" >> "$pf_alw" 2>/dev/null <<'PYX'
import sys, xml.etree.ElementTree as E
try:
    r = E.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for pa in r.iter("privapp-permissions"):
    pkg = pa.get("package") or ""
    for perm in list(pa):
        n = perm.get("name")
        if n:
            print("%s %s" % (pkg, n))
PYX
        done
        info "allowlist entries found: $(wc -l < "$pf_alw")"

        pf_missing=0
        pf_scanned=0
        for d in $(img_ls "$IMG" /system/priv-app); do
            apk=""
            for cand in $(img_ls "$IMG" "/system/priv-app/$d"); do
                case "$cand" in *.apk) apk="/system/priv-app/$d/$cand"; break ;; esac
            done
            [ -n "$apk" ] || continue
            af=$(img_get "$IMG" "$apk") || continue
            pkgname=$("$pf_aapt" dump packagename "$af" 2>/dev/null | tr -d '\r')
            [ -n "$pkgname" ] || continue
            pf_scanned=$((pf_scanned+1))
            for perm in $("$pf_aapt" dump permissions "$af" 2>/dev/null |
                          grep "^uses-permission: name=" | cut -d"'" -f2); do
                grep -qx "$pkgname $perm" "$pf_alw" && continue
                # Exact names, no leading wildcard. '*INSTALL_PACKAGES'
                # also matches REQUEST_INSTALL_PACKAGES, which is how a
                # permission removed from this list kept being reported.
                #
                # REQUEST_INSTALL_PACKAGES is deliberately absent: it is
                # signature|appop per the platform manifest, not privileged,
                # so it needs no allowlist entry. Including it produced a
                # false positive here. Permissions declared behind an
                # android:featureFlag are likewise not blocking - they do
                # not exist at runtime unless the flag is on, which is why
                # stock does not allowlist com.android.shell for
                # INJECT_KEY_EVENTS and still boots.
                #
                # This list is hardcoded because only the image is
                # available here. tools/check-product.sh does this properly
                # by reading protection levels out of
                # frameworks/base/core/res/AndroidManifest.xml - prefer it
                # when you have the tree.
                #
                # Only permissions that are actually signature|privileged are
                # fatal. This list is the platform's privileged set as seen in
                # the exception that caused a boot loop here, plus the obvious
                # neighbours. Keep it on ONE line: an earlier version split the
                # pattern across lines with backslash continuations, the case
                # never matched, and preflight reported a known-bad image as
                # clean - a false negative, which is worse than no check.
                case "$perm" in
                    android.permission.WRITE_SECURE_SETTINGS|android.permission.INSTALL_PACKAGES|android.permission.PACKAGE_USAGE_STATS|android.permission.MANAGE_USB|android.permission.UPDATE_DEVICE_STATS|android.permission.UPDATE_APP_OPS_STATS|android.permission.MODIFY_PHONE_STATE|android.permission.LOCATION_HARDWARE|android.permission.NETWORK_SCAN|android.permission.WATCH_APPOPS|android.permission.INSTALL_LOCATION_PROVIDER|android.permission.CHANGE_DEVICE_IDLE_TEMP_WHITELIST|android.permission.START_ACTIVITIES_FROM_BACKGROUND|android.permission.MANAGE_USERS|android.permission.INTERACT_ACROSS_USERS|android.permission.FAKE_PACKAGE_SIGNATURE)
                        bad "$pkgname requests $perm but it is NOT allowlisted.
        system_server throws at systemReady() and the device boot-loops.
        Add it to a privapp-permissions XML under /system/etc/permissions."
                        pf_missing=$((pf_missing+1)) ;;
                esac
            done
        done
        info "priv-app APKs scanned: $pf_scanned"
        [ "$pf_missing" = 0 ] &&
            ok "no known-fatal privileged permission is missing from the allowlist"
    fi

    # ------------------------------------------------------- 4. SELinux
    head_ "4. SELinux policy"
    proves "the image can compile policy at runtime, which a GSI ALWAYS has
          to do: the vendor's precompiled policy is keyed to the stock
          system's hash and can never match ours."
    if img_has "$IMG" /system/bin/secilc; then
        ok "secilc present (the policy compiler init needs)"
    else
        bad "/system/bin/secilc missing. A GSI must recompile policy at boot
        because the vendor's precompiled policy will not match it. Without
        secilc that is impossible and init dies."
    fi
    img_has "$IMG" /system/etc/selinux/plat_sepolicy.cil &&
        ok "plat_sepolicy.cil present" ||
        bad "/system/etc/selinux/plat_sepolicy.cil missing"

    local maps
    maps=$(img_ls "$IMG" /system/etc/selinux/mapping | tr '\n' ' ')
    info "mapping files: ${maps:-none}"

    # The specific, documented failure: if the mapping file for the
    # VENDOR's sepolicy version is absent, secilc cannot open it, exits
    # 255, and the device reboots to the bootloader.
    if [ -n "$VENDOR" ] && [ -f "$VENDOR" ]; then
        local vver=""
        local vp
        if vp=$(img_get "$VENDOR" /vendor/etc/selinux/plat_sepolicy_vers.txt); then
            vver=$(tr -d ' \r\n' < "$vp")
        fi
        if [ -n "$vver" ]; then
            if img_has "$IMG" "/system/etc/selinux/mapping/${vver}.cil"; then
                ok "vendor wants sepolicy version $vver and mapping/${vver}.cil is present"
            else
                bad "vendor requires sepolicy version $vver but
        /system/etc/selinux/mapping/${vver}.cil is NOT in the image.
        secilc will fail to open it, exit 255, and the device reboots
        to the bootloader."
            fi
        else
            warn "could not read the vendor's sepolicy version from
        /vendor/etc/selinux/plat_sepolicy_vers.txt - cannot check the
        mapping file, which is the check that matters here."
        fi
    else
        warn "no --vendor given, so the mapping-file check (the one that
        decides whether policy compiles on THIS device) did not run."
    fi

    # --------------------------------------------------------- 5. VINTF
    head_ "5. VINTF compatibility"
    proves "the framework's requirements and the vendor's declarations are
          compatible - the same check Android runs before accepting an OTA.
          This is the authoritative answer to 'can this system image run
          on this vendor image', and nothing else here replaces it."
    # Before reaching for checkvintf: is the manifest even well-formed?
    #
    # This is the check that was missing. A duplicated <vendor-ndk> version
    # in /system_ext/etc/vintf/manifest.xml makes libvintf reject the whole
    # file, so servicemanager runs with NO framework manifest at all:
    #
    #   servicemanager: VINTF parse error: Illformed file:
    #     /system_ext/etc/vintf/manifest.xml: Duplicated manifest.vendor-ndk.version 31
    #   servicemanager: NULL VINTF MANIFEST!: framework
    #
    # vold and keystore2 then cannot be found, keystore2 cannot reach
    # KeyMint, and Trusty - where KeyMint runs - exits its critical app and
    # panics the kernel about four minutes into boot. The image looks
    # perfect by every other measure. Preflight passed it twice.
    for mf in /system/etc/vintf/manifest.xml               /system/system_ext/etc/vintf/manifest.xml               /system/product/etc/vintf/manifest.xml; do
        img_has "$IMG" "$mf" || continue
        local mfile
        mfile=$(img_get "$IMG" "$mf") || continue

        # Well-formed XML at all?
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c "import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])" "$mfile" 2>/dev/null; then
                bad "$mf is not well-formed XML. libvintf will reject it and
        servicemanager will run with no manifest."
                continue
            fi
        fi

        # Duplicated vendor-ndk versions - the exact failure above.
        local dups
        dups=$(grep -o '<version>[0-9]*</version>' "$mfile" 2>/dev/null |
               sort | uniq -d | tr '
' ' ')
        if [ -n "$dups" ]; then
            bad "$mf declares DUPLICATE versions: $dups
        libvintf rejects the whole file on a duplicate, servicemanager
        gets a NULL framework manifest, and vold/keystore2 never start.
        Usually caused by two products both contributing
        PRODUCT_EXTRA_VNDK_VERSIONS - set it explicitly once."
        else
            pf_n=$(grep -c '<vendor-ndk>' "$mfile" 2>/dev/null || echo 0)
            ok "$(basename "$(dirname "$(dirname "$mf")")")/vintf manifest well-formed, ${pf_n} vendor-ndk entries, no duplicates"
        fi
    done

    local CV=""
    for c in "$TREE/out/host/linux-x86/bin/checkvintf" "$(command -v checkvintf 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { CV="$c"; break; }
    done
    if [ -z "$CV" ]; then
        warn "checkvintf not built. It is the only authoritative compatibility
        check available and it is missing, so this preflight CANNOT say
        whether the image is compatible with the vendor. Build it:
            cd $TREE && source build/envsetup.sh && lunch <target> && m checkvintf"
    elif [ -z "$VENDOR" ] || [ ! -f "$VENDOR" ]; then
        warn "checkvintf found but no --vendor image given, so there is nothing
        to check compatibility against."
    else
        # checkvintf reads real directories, so both images have to be
        # unpacked far enough to expose their VINTF metadata. Invocation
        # follows build/make/tools/releasetools/check_target_files_vintf.py:
        # --check-compat with a --dirmap per partition, exit 0 = compatible.
        local sysd="$CACHE/sys" vend="$CACHE/ven"
        mkdir -p "$sysd" "$vend"
        debugfs -R "rdump /system/etc/vintf $sysd" "$IMG"    >/dev/null 2>&1
        debugfs -R "rdump /system/etc/vintf $sysd" "$IMG"    >/dev/null 2>&1
        debugfs -R "rdump /vendor/etc/vintf $vend" "$VENDOR" >/dev/null 2>&1
        if [ -d "$sysd/vintf" ] && [ -d "$vend/vintf" ]; then
            mkdir -p "$sysd/etc" "$vend/etc"
            mv "$sysd/vintf" "$sysd/etc/vintf" 2>/dev/null
            mv "$vend/vintf" "$vend/etc/vintf" 2>/dev/null
            local out rc
            out=$("$CV" --check-compat --dirmap "/system:$sysd" --dirmap "/vendor:$vend" 2>&1)
            rc=$?
            if [ "$rc" = 0 ]; then
                ok "checkvintf: compatible"
            elif printf '%s' "$out" | tail -1 | grep -q INCOMPATIBLE; then
                bad "checkvintf: INCOMPATIBLE with this vendor image.
        $(printf '%s' "$out" | tail -5)"
            else
                warn "checkvintf could not complete (exit $rc). Treat compatibility
        as UNKNOWN, not as passing:
        $(printf '%s' "$out" | tail -5)"
            fi
        else
            warn "could not extract VINTF metadata from one of the images"
        fi
    fi

    # ---------------------------------------------- 6. reference compare
    head_ "6. comparison against a known-good image"
    proves "which boot-critical files this image lacks RELATIVE to an image
          proven to boot on this device. Far stronger than any absolute
          check, because it needs no opinion about what 'should' be there."
    if [ -z "$REFERENCE" ] || [ ! -f "$REFERENCE" ]; then
        warn "no --reference image given. Absolute checks cannot tell a working
        image from a broken one - a reference can. Use the stock system.img
        from the device's factory image."
    else
        local d n ours theirs missing_count
        for d in /system/bin /system/lib64 /system/etc/init /system/etc/selinux; do
            n=$(echo "$d" | tr '/' '_')
            img_ls "$IMG" "$d"       > "$CACHE/a$n"
            img_ls "$REFERENCE" "$d" > "$CACHE/b$n"
            ours=$(wc -l < "$CACHE/a$n"); theirs=$(wc -l < "$CACHE/b$n")
            missing_count=$(comm -13 "$CACHE/a$n" "$CACHE/b$n" | wc -l)
            if [ "$missing_count" -eq 0 ]; then
                ok "$d: $ours entries, nothing the reference has is absent"
            else
                info "$d: ours=$ours reference=$theirs, $missing_count present only in reference"
                comm -13 "$CACHE/a$n" "$CACHE/b$n" | head -12 |
                    while read -r x; do say "        $x"; done
            fi
        done
    fi

    # -------------------------------------------------------- 7. vbmeta
    head_ "7. vbmeta"
    proves "the vbmeta to be flashed is a valid AVB image, and reports which
          verity behaviour to expect. It does NOT prove the device will
          honour it. Read the note below before trusting any vbmeta advice,
          including this script's."
    #
    # Two behaviours, both taken from init's own kernel log on the SAME
    # Pixel 7a. They contradict the usual guidance, so neither is asserted
    # here as correct.
    #
    #   MINIMAL vbmeta (4096 bytes, 624 bytes of descriptors, flags=2):
    #     init: [libfs_avb] Returning avb_handle with status: VerificationDisabled
    #     init: [libfs_avb] AVB HASHTREE disabled on: /system
    #     -> /system mounted and the boot continued.
    #
    #   FACTORY vbmeta flashed with --disable-verity --disable-verification:
    #     init: [libfs_avb] Returning avb_handle with status: Success
    #     init: [libfs_avb] Built verity table: ...
    #     init: DM_TABLE_LOAD failed: name=system-verity ...: Argument list too long
    #     init: Failed to mount /system: No such file or directory
    #     -> kernel panic, "Attempted to kill init!"
    #
    # The difference is WHERE the disable bit lives. flags=2 is
    # VERIFICATION_DISABLED set inside the file; the factory vbmeta has
    # flags=0 and depends on fastboot applying --disable-verification at
    # flash time, which this device did not honour. Set the bits in the
    # file and nothing has to be trusted at flash time. A blank vbmeta has its own failure mode - if the slot's
    # boot chain is incomplete the bootloader has nothing to load and never
    # attempts a boot at all (620ms to fastboot, every slot still reported
    # "boot ok"). Both are real; the only authority is the AVB status line
    # in the kernel log of the boot you are actually debugging.
    if [ -z "$VBMETA" ]; then
        warn "no --vbmeta given. A self-built system needs verity off; how to
        achieve that is device-specific - see the note above this check."
    elif [ ! -f "$VBMETA" ]; then
        bad "--vbmeta $VBMETA does not exist"
    elif [ "$(head -c4 "$VBMETA")" != "AVB0" ]; then
        bad "$VBMETA is not an AVB image (no AVB0 magic)"
    else
        # AvbVBMetaImageHeader: descriptors_size is a big-endian u64 at
        # offset 104, flags a big-endian u32 at offset 120.
        local dsz flg
        dsz=$(od -An -tu4 -j108 -N4 --endian=big "$VBMETA" 2>/dev/null | tr -d ' ')
        flg=$(od -An -tu4 -j120 -N4 --endian=big "$VBMETA" 2>/dev/null | tr -d ' ')
        if [ "${dsz:-0}" -gt 0 ]; then
            ok "vbmeta carries $dsz bytes of descriptors (factory-style). Expect
        AVB to run. On a Pixel 7a this produced 'status: Success' and an
        ENFORCED verity table even when flashed with --disable-verity
        --disable-verification, which then failed to load and panicked
        init. Confirm in the kernel log; do not assume."
        else
            warn "vbmeta has no descriptors (blank). On this device that is what
        produced 'VerificationDisabled' and a successful /system mount.
        It fails differently if the slot's boot chain is incomplete: no
        boot is attempted at all. Reported, not judged."
        fi
        case "${flg:-0}" in
            0) warn "vbmeta flags=0 - the file itself does not disable verity.
        fastboot's --disable-verity --disable-verification are meant to
        set these at flash time; on a Pixel 7a they demonstrably did not
        take effect. If you rely on them, verify afterwards that AVB
        reports VerificationDisabled." ;;
            *) ok "vbmeta flags=$flg - the bits are set in the file itself, which
        does not depend on fastboot honouring a command-line flag" ;;
        esac
    fi
}

# =========================================================== device checks
run_device_checks() {
    [ "$SCOPE" = image ] && return 0
    head_ "8. device state"
    proves "the device is in a state where a flash can succeed and a failed
          boot will be observable. Says nothing about the image."

    # NOT local: declaring these local first wipes the values exported by
    # the caller, and the check then reports "adb not on PATH" on a machine
    # where adb was handed to it explicitly.
    ADB="${ADB:-$(command -v adb 2>/dev/null)}"
    FASTBOOT="${FASTBOOT:-$(command -v fastboot 2>/dev/null)}"
    if [ -z "$ADB" ] || [ -z "$FASTBOOT" ]; then
        warn "adb/fastboot not on PATH - device checks skipped. Under WSL the
        platform tools usually live on the Windows side; pass them as
        ADB=... FASTBOOT=... or run this half from Windows."
        return 0
    fi

    # Never block. fastboot waits forever for a device that is not in
    # fastboot mode, and a preflight that hangs looks like progress.
    fb() { timeout 15 "$FASTBOOT" ${SERIAL:+-s "$SERIAL"} "$@" 2>&1; }
    gv() { fb getvar "$1" | grep -o "$1: .*" | head -1 | cut -d' ' -f2-; }

    # "more than one device/emulator" makes adb fail in a way that reads as
    # NO device. A stray emulator is enough. Say which it is.
    local n
    n=$(timeout 10 "$ADB" devices 2>/dev/null | grep -cE "(device|unauthorized)$")
    if [ "${n:-0}" -gt 1 ] && [ -z "$SERIAL" ]; then
        bad "$n devices/emulators attached and no --serial given. Every check
        below would silently report nothing. Attached:
$(timeout 10 "$ADB" devices 2>/dev/null | sed -n '2,$p' | sed 's/^/          /')"
        return 0
    fi

    if ! fb devices | grep -q fastboot; then
        if timeout 10 "$ADB" ${SERIAL:+-s "$SERIAL"} get-state 2>/dev/null | grep -q device; then
            warn "the phone is booted in Android, not fastboot. The checks below
        need fastboot:  adb reboot bootloader"
        else
            warn "no device in fastboot - device checks skipped"
        fi
        return 0
    fi

    [ "$(gv unlocked)" = yes ] && ok "bootloader unlocked" ||
        bad "bootloader is locked - nothing can be flashed"

    local slot rc ub
    slot=$(gv current-slot); slot="${slot:-a}"
    rc=$(gv "slot-retry-count:$slot")
    ub=$(gv "slot-unbootable:$slot")
    info "slot=$slot retries=${rc:-?} unbootable=${ub:-?}"

    # Three failed boots and the bootloader gives up on the slot. Flashing
    # into that is a guaranteed non-event: the device returns to fastboot
    # without ever attempting a boot, which is indistinguishable from the
    # image failing. set_active restores the count and is harmless.
    if [ "${rc:-3}" = 0 ] || [ "$ub" = yes ]; then
        if [ "$FIX" = 1 ]; then
            fb set_active "$slot" >/dev/null 2>&1 &&
                fixed "slot $slot had no attempts left; set_active restored it to $(gv "slot-retry-count:$slot")" ||
                bad "slot $slot is out of boot attempts and set_active failed"
        else
            bad "slot $slot has no boot attempts left. Fix: fastboot set_active $slot"
        fi
    fi

    # A slot is only bootable if the OTHER partitions on it exist too.
    # After a factory restore the active slot can be the one that got the
    # 149 MB stub system and nothing else - no vendor, no product, no
    # system_ext. Flashing a perfectly good system image onto that slot
    # produces a boot that fails for a reason that has nothing to do with
    # the image, and it looks identical to the image being broken.
    for pt in vendor vendor_dlkm; do
        sz=$(gv "partition-size:${pt}_${slot}")
        case "$sz" in
            ""|0x0|0)
                bad "slot $slot has NO $pt (${pt}_${slot} is absent or zero).
        This slot cannot boot anything. Switch to the other slot:
            fastboot --set-active=$( [ "$slot" = a ] && echo b || echo a )
        or restore the factory image to this slot first." ;;
            *) ok "${pt}_${slot} present ($sz)" ;;
        esac
    done

    # oem ramdump is a bootloader setting that SURVIVES REBOOTS. With it on,
    # a device that fails to boot stops dropping into fastboot and instead
    # loops without ever enumerating on USB - no command can reach it and
    # the only way back is holding the power button. It cost two hardware
    # rescues before anyone connected the two.
    local rd
    rd=$(fb oem ramdump | grep -o "ramdump \(enabled\|disabled\)" | head -1)
    case "$rd" in
        *enabled)
            if [ "$FIX" = 1 ]; then
                fb oem ramdump disable >/dev/null 2>&1 &&
                    fixed "oem ramdump was ENABLED - disabled it. Left on, a failed
        boot loops forever without appearing on USB." ||
                    bad "oem ramdump is enabled and could not be disabled"
            else
                bad "oem ramdump is ENABLED. A failed boot will loop without ever
        appearing on USB. Fix: fastboot oem ramdump disable"
            fi ;;
        *disabled) ok "oem ramdump disabled" ;;
        *) info "oem ramdump state unknown (device may not support it)" ;;
    esac

    # A GSI carries its own /product and /system_ext inside system.img, so
    # the device's stock ones just sit in super. Deleting them is NOT done
    # automatically: it is irreversible without a factory flash, and on this
    # device it made no difference to booting - so it is reported, with the
    # command, and left to a human.
    local p sz
    for p in product system_ext; do
        sz=$(gv "partition-size:${p}_${slot}")
        case "$sz" in
            ""|0x0|0) ok "${p}_${slot} already absent" ;;
            *) warn "${p}_${slot} still holds stock content ($sz). A GSI brings its
        own. Not deleted automatically - it needs a factory flash to undo:
            fastboot delete-logical-partition ${p}_${slot}" ;;
        esac
    done

    local st="${LOG%.log}-devicestate.txt"
    if fb getvar all > "$st" 2>&1 && [ -s "$st" ]; then
        info "device state recorded: $st"
    else
        warn "could not record device state"
    fi
}

run_image_checks
run_device_checks

head_ "summary"
say "  $FAILS blocking, $WARNS advisory, $FIXED fixed"
say "  log: $LOG"
if [ "$FAILS" -gt 0 ]; then
    say ""
    say "  ${RED}Do not flash.${OFF} $FAILS problem(s) above will stop it booting."
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    say ""
    say "  No blocking problems - but $WARNS check(s) could not be completed or"
    say "  are advisory. A clean run here is NOT a promise that the image boots;"
    say "  it means the failures this script knows about are absent."
fi
exit 0
