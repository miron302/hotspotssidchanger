include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HotspotSSIDChangerPrefs

HotspotSSIDChangerPrefs_FILES = HSSCRootListController.m
HotspotSSIDChangerPrefs_INSTALL_PATH = /Library/PreferenceBundles
HotspotSSIDChangerPrefs_FRAMEWORKS = UIKit CoreFoundation Foundation
HotspotSSIDChangerPrefs_PRIVATE_FRAMEWORKS = Preferences
HotspotSSIDChangerPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
