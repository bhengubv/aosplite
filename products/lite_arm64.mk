# AOSPLite - arm64 GSI target, trimmed.
#
#   lunch lite_arm64-trunk_staging-userdebug
#   m systemimage
#
# ---------------------------------------------------------------------
# What this is
# ---------------------------------------------------------------------
# Upstream aosp_arm64.mk inherits five product makefiles:
#
#   core_64_bit.mk           64-bit only
#   generic_system.mk        the system image itself
#   handheld_system_ext.mk   phone and tablet UX
#   telephony_system_ext.mk  the radio stack
#   aosp_product.mk          product-partition applications
#
# This target keeps the first two and drops the last three. What remains
# is form-factor-neutral: generic_system.mk builds on base_system.mk,
# which is the layer that TV, Wear, Automotive and handheld all sit on
# top of. Nothing here commits the image to being a phone.
#
# ---------------------------------------------------------------------
# Why the inherits are not trimmed further
# ---------------------------------------------------------------------
# generic_system.mk is what wires up INSTALLED_SYSTEMIMAGE_TARGET.
# Remove it and `m systemimage` returns RC=0 with "ninja: no work to do"
# and produces no system.img at all - a fast, silent, empty success. The
# board device.mk below is what resolves BOARD_SYSTEMIMAGE_PARTITION_SIZE
# via PRODUCT_DEVICE.
#
# Those two are the image plumbing. The three that were dropped are
# payload. That distinction is the whole design of this file.
#
# ---------------------------------------------------------------------
# What you lose
# ---------------------------------------------------------------------
#   - no Launcher, no full SystemUI phone experience
#   - no telephony
#   - no product-partition apps
#
# It boots to shell and adb. That is the intended starting point: add
# your own layer on top rather than subtracting from someone else's.
#
# ---------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------
# Unverified. Nobody has published a boot log for this config. If you
# want the configuration that is known to produce a working GSI, use
# upstream aosp_arm64.mk unchanged.
# ---------------------------------------------------------------------

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/board/generic_arm64/device.mk)

PRODUCT_NAME   := lite_arm64
PRODUCT_DEVICE := generic_arm64
PRODUCT_BRAND  := AOSPLite
PRODUCT_MODEL  := AOSPLite arm64

# Dexpreopt writes ahead-of-time compiled odex into the image. It is a
# large share of both build time and image size, and its only cost when
# disabled is a slower first boot.
WITH_DEXPREOPT := false

# No separate recovery partition.
PRODUCT_BUILD_RECOVERY_IMAGE := false
