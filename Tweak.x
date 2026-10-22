// SquidGesture.x — System-wide gesture control tweak
// Edge swipes, corner taps, multi-finger gestures
// Config: /var/mobile/Library/Preferences/com.minis.squidgesture.plist

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - Settings

static BOOL gEnabled = YES;
static CGFloat gCornerSize = 80.0;

static BOOL gLeftEdgeBack = YES;
static BOOL gRightEdgeSwitcher = YES;
static BOOL gCornerTapLock = YES;
static BOOL gCornerTapScreenshot = YES;
static BOOL gThreeFingerHome = YES;
static BOOL gThreeFingerSwitcher = YES;
static BOOL gVibrationFeedback = YES;

#pragma mark - Preferences

static NSString *const kPrefsFile =
    @"/var/mobile/Library/Preferences/com.minis.squidgesture.plist";

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kPrefsFile];
    if (!p) return;
#define LOAD(k, v, t) if (p[@(k)]) v = [p[@(k)] t]
    LOAD("Enabled", gEnabled, boolValue);
    LOAD("CornerSize", gCornerSize, floatValue);
    LOAD("LeftEdgeBack", gLeftEdgeBack, boolValue);
    LOAD("RightEdgeSwitcher", gRightEdgeSwitcher, boolValue);
    LOAD("CornerTapLock", gCornerTapLock, boolValue);
    LOAD("CornerTapScreenshot", gCornerTapScreenshot, boolValue);
    LOAD("ThreeFingerHome", gThreeFingerHome, boolValue);
    LOAD("ThreeFingerSwitcher", gThreeFingerSwitcher, boolValue);
    LOAD("VibrationFeedback", gVibrationFeedback, boolValue);
#undef LOAD
}

static void prefsChangedCb(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *obj, CFDictionaryRef ui) {
    loadPrefs();
}

#pragma mark - SpringBoardServices (dlsym)

typedef mach_port_t (*PortFunc)(void);
typedef void (*PortActionFunc)(mach_port_t);

static PortFunc gGetPort = NULL;
static PortActionFunc gHome = NULL;
static PortActionFunc gLock = NULL;
static PortActionFunc gShowAppSwitcher = NULL;

static void initSBS(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/"
        "SpringBoardServices",
        RTLD_LAZY);
    if (!h) return;
    gGetPort = (PortFunc)dlsym(h, "SBSSpringBoardServerPort");
    gHome = (PortActionFunc)dlsym(h, "SBSSpringBoardServerPortHome");
    gLock = (PortActionFunc)dlsym(h, "SBSSpringBoardServerPortLockDevice");
    gShowAppSwitcher = (PortActionFunc)dlsym(h, "SBSSpringBoardServerPortShowAppSwitcher");
}

static mach_port_t getPort(void) { return gGetPort ? gGetPort() : 0; }

#pragma mark - Actions

static void vibrate(void) {
    if (gVibrationFeedback) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

static void actionHome(void) {
    vibrate();
    if (gHome) { mach_port_t p = getPort(); if (p) gHome(p); }
}

static void actionLock(void) {
    vibrate();
    if (gLock) { mach_port_t p = getPort(); if (p) gLock(p); }
}

static void actionAppSwitcher(void) {
    vibrate();
    if (gShowAppSwitcher) {
        mach_port_t p = getPort();
        if (p) { gShowAppSwitcher(p); return; }
    }
    // Fallback: go home
    if (gHome) { mach_port_t p = getPort(); if (p) gHome(p); }
}

static void actionScreenshot(void) {
    vibrate();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.windowLevel == UIWindowLevelNormal) { window = w; break; }
        }
        if (!window) window = [UIApplication sharedApplication].keyWindow;
        if (!window) return;

        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
        }];
        if (img) UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);
    });
}

static UIViewController *topVC(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UITabBarController class]])
        vc = [(UITabBarController *)vc selectedViewController];
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = [(UINavigationController *)vc visibleViewController];
    return vc;
}

