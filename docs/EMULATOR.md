# Getting a build onto an emulator

Building an image and running one are separate problems, and the second
is barely documented. AOSP gives you `.img` files; nothing in the tree
tells you what to do with them if you are not on the hardware they were
cut for.

There are two answers. One is supported and wants a machine that matches
your target. The other is manual, works anywhere, and is where the
afternoon goes.

| | Cuttlefish (`launch_cvd`) | QEMU by hand |
|---|---|---|
| Effort | One command | A disk to assemble and a command line to get right |
| Needs KVM | Yes, in practice | No |
| Guest arch | Must match the host | Any |
| Speed | Near native | Roughly a tenth of it under TCG |
| Use it when | Host and target are the same architecture | arm64 guest on an x86-64 host, or no KVM |

Everything below the first section was measured on an **Android 16 tree
with a 6.12 GKI, arm64 guest, x86-64 host, no KVM**. The mechanisms hold
on Android 15; version numbers and file names in it do not.

---

## Path 1 - Cuttlefish

Cuttlefish is AOSP's own virtual device. It is a real target in the
tree, so the images it wants are the images the build produces, and
there is no assembly step.

```bash
source build/envsetup.sh
```

```bash
lunch aosp_cf_arm64_phone-trunk_staging-userdebug
```

```bash
m
```

The `vsoc_*` device directories under `device/google/cuttlefish` list
the products. On an arm64 tree they include `aosp_cf_arm64_phone`,
`aosp_cf_arm64_only_phone` and `aosp_cf_arm64_slim`; the x86-64
equivalents are named the same way. There is also
`aosp_cf_arm64_phone_vendor`, which builds the vendor side alone - that
is the one you want if you are pairing a Cuttlefish vendor with a GSI
you built separately.

Then build the host tools, unpack them next to the images, and launch:

```bash
launch_cvd
```

`launch_cvd` drives crosvm by default. It also accepts QEMU:

```bash
launch_cvd --vm_manager=qemu_cli
```

**Not verified here.** The launcher was not run for this document. The
product names and the `qemu_cli` option were read out of
`device/google/cuttlefish` at Android 16; the rest is Google's
documentation, not measurement. If you are on x86-64 building an x86-64
target, start here anyway - it is one command against a day of the
alternative.

---

## The targets in this repository do not fit path 1

Worth saying plainly, because it is the first thing a reader will try.

`lite_arm64` sets `PRODUCT_DEVICE := generic_arm64` and inherits
`generic_system.mk`. It is a **system image only** - a GSI. `launch_cvd`
expects a Cuttlefish product, which builds a matching vendor, boot and
vendor_boot alongside the system image. Point it at a `lite_arm64` build
and there is nothing for it to boot.

The same is true of `watch_arm64` and `desktop_x86_64`.

So there are three honest options, in increasing order of effort:

**Build a Cuttlefish product instead.** `lunch aosp_cf_arm64_phone`, then
`launch_cvd`. You lose the pruned product config - the tiers still apply,
because they prune the *tree*, not the product - but you get a running
system with one command. This is the right first move for anyone who has
not booted AOSP before.

**Mix the two.** `assemble_cvd` takes a comma-separated list:

```bash
launch_cvd --system_image_dir=out/target/product/vsoc_arm64,out/target/product/generic_arm64
```

It composes `super` from more than one product out directory, which is
how Cuttlefish runs a GSI over its own vendor. The flag is real - it is
declared in `host/commands/assemble_cvd/flags.cc` and split on commas -
but **it has not been run for this document**, and the argument order and
exact directory expectations are not documented here because they were
not tested.

**Assemble the disk yourself.** Path 2 below. This works, and it is what
was measured, but it is a day of work and every one of the traps in the
next section is waiting in it.

### What is actually missing

A Cuttlefish flavour of the lite target - a `lite_cf_arm64.mk` inheriting
`device/google/cuttlefish/vsoc_arm64` - would collapse all of the above
into `lunch`, `m`, `launch_cvd`. It does not exist in this repository. If
you write one and boot it, that is the single most useful contribution
here.

Also worth knowing before you spend an evening: `lite_arm64` drops
`handheld_system_ext.mk`, `telephony_system_ext.mk` and
`aosp_product.mk`. It boots to a shell and adb. There is no launcher and
no phone UI, so a black screen is the expected result, not a failure.

---

## Path 2 - QEMU by hand

Use this when the guest architecture is not the host's, when there is no
KVM, or when you want to boot a GSI against a vendor image that did not
come from the same build.

QEMU has no idea what an Android partition table is. You give it a
kernel, a ramdisk and one disk, and everything Android expects has to be
inside that disk in the right place.

### What you need

| Piece | Where it comes from |
|---|---|
| Kernel | `kernel/prebuilts/<ver>/<arch>/kernel-<ver>` |
| Kernel modules | `kernel/prebuilts/common-modules/virtual-device/<ver>/<arch>/*.ko` |
| Ramdisk | The generic ramdisk plus the vendor ramdisk, concatenated |
| `system.img` | Your build |
| `vendor.img` | A Cuttlefish vendor build for the **same** Android release |
| The rest | `boot`, `init_boot`, `vendor_boot`, `vbmeta`, `misc`, `metadata`, `userdata` |

