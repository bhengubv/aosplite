# Setting up an AOSP build from nothing

Written for someone who has never built Android. It assumes you can use
a terminal and nothing else.

Every step says what it does, roughly how long it takes, and what it
looks like when it goes wrong. Where a number comes from Google it is
marked; where it is an estimate it is marked as one.

---

## Before you start: the numbers

Google's stated requirements for building AOSP:

| | |
|---|---|
| CPU | 64-bit x86 |
| RAM | 64 GB |
| Disk | 400 GB free - 250 GB checkout, 150 GB build |
| OS | Any 64-bit Linux with glibc 2.17 or later |

macOS is not supported. Google ended it in June 2021, at Android 11.

Those are recommendations, not hard gates. Builds do complete on less.
What actually happens below them:

| Shortfall | What you get |
|---|---|
| Under 64 GB RAM | Linking and `javac` swap. A build that takes 2 hours takes 10. |
| Under 16 GB RAM | Link steps get OOM-killed. Reduce `-j` and it may still fail. |
| Under 400 GB disk | The build fills the disk and dies partway. See below. |
| Few cores | Time scales close to linearly. 4 cores is a long day. |

**Disk is the one that ruins your afternoon.** Running out at hour 12
leaves you with no image, no usable `out/`, and nothing cached. Check
before you start, not after:

```bash
df -h .
```

The tiers in this repository bring the checkout down to roughly 75 GB,
which changes the total to something nearer 225 GB. Estimates, not
measurements.

---

## If you are on Windows: read this first

AOSP builds under WSL2. It builds badly if you put the tree in the wrong
place, and this catches almost everyone once.

**The tree must live inside the WSL filesystem**, at something like
`~/android`. It must not live under `/mnt/c/...`.

Anything under `/mnt/c` is reached through a filesystem translation
layer. AOSP touches a million files. The overhead is not a small tax; it
is the difference between a build that finishes and one you abandon.

```bash
# right
cd ~ && mkdir android
```

```bash
# wrong, and it will not be obvious why it is so slow
cd /mnt/c/Development && mkdir android
```

Two more WSL specifics:

**Memory.** WSL2 takes a fraction of host RAM by default. Set it
explicitly in `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=24GB
processors=8
swap=64GB
```

Then `wsl --shutdown` from PowerShell and reopen.

Size those two numbers deliberately:

- `memory` should leave Windows several gigabytes. On a 32 GB host, 24 GB
  is about the ceiling. Taking more makes the whole machine swap.
- `swap` is not the afterthought it looks like. `soong_build` reads every
  build file in the tree in one process and was measured at **22 GB
  resident** on a pruned Android 16 tree. With 16 GB of swap it reached
  11 GB used during analysis alone, before a single file was compiled.
  64 GB costs nothing but disk.

Measured on an 8-thread laptop: analysis completes in about 20 minutes.
The same analysis on a 4-core server took 2 hours 20 minutes, so this is
worth getting right.

**Do not let the machine sleep.** Suspending sends `SIGTERM` to
`soong_ui`:

```
00:58:31 Got signal: terminated
00:58:35 soong bootstrap failed with: signal: killed
```

The build is dead and nothing says so until you look. On a laptop, plug it
in and set sleep to never for the duration - closing the lid is enough to
lose several hours of work.

**Disk.** The WSL virtual disk grows but does not shrink. Deleting files
inside WSL frees space for the build; it does not give the space back to
Windows. If your C: drive is filling up, that is a separate cleanup
involving `wsl --shutdown` and compacting the vhdx.

---

## 1. Host packages

Ubuntu 18.04 or later. Google's list:

```bash
sudo apt-get update
```

```bash
sudo apt-get install git-core gnupg flex bison build-essential zip curl zlib1g-dev libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig
```

Also useful, not in Google's list:

```bash
sudo apt-get install ccache python3 rsync
```

