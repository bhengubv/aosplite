#!/usr/bin/env bash
# check-product.sh [tree] [product]
#
#   tools/check-product.sh ~/android circle_arm64
#
# Catches four faults that cost a full build, or a build-flash-boot cycle,
# to find any other way. Every one of them was found the hard way here.
# The first two are reported by the build as SUCCESS and by the device as
# a boot loop; the last two fail the build at the very end, after the
# compile time has already been spent.
#
#   1. Duplicated VNDK versions
#      Two products each contributing PRODUCT_EXTRA_VNDK_VERSIONS produces
#      a system_ext VINTF manifest with the same <version> twice. libvintf
#      rejects the WHOLE file on a duplicate, so servicemanager runs with
#      no framework manifest:
#          VINTF parse error: Illformed file: .../manifest.xml:
#            Duplicated manifest.vendor-ndk.version 31
#          NULL VINTF MANIFEST!: framework
#      vold and keystore2 then cannot be found, keystore2 cannot reach
#      KeyMint, and Trusty - where KeyMint runs - exits its critical app:
#          Kernel panic - not syncing: trusty crashed
#      Four minutes into boot, with a perfectly healthy-looking image.
#
#   2. A privileged app with no permission allowlist entry
#      Any package in /system/priv-app requesting a signature|privileged
#      permission that is not allowlisted makes system_server throw at
#      startup - not warn, throw:
#          java.lang.IllegalStateException: Signature|privileged
#          permissions not in privileged permission allowlist
#      The device boot-loops on the boot animation and nothing else is
#      wrong with it.
#
# Check 1 runs against the SOURCE, so it costs nothing and can run before
# a build. Check 2 needs the built APKs, so it runs against the staged
# tree at out/target/product/<device>/system - which exists as soon as the
# build finishes and long before anyone flashes anything.
#
# Exit 0 = clean. Exit 1 = something here will boot-loop the device.

set -uo pipefail

TREE="${1:-$HOME/android}"
PRODUCT="${2:-}"

BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; OFF=""
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[1;31m'
    GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; OFF=$'\033[0m'
fi
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
info() { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }
warn() { printf '  %sWARN%s %s\n' "$YEL" "$OFF" "$1"; WARNS=$((WARNS+1)); }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; FAILS=$((FAILS+1)); }

FAILS=0; WARNS=0
[ -d "$TREE" ] || { echo "no tree at $TREE" >&2; exit 2; }

printf '%scheck-product%s  tree=%s product=%s\n' "$BOLD" "$OFF" "$TREE" "${PRODUCT:-<any>}"

# ============================================== 1. VNDK version duplication
printf '\n%s== 1. VNDK versions ==%s\n' "$BOLD" "$OFF"
note "a duplicate makes libvintf reject the whole framework manifest"

mapfile -t vndk_srcs < <(
    grep -rln "PRODUCT_EXTRA_VNDK_VERSIONS" \
        "$TREE/build/make/target/product" \
        "$TREE/build/circle" "$TREE/vendor/circle" "$TREE/device/circle" \
        2>/dev/null | grep -vE '\.(bak|orig|rej|swp)($|\.)' | sort -u)

if [ "${#vndk_srcs[@]}" -eq 0 ]; then
    ok "nothing sets PRODUCT_EXTRA_VNDK_VERSIONS"
else
    for f in "${vndk_srcs[@]}"; do
        op=$(grep -m1 -oE "PRODUCT_EXTRA_VNDK_VERSIONS[[:space:]]*(\+=|:=|=)" "$f" |
             grep -oE '(\+=|:=|=)')
        info "$(basename "$f"): ${op:-?}"
    done
    # Appending after another product already set it is how the duplicate
    # arises. One := wins; a += on top of an inherited value concatenates.
    appends=0
    for f in "${vndk_srcs[@]}"; do
        grep -qE "PRODUCT_EXTRA_VNDK_VERSIONS[[:space:]]*\+=" "$f" && appends=$((appends+1))
    done
    if [ "${#vndk_srcs[@]}" -gt 1 ] && [ "$appends" -gt 0 ]; then
        bad "${#vndk_srcs[@]} files set PRODUCT_EXTRA_VNDK_VERSIONS and $appends of them
       append (+=). Inheriting two of them concatenates the lists and the
       system_ext VINTF manifest ends up with duplicate <version> entries,
       which libvintf rejects outright. Set it ONCE with := in the product."
    else
        ok "no appending contributor - duplication unlikely"
    fi
