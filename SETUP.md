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
memory=48GB
swap=16GB
```

Then `wsl --shutdown` from PowerShell and reopen.

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

## 7. Build

```bash
source build/envsetup.sh
```

```bash
lunch aosp_arm64-trunk_staging-userdebug
```

```bash
m
```

- `source build/envsetup.sh` defines `m`, `lunch` and friends. It only
  affects the current shell - open a new terminal and you do it again.
- `lunch` picks the product and variant, in the form
  `<product>-<release>-<variant>`.
- `m` builds. `m -j8` sets parallelism; bare `m` picks a number itself.

For the targets in this repository:

```bash
cp -r /path/to/aosplite/products device/aosplite
```

```bash
source build/envsetup.sh
```

```bash
lunch lite_arm64-trunk_staging-userdebug
```

```bash
m systemimage
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