You do not need to install a JDK, Python or Make for the build itself.
AOSP ships its own prebuilt copies and uses those regardless of what is
on your system. This surprises people who spend an afternoon installing
the right Java version first.

Time: a few minutes.

---

## 2. The repo tool

`repo` is a Python wrapper around git. AOSP is not one repository but
about a thousand, and `repo` is what clones and updates them together
from a manifest.

```bash
sudo apt-get install repo
```

```bash
repo version
```

If your distribution has no `repo` package, install it manually. Google
publishes the launcher and its signing key at
<https://source.android.com/docs/setup/download>. Follow that page
rather than a copy of it - the key matters, and copies go stale.

You need repo launcher 2.4 or later.

---

## 3. Git identity

`repo` refuses to sync without one.

```bash
git config --global user.name "Your Name"
```

```bash
git config --global user.email "you@example.com"
```

---

## 4. Initialise the tree

```bash
mkdir -p ~/android && cd ~/android
```

```bash
repo init -u https://android.googlesource.com/platform/manifest -b android-15.0.0_r20 --depth=1 --no-tags
```

If you use a different release tag, that is fine. The prune tiers carry
`optional="true"` on every `remove-project`, so entries that do not exist
on your branch are skipped instead of stopping the sync with:

```
error: remove-project element specifies non-existent project
```

```bash
```

What the flags do, since they are half the saving in this repository:

| Flag | Effect |
|---|---|
| `-b android-15.0.0_r20` | A specific release. Without it you get `main`, which moves under you. |
| `--depth=1` | One commit per project instead of full history. |
| `--no-tags` | Skips every release tag ever cut across a thousand repos. |

Together those take the checkout from about 250 GB to about 120 GB, and
they cost nothing except the ability to `git log` inside AOSP projects.

Time: under a minute. This only fetches the manifest.

### Install the prune tiers

```bash
mkdir -p .repo/local_manifests
```

```bash
cp /path/to/aosplite/manifests/prune-tier1-tests.xml .repo/local_manifests/
```

Add one tier at a time. Tier 1 is the safe one to start with. Tier 3
removes hardware support and **must be edited for your target device**
before you use it - read the comment at the top of the file.

Check the entries resolve before syncing:

```bash
/path/to/aosplite/tools/verify-manifest.sh --tag android-15.0.0_r20
```

A `<remove-project>` naming something that does not exist does nothing
at all, silently. That check is the only thing that tells you.

---

## 5. Sync

```bash
repo sync -c -j4 --no-clone-bundle --prune
```

| Flag | Effect |
|---|---|
| `-c` | Current branch only. |
| `-j4` | Four parallel fetches. Raise it on a fast connection; lower it if the server starts refusing you. |
| `--no-clone-bundle` | Skips a bundle step that tends to be slower than plain fetching. |
| `--prune` | Drops remote branches that no longer exist. |

**Time: hours.** On a 100 Mbit connection, expect 2-4 hours for a
shallow sync. It is bandwidth-bound, not CPU-bound.

**It will fail partway at some point.** That is normal - a thousand
repositories, one flaky fetch. Run the same command again and it
resumes.

If a single project is persistently broken, delete its directory and
sync just that path:

```bash
repo sync -c path/to/that/project
```

---

## 6. ccache

Optional, and worth it if you will build more than once.

From `build/make/core/ccache.mk`: AOSP stopped shipping a ccache
prebuilt, and if you want ccache you set `USE_CCACHE` **and** point
`CCACHE_EXEC` at your own binary. Setting `USE_CCACHE=1` alone - which
most older guides still tell you to do - does nothing.

```bash
export USE_CCACHE=1
export CCACHE_EXEC=$(which ccache)
export CCACHE_DIR=~/.ccache
ccache -M 50G
```

Put those in `~/.bashrc` so they survive a new shell, and put
`CCACHE_DIR` on a fast disk.

Size it properly. At the 5 GB default the cache evicts itself partway
through a build and you get the cost with none of the benefit. 50 GB is
a reasonable floor for AOSP.

