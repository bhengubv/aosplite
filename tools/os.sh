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
#   build    and if it fails, read the log, match it against the failures
#            below, apply the fix, and try again
#   verify   the built image against a reference GSI, before you flash it
#
# The retry loop is the point. A pruned AOSP tree reports missing projects
# one per build, hours apart, because ALLOW_MISSING_DEPENDENCIES turns a
# missing dependency into a runtime "echo ... && false". Seven projects
# were found that way over two days. The table at the bottom of this file
# turns each of those into something the script handles by itself.
#
# Every entry in that table is a build that actually died. Add to it when
# one dies in a new way.

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
AUTO_FIX=0                 # opt in; a failure stops the build by default
REPORT_EVERY=1200          # seconds between progress lines during a build
STATUS_DIR=""              # where to publish status; auto-detected on WSL
PHASES="doctor sync check build verify"

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
  --phases "a b c"       run only these: doctor sync check build verify
  --retries N            default 8
  --report-every SECS    progress line during a build, default 1200 (20 min)
  --auto-fix             on a recognised failure, restore the project and
                         retry. Off by default: a failure stops the build
                         and says what it is, because a retry loop that
                         guesses wrong is worse than one that stops

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
        --phases) PHASES="$2"; shift ;;
        --retries) MAX_RETRIES="$2"; shift ;;
        --report-every) REPORT_EVERY="$2"; shift ;;
        --auto-fix) AUTO_FIX=1 ;;
        --status-dir) STATUS_DIR="$2"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

[ -n "$MODE" ] || { echo "choose --lite or --aosp" >&2; usage 1; }
[ -n "$PRODUCT" ] || PRODUCT=$([ "$MODE" = lite ] && echo lite_arm64 || echo aosp_arm64)
LUNCH="$PRODUCT-$RELEASE-$VARIANT"
LOG="$TREE/out/os-sh.log"

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
    # the terminal, a line in STATUS.txt on the Windows side, and a dialog
    # on the desktop. A phase that fails quietly is how hours get lost - a
    # build died here at 00:58 and was found at 05:47.
    local msg="$1" code="${2:-1}" first
    first=$(printf '%s' "$msg" | head -1 | cut -c1-120)
    alarm "FAILED in ${PHASE_NAME:-os.sh}" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '  %s\n' "$msg" >&2
    publish "FAILED ${PHASE_NAME:-os.sh} $(date '+%H:%M:%S') - $first"
    popup "AOSP build FAILED" "$(date '+%H:%M')  ${PHASE_NAME:-os.sh}: $first"
    exit "$code"
}