static void actionBack(void) {
    vibrate();
    UIViewController *vc = topVC();
    if (!vc) return;
    UINavigationController *nav = vc.navigationController;
    if (!nav) {
        // No nav stack — if in a tab bar, try tab's nav
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        UIViewController *root = win.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = [(UITabBarController *)root selectedViewController];
            if ([sel isKindOfClass:[UINavigationController class]])
                nav = (UINavigationController *)sel;
        }
    }
    if (nav && nav.viewControllers.count > 1) {
        // System interactive pop may also fire — just let it
        // Only pop if not already transitioning
        if (!nav.isTransitioning) [nav popViewControllerAnimated:YES];
    }
    // No nav stack → do nothing (or go home)
}

#pragma mark - Gesture Handler

@interface SGHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToWindow:(UIWindow *)window;
@end

static char kAttachedKey;

@implementation SGHandler

+ (instancetype)shared {
    static SGHandler *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [SGHandler new]; });
    return s;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)attachToWindow:(UIWindow *)window {
    if (objc_getAssociatedObject(window, &kAttachedKey)) return;
    objc_setAssociatedObject(window, &kAttachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (gLeftEdgeBack) {
        UIScreenEdgePanGestureRecognizer *g =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:self action:@selector(onLeftPan:)];
        g.edges = UIRectEdgeLeft;
        g.delegate = self;
        [window addGestureRecognizer:g];
    }

    if (gRightEdgeSwitcher) {
        UIScreenEdgePanGestureRecognizer *g =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:self action:@selector(onRightPan:)];
        g.edges = UIRectEdgeRight;
        g.delegate = self;
        [window addGestureRecognizer:g];
    }

    if (gCornerTapLock || gCornerTapScreenshot) {
        UITapGestureRecognizer *g =
            [[UITapGestureRecognizer alloc]
                initWithTarget:self action:@selector(onCornerTap:)];
        g.numberOfTapsRequired = 2;
        g.delegate = self;
        [window addGestureRecognizer:g];
    }

    if (gThreeFingerHome) {
        UISwipeGestureRecognizer *g =
            [[UISwipeGestureRecognizer alloc]
                initWithTarget:self action:@selector(onThreeFingerUp:)];
        g.direction = UISwipeGestureRecognizerDirectionUp;
        g.numberOfTouchesRequired = 3;
        g.delegate = self;
        [window addGestureRecognizer:g];
    }

    if (gThreeFingerSwitcher) {
        UISwipeGestureRecognizer *g =
            [[UISwipeGestureRecognizer alloc]
                initWithTarget:self action:@selector(onThreeFingerDown:)];
        g.direction = UISwipeGestureRecognizerDirectionDown;
        g.numberOfTouchesRequired = 3;
        g.delegate = self;
        [window addGestureRecognizer:g];
    }
}

- (void)onLeftPan:(UIScreenEdgePanGestureRecognizer *)g {
    if (!gEnabled || !gLeftEdgeBack) return;
    if (g.state == UIGestureRecognizerStateEnded) actionBack();
}

- (void)onRightPan:(UIScreenEdgePanGestureRecognizer *)g {
    if (!gEnabled || !gRightEdgeSwitcher) return;
    if (g.state == UIGestureRecognizerStateEnded) actionAppSwitcher();
}

- (void)onCornerTap:(UITapGestureRecognizer *)g {
    if (!gEnabled) return;
    CGPoint loc = [g locationInView:g.view];
    CGRect b = g.view.bounds;
    BOOL topLeft = loc.x < gCornerSize && loc.y < gCornerSize;
    BOOL topRight = loc.x > b.size.width - gCornerSize && loc.y < gCornerSize;
    if (topLeft && gCornerTapLock) actionLock();
    else if (topRight && gCornerTapScreenshot) actionScreenshot();
}

- (void)onThreeFingerUp:(UISwipeGestureRecognizer *)g {
    if (!gEnabled || !gThreeFingerHome) return;
    actionHome();
}

- (void)onThreeFingerDown:(UISwipeGestureRecognizer *)g {
    if (!gEnabled || !gThreeFingerSwitcher) return;
    actionAppSwitcher();
}

@end

#pragma mark - Hooks

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    if (gEnabled) [[SGHandler shared] attachToWindow:self];
}
%end

#pragma mark - Constructor

%ctor {
    loadPrefs();
    initSBS();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, prefsChangedCb,
        CFSTR("com.minis.squidgesture.prefs-changed"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);

    // Attach to existing key window after delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [[SGHandler shared] attachToWindow:w];
    });
}
