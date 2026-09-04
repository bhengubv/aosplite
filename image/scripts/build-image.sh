#!/usr/bin/env bash
#
# build-image.sh - turn myandroid.yml into a flashable Android system image.
#
# No AOSP checkout, no Soong, no 250 GB. It downloads a prebuilt system
# image, mounts it, applies the changes described in the config, and
# writes the result out.
#
# Runs on any Linux with root. Designed to run in GitHub Actions so that
# nobody needs a machine of their own.
#
#   sudo ./build-image.sh ../myandroid.yml out/
#
set -euo pipefail

CONFIG="${1:?usage: build-image.sh <config.yml> <outdir>}"
OUTDIR="${2:-out}"
WORK="$(mktemp -d)"
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"

cleanup() {
    if mountpoint -q "$WORK/mnt" 2>/dev/null; then
        sudo umount "$WORK/mnt" || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '\n=== %s\n' "$*"; }

# ---------------------------------------------------------------------
# Read the config
# ---------------------------------------------------------------------
say "Reading $CONFIG"

python3 - "$CONFIG" "$WORK" <<'PYEOF'
import sys, json
cfg_path, work = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is not installed. pip install pyyaml")
with open(cfg_path) as f:
    cfg = yaml.safe_load(f) or {}

for required in ("name", "base"):
    if not cfg.get(required):
        sys.exit("config error: '%s' is required in %s" % (required, cfg_path))

with open(work + "/cfg.json", "w") as f:
    json.dump(cfg, f)

print("  name:       %s" % cfg["name"])
print("  base:       %s" % cfg["base"])
print("  properties: %d" % len(cfg.get("properties") or {}))
print("  remove:     %d" % len(cfg.get("remove") or []))
print("  add:        %d" % len(cfg.get("add") or []))
PYEOF

NAME=$(python3 -c "import json;print(json.load(open('$WORK/cfg.json'))['name'])")
BASE=$(python3 -c "import json;print(json.load(open('$WORK/cfg.json'))['base'])")

# ---------------------------------------------------------------------
# Fetch the base image
# ---------------------------------------------------------------------
say "Downloading base image"
echo "  $BASE"
curl -fL --retry 3 --progress-bar -o "$WORK/system.img" "$BASE"
ls -lh "$WORK/system.img" | awk '{print "  got " $5}'

# A prebuilt Android system image is either a raw ext4 filesystem or an
# Android sparse image. Sparse ones start with the magic 3aff26ed and
# have to be expanded before they can be mounted.
MAGIC=$(head -c4 "$WORK/system.img" | xxd -p)
if [ "$MAGIC" = "3aff26ed" ]; then
    say "Sparse image - expanding"
    simg2img "$WORK/system.img" "$WORK/raw.img"
    mv "$WORK/raw.img" "$WORK/system.img"
else
    echo "  raw ext4 already, no conversion needed"
fi

# ---------------------------------------------------------------------
# Make room, then mount
# ---------------------------------------------------------------------
# A system image is sized to its contents with little slack. Adding an
# app to a full filesystem fails with ENOSPC, so grow it first. 512 MB
# of headroom costs nothing - the image is resized back down at the end.
say "Growing the filesystem for headroom"
CUR=$(stat -c%s "$WORK/system.img")
truncate -s $((CUR + 512*1024*1024)) "$WORK/system.img"
e2fsck -fy "$WORK/system.img" >/dev/null 2>&1 || true
resize2fs "$WORK/system.img" >/dev/null
df_before=$(stat -c%s "$WORK/system.img")
echo "  $((CUR/1024/1024)) MB -> $((df_before/1024/1024)) MB"

# An AOSP system image is not an ordinary ext4 filesystem. It is built
# to be read-only forever, and two features enforce that:
#
#   shared_blocks   identical blocks across different files point at the
#                   same physical block. It makes the image smaller and
#                   it makes the filesystem unwritable - the kernel
#                   refuses a rw mount outright.
#
#   read-only       a superblock flag saying exactly what it says.
#
# Both can be cleared. e2fsck -E unshare_blocks walks the filesystem and
# gives every shared block its own copy, which is why the image had to be
# grown first - un-sharing needs somewhere to put the copies.
say "Clearing read-only filesystem features"
echo "  features before:"
dumpe2fs -h "$WORK/system.img" 2>/dev/null | grep -i "^Filesystem features" | sed 's/^/    /'

e2fsck -E unshare_blocks -fy "$WORK/system.img" >/dev/null 2>&1 || true
tune2fs -O ^read-only "$WORK/system.img" >/dev/null 2>&1 || true
e2fsck -fy "$WORK/system.img" >/dev/null 2>&1 || true

echo "  features after:"
dumpe2fs -h "$WORK/system.img" 2>/dev/null | grep -i "^Filesystem features" | sed 's/^/    /'

say "Mounting"
mkdir -p "$WORK/mnt"
if ! sudo mount -t ext4 -o loop,rw "$WORK/system.img" "$WORK/mnt"; then
    echo "error: mount failed. Superblock detail follows." >&2
    dumpe2fs -h "$WORK/system.img" >&2 2>/dev/null || true
    exit 1
