# AOSPLite products.
#
# Copy this directory to device/aosplite/ in a synced tree:
#
#   cp -r /path/to/aosplite/products device/aosplite
#
# The path matters. watch_arm64.mk references
# device/aosplite/permissions/ for a file AOSP does not ship, so the
# directory has to land at device/aosplite or that PRODUCT_COPY_FILES
# line will not resolve.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lite_arm64.mk \
    $(LOCAL_DIR)/watch_arm64.mk \
    $(LOCAL_DIR)/desktop_x86_64.mk

# Both release configs are offered on purpose.
#
# trunk_staging is the in-development config. It is correct when the vendor
# half comes from the same build - Cuttlefish, the emulator - and wrong for
# anything that has to run against a vendor partition you did not build. It
# stamps the image as pre-release: codename rather than REL, preview_sdk=1,
# and llndk.api_level a release ahead. A retail device rejects that and
# bootloops, while the same image boots fine on Cuttlefish. That asymmetry
# is what makes it expensive to get wrong - it looks like it works.
#
# bp4a is a released config. Substitute whichever your tree has;
# ls build/release/flag_values/ lists them.

COMMON_LUNCH_CHOICES := \
    lite_arm64-bp4a-userdebug \
    lite_arm64-bp4a-user \
    lite_arm64-trunk_staging-userdebug \
    watch_arm64-bp4a-userdebug \
    watch_arm64-trunk_staging-userdebug \
    desktop_x86_64-bp4a-userdebug \
    desktop_x86_64-trunk_staging-userdebug
