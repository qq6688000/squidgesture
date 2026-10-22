// SquidGesture.x — System-wide gesture control tweak v1.2.0
// Fixes over v1.1.0:
//  1. Lock: use SBLockDevice(port,1) — the exact call Apple's own MDM
//     framework (DMDLockUtilities) uses. Symbol verified in iPhoneOS16.5.tbd.
//     (v1.1 tried SBLockScreenManager lockUIFromSource: which does nothing for
//      a plain lock request.)
//  2. Screenshot: force a visible flash + write a debug log so silent failures
//     become diagnosable; keep permission-aware save + share fallback.
//  3. QQ: attach gestures to ALL windows (QQ puts touch handling on its own
//     high-level windows, not the key window), and hook makeKeyWindow/
//     makeKeyAndVisible/becomeKeyWindow.

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
static BOOL gDebugLog = NO;

static NSString *const kPrefsFile =
    @"/var/mobile/Library/Preferences/com.minis.squidgesture.plist";
static NSString *const kLogFile =
    @"/var/mobile/Library/Preferences/com.minis.squidgesture.log";

static void SGLog(NSString *fmt, ...) {
    if (!gDebugLog) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [NSDate date], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:kLogFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

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
    LOAD("DebugLog", gDebugLog, boolValue);
#undef LOAD
}

static void prefsChangedCb(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *obj, CFDictionaryRef ui) {
    loadPrefs();
}

#pragma mark - Process detection

static BOOL isSpringBoard(void) {
    NSString *name = [[NSProcessInfo processInfo] processName] ?: @"";
    return [name isEqualToString:@"SpringBoard"];
}

#pragma mark - SpringBoardServices (all symbols verified in iPhoneOS16.5.tbd)

typedef mach_port_t (*PortFunc)(void);
typedef void (*SuspendFunc)(mach_port_t);
typedef void (*LockFunc)(mach_port_t, int);
typedef void (*DimFunc)(mach_port_t, int);

static PortFunc gGetPort = NULL;
static SuspendFunc gSuspendFrontmost = NULL;
static LockFunc gLockDevice = NULL;
static DimFunc gDimScreen = NULL;

static void initSBS(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/"
        "SpringBoardServices", RTLD_LAZY);
    if (!h) { SGLog(@"SBS dlopen failed"); return; }
    gGetPort        = (PortFunc)dlsym(h, "SBSSpringBoardServerPort");
    gSuspendFrontmost = (SuspendFunc)dlsym(h, "SBSSuspendFrontmostApplication");
    // Apple's own MDM (DMDLockUtilities) does: SBLockDevice(port, 1)
    gLockDevice     = (LockFunc)dlsym(h, "SBLockDevice");
    gDimScreen      = (DimFunc)dlsym(h, "SBDimScreen");
    SGLog(@"SBS symbols port=%p suspend=%p lock=%p dim=%p",
          gGetPort, gSuspendFrontmost, gLockDevice, gDimScreen);
}

#pragma mark - Darwin actions

#define kNotifyHome     "com.minis.squidgesture.action.home"
#define kNotifyLock     "com.minis.squidgesture.action.lock"
#define kNotifySwitcher "com.minis.squidgesture.action.switcher"

static void vibrate(void) {
    if (gVibrationFeedback) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

#pragma mark - SpringBoard-side executors (run inside SpringBoard)

static void sbHome(void) {
    SGLog(@"sbHome: suspend=%p port=%p", gSuspendFrontmost, gGetPort);
    if (gSuspendFrontmost && gGetPort) {
        mach_port_t p = gGetPort();
        if (p) { gSuspendFrontmost(p); return; }
    }
    SGLog(@"sbHome: no symbol -> fallback");
    Class c = objc_getClass("SBUIController");
    if (c) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstance"));
        SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:");
        SEL alt = NSSelectorFromString(@"handleHomeButtonDoublePressDown");
        if (inst && [inst respondsToSelector:alt])
            ((BOOL(*)(id, SEL))objc_msgSend)(inst, alt);
        (void)sel;
    }
}