### The disk

Android wants named partitions. Build one raw image with a GPT and write
each piece at its offset. A layout that boots:

| # | Name | Size | Holds |
|---|---|---|---|
| 1 | `boot_a` | 64 MB | |
| 2 | `init_boot_a` | 8 MB | |
| 3 | `vendor_boot_a` | 64 MB | |
| 4 | `vbmeta_a` | 12 KB | |
| 5 | `misc` | 512 KB | |
| 6 | `metadata` | 16 MB | |
| 7 | `super` | 2 GB | `system_a` + `vendor_a` |
| 8 | `userdata` | 1 GB | |
| 9 | `frp` | 1 MB | see below |

`super` is a dynamic-partition container, not a filesystem. Build it
with `lpmake` from the host tools:

```bash
lpmake --metadata-size 65536 --metadata-slots 2 --super-name super \
  --device-size 2147483648 --alignment 1048576 \
  --group main:2145386496 \
  --partition system_a:readonly:$(stat -c %s system.img):main --image system_a=system.img \
  --partition vendor_a:readonly:$(stat -c %s vendor.img):main --image vendor_a=vendor.img \
  --output super.img
```

Then `dd` each image to its sector offset in the composite disk with
`conv=notrunc`, and compare the region back against the source
afterwards. A silent short write here looks exactly like a corrupt
filesystem three hours later.

### The command line

```bash
qemu-system-aarch64 \
  -machine virt -cpu cortex-a72 -smp 4 -m 6144 \
  -kernel kernel -initrd ramdisk_combined.img \
  -append "console=ttyAMA0 androidboot.hardware=cutf_cvm \
           androidboot.force_normal_boot=1 androidboot.slot_suffix=_a \
           androidboot.selinux=permissive androidboot.verifiedbootstate=orange \
           androidboot.fstab_suffix=cutf_cvm \
           androidboot.boot_devices=4010000000.pcie \
           androidboot.hw_timeout_multiplier=50 audit=0" \
  -drive file=composite.img,format=raw,if=none,id=main \
  -device virtio-blk-pci,drive=main \
  -device virtio-gpu-pci \
  -vnc 127.0.0.1:1 -serial file:serial.log
```

The flags that are not obvious:

| Flag | Why |
|---|---|
| `androidboot.hardware=cutf_cvm` | Selects the Cuttlefish HAL set and fstab. Without it nothing mounts. |
| `androidboot.boot_devices=...` | The PCI node holding the disk. Wrong value, no `/dev/block/by-name`. |
| `androidboot.hw_timeout_multiplier=50` | Multiplies every framework timeout. Under TCG the watchdog fires long before the boot finishes without it. |
| `audit=0` | Permissive SELinux logs every denial to the console, which under TCG costs more time than the boot. |
| `-vnc 127.0.0.1:1` | The display. Tunnel it over SSH rather than binding it publicly - there is no password on it. |

**Never set `loglevel`.** Lowering it silences the console, which is the
only view into a guest that has not reached a shell yet.

---

## What actually stops it booting

Each of these presents as the same thing: the boot stops, `system_server`
either hangs or restarts, and nothing says why. The service count is the
useful progress signal - `service list | wc -l` from a guest shell - and
each failure has its own ceiling.

### 1. The modules must match the kernel, and the GKI has no system heap

The kernel and its modules are a matched set. `vermagic` inside any
`.ko` must equal the kernel's version string exactly; a mismatch means
the module silently does not load, and a missing storage or console
driver looks like a dead machine.

Less obvious, and the one that cost the most: **the GKI does not build a
DMA-BUF system heap.**

```
# CONFIG_DMABUF_HEAPS_SYSTEM is not set
```

That line is in the shipped config of both the 6.1 and 6.12 arm64
prebuilts. The heap is a module, `system_heap.ko`, and it sits with the
virtual-device modules. If it is not in the ramdisk and not in
`modules.load`, there is no `/dev/dma_heap/system`.

Cuttlefish's vendor sets `debug.c2.use_dmabufheaps=1`, so codec2 asks
for the heap, does not find it, falls back to ION, and ION is not there
either on a modern kernel. `media.swcodec` then segfaults in
`C2AllocatorIon`, restarts, and segfaults again. It does this quietly -
the visible symptom is `system_server` threads blocking in binder calls
into the dying process, by way of `SoundPool`, and a boot that stops
climbing.

Ship the whole matched set:

```
failover.ko nd_virtio.ko net_failover.ko virtio_dma_buf.ko virtio-gpu.ko
virtio_input.ko virtio_net.ko virtio-rng.ko libarc4.ko rfkill.ko
cfg80211.ko mac80211.ko mac80211_hwsim.ko virtio_blk.ko virtio_console.ko
virtio_pci.ko vmw_vsock_virtio_transport.ko virtio_pci_legacy_dev.ko
virtio_pci_modern_dev.ko system_heap.ko
```

