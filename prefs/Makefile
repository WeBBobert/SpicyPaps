include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = BatteryHidePrefs
BatteryHidePrefs_FILES = BHRootController.m
BatteryHidePrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
BatteryHidePrefs_PRIVATE_FRAMEWORKS = Preferences
BatteryHidePrefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
BatteryHidePrefs_INSTALL_PATH = /Library/PreferenceBundles
BatteryHidePrefs_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations
include $(THEOS_MAKE_PATH)/bundle.mk