static void sbLock(void) {
    mach_port_t p = gGetPort ? gGetPort() : 0;
    SGLog(@"sbLock: port=%u lock=%p dim=%p", p, gLockDevice, gDimScreen);
    if (p && gLockDevice) {
        gLockDevice(p, 1);   // exactly what Apple's DMDLockUtilities does
        if (gDimScreen) gDimScreen(p, 1);
        return;
    }
    // Fallback chain
    Class c = objc_getClass("SBLockScreenManager");
    if (c) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstance"));
        SEL sel = NSSelectorFromString(@"lockUIFromSource:withOptions:");
        if (inst && [inst respondsToSelector:sel]) {
            SGLog(@"sbLock: SBS lockUIFromSource fallback");
            ((void(*)(id, SEL, long, id))objc_msgSend)(inst, sel, 0, nil);
        }
    }
}

static void sbSwitcher(void) {
    SGLog(@"sbSwitcher");
    Class c = objc_getClass("SBUIController");
    if (c) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstance"));
        SEL dp = NSSelectorFromString(@"handleHomeButtonDoublePressDown");
        if (inst && [inst respondsToSelector:dp]) {
            ((BOOL(*)(id, SEL))objc_msgSend)(inst, dp);
            return;
        }
    }
    Class coord = objc_getClass("SBMainSwitcherControllerCoordinator");
    if (coord) {
        id sc = nil;
        SEL shim = NSSelectorFromString(@"_shim_activeSwitcherController");
        if ([coord respondsToSelector:shim])
            sc = ((id(*)(id, SEL))objc_msgSend)(coord, shim);
        else
            sc = ((id(*)(id, SEL))objc_msgSend)(coord, NSSelectorFromString(@"sharedInstance"));
        SEL toggle = NSSelectorFromString(@"toggleMainSwitcherWithSource:animated:");
        if (sc && [sc respondsToSelector:toggle]) {
            ((void(*)(id, SEL, long, BOOL))objc_msgSend)(sc, toggle, 20, YES);
        }
    }
}

static void actionNotifyCb(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (CFStringCompare(n, CFSTR(kNotifyLock), 0) == kCFCompareEqualTo) {
            vibrate(); sbLock();
        } else if (CFStringCompare(n, CFSTR(kNotifySwitcher), 0) == kCFCompareEqualTo) {
            vibrate(); sbSwitcher();
        } else if (CFStringCompare(n, CFSTR(kNotifyHome), 0) == kCFCompareEqualTo) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbHome(); });
        }
    });
}

#pragma mark - App-side actions

static UIViewController *topVC(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (w.isKeyWindow) { win = w; break; }
    }
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
    if (isSpringBoard()) { sbHome(); return; }
    appSuspendSelf();
    notify_post(kNotifyHome);
}

static void doLock(void) {
    vibrate();
    SGLog(@"doLock: isSpringBoard=%d", isSpringBoard());
    if (isSpringBoard()) { sbLock(); return; }
    notify_post(kNotifyLock);
}

static void doSwitcher(void) {
    vibrate();
    if (isSpringBoard()) { sbSwitcher(); return; }
    notify_post(kNotifySwitcher);
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
    if (nav && nav.viewControllers.count > 1) [nav popViewControllerAnimated:YES];
}

// Crash-proof screenshot flash overlay
static void showFlash(void) {
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor whiteColor];
    w.alpha = 1.0;
    w.userInteractionEnabled = NO;
    w.rootViewController = [[UIViewController alloc] init];
    [w makeKeyAndVisible];
    [UIView animateWithDuration:0.28 animations:^{
        w.alpha = 0.0;
    } completion:^(BOOL finished) {
        w.hidden = YES;
    }];
}

