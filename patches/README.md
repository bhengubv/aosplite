# patches

Local changes to AOSP projects. `repo sync` overwrites these projects, so
anything here has to be reapplied after a sync — keep it as a patch rather
than an edit you will lose and then spend a night rediscovering.

Apply with:

    tools/apply-patches.sh ~/android

It is idempotent - a patch already in the tree is detected and skipped - and
`tools/os.sh` runs it on every sync, because a `repo sync` done outside
os.sh is invisible from inside it. Doing them by hand still works:

    cd ~/android/<project>
    git apply /path/to/aosplite/patches/<file>.patch

Adding a patch means adding its project to `project_for()` in
apply-patches.sh. A patch with no mapping is skipped with a warning rather
than guessed at.

## 0001-sepolicy-add-memfd_file-class.patch

**Project:** `system/sepolicy`
**Needed when:** the device's vendor image is newer than the AOSP tag you
are building from.

A GSI can never match the vendor's precompiled SELinux policy — the hashes
are keyed to the stock system — so `init` must compile policy at boot with
`secilc`. If the vendor's policy references a security class your platform
policy does not define, that compile fails and the device dies:

    Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00

with nothing else logged, because SELinux setup happens before logging
exists.

On a Pixel 7a (`lynx`, CP1A.260405.005) against `android-16.0.0_r4`, the
vendor's audio HAL policy uses the `memfd_file` class:

    Failed to resolve allow statement at vendor_sepolicy.cil:2109
      from system/sepolicy/vendor/hal_audio_default.te:7
    Failed to resolve AST
    Failed to compile cildb: -2

The tree had 107 security classes; the device's stock policy had 108. The
difference was exactly `memfd_file`.

This patch adds the class, in the position the device's own policy uses
(after `dir`, before `fd` — class order determines the numeric ids), with
the permissions taken from the device's compiled policy:

    (class memfd_file (execute_no_trans entrypoint))
    (classcommon memfd_file file)

### How to tell whether you need it

Reproduce the compile offline before flashing anything — this takes seconds
and is the only way to see the failure at all:

    secilc <plat_sepolicy.cil> -m -M true -G -N -c 30 <mapping/VER.cil> \
        -o /tmp/out -f /dev/null \
        <vendor plat_pub_versioned.cil> <vendor vendor_sepolicy.cil>

Exit 0 means the policy compiles. Any other exit is the reason your device
will not boot, named in full.

### The general case

`memfd_file` is only this device and this tag. The real rule is: **build
from a tree at least as new as the device's vendor image.** If you cannot,
expect to add whatever classes its vendor policy references, and use the
offline compile above to find them one at a time.


## hardened_malloc — 0002, 0003, 0004

**Projects:** `bionic`, `build/soong`, `build/make`
**Needed when:** always. These three plus `manifests/hardened-malloc.xml`
are the whole hardened_malloc integration, and `tools/init.sh` installs the
manifest by default.

AOSP ships Scudo. Chapter 03 section 2.2 of the Circle OS specification
names GrapheneOS `hardened_malloc` as the system allocator instead, and
these patches are the seam:

| Patch | Project | What it does |
|---|---|---|
| 0002 | `bionic` | `-DUSE_HARDENED_MALLOC`, `-DH_MALLOC_PREFIX`, and the `Malloc(x) -> h_x` binding in `malloc_common.h` |
| 0003 | `build/soong` | a product variable `external/hardened_malloc` reads to enable ARM MTE |
| 0004 | `build/make` | the same variable on the Make side |

### Why both defines, and what happens with only one

This cost a build. `bionic/libc/Android.bp` set `-DUSE_HARDENED_MALLOC`
and the comment beside it said it matched `-DH_MALLOC_PREFIX` in
`external/hardened_malloc/Android.bp` — which does set it, at line 12.
bionic did not.

`external/hardened_malloc/include/h_malloc.h` line 12 reads:

```c
#ifndef H_MALLOC_PREFIX
#define h_malloc_usable_size malloc_usable_size
```

So without the define, every `h_` name aliased straight back to the plain
one, and `malloc_common.cpp` hit bionic's own guard:

```
malloc.h:133: __clang_error_if(_FORTIFY_SOURCE >= 3,
  "malloc_usable_size() and _FORTIFY_SOURCE>=3 are incompatible")
```

The build failed at 18% in `malloc_common.o`, roughly 90 minutes in,
because bionic is deep in the graph. `h_malloc.c:1846` already exported
the real symbol — the header was simply defining it away.

`tools/check-product.sh` check 8 now compares the two sides and fails fast
if they disagree.

### What silently reverts

If these patches are lost — a `repo sync` is enough — the build does not
fail. bionic falls back to Scudo, the image boots, and nothing reports it.
The specification still claims hardened_malloc; the device no longer has
it. That is why `os.sh` reapplies on every run rather than trusting the
tree.
