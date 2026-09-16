#!/usr/bin/env bash
# os.sh - sync, check, build and verify an Android system image.
#
#   tools/os.sh --lite                      pruned tree, default target
#   tools/os.sh --aosp                      full manifest, nothing pruned
#   tools/os.sh --lite --product circle_arm64 --release bp4a
#
# One command, five phases, and every failure this project has hit is
# either prevented before the build starts or recognised afterwards and
# fixed automatically.
#
#   doctor   the machine and the tree: memory, disk, tools, sleep,
#            manifests, a patched build system, a lunch target that will
#            produce an image no device accepts
#   sync     repo init and sync, skipped if the tree is already there
#   check    on a pruned tree, what the prune broke - paths and module
#            names that nothing in the tree provides any more
#   build    and if it fails: identify it against tools/failure-rules.txt,
#            restore the project it names, write a new rule if the failure
#            was not yet known, and rebuild. The loop closes itself.
#   verify   the built image against a reference GSI, before you flash it
#   flash    onto the device: fastbootd, system, blank vbmeta, wipe
#   boot     wait for sys.boot_completed and confirm the fingerprint is
#            CircleOS. Done means the OS is running, not that a file exists.
#
# The loop is the point. A pruned AOSP tree reports missing projects one
# per build, hours apart, because ALLOW_MISSING_DEPENDENCIES turns a
# missing dependency into a runtime "echo ... && false". Nine projects were
# found that way over two days, each costing a rebuild to discover.
#
# So the script does the whole cycle: identify, fix, learn, rebuild. The
# learning matters more than the fixing - a rule written into
# tools/failure-rules.txt is one nobody has to find again, on any machine.

set -eo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------- defaults
MODE=""                        # lite | aosp
TREE="$HOME/android"
BRANCH="android-16.0.0_r4"
PRODUCT=""
RELEASE="bp4a"
VARIANT="userdebug"
TARGET="systemimage"
REFERENCE=""                   # GSI to verify against
JOBS="$(nproc)"
MAX_RETRIES=8
AUTO_FIX=1                 # close the loop by default: fix, learn, rebuild
REPORT_EVERY=1200          # seconds between progress lines during a build
STATUS_DIR=""              # where to publish status; auto-detected on WSL
RULES=""                   # tools/failure-rules.txt; set once SELF is known
PHASES="doctor sync modules check build verify preflight-flash flash boot"
PHASES_SET=0               # did the caller name the phases themselves?
VBMETA=""                  # factory vbmeta, flashed with verification off
IMG=""                     # system image to flash; default: newest built
CONTROL=""                 # known-good image to flash INSTEAD, as a control
FORCE_FLASH=0              # flash even if preflight found blocking problems
DELETE_STOCK_PARTS=0       # drop stock product/system_ext; a GSI brings its own
WIPE=1                     # required after changing the boot state
SERIAL=""                  # adb/fastboot serial, if more than one device
BOOT_TIMEOUT=2400          # 40 min; a first boot on a wiped device is slow
BOOT_STALL=900             # 15 min with no new service = hung
FACTORY=""                 # unzipped factory image, for rescuing the log
INSTALL="flash"            # flash | dsu - how the image gets onto the device
DSU_USERDATA=8589934592    # 8 GiB slice for the DSU instance's own userdata
MODULES=""                 # CircleOS/modules - overlay packages to add to the build

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    cat <<'USAGE'

Options
  --lite | --aosp        pruned tree, or the full manifest
  --tree DIR             default ~/android
  --branch TAG           default android-16.0.0_r4
  --product NAME         default lite_arm64 (--lite) or aosp_arm64 (--aosp)
  --release CONFIG       default bp4a. Use trunk_staging ONLY for Cuttlefish
  --variant V            default userdebug
  --target T             default systemimage
  --reference IMG        GSI to verify the built image against
  --jobs N               default nproc
  --phases "a b c"       run only these: doctor sync modules check build
                         verify preflight-flash flash boot, or dsu in
                         place of preflight-flash/flash
  --vbmeta IMG           vbmeta from the FACTORY image, flashed with
                         verification disabled. Not an empty one: a vbmeta
                         with no descriptors leaves the bootloader with no
                         boot chain and it never attempts a boot at all
  --img FILE             system image to flash (default: newest built)
  --control FILE         flash this known-good image INSTEAD of yours, to
                         prove the device and the procedure before blaming
                         the build. Costs one flash, settles the question
  --force-flash          flash even if preflight found blocking problems
  --delete-stock-parts   delete the stock product/system_ext logical
                         partitions. A GSI carries its own inside
                         system.img; the stock ones just sit in super
  --serial S             adb/fastboot serial, if more than one device
  --no-wipe              skip erasing userdata (it will usually not boot)
  --boot-timeout SECS    default 2400
  --factory-image DIR    unzipped factory image. If the device fails to
                         boot, os.sh restores from this and reads the
                         kernel log automatically - the log is perishable
                         and deciding what to do costs it
  --modules DIR          CircleOS/modules. Each subdirectory holding
                         Android.bp + AndroidManifest.xml + patch_reg.py is
                         copied to vendor/circle/apps/<name> and registered
                         in PRODUCT_PACKAGES. Runs BEFORE check, so
                         check-product sees the modules it is meant to
                         catch problems in. Idempotent - a module already
                         in the tree is left alone
  --dsu                  install with DSU instead of flashing. A temporary
                         image inside userdata: stock is untouched, nothing
                         is erased, and a boot that fails falls back to
                         stock by itself. Proves the IMAGE. It never
                         touches vbmeta, verity or the partition write, so
                         it cannot prove the INSTALL - flash for that.
                         Unless --phases is given, this replaces the
                         preflight-flash and flash phases with dsu
  --dsu-userdata BYTES   userdata slice for the DSU instance, default 8 GiB
  --retries N            default 8
  --report-every SECS    progress line during a build, default 1200 (20 min)
  --no-auto-fix          stop on the first failure instead of fixing it.
                         By default os.sh closes the loop: identify the
                         failure, restore the project, write the rule into
                         tools/failure-rules.txt so it is never
                         rediscovered, and rebuild. Failures are loud
                         either way - banner, STATUS.txt, desktop dialog.

Exit codes
  0  image built (and verified, if a reference was given)
  1  something needs a human
  2  the script could not run its own checks
USAGE
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lite) MODE=lite ;;
        --aosp) MODE=aosp ;;
        --tree) TREE="$2"; shift ;;
        --branch) BRANCH="$2"; shift ;;
        --product) PRODUCT="$2"; shift ;;
        --release) RELEASE="$2"; shift ;;
        --variant) VARIANT="$2"; shift ;;
        --target) TARGET="$2"; shift ;;
        --reference) REFERENCE="$2"; shift ;;
        --jobs) JOBS="$2"; shift ;;
        --phases) PHASES="$2"; PHASES_SET=1; shift ;;
        --retries) MAX_RETRIES="$2"; shift ;;
        --report-every) REPORT_EVERY="$2"; shift ;;
        --auto-fix) AUTO_FIX=1 ;;
        --no-auto-fix) AUTO_FIX=0 ;;
        --status-dir) STATUS_DIR="$2"; shift ;;
        --vbmeta) VBMETA="$2"; shift ;;
        --img) IMG="$2"; shift ;;
        --control) CONTROL="$2"; shift ;;
        --force-flash) FORCE_FLASH=1 ;;
        --delete-stock-parts) DELETE_STOCK_PARTS=1 ;;
        --serial) SERIAL="$2"; shift ;;
        --no-wipe) WIPE=0 ;;
        --boot-timeout) BOOT_TIMEOUT="$2"; shift ;;
        --factory-image) FACTORY="$2"; shift ;;
        --modules) MODULES="$2"; shift ;;
        --dsu) INSTALL=dsu ;;
        --dsu-userdata) DSU_USERDATA="$2"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

[ -n "$MODE" ] || { echo "choose --lite or --aosp" >&2; usage 1; }
[ -n "$PRODUCT" ] || PRODUCT=$([ "$MODE" = lite ] && echo lite_arm64 || echo aosp_arm64)

# --dsu swaps the two flash phases for the dsu phase, unless the caller has
# said explicitly what they want. Doing it here rather than making the user
# retype --phases is the difference between a flag people use and a flag
# people get wrong: "--dsu --phases ... flash ..." would silently wipe the
# device it was chosen to protect.
if [ "$INSTALL" = dsu ] && [ "$PHASES_SET" != 1 ]; then
    PHASES="doctor sync modules check build verify dsu boot"
fi
case " $PHASES " in
    *" dsu "*)
        case " $PHASES " in
            *" flash "*)
                echo "refusing: dsu and flash in the same run." >&2
                echo "  dsu leaves the device untouched; flash wipes it." >&2
                echo "  Pick one - they answer different questions." >&2
                exit 1 ;;
        esac ;;
