# AOSPLite - watch, arm64.
#
#   lunch watch_arm64-trunk_staging-userdebug
#   m systemimage
#
# ---------------------------------------------------------------------
# Why this file exists
# ---------------------------------------------------------------------
# AOSP ships no watch product. Wear OS is proprietary and none of it is
# in the tree. That is usually reported as "Android does not do watches
# in AOSP", which is not quite true - what is missing is the product,
# not the support.
#
# What AOSP already has, verified at android-15.0.0_r20:
#
#   frameworks/native/data/etc/wearable_core_hardware.xml
#       The wearable hardware profile. Its own comment says it covers
#       "watches, glasses, backpacks, and sweaters".
#
#   PackageManager.FEATURE_WATCH = "android.hardware.type.watch"
#       Real constant, and the framework branches on it.
#
#   Configuration.UI_MODE_TYPE_WATCH and the -watch resource qualifier
#       Resource selection for round and small screens.
#
# What AOSP does not have:
#
#   A declaration of android.hardware.type.watch. There is an
#   android.hardware.type.automotive.xml, and pc_core_hardware.xml
#   declares android.hardware.type.pc inline, but nothing declares the
#   watch type - because no AOSP product is a watch. This product ships
#   that declaration itself, in permissions/.
#
#   A shell. No watch launcher, no watch face, no watch SystemUI. That
#   is the real work and it is app-layer work, on a system that boots.
#
# ---------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------
# Modelled on device/google/atv/products/atv_system.mk, which is the
# only worked example in AOSP of a form factor layered on the shared
# base. Same shape: inherit the system layer, copy in a hardware
# profile, add packages, set properties.
#
# ---------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------
# Unverified. Never synced, never built, never booted. The feature file
# paths and the board config are checked against the real
# android-15.0.0_r20 manifest; nothing else is.
# ---------------------------------------------------------------------

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/board/generic_arm64/device.mk)

PRODUCT_NAME   := watch_arm64
PRODUCT_DEVICE := generic_arm64
PRODUCT_BRAND  := AOSPLite
PRODUCT_MODEL  := AOSPLite Watch

# The wearable hardware profile, and the device-type declaration AOSP
# does not ship. Both land in /system/etc/permissions where
# PackageManager reads them at boot.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/wearable_core_hardware.xml:system/etc/permissions/wearable_core_hardware.xml \
    device/aosplite/permissions/android.hardware.type.watch.xml:system/etc/permissions/android.hardware.type.watch.xml

# Drives -watch resource qualifier selection and is read by a good deal
# of framework and app code to decide it is on a small round screen.
PRODUCT_CHARACTERISTICS := watch

# A watch is a low-memory device by any phone standard. These are the
# two levers go_defaults_common.mk pulls, applied here directly rather
# than inheriting the whole Go configuration.
PRODUCT_MINIMIZE_JAVA_DEBUG_INFO := true
PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD := false

# Dexpreopt trades first-boot time for image size. On a watch the image
# size matters more.
WITH_DEXPREOPT := false

PRODUCT_BUILD_RECOVERY_IMAGE := false

# What you still have to build:
#
#   a launcher                 nothing claims CATEGORY_HOME
#   a watch face               no equivalent exists in AOSP; the
#                              WatchFace API is Jetpack, not platform
#   a SystemUI                 stock SystemUI assumes a phone status bar
#                              and notification shade
#   companion pairing          Wear OS handles this proprietarily
#
# Without a launcher this boots to a blank screen with adb. That is the
# expected result, not a failure.
