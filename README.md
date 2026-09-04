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
| `manifests/` | Five prune tiers, plus one opt-in extra |
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

| Tier | Cut | Entries | Saves | Risk |
|---|---|---|---|---|
| 1 | Test suites and harnesses - CTS, VTS, MTS, TradeFed | 27 | ~12 GB | very low |
| 2 | Darwin toolchains, JDK 8, mingw cross-compiler | 5 | ~12 GB | low |
| 3 | Device trees, vendor HALs, device kernels | 73 | ~14 GB | low |
| 4 | Stock applications | 11 | ~3 GB | medium |
| 5 | Samples, SDK packaging, emulator, app tooling | 14 | ~8 GB | medium |

Tier 3 is target-specific. Every line removes support for a board or a
vendor's HAL, so edit it for hardware you actually flash. Cuttlefish is
left in - it is how you boot-test without hardware.

Tier 4 is a two-part change: remove the project *and* the module from
`PRODUCT_PACKAGES`, or the build fails looking for something that is no
longer there.

## Form factors

The tiers do not touch form-factor support. AOSP ships product trees for
TV and Automotive alongside handheld, and all of them stay:

| Form factor | In AOSP 15 | Targets |
|---|---|---|
| Handheld, tablet | yes | `aosp_arm64`, `handheld_system.mk`, `large_screen_common.mk` |
| TV | yes | `aosp_tv_arm64`, `aosp_tv_x86`, `gsi_tv_*`, `sdk_atv*` |
| Automotive | yes | `gsi_car_arm64`, `gsi_car_x86_64`, `sdk_car_*` |
| Watch | **no** | Wear OS is proprietary. No AOSP product. |
| Desktop | **no** | No product target. |

Verified against `android-15.0.0_r20` - the Automotive targets are
`gsi_car_*` and `sdk_car_*`; there is no `aosp_car_*`.

`manifests/optional-formfactors.xml` removes the TV and Automotive
product trees for a phone-only tree. It is opt-in, not part of the
numbered tiers, and `tools/init.sh` does not install it.

Worth knowing if you intend to add a form factor AOSP does not ship: the
`atv_*` stack in `device/google/atv/products` is the only worked example
of one layered cleanly on `base_system`. `atv_system.mk` sits beside
`handheld_system.mk` and does the same job for a different device class.
That is the template to copy.

## The silent failure

`<remove-project>` naming a project that does not exist does nothing.
No error, no warning, no saving. Project names move between releases, so
a prune list that worked last year can quietly stop working.

```
tools/verify-manifest.sh --tag android-15.0.0_r20
```

That fetches the release manifest from googlesource and needs no tree at
all. From the root of a synced tree, run it with no arguments to check
against `.repo/manifests/default.xml`. Anything reported MISSING is a
dead line.

All 133 entries in this repository - 130 across the five tiers, 3 in the
optional file - are verified against `android-15.0.0_r20`: 1,035 real
projects, 0 dead.

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

**Verified:** every project name resolves against the real
`android-15.0.0_r20` manifest. 133 entries, 0 dead. Re-checkable in
seconds with the command above.

**Not verified:** no tree has been synced with these tiers applied, no
build has been run, and `products/lite_arm64.mk` has never been booted.
The size figures are estimates, not measurements.

So the names are known good and the outcome is not. Corrections welcome.
Promises are not made.

### Two things worth knowing before you look for them

Android Studio (`tools/adt/idea`, `tools/base`) and AndroidX
(`frameworks/support`) are **not in the AOSP platform manifest**. They
live in separate manifests, so there is nothing to cut - they were never
downloaded.

`platform/development` is deliberately not pruned. It holds host tooling
that parts of the build reference, and removing it produces a confusing
failure rather than a saving.

## Licence

Apache 2.0, matching AOSP.
