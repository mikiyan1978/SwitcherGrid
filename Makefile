ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SwitcherGrid

SwitcherGrid_FILES = Tweak.x
SwitcherGrid_CFLAGS = -fobjc-arc
SwitcherGrid_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = SwitcherGridPrefs

SwitcherGridPrefs_FILES = Prefs/SGRootListController.m
SwitcherGridPrefs_FRAMEWORKS = UIKit
SwitcherGridPrefs_PRIVATE_FRAMEWORKS = Preferences
SwitcherGridPrefs_INSTALL_PATH = /Library/PreferenceBundles
SwitcherGridPrefs_CFLAGS = -fobjc-arc
SwitcherGridPrefs_RESOURCE_DIRS = Prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
