export TARGET = iphone:clang:latest:18.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Preferences
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = BatteryHide
BatteryHide_FILES = Tweak.x
BatteryHide_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-deprecated-declarations
BatteryHide_FRAMEWORKS = UIKit Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
