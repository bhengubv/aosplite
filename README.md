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
| `products/` | Three optional `lunch` targets: generic, watch, desktop |
| `tools/` | Init, verification, per-release maintenance |
| `docs/RATIONALE.md` | What was cut and why |
| `docs/EMULATOR.md` | Running what you built, on Cuttlefish or raw QEMU |
| `SETUP.md` | Building AOSP from nothing, if you have not before |

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

If you have never built AOSP, start with [SETUP.md](SETUP.md). It covers
host packages, the `repo` tool, disk and RAM requirements, the WSL2
filesystem trap, ccache, and what each common failure means. This
section assumes you are past that.

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

The other two targets are `watch_arm64-trunk_staging-userdebug` and
`desktop_x86_64-trunk_staging-userdebug`. The destination path
`device/aosplite` matters - `watch_arm64.mk` copies a permissions file
from it.

## Running what you built

A `system.img` on disk is not a running system, and getting from one to
the other is the part nobody writes down. Two routes -
[docs/EMULATOR.md](docs/EMULATOR.md) covers both:

- **Cuttlefish** (`lunch aosp_cf_arm64_phone`, then `launch_cvd`) when
  the host and the target are the same architecture and you have KVM.
- **QEMU by hand** when they are not. Slower, entirely manual, and the
  document is mostly the list of things that stop it booting - the
  missing DMA-BUF heap module, a vendor image from the wrong Android
  release, unselected multi-install APEXes, an `odm` symlink loop, and
  four more. Each one hangs the boot with no error.

**The three targets here are system images, not devices.** `launch_cvd`
wants a Cuttlefish product and finds nothing to boot in a `lite_arm64`
output. Building `aosp_cf_arm64_phone` instead is the honest first move -
the prune tiers still apply, because they trim the tree rather than the
product. The gap and the two ways round it are in the emulator document;
what would close it is a `lite_cf_arm64.mk`, which nobody has written.

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
| Watch | partly | No product. Profile and framework support exist - see below. |
| Desktop | partly | No product. Profile and framework support exist - see below. |

Verified against `android-15.0.0_r20` - the Automotive targets are
`gsi_car_*` and `sdk_car_*`; there is no `aosp_car_*`.

`manifests/optional-formfactors.xml` removes the TV and Automotive
product trees for a phone-only tree. It is opt-in, not part of the
numbered tiers, and `tools/init.sh` does not install it.

### Watch and desktop

"Not in AOSP" is the usual summary and it is too blunt. What is missing
is the product, not the support. Verified at `android-15.0.0_r20`:

| | Watch | Desktop |
|---|---|---|
| Hardware profile | `wearable_core_hardware.xml` | `pc_core_hardware.xml` |
| Device type constant | `android.hardware.type.watch` exists in the framework but **nothing declares it** | `android.hardware.type.pc`, declared inline in the profile |
| Windowing | `-watch` resource qualifier, `UI_MODE_TYPE_WATCH` | `android.software.freeform_window_management`, `activities_on_secondary_displays`, `window_extensions.mk` |
| Product makefile | none | none |
| Shell | none | none |

`products/watch_arm64.mk` and `products/desktop_x86_64.mk` supply the
missing product layer. Both are modelled on
`device/google/atv/products/atv_system.mk`, the only worked example in
AOSP of a form factor layered on the shared base.

The watch one also ships
`products/permissions/android.hardware.type.watch.xml`, because AOSP
declares the automotive and PC device types but never the watch type -
no AOSP product is a watch, so nothing had reason to.

What neither supplies is a shell. No watch face, no launcher, no
taskbar, no window chrome. Both will boot and show nothing. That is the
expected result and it is stated in the files. The remaining work is at
the app layer, on a system that runs - which is a different problem from
platform bring-up.