esac
LUNCH="$PRODUCT-$RELEASE-$VARIANT"
LOG="$TREE/out/os-sh.log"
RULES="${RULES:-$SELF/tools/failure-rules.txt}"

# ------------------------------------------------------------------ output
BOLD=""; DIM=""; OFF=""
[ -t 1 ] && { BOLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'; }
PHASE_NAME=""
phase() {
    PHASE_NAME="$1"
    printf '\n%s=== %s %s%s\n' "$BOLD" "$1" "$(date +%H:%M:%S)" "$OFF"
    publish "$1 started $(date '+%H:%M:%S')"
}
info()  { printf '  %s\n' "$1"; }
note()  { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }
die() {
    # Every failure leaves the same trace, wherever it happens: a banner in
    # the terminal and a line in STATUS.txt on the Windows side. A phase
    # that fails quietly is how hours get lost - a
    # build died here at 00:58 and was found at 05:47.
    local msg="$1" code="${2:-1}" first
    first=$(printf '%s' "$msg" | head -1 | cut -c1-120)
    alarm "FAILED in ${PHASE_NAME:-os.sh}" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '  %s\n' "$msg" >&2
    publish "FAILED ${PHASE_NAME:-os.sh} $(date '+%H:%M:%S') - $first"
    exit "$code"
}

runs() { case " $PHASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

find_tool() {
    # $1 = adb|fastboot, $2 = variable to set.
    #
    # Under WSL the platform-tools usually live on the Windows side, and
    # WSL's view of /mnt/c is not always complete - on one machine here
    # AppData/Local/Android is missing from the WSL listing entirely while
    # Windows sees it. So: look in several places, and if none of them
    # work, say so now rather than polling a device that was never
    # reachable.
    local want="$1" var="$2" found="" c
    eval "found=\${$var:-}"
    if [ -n "$found" ] && [ -x "$found" ]; then return 0; fi

    for c in "$want" "$want.exe"; do
        if command -v "$c" >/dev/null 2>&1; then
            eval "$var=\$(command -v '$c')"
            return 0
        fi
    done

    if command -v wslpath >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1; then
        local up
        up=$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')
        [ -n "$up" ] && up=$(wslpath -u "$up" 2>/dev/null || true)
        for c in "$up/Android/Sdk/platform-tools/$want.exe"                  "/mnt/c/platform-tools/$want.exe"                  "/usr/lib/android-sdk/platform-tools/$want"; do
            if [ -x "$c" ]; then eval "$var='$c'"; return 0; fi
        done
    fi

    die "cannot find $want.

  Looked on PATH, and for the Windows SDK under %LOCALAPPDATA%.

  Under WSL this often means WSL cannot see the Android SDK even though
  Windows can - check with:
      ls /mnt/c/Users/<you>/AppData/Local/Android/Sdk/platform-tools

  If that is empty, run the flash and boot phases from Windows instead,
  or pass the path explicitly:
      ADB=/path/to/adb FASTBOOT=/path/to/fastboot tools/os.sh ..."
}

# ------------------------------------------------------------ publishing
#
# A report that only exists in a log nobody is tailing is not a report.
# Under WSL the Windows side of the machine is where a person actually
# looks, so status is written there as plain text:
#
#   %USERPROFILE%osp-build\STATUS.txt    one line, the current state
#   %USERPROFILE%osp-build\history.log   every line, timestamped
#
# Text only, deliberately. A dialog box means a resident process holding
# ~100 MB until somebody clicks it, and the whole premise is that nobody
# is watching.
if [ -z "$STATUS_DIR" ] && command -v wslpath >/dev/null 2>&1 &&
   command -v cmd.exe >/dev/null 2>&1; then
    # Ask Windows where the profile is and let wslpath convert it. Globbing
    # /mnt/c/Users/*/ picks up "All Users", "Default" and "Public" -
    # junctions, one of which contains a space, and every path built from it
    # then breaks.
    win=$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null |
          tr -d '\r\n')
    if [ -n "$win" ]; then
        cand=$(wslpath -u "$win" 2>/dev/null || true)
        if [ -n "$cand" ] && [ -d "$cand" ] && [ -w "$cand" ]; then
            STATUS_DIR="$cand/aosp-build"
        fi
    fi
fi
if [ -n "$STATUS_DIR" ]; then
    mkdir -p "$STATUS_DIR" 2>/dev/null || STATUS_DIR=""
fi

publish() {
    # $1 = one-line status. STATUS.txt is overwritten so it always shows the
    # current state at a glance; history.log keeps every line.
    [ -n "$STATUS_DIR" ] || return 0
    echo "$1" > "$STATUS_DIR/STATUS.txt" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$STATUS_DIR/history.log" 2>/dev/null || true
}



# Loud on purpose. A failure buried in a scrolling log is how a build that
# died at 00:58 went unnoticed until 05:47. Prints a banner and rings the
# terminal bell, so it is visible in a window nobody is watching.
RED=""; [ -t 1 ] && RED=$'\033[1;31m'
alarm() {
    printf '\n%s############################################################%s\n' "$RED" "$OFF"
    printf '%s##  %-54s##%s\n' "$RED" "$1" "$OFF"
    [ -n "${2:-}" ] && printf '%s##  %-54s##%s\n' "$RED" "$2" "$OFF"
    printf '%s############################################################%s\n\n' "$RED" "$OFF"
    printf '\a'
}

# ------------------------------------------------------------- environment
# Set here so every phase agrees, and so the reasons travel with them.
#
# GOCACHE / XDG_CACHE_HOME: a default WSL install leaves ~/.cache owned by
# root, and Go dies with "permission denied" before lunch finishes.
export GOCACHE="$HOME/buildcache/go"
export XDG_CACHE_HOME="$HOME/buildcache/xdg"
mkdir -p "$GOCACHE" "$XDG_CACHE_HOME"

# A pruned tree needs this or Soong panics in validate_bindings.go rather
# than skipping modules whose dependencies were pruned. On a full tree it
# is harmless.
[ "$MODE" = lite ] && export ALLOW_MISSING_DEPENDENCIES=true

# USE_CCACHE is deliberately not set. It controls CC_WRAPPER, prepended to
# every C++ compile command; changing it in either direction rewrites all
# ~100,000 of them and ninja rebuilds the tree. Whatever out/ was built
# with, leave it.
unset USE_CCACHE CCACHE_EXEC 2>/dev/null || true

printf '%smode%s     %s\n' "$BOLD" "$OFF" "$MODE"
printf '%stree%s     %s\n' "$BOLD" "$OFF" "$TREE"
printf '%slunch%s    %s\n' "$BOLD" "$OFF" "$LUNCH"
printf '%starget%s   %s\n' "$BOLD" "$OFF" "$TARGET"
printf '%sjobs%s     %s\n' "$BOLD" "$OFF" "$JOBS"

# ================================================================= doctor
if runs doctor; then
    phase "doctor"
    if [ -x "$SELF/tools/check-env.sh" ] || [ -f "$SELF/tools/check-env.sh" ]; then
        set +e
        bash "$SELF/tools/check-env.sh" "$TREE" "$LUNCH" "$TARGET"
        rc=$?
        set -e
        [ "$rc" -le 1 ] || die "check-env could not run (exit $rc)" 2
        if [ "$rc" = 1 ]; then
            die "The machine or the tree will not support this build. Fix the
  FAIL lines above. Nothing has been changed."
        fi
    else
        die "tools/check-env.sh missing - refusing to build unchecked" 2
    fi
fi

# =================================================================== sync
if runs sync; then
    phase "sync"
    if [ -d "$TREE/.repo" ]; then
        info "tree already initialised - not re-syncing"
        note "delete $TREE/.repo to start over, or run with --phases 'doctor check build verify'"
    else
        command -v repo >/dev/null 2>&1 || die "repo not on PATH" 2
        mkdir -p "$TREE"
        info "repo init -b $BRANCH (shallow)"
        ( cd "$TREE" && repo init -u https://android.googlesource.com/platform/manifest \
              -b "$BRANCH" --depth=1 --no-tags )
        if [ "$MODE" = lite ]; then
            mkdir -p "$TREE/.repo/local_manifests"
            n=0
            for f in "$SELF"/manifests/prune-tier*.xml; do
                [ -e "$f" ] || continue
                cp "$f" "$TREE/.repo/local_manifests/"
                n=$((n+1))
            done
            info "installed $n prune tiers"
        fi
        info "repo sync -j$JOBS - this is the long download"
        ( cd "$TREE" && repo sync -c -j"$JOBS" --no-clone-bundle --prune --force-sync )
        info "synced: $(du -sh "$TREE" 2>/dev/null | cut -f1)"
    fi

    # Every run, not only after a fresh sync. repo sync overwrites the
    # projects these patch, and a sync done outside os.sh is invisible from
    # here - so the only safe assumption is that the tree may have lost
    # them. apply-patches.sh is idempotent, so this costs a second.
    #
    # It matters because of what silently reverts: without the bionic patch
    # the allocator falls back to Scudo and nothing says so. The build
    # succeeds, the image boots, and chapter 03 section 2.2 quietly stops
    # being true.
    if [ -f "$SELF/tools/apply-patches.sh" ]; then
        set +e
        out=$(bash "$SELF/tools/apply-patches.sh" "$TREE" 2>&1); rc=$?
        set -e
        echo "$out" | sed -n "s/^  /    /p" | grep -vE "already present|^\s*$" | head -8
        [ "$rc" = 0 ] || die "a patch would not apply - the tree is missing a change
  the build expects. Output above."
        info "patches: $(echo "$out" | grep -oE "[0-9]+ applied, [0-9]+ already present")"
    fi
fi

# ================================================================ modules
#
# CircleOS/modules holds overlay packages that are not in the tree: each is
# a directory with Android.bp, AndroidManifest.xml, res/, src/ and a
# patch_reg.py that inserts the module name into
# vendor/circle/config/common.mk PRODUCT_PACKAGES.
#
# Two details decide whether this works, and both were read out of the
# module files rather than assumed:
#
#   - Android.bp uses relative paths (srcs: ["src/**/*.java"],
#     resource_dirs: ["res"]), so a module only builds from its own
#     directory. It is copied whole.
#   - patch_reg.py opens "config/common.mk" relative to the working
#     directory, so it has to run with cwd = vendor/circle. Run from
#     anywhere else it fails to find the file, or edits the wrong one.
#
# This phase runs BEFORE check, deliberately. check-product.sh exists to
# catch a duplicated resource inside one module and a privileged app with
# no allowlist entry - both of which build cleanly and boot-loop the
# device. Adding 27 app packages is exactly when those appear, so the
# checks have to see the tree that is going to be built, not the one
# before.

if runs modules; then
    phase "modules"

    if [ -z "$MODULES" ]; then
        note "no --modules given - nothing to add"
    else
        [ -d "$MODULES" ] || die "no module directory at $MODULES"
        VC="$TREE/vendor/circle"
        [ -d "$VC" ] || die "no vendor/circle in the tree at $VC.
  The modules register themselves in vendor/circle/config/common.mk, so
  the Circle overlay manifest has to be synced first."
        [ -f "$VC/config/common.mk" ] || die "no $VC/config/common.mk - patch_reg.py
  has nothing to register into."

        added=0; skipped=0; failed=""
        for m in "$MODULES"/*/; do
            m="${m%/}"
            [ -f "$m/Android.bp" ] || continue
            [ -f "$m/AndroidManifest.xml" ] || continue
            [ -f "$m/patch_reg.py" ] || continue

            # The destination is the module's own Soong name, not the
            # folder name: circleos-desktop declares CircleDesktop, and
            # that is what PRODUCT_PACKAGES will name.
            name=$(sed -n 's/^[[:space:]]*name:[[:space:]]*"\([^"]*\)".*/\1/p' \
                   "$m/Android.bp" | head -1)
            if [ -z "$name" ]; then
                failed="$failed $(basename "$m")(no-name)"
                continue
            fi

            dest="$VC/apps/$name"
            if [ -d "$dest" ]; then
                skipped=$((skipped+1))
                continue
            fi

            mkdir -p "$dest"
            cp "$m/Android.bp" "$m/AndroidManifest.xml" "$dest/" 2>/dev/null || true
            [ -d "$m/res" ] && cp -r "$m/res" "$dest/"
            [ -d "$m/src" ] && cp -r "$m/src" "$dest/"

            # Register it. patch_reg.py is already idempotent - it returns 0
            # and says so if the name is in common.mk - so a re-run is safe.
            set +e
            out=$( cd "$VC" && python3 "$m/patch_reg.py" 2>&1 )
            rc=$?
            set -e
            if [ "$rc" != 0 ]; then
                # Leave the copied files: the next run finds the directory,
                # skips the copy, and the failure is about common.mk only.
                failed="$failed $name"
                note "  $name: $(printf '%s' "$out" | tail -1)"
                continue
            fi
            added=$((added+1))
            info "$name"
        done

        info "added $added, already present $skipped"
        if [ -n "$failed" ]; then
            die "could not register:$failed

  patch_reg.py inserts the module after an anchor already in
  PRODUCT_PACKAGES (CircleLauncher among them). If it reports no anchor
  found, vendor/circle/config/common.mk is not the file it expects.
  Nothing is half-done: the module sources are copied and registration is
  all that is outstanding."
        fi
        publish "modules: $added added, $skipped already present"
    fi
fi

# ================================================================== check
if runs check && [ "$MODE" = lite ]; then
    phase "check"
    blocked=0
    # check-product runs for every mode, not just lite: the faults it
    # finds are product-configuration faults, not pruning faults, and a
    # full manifest is no protection against them. Both of the ones it
    # knows about built cleanly and boot-looped the device.
    for c in preflight check-modules check-product; do
        s="$SELF/tools/$c.sh"
        [ -f "$s" ] || die "tools/$c.sh missing - refusing to build unchecked" 2
        info "$c.sh"
        set +e
        # preflight takes the product so it can tell a makefile this
        # build reads from another device's.
        if [ "$c" = preflight ] || [ "$c" = check-product ]; then
            out=$(bash "$s" "$TREE" "$PRODUCT" 2>&1); rc=$?
        else
            out=$(bash "$s" "$TREE" 2>&1); rc=$?
        fi
        set -e
        case "$rc" in
            0) note "  clean" ;;
            1) blocked=1
               # check-product prints its findings as FAIL lines rather
               # than in a block, so show those too - otherwise the phase
               # says "blocked" and names nothing.
               echo "$out" | sed -n '/ACT ON THESE/,/^$/p;/BLOCKING/,/^$/p' | sed 's/^/  /'
               echo "$out" | grep -E '^  FAIL' | sed 's/^/  /' ;;
            *) die "$c.sh exited $rc - it did not complete" 2 ;;
        esac
    done
    if [ "$blocked" = 1 ]; then
        # These are real. Both checks report zero blocking findings on a
        # correctly pruned tree, so anything here will fail the build -
        # some during analysis, some only when the module is reached hours
        # in. Carrying on and hoping is what this script exists to stop.
        die "The checks found references to projects this tree no longer has.
  Each one fails the build. The fix for each is printed above it.
  Re-run with --auto-fix to have recognised ones restored automatically."
    fi
