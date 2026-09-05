ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

# Build a rootless .deb (Dopamine / palera1n rootless / roothide, etc.)
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HotspotSSIDChanger

HotspotSSIDChanger_FILES = Tweak.x
HotspotSSIDChanger_CFLAGS = -fobjc-arc
HotspotSSIDChanger_FRAMEWORKS = Foundation CoreFoundation SystemConfiguration UIKit
HotspotSSIDChanger_PRIVATE_FRAMEWORKS = Preferences
HotspotSSIDChanger_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# Build the Preferences bundle alongside the tweak
SUBPROJECTS += HotspotSSIDChangerPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
