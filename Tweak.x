// SquidGesture.x — System-wide gesture control tweak v1.1.0
// Two-stage architecture:
//   - App process: detect gestures -> Darwin notify
//   - SpringBoard: listen -> execute actions via private APIs directly
// (SpringBoardServices SBSSpringBoardServerPortHome/LockDevice/ShowAppSwitcher
//  were REMOVED in iOS 16 — dlsym returned NULL, actions silently skipped.)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <notify.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Photos/Photos.h>

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

#pragma mark - Process detection

static BOOL isSpringBoard(void) {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSString *name = [pi processName] ?: @"";
    return [name isEqualToString:@"SpringBoard"];
}

#pragma mark - SpringBoardServices (symbols verified in iOS 16.5 tbd)

typedef mach_port_t (*PortFunc)(void);
typedef void (*SuspendFunc)(mach_port_t);

static PortFunc gGetPort = NULL;
static SuspendFunc gSuspendFrontmost = NULL;

static void initSBS(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/"
        "SpringBoardServices",
        RTLD_LAZY);
    if (!h) return;
    gGetPort = (PortFunc)dlsym(h, "SBSSpringBoardServerPort");
    gSuspendFrontmost = (SuspendFunc)dlsym(h, "SBSSuspendFrontmostApplication");
}

#pragma mark - Darwin actions

#define kNotifyHome     "com.minis.squidgesture.action.home"
#define kNotifyLock     "com.minis.squidgesture.action.lock"
#define kNotifySwitcher "com.minis.squidgesture.action.switcher"

static void vibrate(void) {
    if (gVibrationFeedback) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

#pragma mark - SpringBoard-side executors (run in SpringBoard process)

static void sbHome(void) {
    // Suspend frontmost app == home button press equivalent
    if (gSuspendFrontmost && gGetPort) {
        mach_port_t p = gGetPort();
        if (p) gSuspendFrontmost(p);
    }
}

static void sbLock(void) {
    Class c = objc_getClass("SBLockScreenManager");
    if (c) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstance"));
        if (!inst) inst = ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstanceIfExists"));
        SEL lockSel = NSSelectorFromString(@"lockUIFromSource:withOptions:");
        if (inst && [inst respondsToSelector:lockSel]) {
            ((void(*)(id, SEL, long, id))objc_msgSend)(inst, lockSel, 0, nil);
            return;
        }
    }
}

static void sbSwitcher(void) {
    // Way 1: SBUIController home-button double press (system path)
    Class c = objc_getClass("SBUIController");
    if (c) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstance"));
        SEL dp = NSSelectorFromString(@"handleHomeButtonDoublePressDown");
        if (inst && [inst respondsToSelector:dp]) {
            ((BOOL(*)(id, SEL))objc_msgSend)(inst, dp);
            return;
        }
    }
    // Way 2: SBMainSwitcherControllerCoordinator toggle
    Class coord = objc_getClass("SBMainSwitcherControllerCoordinator");
    if (coord) {
        SEL shimSel = NSSelectorFromString(@"_shim_activeSwitcherController");
        id sc = nil;
        if ([coord respondsToSelector:shimSel])
            sc = ((id(*)(id, SEL))objc_msgSend)(coord, shimSel);
        else
            sc = ((id(*)(id, SEL))objc_msgSend)(coord, NSSelectorFromString(@"sharedInstance"));
        SEL toggleSel = NSSelectorFromString(@"toggleMainSwitcherWithSource:animated:");
        if (sc && [sc respondsToSelector:toggleSel]) {
            ((void(*)(id, SEL, long, BOOL))objc_msgSend)(sc, toggleSel, 20, YES);
            return;
        }
    }
}

// Darwin notification callback (SpringBoard only)
static void actionNotifyCb(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (CFStringCompare(n, CFSTR(kNotifyLock), 0) == kCFCompareEqualTo) {
            vibrate();
            sbLock();
        } else if (CFStringCompare(n, CFSTR(kNotifySwitcher), 0) == kCFCompareEqualTo) {
            vibrate();
            sbSwitcher();
        } else if (CFStringCompare(n, CFSTR(kNotifyHome), 0) == kCFCompareEqualTo) {
            // App already suspended itself; this is the safety net
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbHome(); });
        }
    });
}