fi

# ================================================================== build
#
# The failure table. Each entry is: a signature to look for in the build
# log, and the project that provides what is missing. Everything here cost
# at least one failed build to learn.
#
#   signature                             provided by
fix_for_signature() {
    # Reads tools/failure-rules.txt rather than hard-coding the table, so
    # a new rule is a line of data, not an edit to this script. That is
    # what lets the loop close: identify, fix, learn, rebuild.
    local log="$1" errs sig project s

    # Only the failure context. Scanning the whole log matches successful
    # work - a line like
    #   [3% 4703/154564] //prebuilts/gradle-plugin:metalava-gradle-plugin-deps
    # names a module that built fine, and matching on it restored a project
    # that was never missing while the real failure went unread.
    errs=$(mktemp)
    grep -A3 -E "^FAILED:|^error:|^ninja: error" "$log" > "$errs" 2>/dev/null || true
    grep -E "missing dependencies|unrecognized module type|no known rule to make" \
        "$log" >> "$errs" 2>/dev/null || true

    while IFS=$'\t' read -r sig project; do
        case "$sig" in ''|'#'*) continue ;; esac
        [ -n "$project" ] || continue
        if grep -qF "$sig" "$errs" 2>/dev/null; then
            rm -f "$errs"
            echo "$project"
            return 0
        fi
    done < "$RULES"

    # Not covered. Name the missing thing so the caller can try to resolve
    # it and write a new rule.
    s=$(grep -oE 'depends on undefined module "[^"]+"' "$errs" | head -1 |
        sed 's/.*"\(.*\)"/\1/') || true
    [ -z "$s" ] && s=$(grep -oE 'missing dependencies: [^ ,]+' "$errs" |
        head -1 | awk '{print $NF}') || true
    [ -z "$s" ] && s=$(grep -oE "'[^']+' *, needed by" "$errs" | head -1 |
        tr -d "'" | awk '{print $1}') || true
    rm -f "$errs"
    [ -n "$s" ] && { echo "UNKNOWN:$s"; return 0; }
    return 1
}

resolve_project() {
    # Which pruned project provides $1? Two ways, cheapest first.
    #
    # If it looks like a path, the answer is the longest pruned project
    # that is a prefix of it. If it is a module name, ask the upstream
    # manifest for a project whose path ends in that name - which catches
    # prebuilts and app projects, the two that keep coming up.
    local want="$1" best="" p
    while read -r p; do
        case "$want" in
            "${p#platform/}"/*|"$p"/*)
                [ ${#p} -gt ${#best} ] && best="$p" ;;
        esac
    done < <(pruned_projects)
    [ -n "$best" ] && { echo "$best"; return 0; }

    while read -r p; do
        case "${p##*/}" in
            "$want") echo "$p"; return 0 ;;
        esac
    done < <(pruned_projects)
    return 1
}

