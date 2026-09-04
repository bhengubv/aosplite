# AOSPLite

No promises. Use it, or don't.

**Nothing here has been built or booted**, except the image pipeline,
which has run green end to end. Everything else is written from the AOSP
manifest and verified against it, not from a completed build. Read that
sentence again before spending a day on any of it.

## What is here

| | |
|---|---|
| `image/` | Edit a YAML file, get a modified Android system image. Runs in CI. **Works.** |
| `manifests/` | Five prune tiers - cut an AOSP checkout from ~250 GB to ~75 GB |
| `products/` | Watch and desktop `lunch` targets, which AOSP does not ship |
| `tools/verify-manifest.sh` | Checks prune entries resolve against a real AOSP manifest |
| `SETUP.md` | Building AOSP from nothing, for someone who never has |

## image/ - the part that works

Edit `image/myandroid.yml`, commit, and GitHub Actions produces a
modified Android system image. No AOSP checkout, no build machine, no
250 GB.

```yaml
name: MyAndroid
base: <url to a prebuilt system image>
properties:
  ro.myandroid.owner: Jimmy
remove:
  - Browser2
add: []
```

Verified in CI on `android-15.0.0_r20`: the image downloads, the
read-only filesystem features are cleared, properties land in
`build.prop`, the named app is deleted, and the result is repacked and
uploaded. About three minutes.

**It is not a build.** It edits a prebuilt binary someone else compiled.
That distinction matters and is not glossed here.

**It has not been booted.** The base is arm64, and booting arm64 on an
x86 runner needs full CPU emulation, which is too slow for CI. A boot
test needs an x86_64 base.

## manifests/ - pruning a source checkout

For the full-source path. Five tiers, applied one at a time.

| Tier | Cut | Entries | Saves |
|---|---|---|---|
| 1 | Test suites and harnesses | 27 | ~12 GB |
| 2 | Darwin toolchains, JDK 8, mingw | 5 | ~12 GB |
| 3 | Device trees, vendor HALs, device kernels | 73 | ~14 GB |
| 4 | Stock applications | 11 | ~3 GB |
| 5 | Samples, SDK, emulator, app tooling | 14 | ~8 GB |

Half the total saving needs no manifest at all - it is just not
downloading git history:

```
repo init -u https://android.googlesource.com/platform/manifest \
  -b android-15.0.0_r20 --depth=1 --no-tags
repo sync -c --no-clone-bundle --prune
```

Copy a tier into `.repo/local_manifests/`, sync, then run `m nothing`
before the next one. If `m nothing` fails, that tier removed something
load-bearing.

Tier 3 is target-specific - every line removes support for real
hardware. Edit it for the device you flash. Tier 4 is a two-part change:
remove the project **and** the module from `PRODUCT_PACKAGES`, or the
build fails late looking for something that is gone.

### The silent failure

A `<remove-project>` naming a project that does not exist does nothing.
No error, no saving. Project names move between releases.

```
tools/verify-manifest.sh --tag android-15.0.0_r20
```

All 130 entries verified against that tag: 1,035 real projects, 0 dead.

### Do not cut

`build/*` · `frameworks/base` · `frameworks/native` · `system/*` ·
`bionic` · `art` · `libcore` · `dalvik` · `packages/modules/*` ·
`prebuilts/clang/host/linux-x86` · `prebuilts/build-tools` ·
`prebuilts/jdk/jdk21` · `prebuilts/sdk` · most of `external/*` ·
`tools/metalava` unless API checks are disabled too

## products/ - watch and desktop

AOSP ships no watch or desktop product. It does ship most of what one
needs, which is usually reported as it shipping nothing.

Verified at `android-15.0.0_r20`:

| | Watch | Desktop |
|---|---|---|
| Hardware profile | `wearable_core_hardware.xml` | `pc_core_hardware.xml` |
| Device type | constant exists, **nothing declares it** | `android.hardware.type.pc`, inline |
| Windowing | `-watch` qualifier, `UI_MODE_TYPE_WATCH` | freeform, secondary displays |
| Product makefile | none | none |
| Shell | none | none |

`watch_arm64.mk` and `desktop_x86_64.mk` supply the product layer, both
modelled on `device/google/atv/products/atv_system.mk` - the only worked
example in AOSP of a form factor layered on the shared base.

`products/permissions/android.hardware.type.watch.xml` exists because
AOSP declares the automotive and PC device types but never the watch
type. No AOSP product is a watch, so nothing had reason to.

Neither supplies a shell. Both will boot to nothing. Neither has been
built.

## What this does not do

Pruning shrinks disk and analysis time, not compile time. Build time is
governed by the product config.

Every manifest here points at Google's servers. Apache 2.0 is
irrevocable for code already published, but a licence is a right to sue,
not a copy of the source. If you depend on a release, mirror it:

```
repo init --mirror -u https://android.googlesource.com/platform/manifest
```

## Licence

Apache 2.0, matching AOSP.
