TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SquidGesture

SquidGesture_FILES = Tweak.x
SquidGesture_FRAMEWORKS = UIKit AudioToolbox
SquidGesture_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
