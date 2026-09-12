# What was cut, and why

Every tier below is a judgement call about what an Android platform
build actually consumes. Where a cut is conditional, that is said
plainly rather than buried.

## Tier 0 - git history

Not a cut at all, and the largest single saving. Roughly half of a full
`repo sync` is history for a thousand repositories you are going to
build once.

```
repo init ... --depth=1 --no-tags
repo sync -c --no-clone-bundle --prune
```

`--depth=1` takes one commit per project, `-c` takes only the current
branch, `--no-tags` skips every release tag ever cut. Costs nothing,
needs no manifest, and it is the difference between 250 GB and 120 GB.

The trade is that you cannot `git log`, bisect, or cherry-pick across
history in the AOSP repos. For a build tree that is usually fine. For a
tree you intend to develop AOSP itself in, it is not.

## Tier 1 - test suites

CTS, VTS, MLTS, csuite, catbox. These exist to certify a build against
Google's compatibility program, and the suites themselves are neither
inputs to a build nor present on a device.

**"Nothing else depends on them" was wrong**, and it was the most
expensive sentence in this document. Three of these projects define
things the non-test tree consumes, and removing them stops the build:

| Project | What it defines | Who needs it |
|---|---|---|
| `platform/cts` | `cts_defaults`, `mts-target-sdk-version-current` | the `tests/cts` directories that ship *inside* `packages/modules/*` - DeviceLock, Connectivity, Profiling, Uwb |
| `test/app_compat/csuite` | the `csuite_test` Soong module type | `frameworks/base/libs/WindowManager/Shell/tests/flicker/pip`, `art/test` |
| `test/vts-testcase/hal` | the `trusty_dirgroup_test_vts-testcase_hal_treble_vintf_aidl` dirgroup | `trusty/vendor/google/aosp` |

All three are commented out in the tier rather than removed. The
mechanism is worth understanding because it recurs: a project whose
*name* says test defines a Soong primitive - a defaults block, a module
type, a dirgroup - and Soong parses every `Android.bp` in the tree
regardless of what you are building.

If you intend to pursue GMS certification, you need the suites
themselves back too.

## Tier 2 - host toolchains for other operating systems

AOSP carries prebuilt Clang, Go and GCC headers for macOS hosts so that
the same tree builds on any developer's machine. On a Linux builder those
are inert.

`prebuilts/clang/host/linux-x86` is the actual compiler and is not in
this tier. `prebuilts/jdk/jdk21` is the JDK the build runs on.

**The superseded JDKs are not inert.** `prebuilts/jdk/jdk8` was in this
tier on the reasoning that the build uses jdk21. It does - but
`external/guava` *compiles against* jdk8:

```
module guava-both missing dependencies:
prebuilts/jdk/jdk8/linux-x86/jre/lib/jce.jar,
prebuilts/jdk/jdk8/linux-x86/jre/lib/rt.jar
```

Which JDK runs the build and which JDKs modules compile against are
different questions. jdk8 is commented out in the tier now.

## Tier 3 - other vendors' hardware

Device trees and vendor HALs for boards you do not own. This is the one
tier that cannot be applied blind: every line removes support for real
hardware, and one of them may be yours.

Known pairings:

| Device | Needs |
|---|---|
| Pixel 6 / 6 Pro | `device/google/raviole`, `gs101` |
| Pixel 7 / 7 Pro | `device/google/pantah`, `gs201` |
| Qualcomm-based | `hardware/qcom/*` |

A GSI target needs none of these *device trees* - it relies on the vendor
partition already on the device.

It does need `device/sample`, which is in this tier and is not a device
tree at all. `device/sample/etc/apns-full-conf.xml` is copied to
`system/etc/apns-conf.xml` by the product configuration, so removing it
stops the build at packaging:

```
ninja: 'device/sample/etc/apns-full-conf.xml', needed by
'out/target/product/generic_arm64/system/etc/apns-conf.xml',
missing and no known rule to make it
```

Commented out in the tier now.

**Most of this tier is dead on newer branches.** Checked against
`android-16.0.0_r4`, 46 of its 72 entries name projects that no longer
exist under those names, so they prune nothing. The saving quoted for
this tier was measured on `android-15.0.0_r20`. Run
`tools/verify-manifest.sh` against your own branch before believing any
figure here.

## Tier 4 - stock applications

Dialer, Contacts, Calendar, Camera, Gallery, Launcher3 and the rest.
Removable only if your product config does not ask for them.

This is the one tier where the removal is not the hard part. Dropping
the project while `PRODUCT_PACKAGES` still names the module produces a
missing-module failure late in the build. Change both.

## Tier 5 - tooling, samples, AndroidX

`tools/adt/idea` and `tools/base` are Android Studio. `platform/sdk` is
SDK packaging. `developers/*` is sample code. `frameworks/support` is
AndroidX source - platform builds consume AndroidX as prebuilts, not
from this tree.

If you build applications out of the platform tree rather than only the
platform, some of this comes back.

Three entries had to come back regardless, and none of them is obviously
"tooling":

| Project | What it supplies | Who needs it |
|---|---|---|
| `prebuilts/gradle-plugin` | `metalava-gradle-plugin-deps` | `tools/metalava`, which is already on the do-not-cut list |
| `prebuilts/cmdline-tools` | `lint_api` | `tools/lint_checks`, and the `lint/` directories under `packages/modules/*` |
| `prebuilts/maven_repo/bumptech` | `glide-prebuilt` and friends | `packages/apps/DocumentsUI`, `packages/apps/WallpaperPicker2` - both ship in a system image |

The last one was caught by `tools/check-modules.sh` before it broke a
build. The other two were not.

## What is not cut, and will not be

Load-bearing in the sense that the build stops without them:

`build/*` is Soong and Kati themselves. `frameworks/base` is the
framework. `system/*` is init, netd, vold, sepolicy. `art`, `bionic`,
`libcore`, `dalvik` are the runtime. `packages/modules/*` are the
mainline modules that ship as APEX. `external/*` is overwhelmingly
required - it is where the third-party libraries live.

`tools/metalava` is the API surface checker. It can be dropped if API
checks are disabled too, but not on its own.

## How a wrong cut presents

Every mistake above shares one shape: something in the surviving tree
names something in the pruned project. What differs is *when* you are
told, and the expensive cases are the late ones.

| Named thing | When it fails | Example |
|---|---|---|
| A Soong **module type** | analysis, ~20 min in | `unrecognized module type "csuite_test"` |
| A Soong **defaults** block | analysis | `depends on undefined module "cts_defaults"` |
| A **module** | when that module is built - possibly hours in | `module metalava missing dependencies: metalava-gradle-plugin-deps` |
| A **file path** | at packaging, after everything compiles | `missing and no known rule to make it` |

The last two are late because a pruned tree has to set
`ALLOW_MISSING_DEPENDENCIES=true` - without it Soong panics on the first
missing fuzzer rather than reporting anything. With it, each missing
dependency becomes a runtime `echo ... && false`. So the build tells you
about exactly one per run, and you find them one at a time, hours apart.
That is how seven of the eight above were found.

Do not work that way. `tools/preflight.sh` and `tools/check-modules.sh`
read the build files directly and list the whole class in about four
minutes each.

## The floor

Trimming reaches a limit. A booting Android needs `framework.jar`,
libcore and ART, and those are a monolith by design. No arrangement of
manifests makes them smaller.

What the tiers change is everything around that floor, which is most of
what you are currently downloading and a good share of what you are
currently compiling.