pruned_projects() {
    python3 - "$TREE" <<'PRUNED'
import sys, glob, os, xml.etree.ElementTree as ET
tree = sys.argv[1]
for f in sorted(glob.glob(os.path.join(tree, ".repo", "local_manifests", "*.xml"))):
    try:
        for e in ET.parse(f).getroot().findall("remove-project"):
            if e.get("name"):
                print(e.get("name"))
    except Exception:
        pass
PRUNED
}

learn_rule() {
    # Append a rule so this failure is recognised next time, here and on
    # every machine that pulls the repository. The comment records when and
    # from what, because a bare mapping with no provenance is the thing
    # nobody dares delete later.
    local sig="$1" project="$2"
    grep -qF "$sig" "$RULES" 2>/dev/null && return 0
    {
        printf '\n# learned %s: the build failed with this and %s fixed it\n' \
               "$(date '+%Y-%m-%d')" "$project"
        printf '%s\t%s\n' "$sig" "$project"
    } >> "$RULES"
    info "learned: '$sig' -> $project (written to $(basename "$RULES"))"
}

unprune() {
    local project="$1" reason="$2" found=0
    for f in "$TREE"/.repo/local_manifests/*.xml; do
        [ -e "$f" ] || continue
        # Must be an ACTIVE entry. Disabled ones are kept inside XML
        # comments with their reason, and a grep finds those too - which
        # made this report "could not find a remove-project entry" for a
        # project that was already restored.
        python3 - "$f" "$project" <<'ACTIVE' || continue
import sys, xml.etree.ElementTree as ET
tree, name = sys.argv[1], sys.argv[2]
found = any(e.get("name") == name
            for e in ET.parse(tree).getroot().findall("remove-project"))
sys.exit(0 if found else 1)
ACTIVE
        python3 - "$f" "$project" "$reason" <<'PY'
import sys
path, project, reason = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
line = '  <remove-project name="%s" optional="true"/>\n' % project
if line in s:
    s = s.replace(line, '  <!-- kept: %s\n%s  -->\n' % (reason, line))
    open(path, "w").write(s)
    print("OK")
PY
        found=1
        break
    done
    [ "$found" = 1 ] || return 1
    ( cd "$TREE" && repo sync -c -j"$JOBS" --no-clone-bundle "$project" >/dev/null 2>&1 )
}

if runs build; then
    phase "build"
    mkdir -p "$(dirname "$LOG")"
    attempt=1
    while :; do
        info "attempt $attempt of $MAX_RETRIES"

        set +e
        ( cd "$TREE"
          # shellcheck disable=SC1091
          source build/envsetup.sh >/dev/null
          lunch "$LUNCH" >/dev/null
          m -j"$JOBS" "$TARGET" ) > "$LOG" 2>&1 &
        build_pid=$!

        # Report while it runs. A build is hours long and silence is
        # indistinguishable from a hang - which is how a build that died at
        # 00:58 went unnoticed until 05:47. Each line is timestamped, says
        # which phase and how far through, and shows the memory headroom
        # that decides whether it survives.
        last_report=$SECONDS
        build_start=$SECONDS
        prev_done=0
        prev_time=$SECONDS
        while kill -0 "$build_pid" 2>/dev/null; do
            sleep 20
            [ $((SECONDS - last_report)) -ge "$REPORT_EVERY" ] || continue
            last_report=$SECONDS

            progress=$(grep -oE '^\[ *[0-9]+% [0-9]+/[0-9]+' "$LOG" 2>/dev/null | tail -1)
            mem=$(free -g | awk '/^Mem:/{a=$7} /^Swap:/{s=$3; t=$2} END{printf "%sG free, swap %s/%sG", a, s, t}')

            if [ -z "$progress" ]; then
                # Analysis, before ninja has a graph to count. Say how long
                # it has been, not nothing.
                printf '  %s%s%s  analysis, %d min elapsed  %s\n' \
                       "$DIM" "$(date '+%H:%M:%S')" "$OFF" \
                       $(( (SECONDS - build_start) / 60 )) "$mem"
                printf '           %s%s%s\n' "$DIM" "$(tail -1 "$LOG" 2>/dev/null | cut -c1-60)" "$OFF"
                continue
            fi

            done_now=$(echo "$progress" | grep -oE '[0-9]+/' | tr -d '/')
            total=$(grep -oE '^\[ *[0-9]+% [0-9]+/[0-9]+' "$LOG" | tail -1 |
                    awk -F/ '{print $2}')

            # Rate over the last interval, because the early actions are
            # not representative - analysis-adjacent work runs far faster
            # than the C++ and Java that follows.
            # First interval after ninja appears is not a rate: most of
            # that window was Soong analysis, which produces no actions.
            # Measuring across it reported 37 hours on a build that was
            # running at 246 actions/min and finished in nine. Seed the
            # baseline and wait for a clean interval.
            if [ "$prev_done" = 0 ]; then
                prev_done=$done_now
                prev_time=$SECONDS
                printf '  %s%s%s  %s]  measuring rate  %s
'                        "$DIM" "$(date '+%H:%M:%S')" "$OFF" "$progress" "$mem"
                publish "building  $progress]  measuring rate  $mem"
                continue
            fi

            dt=$(( SECONDS - prev_time ))
            dn=$(( done_now - prev_done ))
            prev_time=$SECONDS
            prev_done=$done_now

            eta="?"
            if [ "$dt" -gt 0 ] && [ "$dn" -gt 0 ]; then
                rate=$(( dn * 60 / dt ))                 # actions per minute
                [ "$rate" -gt 0 ] && {
                    left=$(( total - done_now ))
                    mins=$(( left / rate ))
                    eta=$(printf '%dh%02dm left, done ~%s' \
                          $(( mins / 60 )) $(( mins % 60 )) \
                          "$(date -d "+$mins minutes" '+%H:%M' 2>/dev/null || echo '?')")
                }
            fi

            printf '  %s%s%s  %s]  %s  %s\n' \
                   "$DIM" "$(date '+%H:%M:%S')" "$OFF" "$progress" "$eta" "$mem"
            publish "building  $progress]  $eta  $mem"
        done

        wait "$build_pid"
        rc=$?
        set -e

        if [ "$rc" = 0 ]; then
            info "build succeeded on attempt $attempt"
            publish "build SUCCEEDED at $(date '+%H:%M:%S') after $attempt attempt(s)"
            break
        fi

        alarm "BUILD FAILED" "attempt $attempt of $MAX_RETRIES, $(date '+%H:%M:%S')"
        grep -E '^(error|FAILED):|missing dependencies|unrecognized module type|no known rule' "$LOG" \
            | head -6 | sed 's/^/    /'
        echo
        info "full log: $LOG"

        first_err=$(grep -m1 -E '^(error|FAILED):|missing dependencies|unrecognized module type|no known rule' \
                    "$LOG" 2>/dev/null | cut -c1-140)
        publish "FAILED $(date '+%H:%M:%S') - ${first_err:-see $LOG}"

        # Diagnose either way - the answer is useful whether or not we
        # are allowed to act on it.
        set +e
        project=$(fix_for_signature "$LOG"); has_fix=$?
        set -e

        if [ "$AUTO_FIX" != 1 ]; then
            echo
            case "$has_fix:$project" in
                0:UNKNOWN:*)
                    info "diagnosis: module '${project#UNKNOWN:}' is referenced but not"
                    info "           in this tree, and no rule says which project provides it." ;;
                0:*)
                    info "diagnosis: $project was pruned and the build needs it."
                    info "fix:       comment its remove-project entry out, keep the line,"
                    info "           write down why, then"
                    info "           cd $TREE && repo sync -c -j$JOBS --no-clone-bundle $project"
                    info "           then run this again." ;;
                *)
                    info "diagnosis: no rule matches this failure. Read the log." ;;
            esac
            die "Stopped. Re-run with --auto-fix to let it restore and retry by itself."
        fi

        if [ "$attempt" -ge "$MAX_RETRIES" ]; then
            die "gave up after $MAX_RETRIES attempts. Log: $LOG"
        fi

        if [ "$MODE" != lite ]; then
            die "build failed on a full tree - this is not a pruning problem.
  Log: $LOG"
        fi

        [ "$has_fix" = 0 ] || die "no known fix for this failure. Log: $LOG"

        case "$project" in
            UNKNOWN:*)
                # No rule covers this. Try to work out which pruned project
                # provides it, and if that succeeds, write the rule down so
                # this failure is never rediscovered - here or on any other
                # machine that pulls the repository.
                missing="${project#UNKNOWN:}"
                info "no rule for '$missing' - resolving"
                set +e
                project=$(resolve_project "$missing")
                found=$?
                set -e
                if [ "$found" != 0 ] || [ -z "$project" ]; then
                    die "Missing '$missing', and no pruned project obviously provides it.
  Find it upstream, comment the remove-project entry out in the relevant
  manifest, sync it, then add a line to
  $(basename "$RULES"):

      $missing<TAB><project>

  so the next build already knows.
  Log: $LOG"
                fi
                info "resolved: $missing is provided by $project"
                learn_rule "$missing" "$project"
                ;;
        esac

        info "restoring $project and retrying"
        if unprune "$project" "restored automatically by os.sh - the build needs it"; then
            note "  un-pruned and synced"
        else
            die "could not find a remove-project entry for $project. Log: $LOG"
        fi
        attempt=$((attempt+1))
    done
fi

# ================================================================= verify
if runs verify; then
    phase "verify"
    img=$(ls -t "$TREE"/out/target/product/*/system.img 2>/dev/null | head -1 || true)
    if [ -z "$img" ]; then
        die "no system.img under $TREE/out/target/product/"
    fi
    info "image: $img ($(du -h "$img" | cut -f1))"
    if [ -f "$SELF/tools/check-image.sh" ]; then
        set +e
        bash "$SELF/tools/check-image.sh" "$img" "$REFERENCE"
        rc=$?
        set -e
        [ "$rc" = 0 ] || die "the image has differences that stop a device booting.
  Fix those before flashing - a bad flash costs a wipe and destroys the
  kernel log that would tell you why."
    fi