static void doScreenshot(void) {
    vibrate();
    SGLog(@"doScreenshot: isSpringBoard=%d", isSpringBoard());
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.windowLevel == UIWindowLevelNormal && w.bounds.size.width > 0) {
                window = w; break;
            }
        }
        if (!window) window = [UIApplication sharedApplication].keyWindow;
        if (!window) { SGLog(@"doScreenshot: no window"); return; }
        SGLog(@"doScreenshot: window=%@ size=%@", window, NSStringFromCGRect(window.bounds));

        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
        }];
        if (!img) { SGLog(@"doScreenshot: render failed"); return; }
        SGLog(@"doScreenshot: img=%@", NSStringFromCGSize(img.size));
        showFlash();

        PHAuthorizationStatus st =
            [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        SGLog(@"doScreenshot: photoAuth=%ld", (long)st);

        if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);
            SGLog(@"doScreenshot: saved to album");
        } else {
            NSString *path = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"SquidGesture.png"];
            BOOL ok = [UIImagePNGRepresentation(img) writeToFile:path atomically:YES];
            SGLog(@"doScreenshot: wrote tmp=%d path=%@", ok, path);
            NSURL *url = [NSURL fileURLWithPath:path];
            UIActivityViewController *avc = [[UIActivityViewController alloc]
                initWithActivityItems:@[url] applicationActivities:nil];
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

// Let taps/swipes fall through to app UI too (non-destructive)
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
       shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    if (objc_getAssociatedObject(window, &kAttachedKey)) return;
    objc_setAssociatedObject(window, &kAttachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGLog(@"attach to window %@ level=%.1f", NSStringFromClass([window class]),
          (double)window.windowLevel);

    if (gLeftEdgeBack) {
        UIScreenEdgePanGestureRecognizer *g =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:self action:@selector(onLeftPan:)];
        g.edges = UIRectEdgeLeft; g.delegate = self;
        [window addGestureRecognizer:g];
    }
    if (gRightEdgeSwitcher) {
        UIScreenEdgePanGestureRecognizer *g =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:self action:@selector(onRightPan:)];
        g.edges = UIRectEdgeRight; g.delegate = self;
        [window addGestureRecognizer:g];
    }
    if (gCornerTapLock || gCornerTapScreenshot) {
        UITapGestureRecognizer *g =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(onCornerTap:)];
        g.numberOfTapsRequired = 2; g.delegate = self;
        g.cancelsTouchesInView = NO;   // don't eat app taps
        [window addGestureRecognizer:g];
    }
    if (gThreeFingerHome) {
        UISwipeGestureRecognizer *g =
            [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(onThreeFingerUp:)];
        g.direction = UISwipeGestureRecognizerDirectionUp;
        g.numberOfTouchesRequired = 3; g.delegate = self;
        [window addGestureRecognizer:g];
    }
    if (gThreeFingerSwitcher) {
        UISwipeGestureRecognizer *g =
            [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(onThreeFingerDown:)];
        g.direction = UISwipeGestureRecognizerDirectionDown;
        g.numberOfTouchesRequired = 3; g.delegate = self;
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
    BOOL topLeft  = loc.x < gCornerSize && loc.y < gCornerSize;
    BOOL topRight = loc.x > b.size.width - gCornerSize && loc.y < gCornerSize;
    SGLog(@"cornerTap at %.0f,%.0f L=%d R=%d", loc.x, loc.y, topLeft, topRight);
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
- (void)makeKeyWindow {
    %orig;
    if (gEnabled) [[SGHandler shared] attachToWindow:self];
}
- (void)makeKeyAndVisible {
    %orig;
    if (gEnabled) [[SGHandler shared] attachToWindow:self];
}
%end

#pragma mark - Constructor

static void attachAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) {
        [[SGHandler shared] attachToWindow:w];
    }
    UIWindow *key = app.keyWindow;
    if (key) [[SGHandler shared] attachToWindow:key];
}

%ctor {
    loadPrefs();
    initSBS();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCb,
        CFSTR("com.minis.squidgesture.prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorCoalesce);

    if (isSpringBoard()) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyHome), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyLock), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifySwitcher), NULL, CFNotificationSuspensionBehaviorCoalesce);
    }

    // Attach immediately + polled re-attach (covers windows created later,
    // e.g. QQ's own overlay windows that never become key).
    attachAllWindows();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ attachAllWindows(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ attachAllWindows(); });

    // Periodic sweep for late-created windows
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ attachAllWindows(); });
    dispatch_resume(timer);
}