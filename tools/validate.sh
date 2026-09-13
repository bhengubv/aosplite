#!/usr/bin/env bash
# validate.sh - check this repository's own files before trusting them.
#
#   tools/validate.sh
#
# Three things, each of which has shipped broken here at least once:
#
#   XML        optional-formfactors.xml was not well-formed for months - a
#              rule of hyphens inside a comment, which XML forbids. repo
#              would have refused the file outright, and nothing parsed it
#              to find out.
#   Python     the scripts embed Python in heredocs. Generating those from
#              another script ate backslashes more than once, leaving
#              re.sub(r'//[^  <- literal newline inside a string literal.
#              bash -n cannot see that; only compiling the block can.
#   Shell      bash -n on every script.
#
# Exit 0 = everything parses.

set -eo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SELF"
fail=0

echo "=== shell ==="
for f in tools/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        printf '  ok    %s\n' "$(basename "$f")"
    else
        printf '  FAIL  %s\n' "$(basename "$f")"
        bash -n "$f" 2>&1 | head -3 | sed 's/^/          /'
        fail=$((fail+1))
    fi
done

echo
echo "=== xml ==="
for f in manifests/*.xml; do
    if n=$(python3 -c "
import sys, xml.etree.ElementTree as ET
print(len(ET.parse(sys.argv[1]).getroot().findall('remove-project')))" "$f" 2>/dev/null); then
        printf '  ok    %-34s %s active entries\n' "$(basename "$f")" "$n"
    else
        printf '  FAIL  %s\n' "$(basename "$f")"
        python3 -c "
import sys, xml.etree.ElementTree as ET
ET.parse(sys.argv[1])" "$f" 2>&1 | tail -1 | sed 's/^/          /'
        fail=$((fail+1))
    fi
done

echo
echo "=== embedded python ==="
python3 - "$SELF" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
HEREDOC = re.compile(r"<<'([A-Z_]+)'\n(.*?)\n\1\b", re.S)
bad = 0
for f in sorted(glob.glob(os.path.join(root, "tools", "*.sh"))):
    text = open(f, encoding="utf-8").read()
    for tag, body in HEREDOC.findall(text):
        if tag not in ("PY", "PYEOF", "ENTRIES_PY", "ACTIVE"):
            continue
        try:
            compile(body, "%s:%s" % (f, tag), "exec")
            print("  ok    %-28s %-11s %d lines"
                  % (os.path.basename(f), tag, body.count("\n") + 1))
        except SyntaxError as e:
            print("  FAIL  %-28s %-11s line %s: %s"
                  % (os.path.basename(f), tag, e.lineno, e.msg))
            bad += 1
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || fail=$((fail+1))

echo
echo "=== known-broken patterns ==="
# A lone backslash inside single quotes: what is left after a generator
# ate the escape. tr '\' '/' is the one that actually happened.
if grep -n "tr '\\' " tools/*.sh 2>/dev/null; then
    echo "  FAIL  lone backslash in tr - an escape was eaten"
    fail=$((fail+1))
else
    echo "  ok    no eaten backslashes in tr"
fi

echo
if [ "$fail" -gt 0 ]; then
    echo "$fail problem(s). Fix before trusting anything here."
    exit 1
fi
echo "all files parse."