For desktop there is a further limit worth stating plainly:
`desktop_x86_64` targets `generic_x86_64`, so it is an emulator or VM
image. Real PC hardware - storage controllers, GPU, wifi, ACPI, suspend
- is what Android-x86 and Bliss OS exist for and none of it is in
AOSP.

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

### Four that look cuttable and are not

These sit in test and sample directories, so they read as obvious prunes.
Each one stops the build dead. All four are commented out in the tiers
rather than deleted, with the reason next to them:

| Project | What depends on it |
|---|---|
| `platform/cts` | defines `cts_defaults` and `mts-target-sdk-version-current`, used by the CTS directories that ship *inside* `packages/modules/*` - DeviceLock, Connectivity, Profiling, Uwb |
| `platform/test/app_compat/csuite` | defines the `csuite_test` Soong module type, used by `frameworks/base/libs/WindowManager/Shell/tests/flicker/pip` and `art/test` |
| `platform/test/vts-testcase/hal` | `trusty/vendor/google/aosp` needs its `trusty_dirgroup_test_vts-testcase_hal_treble_vintf_aidl` dirgroup |
| `device/sample` | `device/sample/etc/apns-full-conf.xml` is copied to `system/etc/apns-conf.xml` by the product config |

The pattern is the same each time: a project whose *name* says "test"
defines something the non-test tree consumes. Restoring all four costs
about 2.4 GB, almost all of it `cts`.

### A pruned tree needs ALLOW_MISSING_DEPENDENCIES

Even with those four restored, Soong panics rather than skipping modules
whose dependencies were pruned - `system/sepolicy/build/soong/validate_bindings.go`
does this explicitly:

```go
if !ctx.OtherModuleExists(fuzzer) && !ctx.Config().AllowMissingDependencies() {
    panic(fmt.Errorf("Fuzzer doesn't exist : %s", fuzzer))
}
```

So export it before building:

```bash
export ALLOW_MISSING_DEPENDENCIES=true
```

`tools/build.sh` sets it, along with the other environment this tree
needs. Use that rather than setting things by hand:

```bash
tools/build.sh circle_arm64-bp4a-userdebug systemimage
```

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

**Verified on a second branch:** `repo init` and `repo sync` complete
against `android-16.0.0_r4`. This needed a fix - see *Branch
portability* below.

**Now verified:** a tree has been synced with all five tiers applied on
`android-16.0.0_r4` - 111 GB, 29 minutes on an 8-thread laptop - and
Soong analysis completes against it in about 20 minutes. Getting there
needed the four restorations under *Do not cut* and
`ALLOW_MISSING_DEPENDENCIES=true`.

**Still not verified:** `products/lite_arm64.mk` has never been booted,
and no build has been carried through to a flashed image from these
targets specifically. The size figures for the individual tiers remain
estimates.

**Verified separately:** the QEMU path in
[docs/EMULATOR.md](docs/EMULATOR.md), on a different tree - an arm64 GSI
booting to `sys.boot_completed=1` against a Cuttlefish vendor of the same
release, under TCG on an x86-64 host. That says the emulator procedure
works. It says nothing about the targets in this repository, which remain
unbuilt.

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

## Branch portability

The tiers were written against `android-15.0.0_r20`. Projects come and go
between releases, and `repo` treats a `remove-project` naming a project
that is not in the manifest as a fatal error:

```
error: in `sync`: remove-project element specifies non-existent project:
<remove-project name="platform/test/vts-testcase/hal-trace"/>
```

That is one dead entry stopping an entire sync. Every `remove-project` in
this repository therefore carries `optional="true"`, which tells `repo` to
skip an entry it cannot resolve instead of aborting:

```xml
<remove-project name="platform/test/vts-testcase/hal-trace" optional="true"/>
```

The tiers now apply to any branch. Entries that do not exist on your
branch are ignored; the rest still prune. `tools/verify-manifest.sh
--tag <branch>` tells you how many resolved, so a silently-skipped entry
is still countable rather than invisible.
