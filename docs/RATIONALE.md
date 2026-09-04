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
Google's compatibility program. They are not inputs to a build and not
present on a device.

If you intend to pursue GMS certification, you need them back. Nothing
else depends on them.

## Tier 2 - host toolchains for other operating systems

AOSP carries prebuilt Clang, Go and GCC headers for macOS hosts, plus
several superseded JDKs, so that the same tree builds on any developer's
machine. On a Linux builder they are inert.

`prebuilts/clang/host/linux-x86` is the actual compiler and is not in
this tier. `prebuilts/jdk/jdk21` is the JDK the build uses.

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

A GSI target needs none of them - it relies on the vendor partition
already on the device.

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

## What is not cut, and will not be

Load-bearing in the sense that the build stops without them:

`build/*` is Soong and Kati themselves. `frameworks/base` is the
framework. `system/*` is init, netd, vold, sepolicy. `art`, `bionic`,
`libcore`, `dalvik` are the runtime. `packages/modules/*` are the
mainline modules that ship as APEX. `external/*` is overwhelmingly
required - it is where the third-party libraries live.

`tools/metalava` is the API surface checker. It can be dropped if API
checks are disabled too, but not on its own.

## The floor

Trimming reaches a limit. A booting Android needs `framework.jar`,
libcore and ART, and those are a monolith by design. No arrangement of
manifests makes them smaller.

What the tiers change is everything around that floor, which is most of
what you are currently downloading and a good share of what you are
currently compiling.