Generate `modules.dep` with `depmod` against a staging directory, then
rewrite the paths to match where the ramdisk actually puts them.

### 2. The vendor image must be the same Android release as the system image

A GSI is meant to run on an older vendor, within limits, and those
limits are enforced by the compatibility matrix. Android 16 requires
`graphics.composer3` at V3 or later. An Android 14 vendor ships V2. The
result is not a clean refusal: SurfaceFlinger hangs inside `composite()`,
`DisplayManagerService.onBootPhase` deadlocks behind it, and the boot
stops with no error at all.

Build the vendor from the same tree as the system image.

### 3. Multi-install APEXes need to be chosen explicitly

Cuttlefish ships several HALs as APEXes with more than one variant in
the same image. `apexd` will not guess, and aborts. Name the variant on
the command line:

```
androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure
androidboot.vendor.apex.com.android.hardware.gatekeeper=com.android.hardware.gatekeeper.nonsecure
androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.ranchu
androidboot.vendor.apex.com.android.hardware.secure_element=com.android.hardware.secure_element
androidboot.vendor.apex.com.android.hardware.strongbox=none
```

`apexd` logs "does not match expected multi-install APEX" for the ones
it skipped, which is how you find the rest.

### 4. `odm` must not be a symlink loop

A GSI ships `/odm` as a symlink to `/vendor/odm`. Some vendor images
ship `odm` as a symlink back to `/odm`. The two together are a loop,
libvintf gets `ELOOP` reading the device manifest, and returns a null
manifest rather than an error.

Every HAL registration is then rejected as undeclared, `servicemanager`
denies everything, and the boot stops with a long list of services that
cannot find their dependencies. Make `odm` a real directory in the
vendor image.

### 5. `PersistentDataBlockService` wants a partition that exists

It reads `ro.frp.pst` and opens that block device at boot phase 500. On
real Cuttlefish the partition lives on a second disk. If it is absent,
the service throws `init timeout`, `system_server` dies, and it happens
late - after two hundred-odd services, which makes it look like a
resource problem rather than a missing partition.

A 1 MB partition named `frp` is enough.

### 6. Audio has to agree with itself

`audioserver` is not optional, whatever an unrelated crash loop might
tempt you into. `SoundTriggerMiddleware` registers a capture-state
listener through it and the JNI does:

```c
LOG_ALWAYS_FATAL_IF(status != NO_ERROR);
```

If `audioserver` is disabled, that assert takes `system_server` down
with `SIGABRT` and an abort message of `Assertion failed: status !=
NO_ERROR`, several hundred services into the boot, in a thread whose
name mentions neither audio nor the service you disabled.

The corollary: if `audioserver` loops because the vendor's audio HAL is
the wrong generation, fix the vendor. Do not disable `audioserver`.

### 7. Everything is slow, and slow is not hung

Under TCG a full boot to `sys.boot_completed` took **just under two
hours** on four cores. The zygote starts around 14 minutes in,
SurfaceFlinger around 16, and the service count climbs in bursts with
long flat stretches between them. A flat five minutes is normal. That is
what `hw_timeout_multiplier` exists for.

---

## Knowing whether it booted

Do not grep the console for it. `sys.bootstat.first_boot_completed`
appears in the log during a boot that later fails, and matching on
`boot_completed` catches it.

Ask the guest:

```bash
getprop sys.boot_completed
```

`1` is the only answer that counts. For progress before that:

```bash
service list | wc -l
```

A finished boot on a phone target is somewhere north of 240 services. A
count that stops climbing for twenty minutes is a hang; a count that
resets to single digits is `system_server` restarting.

### Reading the wreckage without a shell

When `system_server` dies, the guest writes the reason to `/data` before
anything else notices. You can read it from the host without the guest
running - copy the userdata region out of the composite disk, run
`e2fsck -fy` on the copy, and use `debugfs`:

```bash
dd if=composite.img of=ud.img bs=512 skip=<offset> count=<count>
e2fsck -fy ud.img
debugfs -R "ls -l system/dropbox" ud.img
debugfs -R "cat system/dropbox/system_server_crash@....txt" ud.img
```

`system/dropbox` holds the Java crash with its stack, `anr/` holds
thread dumps naming the lock and its holder, and `tombstones/` holds
native crashes with the abort message. Every failure in the list above
was found this way rather than guessed.

---

## Status

**Verified.** An arm64 GSI booted to `sys.boot_completed=1` against a
Cuttlefish vendor of the same release, under QEMU with TCG on an x86-64
host, on 2026-09-08. 249 services. Every fix listed above was needed to
get there, and each was diagnosed from guest-written evidence.

**Not verified.** The `launch_cvd` path in this document. The exact
sizes in the partition table are what one working disk used, not
minimums. Timings are from a single four-core machine.

Corrections welcome.