**Decide once, then never change it.** `USE_CCACHE` controls
`CC_WRAPPER`, which is prepended to every C++ compile command. Turning it
on - or off - rewrites all of them, and ninja correctly concludes that
every object in `out/` is stale:

```
ninja explain: command line changed for .../bionic/libc/.../android_mallopt.o
```

On a full tree that is roughly 100,000 actions. A 90-minute incremental
becomes a full rebuild measured in days, and Soong re-reads the whole tree
first because its analysis is cached against the environment too. Whatever
your existing `out/` was built with, leave the setting alone.

**What ccache does not do:** it caches compiles, not links, and it is
invalidated wholesale when the compiler changes. A `repo sync` that
pulls a new Clang prebuilt resets your hit rate to zero, legitimately.
That is not a misconfiguration, and no amount of tuning avoids it.

Check whether it is actually working:

```bash
ccache -z
```

Build something, then:

```bash
ccache -s
```

Hits should dominate on a second build of the same thing. If they do
not, the cache is not being consulted at all - check `CCACHE_EXEC`.

---

## 6b. Preflight, if you pruned the tree

Skip this if you synced the full manifest. If you applied the tiers in
this repository, run both checks before starting a build - each takes
about two minutes, and each one you skip is potentially hours lost:

```bash
tools/preflight.sh ~/android
```

```bash
tools/check-modules.sh ~/android
```

```bash
tools/build.sh <lunch-target> nothing
```

The first finds build files that name paths inside pruned projects. The
second finds module names nothing in the tree defines. The third runs
Soong's own analysis and stops before compiling, which is the only thing
that catches a missing *module type* such as `csuite_test`.

Anything they flag, you fix by un-pruning: comment the `remove-project`
entry out in the relevant manifest, keep the line, write down why, then
`repo sync -c -j$(nproc) --no-clone-bundle <project>`.

---

## 7. Build


```bash
source build/envsetup.sh
```

```bash
lunch aosp_arm64-bp4a-userdebug
```

```bash
m
```

- `source build/envsetup.sh` defines `m`, `lunch` and friends. It only
  affects the current shell - open a new terminal and you do it again.
- `lunch` picks the product and variant, in the form
  `<product>-<release>-<variant>`. **The middle field decides whether your
  image can run on real hardware**, and it is the easiest thing here to get
  quietly wrong:

  | Config | Correct when |
  |---|---|
  | `trunk_staging` | The vendor half comes from the same build - Cuttlefish, the emulator, a full device build. Nothing can mismatch. |
  | released: `bp4a`, `bp2a`, `ap4a`, ... | The image runs against a vendor partition you did not build - any retail phone. |

  `trunk_staging` is the in-development configuration and stamps the image
  as pre-release: `ro.build.version.codename` is the codename rather than
  `REL`, `ro.build.version.preview_sdk=1`, and `ro.llndk.api_level` is one
  release ahead of the device. A retail device refuses that and bootloops.

  What makes this expensive is that the same image boots perfectly on
  Cuttlefish, so the target looks fine right up until you flash a phone.
  `ls build/release/flag_values/` lists what your tree has. Google's own
  GSIs are built from a released config.
- `m` builds. `m -j8` sets parallelism; bare `m` picks a number itself.

For the targets in this repository:

```bash
cp -r /path/to/aosplite/products device/aosplite
```

```bash
/path/to/aosplite/tools/build.sh lite_arm64-bp4a-userdebug systemimage
```

**Time: hours.** A full build is 1-3 hours on a large machine and
comfortably over 12 on four cores. No configuration changes that
materially - it is the amount of code.

`m nothing` runs the whole configuration and analysis pass and compiles
nothing. It takes minutes and catches config errors, so use it after any
change to a `.mk` file or to your prune tiers, before committing to a
real build.

```bash
m nothing
```