fi

# Two layouts exist. On some images the mount point is the root of the
# system partition and build.prop sits at ./build.prop. On others the
# partition contains a system/ directory and everything lives under it.
# Detect rather than assume.
if [ -f "$WORK/mnt/build.prop" ]; then
    SYS="$WORK/mnt"
elif [ -f "$WORK/mnt/system/build.prop" ]; then
    SYS="$WORK/mnt/system"
else
    echo "error: no build.prop found at either layout. Contents:" >&2
    ls "$WORK/mnt" >&2
    exit 1
fi
echo "  system root: ${SYS#$WORK/}"

# ---------------------------------------------------------------------
# Show what is in there, so the config can be written against reality
# ---------------------------------------------------------------------
say "Apps in this image"
for d in app priv-app product/app product/priv-app system_ext/app system_ext/priv-app; do
    [ -d "$SYS/$d" ] || continue
    printf '  %s/\n' "$d"
    ls "$SYS/$d" 2>/dev/null | sed 's/^/    /'
done

# ---------------------------------------------------------------------
# Apply the config
# ---------------------------------------------------------------------
say "Applying properties"
python3 - "$WORK/cfg.json" "$SYS/build.prop" <<'PYEOF'
import json, sys, time
cfg = json.load(open(sys.argv[1]))
props = cfg.get("properties") or {}
target = sys.argv[2]

# ro.* properties are read-only and the first definition wins, so a
# duplicate appended at the end is silently ignored. Replace in place
# where the key already exists, append only where it does not.
lines = open(target).read().splitlines()
existing = {}
for i, line in enumerate(lines):
    if "=" in line and not line.startswith("#"):
        existing[line.split("=", 1)[0]] = i

added = replaced = 0
for k, v in props.items():
    entry = "%s=%s" % (k, v)
    if k in existing:
        lines[existing[k]] = entry
        replaced += 1
    else:
        lines.append(entry)
        added += 1

stamp = "ro.build.display.id=%s-%s" % (cfg["name"], time.strftime("%Y%m%d"))
if "ro.build.display.id" in existing:
    lines[existing["ro.build.display.id"]] = stamp
else:
    lines.append(stamp)

open(target, "w").write("\n".join(lines) + "\n")
print("  %d replaced, %d added" % (replaced, added))
print("  ro.build.display.id=%s-%s" % (cfg["name"], time.strftime("%Y%m%d")))
PYEOF

say "Removing apps"
python3 -c "
import json;print('\n'.join(json.load(open('$WORK/cfg.json')).get('remove') or []))
" > "$WORK/remove.txt"
if [ -s "$WORK/remove.txt" ]; then
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        found=0
        for d in app priv-app product/app product/priv-app system_ext/app system_ext/priv-app; do
            if [ -d "$SYS/$d/$app" ]; then
                sudo rm -rf "$SYS/$d/$app"
                echo "  removed $d/$app"
                found=1
            fi
        done
        [ $found -eq 1 ] || echo "  not found: $app (see the app list above)"
    done < "$WORK/remove.txt"
else
    echo "  nothing to remove"
fi

say "Adding apps"
python3 -c "
import json;print('\n'.join(json.load(open('$WORK/cfg.json')).get('add') or []))
" > "$WORK/add.txt"
if [ -s "$WORK/add.txt" ]; then
    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
        src="$CONFIG_DIR/apps/$apk"
        if [ ! -f "$src" ]; then
            echo "  missing: image/apps/$apk" >&2
            exit 1
        fi
        base=$(basename "$apk" .apk)
        sudo mkdir -p "$SYS/app/$base"
        sudo cp "$src" "$SYS/app/$base/$base.apk"
        sudo chmod 644 "$SYS/app/$base/$base.apk"
        echo "  added app/$base"
    done < "$WORK/add.txt"
else
    echo "  nothing to add"
fi

# ---------------------------------------------------------------------
# Close up
# ---------------------------------------------------------------------
say "Unmounting and shrinking"
sudo umount "$WORK/mnt"
e2fsck -fy "$WORK/system.img" >/dev/null 2>&1 || true
resize2fs -M "$WORK/system.img" >/dev/null
e2fsck -fy "$WORK/system.img" >/dev/null 2>&1 || true

mkdir -p "$OUTDIR"
OUT="$OUTDIR/system-$(echo "$NAME" | tr 'A-Z ' 'a-z-').img"
mv "$WORK/system.img" "$OUT"

say "Done"
ls -lh "$OUT" | awk '{print "  " $9 "  " $5}'

# The image is modified, so it no longer matches the verified-boot
# hashes it shipped with. Flashing it requires an unlocked bootloader
# and a vbmeta flashed with verification disabled. Booting it in an
# emulator requires neither, which is why that is the path we test.
echo
echo "  This image is modified, so Android verified boot will reject it"
echo "  unless verification is disabled. Boot it in an emulator first."
