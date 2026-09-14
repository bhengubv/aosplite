# patches

Local changes to AOSP projects. `repo sync` overwrites these projects, so
anything here has to be reapplied after a sync — keep it as a patch rather
than an edit you will lose and then spend a night rediscovering.

Apply with:

    cd ~/android/<project>
    git apply /path/to/aosplite/patches/<file>.patch

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