fi

# ================================================================== flash
#
# An image that builds is not an OS. The only measure that counts is
# CircleOS running on the device, so the flow does not end at a .img.
#
# Everything here was learned the hard way on a Pixel 7a:
#
#   - flashing the system partition needs USERSPACE fastboot (fastbootd).
#     Bootloader fastboot cannot write a logical partition and says so in
#     a way that reads like a driver problem.
#   - vbmeta has to be written with verification disabled or the device
#     shows "your device is corrupt" and refuses. That in turn forces a
#     data wipe, because the encryption keys are tied to the boot state.
#   - the kernel log that says WHY a boot failed lives in RAM. It survives
#     a reboot but not a power-off, and userspace fastboot runs its own
#     kernel and overwrites it. One look per flash.

adb_() { "$ADB" ${SERIAL:+-s "$SERIAL"} "$@"; }
fb_()  { "$FASTBOOT" ${SERIAL:+-s "$SERIAL"} "$@"; }

device_state() {
    if fb_ devices 2>/dev/null | grep -q fastboot; then echo fastboot
    elif adb_ get-state 2>/dev/null | grep -q device; then echo adb
    else echo none; fi
}

# ==================================================================== dsu
#
# Dynamic System Updates: run the image from a temporary logical partition
# inside userdata, with the installed system left exactly where it is.
#
# This exists because the flash path below is expensive in a way that
# shapes how people work. A flash erases userdata, needs a vbmeta whose
# disable bits are right for the device, and destroys the kernel log that
# would explain a failure - one look per attempt, and a wipe to get it. So
# a bad image costs twenty minutes and an argument about what was actually
# done to the device.
#
# DSU costs a reboot. The stock system is not modified, userdata is not
# erased, and a boot that does not complete falls back to stock on its
# own, so the log can be read from a system that is running.
#
# What it does NOT do, and this is the whole reason it does not replace
# the flash phase: it never writes a partition, never touches vbmeta and
# never exercises verity. It proves the IMAGE boots. It cannot prove the
# INSTALL works. Both questions have to be answered before a release, and
# only one of them is cheap.
#
# Requirements, all verified on the reference device (Pixel 7a, lynx,
# 2026-09-16): ro.boot.dynamic_partitions=true, ro.virtual_ab.enabled=true,
# /system/bin/gsi_tool present, DynamicSystem service registered.

if runs dsu; then
    phase "dsu"

    find_tool adb ADB

    IMG="${IMG:-$(ls -t "$TREE"/out/target/product/*/system.img 2>/dev/null | head -1)}"
    [ -n "$IMG" ] && [ -f "$IMG" ] || die "no system.img to install. Build first, or pass --img."
    info "image : $IMG ($(du -h "$IMG" | cut -f1))"

    # The device has to be BOOTED for this. DSU is installed by the running
    # system into its own userdata - there is no fastboot involved at any
    # point, which is exactly why it costs nothing.
    case "$(device_state)" in
        fastboot) die "device is in fastboot. DSU is installed by the running
  system, not by the bootloader. Boot it first:  fastboot reboot" ;;
        none)     die "no device. Connect it with USB debugging enabled." ;;
    esac

    # Prerequisites, read off the device rather than assumed. Each of these
    # produces a different and unhelpful failure if it is missing, and all
    # four are one getprop away.
    dsu_dyn=$(adb_ shell getprop ro.boot.dynamic_partitions 2>/dev/null | tr -d '\r')
    [ "$dsu_dyn" = true ] || die "ro.boot.dynamic_partitions is '${dsu_dyn:-unset}', not true.
  DSU needs dynamic partitions - there is nowhere to put the image."

    adb_ shell 'test -x /system/bin/gsi_tool' 2>/dev/null ||
        die "no /system/bin/gsi_tool on the device. DSU is unavailable on
  this build; use the flash path instead."

    # gsi_tool install writes into the DSU metadata and needs root. On a
    # userdebug build 'adb root' gives it; on user builds it does not, and
    # the documented route is the DynamicSystem intent, which puts a
    # confirmation dialog on the screen. Say which one is happening rather
    # than letting an unattended run block on a dialog nobody sees.
    dsu_id=$(adb_ shell id -u 2>/dev/null | tr -d '\r')
    if [ "$dsu_id" != 0 ]; then
        info "requesting adb root for gsi_tool"
        adb_ root >/dev/null 2>&1 || true
        sleep 4
        find_tool adb ADB
        dsu_id=$(adb_ shell id -u 2>/dev/null | tr -d '\r')
    fi
    [ "$dsu_id" = 0 ] || die "gsi_tool install needs root and adb root was refused
  (uid=${dsu_id:-unknown}). This is a user build, or adbd is not rootable.
  Install it by hand instead - that route asks for confirmation on the
  device screen:
      adb push '$IMG' /sdcard/Download/system.img
      adb shell am start-activity \\
        -n com.android.dynsystem/com.android.dynsystem.VerificationActivity \\
        -a android.os.image.action.START_INSTALL \\
        -d file:///storage/emulated/0/Download/system.img \\
        --el KEY_USERDATA_SIZE $DSU_USERDATA --ez KEY_ENABLE_WHEN_COMPLETED true"

    # Free space. The image AND the instance's own userdata slice both live
    # in /data. Running out part-way leaves a half-written DSU slot that
    # gsi_tool has to wipe before the next attempt, so check first.
    dsu_sz=$(stat -c %s "$IMG" 2>/dev/null || wc -c < "$IMG")
    dsu_need=$(( (dsu_sz + DSU_USERDATA) / 1024 / 1024 ))
    dsu_free=$(adb_ shell 'df -m /data 2>/dev/null | tail -1' 2>/dev/null |
               tr -d '\r' | awk '{print $4}')
    info "space : need ~${dsu_need} MB, free ${dsu_free:-?} MB on /data"
    if [ -n "$dsu_free" ] && [ "$dsu_free" -lt "$dsu_need" ]; then
        die "not enough room in /data for the image plus a ${DSU_USERDATA}-byte
  userdata slice. Lower it with --dsu-userdata, or free space."
    fi

    # A DSU slot left over from a previous run is refused rather than
    # replaced, and the error does not say so clearly. Clear it first.
    dsu_state=$(adb_ shell gsi_tool status 2>/dev/null | tr -d '\r' | head -1)
    info "gsi   : ${dsu_state:-unknown}"
    case "$dsu_state" in
        normal|"") ;;
        *) note "an existing DSU installation is present - wiping it first"
           adb_ shell gsi_tool wipe >/dev/null 2>&1 || true ;;
    esac

    # gsi_tool reads the image from stdin, so it streams rather than
    # needing a second copy on the device. --gsi-size must be the real
    # byte count; a wrong one produces a truncated image that boots to
    # nothing.
    info "installing (streaming $(du -h "$IMG" | cut -f1) over adb - several minutes)"
    publish "dsu install started $(date '+%H:%M:%S')"
    set +e
    adb_ shell "gsi_tool install --userdata-size $DSU_USERDATA --gsi-size $dsu_sz" \
        < "$IMG" 2>&1 | tail -6 | sed 's/^/    /'
    dsu_rc="${PIPESTATUS[0]}"
    set -e
    [ "$dsu_rc" = 0 ] || die "gsi_tool install failed (exit $dsu_rc). Nothing has changed
  on the device - the installed system is untouched."

    adb_ shell gsi_tool enable >/dev/null 2>&1 || true
    ok_state=$(adb_ shell gsi_tool status 2>/dev/null | tr -d '\r' | head -1)
    info "gsi   : ${ok_state:-unknown} (installed)"

    info "rebooting into the DSU image"
    publish "dsu installed, rebooting $(date '+%H:%M:%S')"
    adb_ reboot >/dev/null 2>&1 || true
    sleep 10

    # The boot phase below does the verifying. It checks for a fingerprint
    # containing "circle", which is the same question here as after a
    # flash - and if this image does not boot, the device returns to stock
    # by itself rather than sitting in fastboot.
    note "if this image does not boot, the device returns to stock on its own."
    note "to leave DSU afterwards:  adb shell gsi_tool disable && adb reboot"