runs() { case " $PHASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------ publishing
#
# A report that only exists in a log nobody is tailing is not a report.
# Under WSL the Windows side of the machine is the place a person actually
# looks, so status is written there and a failure raises a dialog box.
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

popup() {
    # A dialog on the Windows desktop. Failure and completion only -
    # anything more frequent gets dismissed without being read.
    command -v powershell.exe >/dev/null 2>&1 || return 0
    local title body
    title=$(printf '%s' "$1" | tr -d "'")
    body=$(printf '%s' "$2" | tr -d "'")
    powershell.exe -NoProfile -Command \
        "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('$body','$title') | Out-Null" \
        >/dev/null 2>&1 &
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
fi

# ================================================================== check
if runs check && [ "$MODE" = lite ]; then
    phase "check"
    blocked=0
    for c in preflight check-modules; do
        s="$SELF/tools/$c.sh"
        [ -f "$s" ] || die "tools/$c.sh missing - refusing to build unchecked" 2
        info "$c.sh"
        set +e
        # preflight takes the product so it can tell a makefile this
        # build reads from another device's.
        if [ "$c" = preflight ]; then
            out=$(bash "$s" "$TREE" "$PRODUCT" 2>&1); rc=$?
        else
            out=$(bash "$s" "$TREE" 2>&1); rc=$?
        fi
        set -e
        case "$rc" in
            0) note "  clean" ;;
            1) blocked=1; echo "$out" | sed -n '/ACT ON THESE/,/^$/p;/BLOCKING/,/^$/p' | sed 's/^/  /' ;;
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
    local log="$1"
    local s errs

    # Only look at failure context. Scanning the whole log matches
    # successful work: a line like
    #   [3% 4703/154564] //prebuilts/gradle-plugin:metalava-gradle-plugin-deps
    # names a module that built fine, and matching on it restored a project
    # that was never missing while the real failure went unread.
    errs=$(mktemp)
    grep -A3 -E "^FAILED:|^error:|^ninja: error" "$log" > "$errs" 2>/dev/null || true
    grep -E "missing dependencies|unrecognized module type|no known rule to make"         "$log" >> "$errs" 2>/dev/null || true
    log="$errs"

    # A missing Soong module type. Fails during analysis, so it is cheap
    # to hit but stops everything.
    if grep -q 'unrecognized module type "csuite_test"' "$log"; then
        echo "platform/test/app_compat/csuite"; return 0; fi

    # Missing defaults blocks. cts_defaults and mts-target-sdk-version-current
    # are defined in platform/cts and used by the tests/cts directories that
    # ship inside packages/modules/*.
    if grep -qE 'undefined module "(cts_defaults|mts-target-sdk-version-current)"' "$log"; then
        echo "platform/cts"; return 0; fi

    # trusty needs a dirgroup defined in the vts hal tests.
    if grep -q 'trusty_dirgroup_test_vts-testcase_hal' "$log"; then
        echo "platform/test/vts-testcase/hal"; return 0; fi

    # A PRODUCT_COPY_FILES source. Fails at packaging, after everything has
    # compiled, which makes it the most expensive of these to hit.
    if grep -q "device/sample/etc/apns-full-conf.xml.*missing" "$log"; then
        echo "device/sample"; return 0; fi

    # guava compiles against jdk8 even though the build runs on jdk21.
    if grep -q 'prebuilts/jdk/jdk8/linux-x86/jre/lib/\(rt\|jce\)\.jar' "$log"; then
        echo "platform/prebuilts/jdk/jdk8"; return 0; fi

    if grep -q 'metalava-gradle-plugin-deps' "$log"; then
        echo "platform/prebuilts/gradle-plugin"; return 0; fi

    if grep -q 'missing dependencies: lint_api' "$log"; then
        echo "platform/prebuilts/cmdline-tools"; return 0; fi

    if grep -qE 'missing dependencies:.*glide-(prebuilt|gifdecoder|disklrucache)' "$log"; then
        echo "platform/prebuilts/maven_repo/bumptech"; return 0; fi

    # Launcher3 provides an aconfig flags library that frameworks/base
    # links against - services/core and the WindowManager Shell both do -
    # so pruning the launcher breaks the framework, not just the launcher.
    if grep -q 'com_android_launcher3_flags_lib' "$log"; then
        echo "platform/packages/apps/Launcher3"; return 0; fi

    # Generic fallback: Soong names the module, and for a great many of
    # them the project is the module's own directory. Only used when
    # nothing above matched.
    s=$(grep -oE 'depends on undefined module "[^"]+"' "$log" | head -1 |
        sed 's/.*"\(.*\)"/\1/') || true
    if [ -n "$s" ]; then
        echo "UNKNOWN:$s"; return 0
    fi
    s=$(grep -oE 'module [A-Za-z0-9_.-]+ missing dependencies: [^ ]+' "$log" |
        head -1 | awk '{print $NF}') || true
    [ -n "$s" ] && { echo "UNKNOWN:$s"; return 0; }
    return 1
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
        popup "AOSP build FAILED" "$(date '+%H:%M') attempt $attempt. ${first_err:-see log}"

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
                die "Missing module '${project#UNKNOWN:}', and this script does not
  know which project provides it. Find it upstream, comment the
  remove-project entry out in the relevant manifest, run
  'repo sync -c -j$JOBS --no-clone-bundle <project>', then add a rule to
  fix_for_signature() in $(basename "${BASH_SOURCE[0]}") so the next person
  does not have to.
  Log: $LOG" ;;
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

phase "done"
publish "DONE at $(date '+%H:%M:%S') - ${img:-image under $TREE/out/target/product/}"
popup "AOSP build finished" "$(date '+%H:%M')  ${img:-see $TREE/out/target/product/}"
info "image: ${img:-see $TREE/out/target/product/}"
[ -n "$REFERENCE" ] || note "pass --reference <gsi system.img> to check it against a GSI that boots"