fi

# The definitive check: if a manifest has already been staged, read it.
for mf in "$TREE"/out/target/product/*/system/system_ext/etc/vintf/manifest.xml \
          "$TREE"/out/target/product/*/system/etc/vintf/manifest.xml; do
    [ -f "$mf" ] || continue
    dups=$(grep -o '<version>[0-9]*</version>' "$mf" 2>/dev/null | sort | uniq -d | tr '\n' ' ')
    if [ -n "$dups" ]; then
        bad "$mf has DUPLICATE versions: $dups
       libvintf will reject the file and servicemanager will have no
       framework manifest."
    else
        n=$(grep -c '<vendor-ndk>' "$mf" 2>/dev/null | head -1 | tr -d '[:space:]')
        n="${n:-0}"
        ok "$(echo "$mf" | sed "s#$TREE/##"): $n vendor-ndk entries, no duplicates"
    fi
done

# ==================================== 2. privileged app permission allowlist
printf '\n%s== 2. privileged app permissions ==%s\n' "$BOLD" "$OFF"
note "one missing entry makes system_server throw at boot, not warn"

STAGE=""
for d in "$TREE"/out/target/product/*/system; do
    [ -d "$d/priv-app" ] && { STAGE="$d"; break; }
done

if [ -z "$STAGE" ]; then
    warn "no staged system tree with priv-app under $TREE/out/target/product/.
       This check needs the built APKs. Run it after a build; it still
       runs long before anything is flashed."
else
    AAPT=""
    for c in "$TREE/out/host/linux-x86/bin/aapt2" "$(command -v aapt2 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { AAPT="$c"; break; }
    done
    if [ -z "$AAPT" ]; then
        warn "aapt2 not built, so the APKs cannot be read. Build it:  m aapt2"
    else
        ALLOW=$(mktemp)
        for x in "$STAGE"/etc/permissions/*.xml \
                 "$STAGE"/system_ext/etc/permissions/*.xml \
                 "$STAGE"/product/etc/permissions/*.xml; do
            [ -f "$x" ] || continue
            python3 - "$x" >> "$ALLOW" 2>/dev/null <<'PYX'
import sys, xml.etree.ElementTree as E
try:
    root = E.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for pa in root.iter("privapp-permissions"):
    pkg = pa.get("package") or ""
    for perm in list(pa):
        n = perm.get("name")
        if n:
            print("%s %s" % (pkg, n))
PYX
        done
        info "allowlist entries: $(wc -l < "$ALLOW")"

        # Which permissions are actually signature|privileged is not a
        # matter of opinion - the platform manifest says so. An earlier
        # version of this check hardcoded a list and flagged
        # REQUEST_INSTALL_PACKAGES, which is signature|appop and needs no
        # allowlist entry at all. Read the source of truth instead.
        PRIV=$(mktemp); trap 'rm -f "$ALLOW" "$PRIV"' EXIT
        PLATMAN="$TREE/frameworks/base/core/res/AndroidManifest.xml"
        if [ -f "$PLATMAN" ]; then
            python3 - "$PLATMAN" > "$PRIV" <<'PYP'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
# <permission ... android:name="X" ... android:protectionLevel="a|b" >
for m in re.finditer(r'[<]permission[^A-Za-z][^>]*?>', t, re.S):
    blk = m.group(0)
    n = re.search(r'android:name="([^"]+)"', blk)
    l = re.search(r'android:protectionLevel="([^"]+)"', blk)
    # A permission declared behind android:featureFlag does not exist at
    # runtime unless that flag is on, so it needs no allowlist entry.
    # Without this the check flags com.android.shell for
    # INJECT_KEY_EVENTS - which stock Android does not allowlist either,
    # and stock boots. Flagging it would be a false positive.
    if "android:featureFlag" in blk:
        continue
    if n and l and "privileged" in l.group(1):
        print(n.group(1))
PYP
            info "privileged permissions per the platform manifest: $(wc -l < "$PRIV")"
        else
            warn "platform manifest not found at $PLATMAN - falling back to a
       hardcoded list, which has been wrong before."
            printf '%s
'                 android.permission.WRITE_SECURE_SETTINGS                 android.permission.INSTALL_PACKAGES                 android.permission.PACKAGE_USAGE_STATS                 android.permission.MANAGE_USB                 android.permission.MODIFY_PHONE_STATE > "$PRIV"
        fi

        missing=0; scanned=0
        while IFS= read -r apk; do
            pkg=$("$AAPT" dump packagename "$apk" 2>/dev/null | tr -d '\r')
            [ -n "$pkg" ] || continue
            scanned=$((scanned+1))
            while IFS= read -r perm; do
                [ -n "$perm" ] || continue
                grep -qx "$pkg $perm" "$ALLOW" && continue
                grep -qx "$perm" "$PRIV" || continue
                bad "$pkg requests $perm and it is NOT allowlisted.
       That permission is signature|privileged per the platform manifest,
       so system_server throws at systemReady() and the device
       boot-loops. Add it to a privapp-permissions XML."
                missing=$((missing+1))
            done < <("$AAPT" dump permissions "$apk" 2>/dev/null |
                     grep "^uses-permission: name=" | cut -d"'" -f2)
        done < <(find "$STAGE/priv-app" -maxdepth 2 -name '*.apk' 2>/dev/null)

        info "priv-app APKs scanned: $scanned"
        [ "$missing" = 0 ] && ok "every privileged permission is allowlisted"
    fi
fi

# ==================================== 3. stray files in resource directories
printf '\n%s== 3. resource directories ==%s\n' "$BOLD" "$OFF"
note "aapt2 rejects any file in res/ that is not a resource"
#
# A single editor backup left in a res/ tree fails the build - and it fails
# at the very end, after seventeen minutes, with a message that names the
# file but not the cause:
#
#   error: invalid file path
#     'vendor/circle/overlay/systemui/res/values/circle_overlay_config.xml.bak.201138'
#
# Cheap to check, expensive to hit.
stray=$(find "$TREE/vendor" "$TREE/device" "$TREE/build" -path "*/res/*" -type f \
        \( -name "*.bak*" -o -name "*.orig" -o -name "*~" -o -name "*.rej" \
           -o -name "*.swp" -o -name "*.tmp" \) 2>/dev/null | head -20)
if [ -n "$stray" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        bad "$(echo "$f" | sed "s#$TREE/##") is inside a res/ directory.
       aapt2 rejects it and the build fails during packaging. Move it
       outside the resource tree."
    done <<< "$stray"
else
    ok "no editor backups or temp files inside any res/ directory"
fi

# ================================== 4. malformed XML in a resource directory
#
# aapt2 parses every file under res/ and refuses the whole module on the
# first malformed one:
#
#   themes_mode_secure.xml:0: error: xml parser error: mismatched tag.
#   error: file failed to compile.
#
# The line number is 0 and the message does not say which tag, so the file
# has to be read by eye. The one that cost a build here closed an <item>
# with </color>, and had been committed in that state for months - harmless
# only because the module it lives in was not in PRODUCT_PACKAGES, so aapt2
# had never been asked to compile it. Adding the module to the product is
# what surfaced it, sixteen minutes into a build.
#
# Checking is a parse of every resource XML in the tree and takes seconds.
malformed=$(find "$TREE/vendor" "$TREE/device" "$TREE/build" \
            -path "*/res/*" -name "*.xml" -type f 2>/dev/null |
    while IFS= read -r f; do
        python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$f" 2>/dev/null ||
            printf '%s\n' "$f"
    done)
nxml=$(find "$TREE/vendor" "$TREE/device" "$TREE/build" \
       -path "*/res/*" -name "*.xml" -type f 2>/dev/null | wc -l)
if [ -n "$malformed" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Report the parser's own reason - it names the line, unlike aapt2.
        why=$(python3 -c 'import sys,xml.dom.minidom as m
try:
    m.parse(sys.argv[1])
except Exception as e:
    print(e)' "$f" 2>/dev/null)
        bad "$(echo "$f" | sed "s#$TREE/##") is not well-formed XML.
       $why
       aapt2 fails the whole module on this, at the end of the build."
    done <<< "$malformed"
else
    ok "all $nxml resource XML files parse"
fi

printf '\n%s== summary ==%s\n' "$BOLD" "$OFF"
printf '  %d blocking, %d advisory\n' "$FAILS" "$WARNS"
if [ "$FAILS" -gt 0 ]; then
    printf '\n  %sDo not build an image from this tree until these are fixed.%s\n' "$RED" "$OFF"
    printf '  Each one either boot-loops the device while the build reports\n'
    printf '  success, or fails the build after the compile time is spent.\n'
    exit 1
fi
exit 0
