# AOSPLite - system feature declarations.
#
#   AOSPLITE_FEATURE_SETS := all
#   $(call inherit-product, device/aosplite/features.mk)
#
# ---------------------------------------------------------------------
# WHAT THIS COVERS
# ---------------------------------------------------------------------
# All 174 system features Circle OS targets, grouped as 15 sets plus
# 'all'. Every product in this repository takes 'all', so anyone
# building AOSPLite gets the complete set rather than a subset.
#
# Resolution was done by INDEXING every <feature name=...> across all
# 170 XMLs in frameworks/native/data/etc, not by matching filenames.
# That matters: android.hardware.camera.full.xml declares four of these,
# android.hardware.location.xml declares two, and the versioned ones
# live in variant files such as android.hardware.vulkan.level-0.xml.
# Matching on filename missed 25 features that were there all along.
#
# So the lists below are one line per SOURCE FILE, not per feature - a
# composite that satisfies four features is copied once. 167 files cover
# all 174.
#
# ---------------------------------------------------------------------
# VERSIONED FEATURES - read before changing
# ---------------------------------------------------------------------
# Five carry a version that describes real hardware capability, and the
# most CONSERVATIVE variant is used here so the claim is true on the
# widest range of boards:
#
#   vulkan.level            level-0
#   vulkan.version          1_0_3   (4194307)
#   vulkan.compute          compute-0
#   vulkan.deqp.level       2019-03-01  (132317953)
#   opengles.deqp.level     2020-03-01
#
# A device whose GPU does better should override with the higher
# variant. Claiming a level the driver cannot meet fails CTS and breaks
# apps that gate on it.
#
# android.hardware.hardware_keystore is version="100" (KeyMint 1.0).
# Raise it on a device with newer KeyMint.
#
# ---------------------------------------------------------------------
# THE HONEST CAVEAT
# ---------------------------------------------------------------------
# A feature XML makes PackageManager report that feature as present,
# unconditionally. Nothing consults the hardware at runtime.
#
# Declaring all 174 is therefore a claim that the device has all of
# them. On hardware that does not, an app querying hasSystemFeature()
# gets true and takes a path that fails.
#
# The sets below exist so a device tree can take a subset instead:
#
#   AOSPLITE_FEATURE_SETS := core telephony wifi camera sensors
#
# 'all' is the default because it is what was asked for. A real device
# port should narrow it.
# ---------------------------------------------------------------------

LOCAL_FEATURE_PATH := frameworks/native/data/etc
LOCAL_OWN_PATH     := device/aosplite/permissions

# ---------------------------------------------------------------------
# Audio - 5 features, 5 source file(s)
AOSPLITE_FEATURES_audio := \
    frameworks/native/data/etc/android.hardware.audio.low_latency.xml \
    frameworks/native/data/etc/android.hardware.audio.output.xml \
    frameworks/native/data/etc/android.hardware.audio.pro.xml \
    device/aosplite/permissions/android.hardware.microphone.xml \
    frameworks/native/data/etc/android.software.midi.xml

# ---------------------------------------------------------------------
# Bluetooth - 3 features, 3 source file(s)
AOSPLITE_FEATURES_bluetooth := \
    frameworks/native/data/etc/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.channel_sounding.xml

# ---------------------------------------------------------------------
# Wi-Fi - 5 features, 5 source file(s)
AOSPLITE_FEATURES_wifi := \
    frameworks/native/data/etc/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.hardware.wifi.aware.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.hardware.wifi.passpoint.xml \
    frameworks/native/data/etc/android.hardware.wifi.rtt.xml