fi

# ======================================================== preflight-flash
#
# Everything in here is a failure we actually hit on a Pixel 7a, in the
# order it cost us the most time. None of it is theoretical.
#
# The rule this phase exists to enforce: never learn from the device what
# you could have learned from the file. A bad image costs a flash, a
# reboot, a failed boot, a log hunt and often a hardware rescue - call it
# twenty minutes - and every check below runs in seconds.
#
# It is also the phase that says "flash the known-good image first". When
# a flash fails repeatedly, changing your own image again teaches nothing:
# you cannot tell "my build is wrong" from "my procedure is wrong" until
# one of them is held fixed. Run --control once and the answer is free.

img_has() {
    # Is $2 present inside ext4 image $1? debugfs prints an Inode: line for
    # anything that exists. Quieter and far faster than mounting.
    debugfs -R "stat $2" "$1" 2>/dev/null | grep -q "Inode:"
}

if runs preflight-flash; then
    phase "preflight-flash"
    PF_FAIL=0
    pf_warn() { note "WARN  $1"; }
    pf_bad()  { printf '  %sFAIL  %s%s\n' "$RED" "$1" "$OFF"; PF_FAIL=$((PF_FAIL+1)); }
    pf_ok()   { info "ok    $1"; }

    # --------------------------------------------------------- 1. the image
    IMG="${IMG:-$(ls -t "$TREE"/out/target/product/*/system.img 2>/dev/null | head -1)}"
    [ -n "$IMG" ] && [ -f "$IMG" ] || die "no system.img found. Build first, or pass --img."
    info "image : $IMG ($(du -h "$IMG" | cut -f1))"

    # The two halves of this phase do not live on the same machine. Reading
    # the image needs debugfs, which is Linux; talking to the phone needs
    # the Android platform tools, which under WSL sit on the Windows side.
    # Requiring both in one place means neither half ever runs - so each is
    # skipped independently, loudly, and the other still does its job.
    pf_img_checks=1
    if ! command -v debugfs >/dev/null 2>&1; then
        pf_img_checks=0
        pf_warn "debugfs not found - skipping every image check. Run this phase
        on the build machine as well (sudo apt install e2fsprogs); those
        are the checks that catch a bad build before it costs a flash."
    fi

    # A GSI is not just a system image. circle_arm64 inherited
    # generic_system.mk but not gsi_release.mk, which produces a perfectly
    # good EMULATOR image that panics on real hardware at ~1.1s with
    # "Attempted to kill init! exitcode=0x00007f00". These three files are
    # what gsi_release.mk adds, and what their absence costs.
    if [ "$pf_img_checks" = 1 ]; then
    for f in /system/system_ext/etc/init/config/skip_mount.cfg \
             /system/system_ext/etc/init/init.gsi.rc \
             /system/system_ext/etc/gsi/init.vndk-nodef.rc; do
        if img_has "$IMG" "$f"; then
            pf_ok "GSI file $(basename "$f")"
        else
            pf_bad "not a GSI: $f missing - is gsi_release.mk inherited?"
        fi
    done

    # init and the linker it names. Exit code 127 means "could not exec",
    # which is either a missing binary or a missing library - so check the
    # binary, its interpreter, and every library it declares.
    if img_has "$IMG" /system/bin/init; then
        pf_ok "/system/bin/init present"
        pf_tmp=$(mktemp -d)
        debugfs -R "dump /system/bin/init $pf_tmp/init" "$IMG" >/dev/null 2>&1
        if [ -s "$pf_tmp/init" ] && command -v readelf >/dev/null 2>&1; then
            pf_interp=$(readelf -lW "$pf_tmp/init" 2>/dev/null |
                        grep -o "interpreter: [^]]*" | head -1 | cut -d' ' -f2)
            if [ -n "$pf_interp" ]; then
                if img_has "$IMG" "$pf_interp"; then
                    pf_ok "interpreter $pf_interp"
                else
                    pf_bad "init needs $pf_interp and it is not in the image"
                fi
            fi
            pf_miss=0
            for pf_lib in $(readelf -dW "$pf_tmp/init" 2>/dev/null |
                            grep -o "Shared library: [^]]*" | cut -d'[' -f2); do
                img_has "$IMG" "/system/lib64/$pf_lib" && continue
                img_has "$IMG" "/system/lib64/bootstrap/$pf_lib" && continue
                pf_bad "init needs $pf_lib - not in /system/lib64 or bootstrap"
                pf_miss=$((pf_miss+1))
            done
            [ "$pf_miss" = 0 ] && pf_ok "all of init's shared libraries resolve"
        fi
        rm -rf "$pf_tmp"
    else
        pf_bad "/system/bin/init missing from the image"
    fi

    # A staging build boots on Cuttlefish and bootloops on retail hardware,
    # and the only visible difference is three properties.
    pf_bp=$(mktemp)
    debugfs -R "dump /system/build.prop $pf_bp" "$IMG" >/dev/null 2>&1
    if [ -s "$pf_bp" ]; then
        pf_cn=$(grep -m1 "^ro.build.version.codename=" "$pf_bp" | cut -d= -f2)
        pf_ps=$(grep -m1 "^ro.build.version.preview_sdk=" "$pf_bp" | cut -d= -f2)
        if [ "$pf_cn" = REL ] && [ "$pf_ps" = 0 ]; then
            pf_ok "released config (codename=$pf_cn preview_sdk=$pf_ps)"
        else
            pf_bad "staging build (codename=$pf_cn preview_sdk=$pf_ps) - build with
        a released config such as -bp4a-, not -trunk_staging-"
        fi
    else
        pf_warn "could not read build.prop from the image"
    fi
    rm -f "$pf_bp"
    fi   # pf_img_checks

    # --------------------------------------------------------- 2. vbmeta
    #
    # A vbmeta with no descriptors is 4096 bytes of header. Flashing one
    # leaves the bootloader with no boot chain at all: it does not reject
    # the image, it never attempts a boot - 620ms to fastboot, no AVB line
    # in the log, and every slot still marked "boot ok". That looks exactly
    # like a device ignoring you, and it cost a whole night.
    if [ -n "$VBMETA" ]; then
        if [ ! -f "$VBMETA" ]; then
            pf_bad "--vbmeta $VBMETA does not exist"
        elif [ "$(head -c4 "$VBMETA")" != "AVB0" ]; then
            pf_bad "$VBMETA is not an AVB image (no AVB0 magic)"
        else
            # descriptors_size is a big-endian u64 at offset 104; flags is a
            # big-endian u32 at offset 120. See AvbVBMetaImageHeader.
            pf_dsz=$(od -An -tu4 -j108 -N4 --endian=big "$VBMETA" 2>/dev/null | tr -d ' ')
            pf_flg=$(od -An -tu4 -j120 -N4 --endian=big "$VBMETA" 2>/dev/null | tr -d ' ')
            if [ "${pf_dsz:-0}" -gt 0 ]; then
                pf_ok "vbmeta carries $pf_dsz bytes of descriptors"
            else
                pf_bad "vbmeta has NO descriptors - the bootloader will have no boot
        chain and will never attempt a boot. Use the vbmeta.img from the
        factory image, not an empty one."
            fi
            case "${pf_flg:-0}" in
                0) pf_warn "vbmeta flags=0 - verity and verification are ON. Flash it
        with --disable-verity --disable-verification, or a self-built
        system will not match the stock hashtree." ;;
                *) pf_ok "vbmeta flags=$pf_flg (verity/verification bits set)" ;;
            esac
        fi
    else
        pf_warn "no --vbmeta given. Without one the device reports the image as
        corrupt and refuses to boot it."
    fi

    # --------------------------------------------------------- 3. the device
    #
    # The device half is optional on purpose. Every check above reads a
    # file and is worth running on a build machine that has never seen a
    # phone - under WSL that is the normal case, because the platform
    # tools live on the Windows side. Missing adb must not throw away the
    # image checks that already passed.
    ( find_tool adb ADB ) >/dev/null 2>&1 && find_tool adb ADB >/dev/null 2>&1
    pf_have_tools=$?
    if [ "$pf_have_tools" = 0 ]; then
        ( find_tool fastboot FASTBOOT ) >/dev/null 2>&1 &&
            find_tool fastboot FASTBOOT >/dev/null 2>&1
        pf_have_tools=$?
    fi

    # "more than one device/emulator" makes adb get-state fail, and a naive
    # check reads that as NO device - a silent pass on a machine that has
    # one. A running emulator is enough to trigger it. Name the problem.
    if [ "$pf_have_tools" = 0 ] && [ -z "$SERIAL" ]; then
        pf_n=$("$ADB" devices 2>/dev/null | grep -cE "(device|unauthorized)$")
        if [ "${pf_n:-0}" -gt 1 ]; then
            pf_bad "$pf_n devices/emulators are attached, so adb cannot tell which
        one you mean and every device check below would silently report
        nothing. Pass --serial <id>. Attached:
