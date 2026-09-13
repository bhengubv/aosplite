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
PHASES="doctor sync check build verify flash boot"
VBMETA=""                  # blank vbmeta to flash with verification off
WIPE=1                     # required after changing the boot state
SERIAL=""                  # adb/fastboot serial, if more than one device
BOOT_TIMEOUT=2400          # 40 min; a first boot on a wiped device is slow
BOOT_STALL=900             # 15 min with no new service = hung

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
                         flash boot
  --vbmeta IMG           blank vbmeta, flashed with verification disabled.
                         Without it a device refuses a self-built image
  --serial S             adb/fastboot serial, if more than one device
  --no-wipe              skip erasing userdata (it will usually not boot)
  --boot-timeout SECS    default 2400
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
        --phases) PHASES="$2"; shift ;;
        --retries) MAX_RETRIES="$2"; shift ;;
        --report-every) REPORT_EVERY="$2"; shift ;;
        --auto-fix) AUTO_FIX=1 ;;
        --no-auto-fix) AUTO_FIX=0 ;;
        --status-dir) STATUS_DIR="$2"; shift ;;
        --vbmeta) VBMETA="$2"; shift ;;
        --serial) SERIAL="$2"; shift ;;
        --no-wipe) WIPE=0 ;;
        --boot-timeout) BOOT_TIMEOUT="$2"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

[ -n "$MODE" ] || { echo "choose --lite or --aosp" >&2; usage 1; }
[ -n "$PRODUCT" ] || PRODUCT=$([ "$MODE" = lite ] && echo lite_arm64 || echo aosp_arm64)
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
        up=$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '
')
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

    info "flashing system"
    fb_ flash system "$IMG" 2>&1 | tail -2 | sed 's/^/    /' ||
        die "fastboot flash system failed"

    if [ -n "$VBMETA" ] && [ -f "$VBMETA" ]; then
        info "flashing vbmeta with verification disabled"
        fb_ --disable-verity --disable-verification flash vbmeta "$VBMETA" 2>&1 |
            tail -2 | sed 's/^/    /' || die "vbmeta flash failed"
    else
        note "no --vbmeta given; skipping. Without a blank vbmeta the device"
        note "will refuse a self-built image as corrupt."
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

    while [ "$SECONDS" -lt "$deadline" ]; do
        completed=$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        services=$(adb_ shell service list 2>/dev/null | wc -l)

        if [ "$completed" = 1 ]; then
            info "booted - sys.boot_completed=1, $services services"
            build=$(adb_ shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')
            codename=$(adb_ shell getprop ro.build.version.codename 2>/dev/null | tr -d '\r')
            info "fingerprint: $build"
            publish "BOOTED $(date '+%H:%M:%S') - $services services - $build"
            case "$build" in
                *[Cc]ircle*) popup "CircleOS is running" "$(date '+%H:%M')  $services services
$build" ;;
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
            note "no adb. The kernel log is in RAM and will be destroyed by"
            note "the userspace fastboot needed to recover the device. Read it"
            note "first if you can: boot a known-good image, then"
            note "  adb shell dumpsys dropbox --print SYSTEM_LAST_KMSG"
        fi
        publish "DID NOT BOOT $(date '+%H:%M:%S') - ${crash:-no log captured}"
        popup "CircleOS did not boot" "$(date '+%H:%M')  See $crash"
        die "The device did not reach sys.boot_completed within $(( BOOT_TIMEOUT / 60 )) minutes."
    fi
fi

phase "done"
publish "DONE at $(date '+%H:%M:%S') - ${img:-image under $TREE/out/target/product/}"
popup "AOSP build finished" "$(date '+%H:%M')  ${img:-see $TREE/out/target/product/}"
info "image: ${img:-see $TREE/out/target/product/}"
[ -n "$REFERENCE" ] || note "pass --reference <gsi system.img> to check it against a GSI that boots"