When the build produces images, running them is a separate job with its
own set of traps - see [docs/EMULATOR.md](docs/EMULATOR.md).

---

## What failure looks like

| What you see | What it means |
|---|---|
| `ninja: no work to do` and no `.img` file | The product defines no system image. Its inherit chain is missing `generic_system.mk` or the board `device.mk`. A fast, silent, empty success - the most confusing failure in AOSP. |
| `No space left on device`, hours in | Exactly what it says. `out/` needs 100-150 GB. Nothing is salvageable; free space and restart. |
| `Killed` during a link step | Out of memory. Lower `-j`, add swap, or raise the WSL memory limit. |
| `error: module 'X' already defined` | Two `Android.bp` files declare the same module name. Rename one. |
| `package X does not exist` in javac | A module's `Android.bp` is missing a `static_libs` entry for a library it imports. |
| `plain text not allowed here` from aapt2 | Malformed XML in a `res/values/` file - often a stray character outside an element. |
| A `<remove-project>` that saved nothing | The project name is wrong for this release. Run `verify-manifest.sh`. |
| Build is absurdly slow on Windows | The tree is under `/mnt/c`. Move it into the WSL filesystem. |
| `unrecognized module type \"X\"` | The project defining that Soong module type was pruned. `csuite_test` comes from `test/app_compat/csuite`. |
| `depends on undefined module \"X\"` | The project defining module X was pruned. `cts_defaults` comes from `platform/cts`. Run `tools/check-modules.sh`. |
| `module X missing dependencies: <path>` | A pruned project, surfacing at build time rather than analysis because `ALLOW_MISSING_DEPENDENCIES` is set. Run `tools/preflight.sh`. |
| `missing and no known rule to make it` | A `PRODUCT_COPY_FILES` source inside a pruned project. `device/sample/etc/apns-full-conf.xml` is the usual one. |
| `panic ... Fuzzer doesn't exist` | A pruned tree without `ALLOW_MISSING_DEPENDENCIES=true`. Set it - `tools/build.sh` does. |
| `remove-project element specifies non-existent project` | A prune entry naming a project absent from your branch. Add `optional=\"true\"` to it. |
| `Got signal: terminated` with no error | The machine slept. Nothing is wrong with the build; disable sleep and start again. |
| Everything rebuilds after a one-line change | `USE_CCACHE` changed between runs. It rewrites every compile command. Put it back and leave it. |
| Image boots on Cuttlefish, bootloops on a phone | Built with `trunk_staging`. Check `ro.build.version.codename` in the image - it must be `REL`. Rebuild with a released config. |

---

## If your machine is smaller than the requirements

In order of effect:

1. **Prune the tree.** The tiers here take the checkout to roughly
   75 GB. Disk is the constraint that stops a build dead.
2. **Build less.** `m systemimage` rather than `m`. A trimmed product
   config - fewer inherited packages - is the single biggest lever on
   build time.
3. **Turn off dexpreopt.** `WITH_DEXPREOPT := false` costs first-boot
   time and saves a large share of build time and image size.
4. **Drop 32-bit.** A standard build compiles every native library
   twice. If you do not need 32-bit app support, that is close to half
   the native compile volume.
5. **Lower `-j`.** Counter-intuitive, but on a memory-starved machine
   fewer parallel jobs finish sooner than more jobs that swap.
6. **Build in the cloud.** A spot instance with 64 cores does in under
   an hour what four cores do overnight, for a few dollars. If the goal
   is an image rather than a local development loop, this is usually the
   honest answer.

---

## Sources

Hardware requirements, supported OS and the package list come from
Google's own documentation:

- <https://source.android.com/docs/setup/start/requirements>
- <https://source.android.com/docs/setup/start/initializing>
- <https://source.android.com/docs/setup/download>

The ccache mechanism is taken from `build/make/core/ccache.mk` at
`android-15.0.0_r20`.

Timings, size estimates and the failure table are from experience and
inference, not measurement. Treat them as orientation, not fact.