$("$ADB" devices 2>/dev/null | sed -n '2,$p' | sed 's/^/          /')"
        fi
    fi

    if [ "$pf_have_tools" != 0 ]; then
        pf_warn "adb/fastboot not reachable from here - image checks only.
        Run the flash phases from Windows, or pass ADB= and FASTBOOT=."
        pf_dev=skip
    else
        pf_dev=$(device_state)
    fi

    # Never let a check block. fastboot waits forever for a device that is
    # not in fastboot mode, and a preflight that hangs is worse than one
    # that fails - it looks like progress.
    pf_fb() { timeout 15 "$FASTBOOT" ${SERIAL:+-s "$SERIAL"} "$@" 2>&1; }

    case "$pf_dev" in
        skip) ;;
        adb)  pf_warn "the phone is booted in Android, not fastboot, so the device
        checks below cannot run - fastboot would block waiting for it.
        Reboot it first:  adb reboot bootloader" ;;
        none) pf_warn "no device connected - image checks only" ;;
        *)
            pf_gv() { pf_fb getvar "$1" | grep -o "$1: .*" | head -1 | cut -d' ' -f2-; }

            if [ "$(pf_gv unlocked)" = yes ]; then
                pf_ok "bootloader unlocked"
            else
                pf_bad "bootloader is locked - nothing can be flashed"
            fi

            pf_slot=$(pf_gv current-slot)
            [ -n "$pf_slot" ] || pf_slot=a
            info "slot  : $pf_slot"

            # Three failed boots and the bootloader marks the slot unbootable
            # and stops trying. Flashing into that is a guaranteed non-event,
            # and the fix is one command - so say so, rather than let someone
            # spend another twenty minutes on a boot that never happens.
            pf_rc=$(pf_gv "slot-retry-count:$pf_slot")
            pf_ub=$(pf_gv "slot-unbootable:$pf_slot")
            info "retries: ${pf_rc:-?}  unbootable: ${pf_ub:-?}"
            if [ "${pf_rc:-3}" = 0 ] || [ "$pf_ub" = yes ]; then
                pf_bad "slot $pf_slot has no boot attempts left. Reset it with
        fastboot set_active $pf_slot   (that restores the retry count)"
            fi

            # oem ramdump is a bootloader setting that SURVIVES REBOOTS. With
            # it on, a device that fails to boot no longer stops in fastboot -
            # it loops forever and never enumerates on USB, so no command can
            # reach it and the only recovery is holding the power button.
            # Turn it off before flashing, always.
            pf_rd=$(pf_fb oem ramdump | grep -o "ramdump \(enabled\|disabled\)" | head -1)
            case "$pf_rd" in
                *enabled)
                    pf_bad "oem ramdump is ENABLED. A failed boot will loop without ever
        appearing on USB, and will need a hardware rescue. Turn it off:
        fastboot oem ramdump disable" ;;
                *disabled) pf_ok "oem ramdump disabled" ;;
            esac

            # A GSI carries its own /product and /system_ext inside
            # system.img. The device's stock ones stay behind unless they are
            # deleted, and on a Pixel 7a that is 4.1 GB of product and 381 MB
            # of system_ext sitting in super alongside the GSI.
            for pf_p in product system_ext; do
                pf_sz=$(pf_gv "partition-size:${pf_p}_${pf_slot}")
                case "$pf_sz" in
                    ""|0x0|0) pf_ok "${pf_p}_${pf_slot} already cleared" ;;
                    *) pf_warn "${pf_p}_${pf_slot} still holds stock content ($pf_sz). A GSI
        supplies its own. If the boot fails, clear it in fastbootd:
        fastboot delete-logical-partition ${pf_p}_${pf_slot}" ;;
                esac
            done

            # Record what we found, so the phase that changes it can put it
            # back and so a later failure can be compared against a known
            # starting point rather than a memory of one.
            # Where the tree is not writable - running this half from
            # Windows while the tree lives in WSL - fall back rather than
            # claim a file was written that was not.
            pf_st="$TREE/out/device-state-$(date +%Y%m%d-%H%M%S).txt"
            mkdir -p "$(dirname "$pf_st")" 2>/dev/null ||
                pf_st="${TMPDIR:-/tmp}/device-state-$(date +%Y%m%d-%H%M%S).txt"
            if pf_fb getvar all > "$pf_st" 2>/dev/null && [ -s "$pf_st" ]; then
                info "device state saved: $pf_st"
            else
                pf_warn "could not save device state to $pf_st"
            fi
            ;;
    esac

    # --------------------------------------------------------- 4. the control
    #
    # Hold your own image fixed and flash a known-good one instead. If it
    # boots, the device, the boot chain, the vbmeta handling and this whole
    # procedure are proven, and the fault is in your image alone. If it does
    # not, no change to your build was ever going to help. Four minutes
    # either way, and it is the difference between debugging and gambling.
    if [ -n "$CONTROL" ]; then
        [ -f "$CONTROL" ] || die "--control $CONTROL does not exist"
        pf_warn "control run: $CONTROL will be flashed INSTEAD of your image"
        IMG="$CONTROL"
    fi

    if [ "$PF_FAIL" -gt 0 ] && [ "$FORCE_FLASH" != 1 ]; then
        alarm "PREFLIGHT FAILED" "$PF_FAIL blocking problem(s) - nothing flashed"
        die "$PF_FAIL blocking problem(s) above. Nothing has been written to the
  device. Fix them, or re-run with --force-flash to proceed anyway."
    elif [ "$PF_FAIL" -gt 0 ]; then
        pf_warn "$PF_FAIL blocking problem(s), flashing anyway (--force-flash)"
    fi
    pf_ok "preflight clean"
fi