# ---------------------------------------------------------------------
# Telephony - 22 features, 21 source file(s)
AOSPLITE_FEATURES_telephony := \
    frameworks/native/data/etc/android.hardware.telephony.gsm.xml \
    frameworks/native/data/etc/android.hardware.telephony.calling.xml \
    frameworks/native/data/etc/android.hardware.telephony.carrierlock.xml \
    frameworks/native/data/etc/android.hardware.telephony.cdma.xml \
    frameworks/native/data/etc/android.hardware.telephony.data.xml \
    frameworks/native/data/etc/android.hardware.telephony.euicc.xml \
    frameworks/native/data/etc/android.hardware.telephony.euicc.mep.xml \
    frameworks/native/data/etc/android.hardware.telephony.ims.xml \
    frameworks/native/data/etc/android.hardware.telephony.ims.singlereg.xml \
    frameworks/native/data/etc/android.hardware.telephony.mbms.xml \
    frameworks/native/data/etc/android.hardware.telephony.messaging.xml \
    frameworks/native/data/etc/android.hardware.telephony.radio.access.xml \
    frameworks/native/data/etc/android.hardware.telephony.satellite.xml \
    frameworks/native/data/etc/android.hardware.telephony.subscription.xml \
    frameworks/native/data/etc/android.software.telecom.xml \
    frameworks/native/data/etc/android.software.connectionservice.xml \
    frameworks/native/data/etc/android.software.sip.xml \
    frameworks/native/data/etc/android.software.sip.voip.xml \
    device/aosplite/permissions/android.hardware.telephony.callerid.xml \
    device/aosplite/permissions/android.hardware.telephony.callforwarding.xml \
    device/aosplite/permissions/android.hardware.telephony.callwaiting.xml

# ---------------------------------------------------------------------
# OtherRadios - 13 features, 12 source file(s)
AOSPLITE_FEATURES_radios := \
    frameworks/native/data/etc/android.hardware.nfc.xml \
    frameworks/native/data/etc/android.hardware.nfc.ese.xml \
    frameworks/native/data/etc/android.hardware.nfc.hce.xml \
    frameworks/native/data/etc/android.hardware.nfc.hcef.xml \
    frameworks/native/data/etc/android.hardware.nfc.uicc.xml \
    device/aosplite/permissions/com.android.nfc_extras.xml \
    frameworks/native/data/etc/com.nxp.mifare.xml \
    frameworks/native/data/etc/android.hardware.uwb.xml \
    frameworks/native/data/etc/android.hardware.thread_network.xml \
    frameworks/native/data/etc/android.hardware.broadcastradio.xml \
    frameworks/native/data/etc/android.hardware.consumerir.xml \
    frameworks/native/data/etc/android.hardware.ethernet.xml

# ---------------------------------------------------------------------
# Camera - 12 features, 9 source file(s)
AOSPLITE_FEATURES_camera := \
    frameworks/native/data/etc/android.hardware.camera.xml \
    frameworks/native/data/etc/android.hardware.camera.full.xml \
    frameworks/native/data/etc/android.hardware.camera.ar.xml \
    frameworks/native/data/etc/android.hardware.camera.autofocus.xml \
    frameworks/native/data/etc/android.hardware.camera.raw.xml \
    frameworks/native/data/etc/android.hardware.camera.concurrent.xml \
    frameworks/native/data/etc/android.hardware.camera.external.xml \
    frameworks/native/data/etc/android.hardware.camera.flash-autofocus.xml \
    frameworks/native/data/etc/android.hardware.camera.front.xml

# ---------------------------------------------------------------------
# Sensors - 23 features, 23 source file(s)
AOSPLITE_FEATURES_sensors := \
    frameworks/native/data/etc/android.hardware.sensor.accelerometer.xml \
    frameworks/native/data/etc/android.hardware.sensor.accelerometer_limited_axes.xml \
    frameworks/native/data/etc/android.hardware.sensor.accelerometer_limited_axes_uncalibrated.xml \
    frameworks/native/data/etc/android.hardware.sensor.ambient_temperature.xml \
    frameworks/native/data/etc/android.hardware.sensor.assist.xml \
    frameworks/native/data/etc/android.hardware.sensor.barometer.xml \
    frameworks/native/data/etc/android.hardware.sensor.compass.xml \
    frameworks/native/data/etc/android.hardware.sensor.dynamic.head_tracker.xml \
    frameworks/native/data/etc/android.hardware.sensor.gyroscope.xml \
    frameworks/native/data/etc/android.hardware.sensor.gyroscope_limited_axes.xml \
    frameworks/native/data/etc/android.hardware.sensor.gyroscope_limited_axes_uncalibrated.xml \
    frameworks/native/data/etc/android.hardware.sensor.heading.xml \
    frameworks/native/data/etc/android.hardware.sensor.heartrate.xml \
    frameworks/native/data/etc/android.hardware.sensor.heartrate.ecg.xml \
    frameworks/native/data/etc/android.hardware.sensor.heartrate.fitness.xml \
    frameworks/native/data/etc/android.hardware.sensor.hifi_sensors.xml \
    frameworks/native/data/etc/android.hardware.sensor.hinge_angle.xml \
    frameworks/native/data/etc/android.hardware.sensor.light.xml \
    frameworks/native/data/etc/android.hardware.sensor.proximity.xml \
    frameworks/native/data/etc/android.hardware.sensor.relative_humidity.xml \
    frameworks/native/data/etc/android.hardware.sensor.stepcounter.xml \
    frameworks/native/data/etc/android.hardware.sensor.stepdetector.xml \
    device/aosplite/permissions/android.hardware.sensor.context_hub.xml

