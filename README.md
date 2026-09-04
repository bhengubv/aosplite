# AOSPLite

A maintained debloat of the Android Open Source Project.

AOSP is about 250 GB to check out and takes hours to build. A large part
of that is weight you will never ship: git history, host toolchains for
operating systems you do not use, compliance test suites, device trees
for silicon you do not own, sample code, IDE tooling.

Trimming it is not difficult. It is just tedious, undocumented, and
everybody does it again from scratch. This repository is that work,
written down.

No promises. Use it, or don't.

## What it holds

| | |
|---|---|
| `manifests/` | Five prune tiers as repo local manifests |
| `products/` | An optional trimmed `lunch` target |
| `tools/` | Init, verification, per-release maintenance |
| `docs/` | What was cut and why |

The manifests and the product are independent. Take the prune list and
bring your own product config, or take the product and prune nothing.

## Sizes

| | |
|---|---|
| AOSP, full sync | ~250 GB |
| Shallow sync, no prune | ~120 GB |
| Shallow sync, all five tiers | ~75 GB |

Approximate, and they move with each release.

## Use

```
git clone https://github.com/<you>/aosplite
aosplite/tools/init.sh ~/android android-15.0.0_r20
cd ~/android
repo sync -c -j4 --no-clone-bundle --prune
```

Half the saving is the shallow init and needs no manifest at all:

```
repo init -u https://android.googlesource.com/platform/manifest \
  -b android-15.0.0_r20 --depth=1 --no-tags
```

Then, if you want the trimmed target:

```
cp -r aosplite/products device/aosplite
source build/envsetup.sh
lunch lite_arm64-trunk_staging-userdebug
m systemimage
```

## Tiers

Apply one at a time. Run `m nothing` between them - it runs the whole
configuration and analysis pass without compiling anything, so a broken
prune surfaces in minutes rather than hours.

| Tier | Cut | Saves | Risk |
|---|---|---|---|
| 1 | Test suites - CTS, VTS, MLTS | ~10 GB | very low |
| 2 | Darwin toolchains, superseded JDKs | ~15 GB | low |
| 3 | Other vendors' hardware | ~10 GB | low |
| 4 | Stock applications | ~3 GB | medium |
| 5 | Samples, SDK, IDE tooling, AndroidX | ~8 GB | medium |

Tier 3 is target-specific. Every line removes support for a board or a
vendor's HAL, so edit it for hardware you actually flash.

Tier 4 is a two-part change: remove the project *and* the module from
`PRODUCT_PACKAGES`, or the build fails looking for something that is no
longer there.

## The silent failure

`<remove-project>` naming a project that does not exist does nothing.
No error, no warning, no saving. Project names move between releases, so
a prune list that worked last year can quietly stop working.

```
tools/verify-manifest.sh /path/to/aosplite/manifests
```

Run from the root of a synced tree. Anything reported MISSING is a dead
line.

## Maintenance

One branch per AOSP release. Keeping a branch current is:

```
tools/manifest-diff.sh old-default.xml new-default.xml
```

New projects arrive included by default, which is the safe direction but
means bloat returns unless someone looks. Removed projects leave dead
entries behind. Then build, and see whether it still boots.

## Do not cut

Load-bearing. Removing any of these breaks the build:

`build/*` · `frameworks/base` · `frameworks/native` · `system/*` ·
`bionic` · `art` · `libcore` · `dalvik` · `packages/modules/*` ·
`prebuilts/clang/host/linux-x86` · `prebuilts/build-tools` ·
`prebuilts/jdk/jdk21` · `prebuilts/sdk` · most of `external/*` ·
`tools/metalava` unless API checks are also disabled

## Two things this does not do

**It does not shrink the compile.** Pruning cuts disk and analysis time.
Build time is governed by the product config - what gets inherited and
therefore built. `products/lite_arm64.mk` is the lever for that, and it
is a separate job from the manifests.

**It is not a mirror.** Every manifest here points at Google's servers.
The Apache 2.0 licence on AOSP is irrevocable for code already
published, but a licence is a right to sue, not a copy of the source. If
you depend on a release, mirror it yourself:

```
repo init --mirror -u https://android.googlesource.com/platform/manifest
```

## Status

Nothing here has been verified end to end. The prune tiers are derived
from the structure of the AOSP manifest, not from a completed build, and
`products/lite_arm64.mk` has never been booted. Treat every size figure
as an estimate and every claim as untested until you test it.

Corrections welcome. Promises are not made.

## Licence

Apache 2.0, matching AOSP.
