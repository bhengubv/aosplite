# From nothing to a booted device

A single walk-through: clone, sync, check, build, verify, flash, confirm
the device booted — and what to do when it does not.

Every command here has been run. Every failure described is one that
actually happened, with the message it actually produced. Where a step
looks paranoid, it is because skipping it cost hours.

**Before you start**, if you have never built AOSP: read
[SETUP.md](../SETUP.md) first. It covers host packages, the `repo` tool,
disk and RAM, the WSL2 filesystem trap, and ccache. This tutorial assumes
you are past that.

---

## First: which image are you building?

There are two, they are not the same thing, and the difference is not
branding. Decide now, because it changes steps 1 through 3. Steps 4
onward are identical.

| | **AOSPLite** | **Circle OS** |
|---|---|---|
| What it is | Plain AOSP, trimmed. No Google, no vendor payload, no house style | A product built on AOSPLite: its own apps, launcher, theme, fonts, permissions and microG |
| Repos needed | this one | this one **and** [`CircleOS`](https://github.com/bhengubv/CircleOS) plus the `CircleOS_*` projects |
| Product | `lite_arm64` | `circle_arm64` |
| Form factor | **neutral** — `handheld_system_ext` and telephony are dropped | handheld |
| Booted on real hardware? | **no — see the warning below** | yes: Pixel 7a, 2026-09-14 |

### If you build AOSPLite, know what you get

`lite_arm64` keeps `core_64_bit.mk` and `generic_system.mk` and drops
`handheld_system_ext.mk`, `telephony_system_ext.mk` and
`aosp_product.mk`. What remains is form-factor-neutral — it is the layer
TV, Wear, Automotive and handheld all sit on.

That means **no launcher, no dialer, no phone UX**. It boots; there is
not much to look at. That is deliberate: it is a base to build a product
on, not a product. If you want a usable handheld out of the box, either
build upstream `aosp_arm64` or add the handheld inherits back.

> **`lite_arm64` has never been flashed to a device.** The mechanics in
> this tutorial — the checks, the build wrapper, the vbmeta, the flash
> order, the log recovery — are all verified, but they were verified by
> building and booting Circle OS's `circle_arm64` from a tree pruned by
> these tiers. The procedure is proven. This particular target is not.
> If you boot it, corrections are welcome.

Substitute your product name for `<product>` throughout.

---

## What it costs

| | |
|---|---|
| Disk | ~75 GB synced with all five tiers, plus ~80 GB of build output |
| RAM | 16 GB works; `soong_build` peaks around 22 GB resident, so give it swap |
| Time, first build | 3–6 hours on 8 threads |
| Time, incremental | 8–20 minutes |
| Time, sync | ~30 minutes on a fast link |

---

## 1. Get a tree

Both paths start the same way:

```bash
git clone https://github.com/<you>/aosplite
aosplite/tools/init.sh ~/android android-16.0.0_r4
cd ~/android
```

`init.sh` runs `repo init` and installs the five prune tiers into
`.repo/local_manifests/`. Any release tag works.

### AOSPLite — sync and add the products

```bash
repo sync -c -j$(nproc) --no-clone-bundle --prune
cp -r aosplite/products device/aosplite
```

### Circle OS — add the overlay manifest first

Circle OS is assembled from separate repositories that sync into fixed
paths in the same tree. Add its manifest alongside the prune tiers, then
sync once:

```bash
curl -o .repo/local_manifests/circle.xml \
     https://raw.githubusercontent.com/bhengubv/CircleOS/main/manifests/circle.xml
repo sync -c -j$(nproc) --no-clone-bundle --prune
```

That brings in `vendor/circle`, `build/circle`, `device/circle/*` and
`packages/apps/CircleLauncher`. The full inventory, and the things in it
that are not what they look like, are in
[CircleOS/docs/WHERE_EVERYTHING_LIVES.md](https://github.com/bhengubv/CircleOS/blob/main/docs/WHERE_EVERYTHING_LIVES.md).

Do **not** delete upstream `frameworks/base` to make room for a Circle
fork. Older instructions said to; the fork is not in use and removing the
upstream project breaks the tree.

### Either way, a pruned tree needs one environment variable

```bash
export ALLOW_MISSING_DEPENDENCIES=true
```

Without it Soong panics on a fuzzer or test module that references a
pruned project, rather than skipping it. `tools/build.sh` sets this for
you; if you run `m` by hand, you need it.

---

## 2. Check the tree *before* you spend a build

```bash
aosplite/tools/check-product.sh ~/android <product>
```

This is the cheapest step in the whole document and it catches four
faults that are otherwise expensive:

| Check | What it costs you if you skip it |
|---|---|
| Duplicated VNDK versions | A successful build, a flash, and a kernel panic four minutes into boot |
| A privileged app with no allowlist entry | A successful build, a flash, and a boot loop on the boot animation |
| A stray file in a `res/` directory | A build that fails at packaging, after all the compile time |
| Malformed XML in a `res/` directory | The same, with an error that names line 0 and no tag |

It ends with a verdict:

```
== summary ==
  0 blocking, 0 advisory
```

**Anything other than `0 blocking` means stop.** The first two faults
produce an image that builds cleanly and reports success. The device is
where you find out, and by then you have spent hours.

Checks 1, 3 and 4 read the source and run in seconds. Check 2 reads the
built APKs under `out/target/product/<device>/system`, so on a tree that
has never been built it has nothing to look at yet — run it again after
the first build.

Both faults check 1 and 2 catch came from a product carrying its own apps
and overlays. A bare AOSPLite build has no privileged apps of its own and
is unlikely to trip either. Run it anyway; it costs seconds.

---

## 3. Build

```bash
# AOSPLite
aosplite/tools/build.sh lite_arm64-bp4a-userdebug systemimage

# Circle OS
aosplite/tools/build.sh circle_arm64-bp4a-userdebug systemimage
```

`build.sh` fixes the environment in a file rather than in your shell
history, which is the only reason it exists.

On a pruned tree it also runs three checks first and refuses to build if
one fails: `check-env` (is the lunch config a release config, does the
make target build anything), `preflight` (is the tree in a state that can
build) and `check-modules`.

**`check-product.sh` is not one of them.** It takes a product argument
that `build.sh` does not pass, so you must run it yourself — which is why
it is step 2 above, rather than something you can assume happened.

### The release config is not optional

`bp4a` is a released release-config. Build `trunk_staging` instead and
you get an image that declares itself pre-release:

```
ro.build.version.codename=Baklava
ro.build.version.preview_sdk=1
ro.llndk.api_level=202604
```

It will not boot on a released device, and patching those three
properties inside the finished image does not help — the libraries
underneath are still staging builds. Confirm the release config took by
reading the build header:

```
PLATFORM_VERSION_CODENAME=REL
PLATFORM_VERSION=16
```

`REL`, not a codename.

### Where the image lands

Under `PRODUCT_DEVICE`, which is often not the product name. Both
products here build `generic_arm64`:

```
out/target/product/generic_arm64/system.img
```

### Do not change ccache mid-tree

Turning `USE_CCACHE` on or off changes `CC_WRAPPER`, which changes every
C++ compile command, which makes ninja rebuild all ~100,000 of them.
Whatever `out/` was built with, keep it. This turned a 90-minute build
into a 28-hour one once.

---

> **Everything from here is the same for both products.**

---

## 4. Read the image before you flash it

A build reporting success tells you the compiler was happy. It says
nothing about whether the thing boots. Two minutes here is cheaper than a
flash-and-fail cycle.

```bash
debugfs -R "dump /system/build.prop /tmp/bp" \
        out/target/product/generic_arm64/system.img
grep -E "codename|preview_sdk|llndk" /tmp/bp
```

Expect `REL`, `0`, `202504`. If you see `Baklava`, `1`, `202604`, you
built `trunk_staging` — go back to step 3.

`debugfs -R "ls -l /system/etc/permissions"` and friends will tell you
whether what you think you added is actually in the image. It is worth
asking: "is the overlay I wrote actually in here" has a different answer
from "did the build succeed" more often than you would like.

---

## 5. Get a vbmeta that actually disables verification

**This is the step that costs people a night.**

A GSI's `/system` cannot match the vbmeta already on the device, which
describes the stock system. Verification has to be off, or `/system`
never mounts and init dies.

The trap: `fastboot --disable-verity --disable-verification` **did not
take effect** on a Pixel 7a. AVB reported success and a verity table was
built anyway:

```
avb_handle with status: Success
DM_TABLE_LOAD failed ... Argument list too long
```

`/system` never mounted; init died; the device looped. The flags were
passed and ignored.

**Put the bits in the file instead.** Build a vbmeta whose header carries
`VERIFICATION_DISABLED`:

```bash
python3 external/avb/avbtool.py make_vbmeta_image \
        --flags 2 --padding_size 4096 --output ~/vbmeta-disabled.img
```

Flag bit 1 (value 2) is `AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED`.
Read it back before trusting it — offset 120, four bytes, big-endian:

```bash
python3 - ~/vbmeta-disabled.img <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
flags = struct.unpack(">I", b[120:124])[0]
print("magic:", b[:4].decode(), "flags:", flags,
      "verification_disabled:", bool((flags >> 1) & 1))
PY
```

`flash-preflight.sh` checks this for you and reports what it finds. It
reports rather than judges: a blank vbmeta is what produced a working
mount on this device, but it fails differently if the slot's boot chain
is incomplete — no boot is attempted at all.

---

## 6. Flash

```bash
aosplite/tools/flash.sh \
    --img    out/target/product/generic_arm64/system.img \
    --vbmeta ~/vbmeta-disabled.img \
    --serial <your serial>
```

Preflight always runs. There is no flag to skip it — only `--force`,
which is recorded in the log and printed in the summary. **If preflight
reports a blocking problem, nothing is written to the device.**

The script exists because every flash used to be typed by hand: the order
changed between attempts, the vbmeta changed between attempts, preflight
got skipped when it was late, and nothing was written down. A failure
then became an argument instead of a datapoint.

### The order, and why it is this order

1. **reboot to fastbootd** — the bootloader cannot write a logical partition
2. **erase system** — the partition is resized to fit; writing over a larger one leaves its tail behind
3. **flash system**
4. *(optional)* delete stock `product` / `system_ext` — a GSI carries its own
5. **reboot to bootloader** — vbmeta is written from here, not fastbootd
6. **flash vbmeta — last.** It is the root of the boot chain; writing it first means the rest of the flash invalidates what it describes
7. **wipe userdata and metadata** — required once the boot state changes
8. **`set_active` + reboot** — restores the slot's retry count

### On Windows

`fastboot` cannot see a device from inside WSL2 — there is no USB
passthrough, and it simply reports "no device". But `debugfs`, which the
image checks need, is not in Git Bash. So `flash.sh` runs the image half
through WSL and the device half natively, and **both must pass**.

Pass paths in Windows form (`C:/path/...`). A Git Bash path like
`/c/path/...` works for the WSL half but Windows `fastboot.exe` cannot
open it:

```
fastboot: error: cannot load '/c/Development/circle-flash/system.img':
          No such file or directory
```

If you hit that *after* the erase step, the device has no system
partition. It is not bricked — it is still in fastbootd. Fix the path and
run the same command again.

---

## 7. Confirm it actually booted

`flash.sh` waits and prints a verdict. Do not stop there — check the
device:

```bash
adb shell getprop sys.boot_completed     # 1
adb shell service list | wc -l           # a few hundred
adb logcat -d -b crash | tail            # empty
adb shell getprop ro.build.fingerprint   # yours, not the stock one
```

`sys.boot_completed` reads empty for a while during a first boot after a
wipe. An empty answer thirty seconds in means "not yet", not "failed" —
wait and ask again before concluding anything.

On an AOSPLite image, expect a booted system with no home screen. That is
the product, not a fault. `sys.boot_completed=1` and a populated service
list are the success criteria there.

---

## 8. When it does not boot

**Read the log before you do anything else.** This is the rule that gets
broken most and costs most.

Userspace fastboot runs its own kernel and overwrites the RAM buffer the
crash log lives in. Rebooting to recovery, re-flashing, or restoring the
factory image **destroys the evidence**. The device sitting in a boot
loop is the most informative state it will ever be in.

```bash
aosplite/tools/rescue-log.sh [factory-image-dir] [serial]
```

Both arguments are positional and optional.

If the device reaches Android at all, the previous boot's kernel log
survives a reboot (not a power-off) in pstore:

```bash
adb shell dumpsys dropbox --print SYSTEM_LAST_KMSG
```

### What the common failures look like

| What you see | What it is |
|---|---|
| `Kernel panic - not syncing: trusty crashed` about four minutes in | Duplicated VNDK versions. `libvintf` rejected the whole system_ext manifest, servicemanager had no framework manifest, keystore2 could not reach KeyMint. Check 1 catches this. |
| Boot animation forever, nothing else wrong | A privileged app with no allowlist entry. `system_server` threw `IllegalStateException` at `systemReady()`. Check 2 catches this. |
| `DM_TABLE_LOAD failed`, `/system` never mounts | Verification was not actually disabled. See step 5. |
| No boot attempted at all, no log | The boot chain is incomplete — often a vbmeta problem rather than a system-image problem. |
| `avc: denied` around a class init does not know | The vendor's SELinux policy references a class the GSI's policy lacks. Reproduce it offline by running init's own `secilc` command against the device's policy files; the error names the class. |

### Do not enable ramdump to "get more information"

`fastboot oem ramdump enable` made this device loop without enumerating
USB at all, which cost two hardware rescues. `flash-preflight.sh` now
blocks on it.

---

## The shortest honest summary

```bash
# check-product is the one you have to remember; build.sh does not run it
aosplite/tools/check-product.sh ~/android <product>     # before building
aosplite/tools/build.sh <product>-bp4a-userdebug systemimage
aosplite/tools/check-product.sh ~/android <product>     # again, now APKs exist
aosplite/tools/flash.sh --img <image> --vbmeta <vbmeta flags=2> --serial <serial>
adb shell getprop sys.boot_completed
```

A clean preflight is not a promise that the image boots. It means the
failures these scripts know about are absent — which is a smaller claim,
and the only one worth making.
