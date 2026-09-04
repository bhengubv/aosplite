# AOSPLite - desktop, x86_64.
#
#   lunch desktop_x86_64-trunk_staging-userdebug
#   m systemimage
#
# ---------------------------------------------------------------------
# Why this file exists
# ---------------------------------------------------------------------
# AOSP ships no desktop product either, but it ships more of the desktop
# than most people expect. Verified at android-15.0.0_r20,
# frameworks/native/data/etc/pc_core_hardware.xml declares:
#
#   android.hardware.type.pc
#   android.software.freeform_window_management
#   android.software.activities_on_secondary_displays
#   android.software.picture_in_picture
#   android.software.window_magnification
#   android.software.managed_users
#   android.software.device_admin
#
# That is a desktop profile, present in the tree, today. Freeform
# windowing has its own feature file as well
# (android.software.freeform_window_management.xml), and
# build/make/target/product carries window_extensions.mk and
# large_screen_common.mk.
#
# So the framework knows what a PC is. What is missing is a product that
# says "I am one", and a shell to put on top.
#
# ---------------------------------------------------------------------
# What is not here
# ---------------------------------------------------------------------
# This targets generic_x86_64, which means an emulator or a VM. Running
# on real PC hardware is a separate and much larger problem: storage
# controllers, GPU drivers, wifi, ACPI, suspend. That work is what
# Android-x86 and Bliss OS exist to do, and neither is in AOSP.
#
# Getting a desktop-profile image to boot in a VM is the first step.
# Getting it onto a laptop is a different project.
#
# ---------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------
# Unverified. Never synced, never built, never booted. The feature file
# path and the board config are checked against the real
# android-15.0.0_r20 manifest; nothing else is.
# ---------------------------------------------------------------------

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/board/generic_x86_64/device.mk)

# Activity embedding and window extensions - the framework side of
# multi-window on a large screen.
$(call inherit-product, $(SRC_TARGET_DIR)/product/window_extensions.mk)

PRODUCT_NAME   := desktop_x86_64
PRODUCT_DEVICE := generic_x86_64
PRODUCT_BRAND  := AOSPLite
PRODUCT_MODEL  := AOSPLite Desktop

# The PC hardware profile. This one file is what makes the framework
# treat the device as a desktop: it carries android.hardware.type.pc and
# the freeform windowing feature together, so no extra declaration is
# needed the way it is for watch.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/pc_core_hardware.xml:system/etc/permissions/pc_core_hardware.xml

# Read by resource selection and by apps deciding on a desktop layout.
PRODUCT_CHARACTERISTICS := tablet,nosdcard

# Freeform windowing must be enabled at the WindowManager level as well
# as declared as a feature. Without this, windows are still fullscreen
# even though the feature is advertised.
PRODUCT_SYSTEM_PROPERTIES += \
    persist.wm.debug.desktop_mode_2=true \
    ro.config.per_app_memcg=false

WITH_DEXPREOPT := false

PRODUCT_BUILD_RECOVERY_IMAGE := false

# What you still have to build:
#
#   a desktop shell            no taskbar, no window chrome, no app
#                              launcher meant for a mouse
#   multi-display handling     the feature is declared; arranging
#                              displays is not
#   input                      stock SystemUI assumes touch first
#   real hardware support      see the note above - that is Android-x86
#                              and Bliss OS territory, not this file
#
# Expect a booting system that advertises itself as a PC and has nothing
# to show on screen. That is the expected result, not a failure.