# ---------------------------------------------------------------------
# Location - 3 features, 2 source file(s)
AOSPLITE_FEATURES_location := \
    frameworks/native/data/etc/android.hardware.location.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml

# ---------------------------------------------------------------------
# Security - 21 features, 21 source file(s)
AOSPLITE_FEATURES_security := \
    frameworks/native/data/etc/android.hardware.strongbox_keystore.xml \
    device/aosplite/permissions/android.hardware.hardware_keystore.xml \
    frameworks/native/data/etc/android.hardware.keystore.app_attest_key.xml \
    frameworks/native/data/etc/android.hardware.keystore.limited_use_key.xml \
    frameworks/native/data/etc/android.hardware.keystore.single_use_key.xml \
    frameworks/native/data/etc/android.hardware.device_unique_attestation.xml \
    device/aosplite/permissions/android.hardware.security.model.compatible.xml \
    frameworks/native/data/etc/android.hardware.reboot_escrow.xml \
    device/aosplite/permissions/android.hardware.identity_credential.xml \
    frameworks/native/data/etc/android.hardware.se.omapi.ese.xml \
    frameworks/native/data/etc/android.hardware.se.omapi.sd.xml \
    frameworks/native/data/etc/android.hardware.se.omapi.uicc.xml \
    frameworks/native/data/etc/android.hardware.fingerprint.xml \
    frameworks/native/data/etc/android.hardware.biometrics.face.xml \
    frameworks/native/data/etc/android.software.secure_lock_screen.xml \
    frameworks/native/data/etc/android.software.verified_boot.xml \
    frameworks/native/data/etc/android.software.device_id_attestation.xml \
    frameworks/native/data/etc/android.software.credentials.xml \
    device/aosplite/permissions/android.software.device_lock.xml \
    frameworks/native/data/etc/android.software.ipsec_tunnels.xml \
    frameworks/native/data/etc/android.software.ipsec_tunnel_migration.xml

# ---------------------------------------------------------------------
# Graphics - 6 features, 6 source file(s)
AOSPLITE_FEATURES_graphics := \
    frameworks/native/data/etc/android.hardware.vulkan.compute-0.xml \
    frameworks/native/data/etc/android.hardware.vulkan.level-0.xml \
    frameworks/native/data/etc/android.hardware.vulkan.version-1_0_3.xml \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.software.vulkan.deqp.level-2019-03-01.xml \
    frameworks/native/data/etc/android.software.opengles.deqp.level-2020-03-01.xml

# ---------------------------------------------------------------------
# DisplayInput - 16 features, 15 source file(s)
AOSPLITE_FEATURES_input := \
    frameworks/native/data/etc/android.hardware.touchscreen.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.distinct.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.hardware.faketouch.xml \
    frameworks/native/data/etc/android.hardware.faketouch.multitouch.distinct.xml \
    frameworks/native/data/etc/android.hardware.faketouch.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.hardware.screen.landscape.xml \
    frameworks/native/data/etc/android.hardware.screen.portrait.xml \
    frameworks/native/data/etc/android.hardware.gamepad.xml \
    frameworks/native/data/etc/android.hardware.hdmi.cec.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml \
    device/aosplite/permissions/android.software.input_methods.xml \
    frameworks/native/data/etc/android.software.window_magnification.xml

# ---------------------------------------------------------------------
# FormFactor - 11 features, 11 source file(s)
AOSPLITE_FEATURES_formfactor := \
    frameworks/native/data/etc/android.hardware.type.automotive.xml \
    device/aosplite/permissions/android.hardware.type.embedded.xml \
    device/aosplite/permissions/android.hardware.type.pc.xml \
    device/aosplite/permissions/android.hardware.type.television.xml \
    device/aosplite/permissions/android.hardware.type.watch.xml \
    device/aosplite/permissions/android.software.leanback.xml \
    device/aosplite/permissions/android.software.leanback_only.xml \
    frameworks/native/data/etc/android.software.live_tv.xml \
    frameworks/native/data/etc/android.hardware.tv.tuner.xml \
    device/aosplite/permissions/com.google.android.tv.installed.xml \
    device/aosplite/permissions/com.google.android.tv.mdns_offload.xml