if runs flash; then
    phase "flash"

    find_tool adb  ADB
    find_tool fastboot FASTBOOT

    IMG="${IMG:-$(ls -t "$TREE"/out/target/product/*/system.img 2>/dev/null | head -1)}"
    [ -n "$IMG" ] && [ -f "$IMG" ] || die "no system.img to flash under $TREE/out/target/product/"
    info "image  : $IMG ($(du -h "$IMG" | cut -f1))"

    case "$(device_state)" in
        none) die "no device. Connect it, enable USB debugging, and make sure
  the bootloader is unlocked." ;;
        adb)  info "device in Android - rebooting to userspace fastboot"
              adb_ reboot fastboot >/dev/null 2>&1 || true
              sleep 25 ;;
    esac

    # Must be userspace fastboot. The bootloader's fastboot cannot write a
    # logical partition inside super.
    userspace=$(fb_ getvar is-userspace 2>&1 | grep -oE 'is-userspace: *[a-z]+' | awk '{print $2}')
    if [ "$userspace" != yes ]; then
        info "in bootloader fastboot - rebooting to fastbootd"
        fb_ reboot fastboot >/dev/null 2>&1 || true
        sleep 25
        userspace=$(fb_ getvar is-userspace 2>&1 | grep -oE 'is-userspace: *[a-z]+' | awk '{print $2}')
    fi
    [ "$userspace" = yes ] || die "could not reach userspace fastboot (fastbootd).
  Writing the system partition is impossible from bootloader fastboot."

    slot=$(fb_ getvar current-slot 2>&1 | grep -oE 'current-slot: *[a-z]+' | awk '{print $2}')
    info "slot   : ${slot:-unknown}"
    publish "flashing to slot ${slot:-?} $(date '+%H:%M:%S')"

    # Order matters, and this is Google's, not ours. Erase before writing:
    # the logical partition is resized to fit, and writing over a larger
    # stock system leaves the tail of it behind.
    info "erasing system"
    fb_ erase system 2>&1 | tail -1 | sed 's/^/    /' || true

    info "flashing system"
    fb_ flash system "$IMG" 2>&1 | tail -2 | sed 's/^/    /' ||
        die "fastboot flash system failed"

    # A GSI supplies its own /product and /system_ext inside system.img.
    # The device's stock ones remain in super unless they are deleted - on
    # a Pixel 7a that is 4.1 GB of product that the GSI never asked for.
    if [ "$DELETE_STOCK_PARTS" = 1 ]; then
        for p in product system_ext; do
            info "deleting stock ${p}_${slot:-a}"
            fb_ delete-logical-partition "${p}_${slot:-a}" 2>&1 |
                tail -1 | sed 's/^/    /' || true
        done
    fi

    # vbmeta goes LAST, and from the BOOTLOADER, not fastbootd. It is the
    # root of the boot chain: write it first and the rest of the flash
    # invalidates what it describes.
    #
    # WHICH vbmeta is not settled, and this project has been wrong about it
    # in both directions. From init's own kernel log on one Pixel 7a:
    #
    #   minimal vbmeta (4096 bytes, 624 bytes of descriptors, flags=2)
    #       -> "avb_handle with status: VerificationDisabled"
    #          "AVB HASHTREE disabled on: /system"      -> /system mounted
    #
    #   factory vbmeta + --disable-verity --disable-verification
    #       -> "avb_handle with status: Success", a verity table was built,
    #          "DM_TABLE_LOAD failed ... Argument list too long",
    #          "Failed to mount /system"                -> kernel panic
    #
    # The difference is WHERE the disable bit lives: flags=2 is set inside
    # the file, while the factory vbmeta has flags=0 and relies on fastboot
    # applying --disable-verification, which this device did not honour. The blank one fails differently when the slot's boot
    # chain is incomplete: no boot is attempted at all, 620ms to fastboot,
    # every slot still reported "boot ok".
    #
    # Pass whichever your device needs with --vbmeta, then CHECK the AVB
    # status line in the kernel log rather than believing either story.
    if [ -n "$VBMETA" ] && [ -f "$VBMETA" ]; then
        info "rebooting to bootloader fastboot for vbmeta"
        fb_ reboot bootloader >/dev/null 2>&1 || true
        sleep 22
        info "flashing vbmeta with verity and verification disabled"
        fb_ --disable-verity --disable-verification flash vbmeta "$VBMETA" 2>&1 |
            tail -2 | sed 's/^/    /' || die "vbmeta flash failed"
    else
        note "no --vbmeta given; skipping. A self-built system needs verity"
        note "off, and how to achieve that is device-specific - see the"
        note "comment above this block before choosing one."
    fi

    if [ "$WIPE" = 1 ]; then
        info "wiping userdata - required after changing the boot state"
        fb_ erase userdata >/dev/null 2>&1 || true
        fb_ erase metadata >/dev/null 2>&1 || true
    fi

    info "rebooting"
    fb_ reboot >/dev/null 2>&1 || true
fi

# =================================================================== boot
#
# Done means the OS is running, not that a file exists.
if runs boot; then
    phase "boot"
    find_tool adb ADB

    # Confirm the device answers before settling in to poll. The first
    # version of this waited forty minutes in silence because adb was not
    # reachable at all - which is indistinguishable, from the outside, from
    # a device that is simply slow to boot.
    if ! adb_ devices 2>/dev/null | grep -qE 'device$|recovery$|unauthorized$'; then
        note "no device answering adb yet - it may still be rebooting"
    fi
    deadline=$(( SECONDS + BOOT_TIMEOUT ))
    last_services=0
    stuck_since=$SECONDS

    find_tool fastboot FASTBOOT
    while [ "$SECONDS" -lt "$deadline" ]; do
        # A device that gives up on a slot drops back into BOOTLOADER
        # fastboot. Polling adb will never notice - it looks exactly like a
        # slow boot, and the wait runs the clock out. Check every pass.
        if fb_ devices 2>/dev/null | grep -q fastboot; then
            alarm "DID NOT BOOT - FELL BACK TO FASTBOOT" "$(date '+%Y-%m-%d %H:%M:%S')"
            publish "DID NOT BOOT $(date '+%H:%M:%S') - device sitting in fastboot"
            cat >&2 <<'FELLBACK'
  The bootloader tried the slot, failed, and dropped to fastboot.

  The reason is in the kernel's RAM console right now, and it is fragile:

    - it survives a reboot, NOT a power-off. Do not hold the power button.
    - reading it needs a booted Android, so restoring stock is how you
      read it, not what destroys it.
    - it holds ONE boot. Every extra reboot costs you the one you wanted.

  This works, and it is the fastest route to an actual answer - on
  2026-09-14 it named a verity failure in one line after a night of
  theories. Do it FIRST:

      tools/rescue-log.sh <unzipped-factory-image-dir>

FELLBACK
            # Do it rather than advise it. The log is perishable and every
            # minute spent deciding is a minute it can be lost - a power
            # button pressed to "reset" a stuck USB port erases it.
            if [ -n "$FACTORY" ] && [ -d "$FACTORY" ] &&
               [ -f "$SELF/tools/rescue-log.sh" ]; then
                info "rescuing the kernel log before recovering the device"
                set +e
                OUT="$TREE/out/last_kmsg-$(date +%Y%m%d-%H%M%S).txt" \
                    bash "$SELF/tools/rescue-log.sh" "$FACTORY" "$SERIAL"
                rc=$?
                set -e
                [ "$rc" = 0 ] && publish "log rescued after failed boot $(date '+%H:%M:%S')"
            else
                note "no --factory-image given, so the log cannot be rescued"
                note "automatically. Do it by hand before recovering:"
                note "    tools/rescue-log.sh <unzipped-factory-image-dir>"
            fi
            die "Device did not boot."
        fi

        completed=$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        services=$(adb_ shell service list 2>/dev/null | wc -l)

        if [ "$completed" = 1 ]; then
            info "booted - sys.boot_completed=1, $services services"
            build=$(adb_ shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')
            codename=$(adb_ shell getprop ro.build.version.codename 2>/dev/null | tr -d '\r')
            info "fingerprint: $build"
            publish "BOOTED $(date '+%H:%M:%S') - $services services - $build"
            case "$build" in
                *[Cc]ircle*)
                   alarm "CIRCLEOS IS RUNNING" "$services services, $(date '+%H:%M:%S')" ;;
                *) alarm "BOOTED, BUT NOT CIRCLEOS" "$build"
                   die "The device booted something that is not CircleOS:
  $build
  codename=$codename
  The flash did not take, or it fell back to the other slot." ;;
            esac
            BOOTED=1
            break
        fi

        # A count that climbs is progress; a count that stops for long
        # enough is a hang, and a count that resets is system_server
        # restarting in a loop.
        if [ "$services" -gt "$last_services" ]; then
            last_services=$services
            stuck_since=$SECONDS
        elif [ "$services" -lt "$last_services" ] && [ "$services" -gt 0 ]; then
            note "service count fell $last_services -> $services (system_server restarting)"
            last_services=$services
            stuck_since=$SECONDS
        fi

        if [ $(( SECONDS - stuck_since )) -gt "$BOOT_STALL" ]; then
            alarm "BOOT STALLED" "$services services for $(( (SECONDS - stuck_since) / 60 )) min"
            break
        fi

        printf '  %s%s%s  %d services, %d min elapsed\n' \
               "$DIM" "$(date '+%H:%M:%S')" "$OFF" "$services" \
               $(( (SECONDS - (deadline - BOOT_TIMEOUT)) / 60 ))
        publish "booting - $services services, $(( (SECONDS - (deadline - BOOT_TIMEOUT)) / 60 )) min"
        sleep 30
    done

    if [ "${BOOTED:-0}" != 1 ]; then
        # Get the log BEFORE anything recovers the device. Userspace
        # fastboot runs its own kernel and overwrites the RAM buffer this
        # lives in, so recovering the phone destroys the only explanation.
        alarm "DID NOT BOOT" "$(date '+%Y-%m-%d %H:%M:%S')"
        crash="$TREE/out/last_kmsg-$(date +%Y%m%d-%H%M%S).txt"
        if adb_ get-state >/dev/null 2>&1; then
            note "device is up enough for adb - saving the kernel log first"
            adb_ shell dumpsys dropbox --print SYSTEM_LAST_KMSG > "$crash" 2>/dev/null || true
            [ -s "$crash" ] && info "kernel log saved: $crash"
        else
            note "no adb. The kernel log is in RAM and holds only this boot."
            note "Restore stock and read it - that is the proven route, not a"
            note "last resort:"
            note "  tools/rescue-log.sh <unzipped-factory-image-dir>"
            note "  adb shell dumpsys dropbox --print SYSTEM_LAST_KMSG"
        fi
        publish "DID NOT BOOT $(date '+%H:%M:%S') - ${crash:-no log captured}"
        die "The device did not reach sys.boot_completed within $(( BOOT_TIMEOUT / 60 )) minutes."
    fi
fi

phase "done"
publish "DONE at $(date '+%H:%M:%S') - ${img:-image under $TREE/out/target/product/}"
info "image: ${img:-see $TREE/out/target/product/}"
[ -n "$REFERENCE" ] || note "pass --reference <gsi system.img> to check it against a GSI that boots"
