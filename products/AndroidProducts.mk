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

COMMON_LUNCH_CHOICES := \
    lite_arm64-trunk_staging-userdebug \
    lite_arm64-trunk_staging-user \
    watch_arm64-trunk_staging-userdebug \
    desktop_x86_64-trunk_staging-userdebug