# ---------------------------------------------------------------------
# Automotive - 4 features, 4 source file(s)
AOSPLITE_FEATURES_automotive := \
    device/aosplite/permissions/android.software.car.display_compatibility.xml \
    device/aosplite/permissions/android.software.car.splitscreen_multitasking.xml \
    device/aosplite/permissions/android.software.car.templates_host.xml \
    device/aosplite/permissions/com.android.car.background_audio_while_driving.xml

# ---------------------------------------------------------------------
# XRVR - 8 features, 8 source file(s)
AOSPLITE_FEATURES_xr := \
    frameworks/native/data/etc/android.hardware.vr.headtracking-0.xml \
    frameworks/native/data/etc/android.hardware.vr.high_performance.xml \
    frameworks/native/data/etc/android.software.vr.xml \
    frameworks/native/data/etc/android.hardware.xr.input.controller.xml \
    frameworks/native/data/etc/android.hardware.xr.input.eye_tracking.xml \
    frameworks/native/data/etc/android.hardware.xr.input.hand_tracking.xml \
    frameworks/native/data/etc/android.software.xr.api.openxr-1_0.xml \
    frameworks/native/data/etc/android.software.xr.api.spatial-1.xml

# ---------------------------------------------------------------------
# SystemUX - 22 features, 22 source file(s)
AOSPLITE_FEATURES_system := \
    device/aosplite/permissions/android.software.home_screen.xml \
    frameworks/native/data/etc/android.software.app_widgets.xml \
    frameworks/native/data/etc/android.software.activities_on_secondary_displays.xml \
    frameworks/native/data/etc/android.software.freeform_window_management.xml \
    frameworks/native/data/etc/android.software.picture_in_picture.xml \
    frameworks/native/data/etc/android.software.autofill.xml \
    frameworks/native/data/etc/android.software.backup.xml \
    device/aosplite/permissions/android.software.cant_save_state.xml \
    frameworks/native/data/etc/android.software.companion_device_setup.xml \
    frameworks/native/data/etc/android.software.controls.xml \
    frameworks/native/data/etc/android.software.device_admin.xml \
    frameworks/native/data/etc/android.software.managed_users.xml \
    frameworks/native/data/etc/android.software.securely_removes_users.xml \
    frameworks/native/data/etc/android.software.print.xml \
    frameworks/native/data/etc/android.software.webview.xml \
    frameworks/native/data/etc/android.software.voice_recognizers.xml \
    device/aosplite/permissions/android.software.live_wallpaper.xml \
    device/aosplite/permissions/android.software.virtualization_framework.xml \
    frameworks/native/data/etc/android.software.app_compat_overrides.xml \
    frameworks/native/data/etc/android.software.preview_sdk.xml \
    frameworks/native/data/etc/android.software.cts.xml \
    device/aosplite/permissions/com.google.android.mainline.patchlevel.2.xml

# ---------------------------------------------------------------------
# all - every set above. The default.
AOSPLITE_FEATURES_all := \
    $(AOSPLITE_FEATURES_audio) \
    $(AOSPLITE_FEATURES_bluetooth) \
    $(AOSPLITE_FEATURES_wifi) \
    $(AOSPLITE_FEATURES_telephony) \
    $(AOSPLITE_FEATURES_radios) \
    $(AOSPLITE_FEATURES_camera) \
    $(AOSPLITE_FEATURES_sensors) \
    $(AOSPLITE_FEATURES_location) \
    $(AOSPLITE_FEATURES_security) \
    $(AOSPLITE_FEATURES_graphics) \
    $(AOSPLITE_FEATURES_input) \
    $(AOSPLITE_FEATURES_formfactor) \
    $(AOSPLITE_FEATURES_automotive) \
    $(AOSPLITE_FEATURES_xr) \
    $(AOSPLITE_FEATURES_system)

AOSPLITE_FEATURE_SETS ?= all

# sort de-duplicates: a source file named by two sets is copied once.
PRODUCT_COPY_FILES += $(sort $(foreach set,$(AOSPLITE_FEATURE_SETS),\
                        $(foreach src,$(AOSPLITE_FEATURES_$(set)),\
                          $(src):$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/$(notdir $(src)))))