#pragma mark - App-side actions (run in normal app process)

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

static void appSuspendSelf(void) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"suspend");
    if (app && [app respondsToSelector:sel])
        ((void(*)(id, SEL))objc_msgSend)(app, sel);
}

static void doHome(void) {
    vibrate();
    if (isSpringBoard()) {
        sbHome();
        return;
    }
    // Primary: suspend current app (== home button, process-local, no sandbox issue)
    appSuspendSelf();
    // Safety net: ask SpringBoard to suspend frontmost app too
    notify_post(kNotifyHome);
}

static void doLock(void) {
    vibrate();
    if (isSpringBoard()) sbLock();
    else notify_post(kNotifyLock);
}

static void doSwitcher(void) {
    vibrate();
    if (isSpringBoard()) sbSwitcher();
    else notify_post(kNotifySwitcher);
}

static void doBack(void) {
    vibrate();
    UIViewController *vc = topVC();
    if (!vc) return;
    UINavigationController *nav = vc.navigationController;
    if (!nav) {
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        UIViewController *root = win ? win.rootViewController : nil;
        if ([root isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = [(UITabBarController *)root selectedViewController];
            if ([sel isKindOfClass:[UINavigationController class]])
                nav = (UINavigationController *)sel;
        }
    }
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
    }
    // No nav stack -> nothing to go back to
}

static void doScreenshot(void) {
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
        if (!img) return;

        // Permission-aware save: silent fail/crash risks otherwise
        PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);
        } else {
            // Fallback: temporary file + share sheet
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SquidGesture.png"];
            [UIImagePNGRepresentation(img) writeToFile:path atomically:YES];
            NSURL *url = [NSURL fileURLWithPath:path];
            UIActivityViewController *avc =
                [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            UIViewController *top = topVC();
            if (top) {
                if (avc.popoverPresentationController)
                    avc.popoverPresentationController.sourceView = top.view;
                [top presentViewController:avc animated:YES completion:nil];
            }
        }
    });
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
    if (g.state == UIGestureRecognizerStateEnded) doBack();
}

- (void)onRightPan:(UIScreenEdgePanGestureRecognizer *)g {
    if (!gEnabled || !gRightEdgeSwitcher) return;
    if (g.state == UIGestureRecognizerStateEnded) doSwitcher();
}

- (void)onCornerTap:(UITapGestureRecognizer *)g {
    if (!gEnabled) return;
    CGPoint loc = [g locationInView:g.view];
    CGRect b = g.view.bounds;
    BOOL topLeft = loc.x < gCornerSize && loc.y < gCornerSize;
    BOOL topRight = loc.x > b.size.width - gCornerSize && loc.y < gCornerSize;
    if (topLeft && gCornerTapLock) doLock();
    else if (topRight && gCornerTapScreenshot) doScreenshot();
}

- (void)onThreeFingerUp:(UISwipeGestureRecognizer *)g {
    if (!gEnabled || !gThreeFingerHome) return;
    doHome();
}

- (void)onThreeFingerDown:(UISwipeGestureRecognizer *)g {
    if (!gEnabled || !gThreeFingerSwitcher) return;
    doSwitcher();
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

    // Preferences reload
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, prefsChangedCb,
        CFSTR("com.minis.squidgesture.prefs-changed"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);

    // Action executor listeners — SpringBoard process only
    if (isSpringBoard()) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, actionNotifyCb,
            CFSTR(kNotifyHome), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, actionNotifyCb,
            CFSTR(kNotifyLock), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, actionNotifyCb,
            CFSTR(kNotifySwitcher), NULL, CFNotificationSuspensionBehaviorCoalesce);
    }

    // Attach gestures to existing key window
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [[SGHandler shared] attachToWindow:w];
    });
}