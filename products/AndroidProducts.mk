# AOSPLite products.
#
# Copy this directory to device/aosplite/ in a synced tree, or point
# PRODUCT_MAKEFILES at it from your own device tree.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lite_arm64.mk

COMMON_LUNCH_CHOICES := \
    lite_arm64-trunk_staging-userdebug \
    lite_arm64-trunk_staging-user
