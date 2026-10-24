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

#import <unistd.h>
#import <sys/wait.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <notify.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Settings

static BOOL gEnabled = YES;
static CGFloat gCornerSize = 80.0;

static BOOL gLeftEdgeBack = YES;
static BOOL gRightEdgeSwitcher = YES;
static BOOL gCornerTapLock = YES;
static BOOL gCornerTapPower = YES;      // 2.1.0: left top-bar double tap
static BOOL gTwoFingerScreenshot = YES; // 2.1.0: two-finger swipe down
static BOOL gCornerTapScreenshot = YES;
static BOOL gThreeFingerHome = YES;
static BOOL gThreeFingerSwitcher = YES;
static BOOL gVibrationFeedback = YES;
static BOOL gDebugLog = YES;   // v1.4.0: on by default for diagnosis

// launcher panel
static BOOL gPanelEnabled = YES;
static BOOL gPanelVibrate = YES;
static BOOL gPanelPrewarm = YES;        // preload panel apps while the panel is open
static NSInteger gPanelPrewarmLimit = 4; // how many apps to prewarm per open
static CGFloat gPanelBarTolerance = 28.0; // band height ABOVE the bar's top edge
static CGFloat gPanelBarWidth     = 200.0; // zone width measured left from the right edge
static NSMutableArray<NSString *> *gPanelApps = nil;

@class SGLauncherVC;
static UIWindow *gPanelWindow;
static SGLauncherVC *gPanelVC;
static __weak UIWindow *gPanelPrevKey;
static void SGLauncherShow(void);
static void SGLauncherHide(void);

static __weak UIWindowScene *gCachedScene = nil;

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
    LOAD("CornerTapPower", gCornerTapPower, boolValue);
    LOAD("TwoFingerScreenshot", gTwoFingerScreenshot, boolValue);
    LOAD("CornerTapScreenshot", gCornerTapScreenshot, boolValue);
    LOAD("ThreeFingerHome", gThreeFingerHome, boolValue);
    LOAD("ThreeFingerSwitcher", gThreeFingerSwitcher, boolValue);
    LOAD("VibrationFeedback", gVibrationFeedback, boolValue);
    LOAD("DebugLog", gDebugLog, boolValue);
    LOAD("PanelEnabled", gPanelEnabled, boolValue);
    LOAD("PanelVibrate", gPanelVibrate, boolValue);
    LOAD("PanelPrewarm", gPanelPrewarm, boolValue);
#undef LOAD
    if (p[@"PanelPrewarmLimit"]) gPanelPrewarmLimit = [p[@"PanelPrewarmLimit"] integerValue];
    if (p[@"PanelBarTolerance"]) gPanelBarTolerance = [p[@"PanelBarTolerance"] floatValue];
    if (p[@"PanelBarWidth"]) gPanelBarWidth = [p[@"PanelBarWidth"] floatValue];

    NSArray *list = p[@"PanelApps"];
    if (!list) list = @[ @"com.apple.MobileSMS", @"com.apple.mobilesafari",
                         @"com.apple.camera", @"com.apple.mobiletimer",
                         @"com.apple.mobilenotes", @"com.apple.calculator" ];
    if ([list isKindOfClass:[NSArray class]]) {
        NSMutableArray *clean = [NSMutableArray array];
        for (id o in list)
            if ([o isKindOfClass:[NSString class]] && [o length]) [clean addObject:o];
        gPanelApps = clean;
    } else if (!gPanelApps) {
        gPanelApps = [NSMutableArray array];
    }
}

static void SGSavePanelApps(NSArray<NSString *> *apps) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsFile];
    if (!d) d = [NSMutableDictionary dictionary];
    d[@"PanelApps"] = apps ?: @[];
    BOOL ok = [d writeToFile:kPrefsFile atomically:YES];
    SGLog(@"save panel apps (%lu) -> %d", (unsigned long)apps.count, ok);
}

static void SGInvalidateCatalog(void);

static void prefsChangedCb(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *obj, CFDictionaryRef ui) {
    loadPrefs();
    SGInvalidateCatalog();
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
#define kNotifyPanel    "com.minis.squidgesture.action.panel"
// 2.1.0: left-half top-bar double tap -> power menu
#define kNotifyPower    "com.minis.squidgesture.action.power"
// 2.4.0: screenshot must run inside SpringBoard (apps cannot capture the screen)
#define kNotifyShot     "com.minis.squidgesture.action.screenshot"
// Fire this from a shell to open the panel without touching the screen:
//   notify_post com.minis.squidgesture.test.panel
#define kNotifyTest     "com.minis.squidgesture.test.panel"
// Emergency escape hatch - force-close the panel from a shell:
//   notify_post com.minis.squidgesture.test.hide
#define kNotifyHide     "com.minis.squidgesture.test.hide"

// 2.9.2: all haptic feedback removed at the user's request. Kept as no-op
// functions so every existing call site stays valid.
static void vibrate(void) { }
static void SGPanelVibrate(void) { }

#pragma mark - Launcher panel : app catalog

@interface SGCatalogItem : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) id proxy;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, assign) BOOL triedIcon;
@end

@implementation SGCatalogItem
@end

static NSArray<SGCatalogItem *> *gCachedCatalog = nil;
static BOOL gCatalogLoading = NO;

static void SGInvalidateCatalog(void);
static void SGInvalidateCatalog(void) {
    gCachedCatalog = nil;
    gCatalogLoading = NO;
}

static UIImage *SGLetterIcon(NSString *name, CGSize size) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CFArrayRef colors = (__bridge CFArrayRef) @[
            (id)[UIColor colorWithRed:0.36 green:0.42 blue:0.55 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.22 green:0.25 blue:0.34 alpha:1.0].CGColor
        ];
        CGGradientRef grad = CGGradientCreateWithColors(cs, colors, NULL);
        CGContextDrawLinearGradient(c, grad, CGPointZero,
                                    CGPointMake(size.width, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);

        NSString *ch = name.length ? [name substringToIndex:1] : @"?";
        NSDictionary *attrs = @{
            NSFontAttributeName :
                [UIFont systemFontOfSize:size.height * 0.5 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName : [UIColor whiteColor]
        };
        CGSize ts = [ch sizeWithAttributes:attrs];
        [ch drawAtPoint:CGPointMake((size.width - ts.width) / 2, (size.height - ts.height) / 2)
         withAttributes:attrs];
    }];
}

// Synchronous icon resolution. MUST NOT be called on the main thread.
static UIImage *SGResolveIcon(SGCatalogItem *item) {
    if (item.triedIcon) return item.icon;
    item.triedIcon = YES;

    UIImage *img = nil;
    if (item.bundleID.length) {
        SEL s1 = NSSelectorFromString(@"iconDataForVariant:");
        if ([item.proxy respondsToSelector:s1]) {
            @try {
                id d = ((id(*)(id, SEL, int))objc_msgSend)(item.proxy, s1, 0);
                if ([d isKindOfClass:[NSData class]] && [(NSData *)d length])
                    img = [UIImage imageWithData:d];
                else if ([d isKindOfClass:[UIImage class]])
                    img = d;
            } @catch (__unused NSException *e) {
            }
        }

        if (!img) {
            SEL bsel = NSSelectorFromString(@"bundleURL");
            NSURL *url = nil;
            if ([item.proxy respondsToSelector:bsel])
                url = ((id(*)(id, SEL))objc_msgSend)(item.proxy, bsel);
            if ([url isKindOfClass:[NSURL class]]) {
                NSMutableArray *names = [NSMutableArray array];
                for (NSString *key in @[ @"CFBundleIcons", @"CFBundleIcons~ipad" ]) {
                    NSDictionary *info = [NSDictionary
                        dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]];
                    NSArray *files = info[key][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
                    if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
                }
                if (!names.count) [names addObject:@"AppIcon60x60"];
                for (NSString *base in [names reverseObjectEnumerator]) {
                    for (NSString *suffix in @[ @"@3x.png", @"@2x.png", @".png" ]) {
                        NSString *p = [[url path]
                            stringByAppendingPathComponent:[base stringByAppendingString:suffix]];
                        img = [UIImage imageWithContentsOfFile:p];
                        if (img) break;
                    }
                    if (img) break;
                }
            }
        }
    }
    item.icon = img;
    return img;
}

// Never blocks: returns the cached icon or a letter placeholder.
static UIImage *SGIconQuick(SGCatalogItem *item, CGSize size) {
    if (item.icon) return item.icon;
    NSString *label = item.name ?: item.bundleID ?: @"?";
    return SGLetterIcon(label, size);
}

static id SGLookupWorkspace(void) {
    Class LSAppWorkspace = objc_getClass("LSApplicationWorkspace");
    if (!LSAppWorkspace) {
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
               RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        LSAppWorkspace = objc_getClass("LSApplicationWorkspace");
    }
    if (!LSAppWorkspace) return nil;
    SEL dw = NSSelectorFromString(@"defaultWorkspace");
    if (![LSAppWorkspace respondsToSelector:dw]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(LSAppWorkspace, dw);
}

#pragma mark - Launch acceleration (prewarm)

// The panel opening is a free head start: by the time the user taps a tile the
// target app can already be booted, turning a cold start into a warm one.
// launchApplicationWithIdentifier:suspended: loads a process without bringing it
// to the foreground, so nothing appears on screen while we do this.
static NSMutableDictionary<NSString *, NSNumber *> *gPrewarmAt = nil;
static double const kPrewarmCooldown = 60.0;

static void SGPrewarmPanelApps(void) {
    if (!isSpringBoard() || !gPanelEnabled || !gPanelPrewarm) return;
    if (!gPanelPrewarmLimit) return;

    NSArray<NSString *> *apps = [gPanelApps copy];
    if (!apps.count) return;
    if (!gPrewarmAt) gPrewarmAt = [NSMutableDictionary dictionary];

    NSInteger limit = gPanelPrewarmLimit;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      UIApplication *app = [UIApplication sharedApplication];
      SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
      if (![app respondsToSelector:sel]) {
          SGLog(@"prewarm: API unavailable");
          return;
      }
      NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
      NSInteger done = 0;
      for (NSString *bid in apps) {
          if (done >= limit) break;
          NSNumber *last = gPrewarmAt[bid];
          if (last && (now - last.doubleValue) < kPrewarmCooldown) continue;
          NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
          @try {
              ((void(*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, YES);
              gPrewarmAt[bid] = @(now);
              done++;
              SGLog(@"prewarm %@ in %.0f ms", bid,
                    ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
          } @catch (NSException *e) {
              SGLog(@"prewarm %@ threw %@", bid, e);
          }
      }
    });
}

static BOOL SGLaunchApp(NSString *bundleID) {
    if (!bundleID.length) return NO;
    id ws = SGLookupWorkspace();
    if (ws) {
        SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([ws respondsToSelector:open]) {
            BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, open, bundleID);
            SGLog(@"launch %@ -> %d", bundleID, ok);
            if (ok) return YES;
        }
        SEL open2 = NSSelectorFromString(@"openApplicationWithBundleID:options:");
        if ([ws respondsToSelector:open2]) {
            BOOL ok = ((BOOL(*)(id, SEL, id, id))objc_msgSend)(ws, open2, bundleID, nil);
            if (ok) return YES;
        }
    }
    UIApplication *app = [UIApplication sharedApplication];
    SEL l = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:l]) {
        @try {
            ((void(*)(id, SEL, id, BOOL))objc_msgSend)(app, l, bundleID, NO);
            return YES;
        } @catch (__unused NSException *e) {
        }
    }
    SGLog(@"launch %@ FAILED", bundleID);
    return NO;
}

// Heavy work - background queue only.
static NSArray<SGCatalogItem *> *SGEnumerateApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    id ws = SGLookupWorkspace();
    SEL allSel = NSSelectorFromString(@"allInstalledApplications");
    NSArray *apps = (ws && [ws respondsToSelector:allSel])
                        ? ((id(*)(id, SEL))objc_msgSend)(ws, allSel)
                        : nil;

    for (id proxy in apps) {
        @try {
            NSString *bid = nil;
            SEL sBid = NSSelectorFromString(@"bundleIdentifier");
            if ([proxy respondsToSelector:sBid])
                bid = ((id(*)(id, SEL))objc_msgSend)(proxy, sBid);
            if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
            if ([bid hasPrefix:@"com.apple.WebKit"]) continue;
            if ([bid isEqualToString:@"com.apple.SafariViewService"]) continue;

            NSString *name = bid;
            SEL sName = NSSelectorFromString(@"localizedName");
            if ([proxy respondsToSelector:sName]) {
                id n = ((id(*)(id, SEL))objc_msgSend)(proxy, sName);
                if ([n isKindOfClass:[NSString class]] && [n length]) name = n;
            }

            SEL sType = NSSelectorFromString(@"applicationType");
            if ([proxy respondsToSelector:sType]) {
                id t = ((id(*)(id, SEL))objc_msgSend)(proxy, sType);
                if ([t isKindOfClass:[NSString class]] && [t isEqualToString:@"Internal"]) continue;
            }
            SEL sHidden = NSSelectorFromString(@"isHidden");
            if ([proxy respondsToSelector:sHidden] &&
                ((BOOL(*)(id, SEL))objc_msgSend)(proxy, sHidden))
                continue;
            SEL sPlace = NSSelectorFromString(@"isPlaceholder");
            if ([proxy respondsToSelector:sPlace] &&
                ((BOOL(*)(id, SEL))objc_msgSend)(proxy, sPlace))
                continue;

            SGCatalogItem *it = [SGCatalogItem new];
            it.bundleID = bid;
            it.name = name;
            it.proxy = proxy;
            [out addObject:it];
        } @catch (__unused NSException *e) {
        }
    }

    [out sortUsingComparator:^NSComparisonResult(SGCatalogItem *a, SGCatalogItem *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

// Async catalog: callback always runs on the main queue.
static void SGLoadCatalogAsync(void (^done)(NSArray<SGCatalogItem *> *)) {
    if (gCachedCatalog) {
        if (done) done(gCachedCatalog);
        return;
    }
    if (gCatalogLoading) {           // someone else is already loading
        if (done) done(nil);
        return;
    }
    gCatalogLoading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSArray *cat = SGEnumerateApps();
      gCachedCatalog = cat;
      gCatalogLoading = NO;
      SGLog(@"catalog: %lu apps", (unsigned long)cat.count);
      dispatch_async(dispatch_get_main_queue(), ^{
        if (done) done(cat);
      });
    });
}

// Resolve icons for a set of items off the main thread, then call back on main.
static void SGResolveIconsAsync(NSArray<SGCatalogItem *> *items, void (^done)(void)) {
    NSMutableArray *todo = [NSMutableArray array];
    for (SGCatalogItem *it in items)
        if (!it.triedIcon) [todo addObject:it];
    if (!todo.count) {
        if (done) done();
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      for (SGCatalogItem *it in todo) {
          @autoreleasepool {
              SGResolveIcon(it);
          }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (done) done();
      });
    });
}

static SGCatalogItem *SGCatalogFind(NSArray<SGCatalogItem *> *catalog, NSString *bid) {
    for (SGCatalogItem *it in catalog)
        if ([it.bundleID isEqualToString:bid]) return it;
    SGCatalogItem *it = [SGCatalogItem new];
    it.bundleID = bid;
    it.name = bid;      // shown until the catalog arrives
    return it;
}

#pragma mark - Launcher panel : tile

@interface SGTile : UIControl
@property (nonatomic, strong) SGCatalogItem *item;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIButton *removeBtn;
@property (nonatomic, assign) BOOL addTile;
// 2.9.0: icon on the left, label on the right (one-row layout).
@property (nonatomic, assign) BOOL vertical;
@end

@implementation SGTile

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView.clipsToBounds = YES;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.font = [UIFont systemFontOfSize:10.5];
    _nameLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.userInteractionEnabled = NO;
    [self addSubview:_nameLabel];

    _removeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _removeBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    _removeBtn.layer.cornerRadius = 11;
    _removeBtn.layer.borderColor = [UIColor colorWithWhite:0.12 alpha:1.0].CGColor;
    _removeBtn.layer.borderWidth = 1.5;
    [_removeBtn setTitle:@"−" forState:UIControlStateNormal];
    [_removeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _removeBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _removeBtn.hidden = YES;
    [self addSubview:_removeBtn];

    self.exclusiveTouch = YES;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    if (_vertical) {
        // 2.9.1: icon on top, label underneath (10pt), centred in the strip.
        CGFloat iconSize = 40.0;
        CGFloat blockH = iconSize + 4.0 + 12.0;
        CGFloat top = (h - blockH) / 2.0;
        _iconView.frame = CGRectMake((w - iconSize) / 2.0, top, iconSize, iconSize);
        _iconView.layer.cornerRadius = iconSize * 0.225;
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.font = [UIFont systemFontOfSize:10.0];
        _nameLabel.frame = CGRectMake(2, top + iconSize + 4.0, w - 4, 12);
        _removeBtn.frame = CGRectMake(_iconView.frame.origin.x - 5,
                                      _iconView.frame.origin.y - 5, 19, 19);
        return;
    }

    CGFloat iconSize = MIN(w - 6, 60.0);
    _iconView.frame = CGRectMake((w - iconSize) / 2, 0, iconSize, iconSize);
    _iconView.layer.cornerRadius = iconSize * 0.225;
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.font = [UIFont systemFontOfSize:10.5];
    _nameLabel.frame = CGRectMake(-4, iconSize + 5, w + 8, 13);
    _removeBtn.frame = CGRectMake(_iconView.frame.origin.x - 6, -6, 22, 22);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1.0;
}

@end

#pragma mark - Launcher panel : view controller

@interface SGLauncherVC : UIViewController <UITableViewDataSource, UITableViewDelegate,
                                            UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIControl *backdrop;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *editBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *loadingLabel;
@property (nonatomic, strong) NSArray<SGCatalogItem *> *catalog;
@property (nonatomic, strong) NSArray<SGCatalogItem *> *catalogSections;   // picker rows
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign) BOOL pickerMode;
- (void)showPanel;
- (void)hidePanel;
- (void)hidePanelNow;
@end

@implementation SGLauncherVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _backdrop = [[UIControl alloc] initWithFrame:self.view.bounds];
    _backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
    _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_backdrop addTarget:self
                  action:@selector(tapOutside)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_backdrop];

    _sheet = [[UIView alloc] initWithFrame:CGRectZero];
    _sheet.layer.cornerRadius = 30;
    _sheet.layer.cornerCurve = kCACornerCurveContinuous;
    _sheet.clipsToBounds = YES;
    _sheet.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
    [self.view addSubview:_sheet];


    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"应用";
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor whiteColor];
    [_sheet addSubview:_titleLabel];

    _editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_editBtn setTitle:@"编辑" forState:UIControlStateNormal];
    _editBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [_editBtn setTitleColor:[UIColor colorWithRed:0.35 green:0.62 blue:1.0 alpha:1.0]
                   forState:UIControlStateNormal];
    [_editBtn addTarget:self action:@selector(toggleEdit) forControlEvents:UIControlEventTouchUpInside];
    [_sheet addSubview:_editBtn];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [_closeBtn setTitleColor:[UIColor colorWithWhite:0.65 alpha:1.0] forState:UIControlStateNormal];
    [_closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [_sheet addSubview:_closeBtn];

    _scroll = [[UIScrollView alloc] init];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    [_sheet addSubview:_scroll];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"还没有应用\n点右下角 ＋ 添加";
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont systemFontOfSize:13];
    _emptyLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _emptyLabel.hidden = YES;
    [_sheet addSubview:_emptyLabel];

    _loadingLabel = [[UILabel alloc] init];
    _loadingLabel.text = @"正在读取应用列表…";
    _loadingLabel.textAlignment = NSTextAlignmentCenter;
    _loadingLabel.font = [UIFont systemFontOfSize:13];
    _loadingLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    _loadingLabel.hidden = YES;
    [_sheet addSubview:_loadingLabel];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.hidden = YES;
    _table.rowHeight = 54;
    _table.contentInset = UIEdgeInsetsMake(0, 0, 20, 0);
    [_sheet addSubview:_table];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(onSheetPan:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    [_sheet addGestureRecognizer:pan];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutSheet];
}

- (void)layoutSheet {
    static BOOL inLayout = NO;
    if (inLayout) return;
    inLayout = YES;
    @try {
    CGSize s = self.view.bounds.size;
    if (s.width < 10 || s.height < 10) s = [UIScreen mainScreen].bounds.size;
    if (s.width < 10) return;

    // 2.9.0: the panel is a vertical strip pinned to the RIGHT edge, not a
    // bottom sheet. One column of icon+label rows, vertically centred.
    CGFloat panelW = 118;
    CGFloat margin = 10;
    CGFloat headerH = 40;
    CGFloat maxH = s.height - margin * 2;
    CGFloat contentH;

    if (_pickerMode) {
        contentH = MIN(maxH, s.height * 0.8);
    } else {
        NSInteger n = [self panelItems].count + 1;   // + "add" tile
        CGFloat rowH = 58;
        contentH = headerH + n * rowH + 12;
        contentH = MIN(MAX(contentH, headerH + rowH), maxH);
    }

    CGFloat x = s.width - panelW - margin;
    CGFloat y = (s.height - contentH) / 2.0;
    _sheet.frame = CGRectMake(x, y, panelW, contentH);

    CGFloat pad = 10;
    _titleLabel.frame = CGRectMake(pad, 9, panelW - pad * 2 - 60, 22);
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _closeBtn.frame = CGRectMake(panelW - 32, 5, 27, 28);
    _editBtn.frame = CGRectMake(panelW - 32 - 44, 6, 44, 26);
    _editBtn.titleLabel.font = [UIFont systemFontOfSize:11.5];

    CGFloat top = headerH;
    if (_pickerMode) {
        _table.frame = CGRectMake(0, top, panelW, contentH - top);
    } else {
        _scroll.frame = CGRectMake(0, top, panelW, contentH - top);
    }
    _emptyLabel.frame = CGRectMake(pad, (contentH - 60) / 2, panelW - pad * 2, 60);
    _emptyLabel.font = [UIFont systemFontOfSize:12];
    _loadingLabel.frame = _emptyLabel.frame;

    [self layoutGrid];
    } @finally {
        inLayout = NO;
    }
}

- (NSArray<SGCatalogItem *> *)panelItems {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *bid in gPanelApps) [out addObject:SGCatalogFind(_catalog ?: @[], bid)];
    return out;
}

- (UIImage *)plusIcon:(CGFloat)size {
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor colorWithWhite:1.0 alpha:0.8] setStroke];
        CGContextSetLineWidth(c, 2.5);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextMoveToPoint(c, size / 2 - 11, size / 2);
        CGContextAddLineToPoint(c, size / 2 + 11, size / 2);
        CGContextMoveToPoint(c, size / 2, size / 2 - 11);
        CGContextAddLineToPoint(c, size / 2, size / 2 + 11);
        CGContextStrokePath(c);
    }];
}

- (void)layoutGrid {
    if (_pickerMode) return;
    for (UIView *v in [_scroll.subviews copy]) [v removeFromSuperview];

    NSArray<SGCatalogItem *> *items = [self panelItems];
    CGFloat w = _sheet.bounds.size.width;
    if (w < 10) return;

    // 2.9.0: one column, full width of the strip.
    CGFloat pad = 10;
    CGFloat tileW = w - pad * 2;
    CGFloat rowGap = 6;
    CGFloat rowH = 58;

    NSInteger total = items.count + 1;
    for (NSInteger i = 0; i < total; i++) {
        BOOL isAdd = (i == (NSInteger)items.count);
        CGRect f = CGRectMake(pad, 4 + i * (rowH + rowGap), tileW, rowH);

        SGTile *tile = [[SGTile alloc] initWithFrame:f];
        tile.vertical = YES;
        if (isAdd) {
            tile.addTile = YES;
            tile.iconView.image = [self plusIcon:40];
            tile.iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            tile.nameLabel.text = @"添加";
        } else {
            SGCatalogItem *it = items[i];
            tile.item = it;
            tile.iconView.image = SGIconQuick(it, CGSizeMake(40, 40));
            tile.nameLabel.text = it.name ?: it.bundleID;
            tile.removeBtn.hidden = !_editing;
            [tile.removeBtn addTarget:self
                               action:@selector(removeTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
        }
        [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:tile];
    }

    _scroll.contentSize = CGSizeMake(w, 4 + total * (rowH + rowGap) + 4);
    _emptyLabel.hidden = (items.count != 0) || (_catalog != nil);

    NSArray *snapshot = items;
    if (snapshot.count) {
        __weak SGLauncherVC *weakSelf = self;
        SGResolveIconsAsync(snapshot, ^{
          SGLauncherVC *sself = weakSelf;
          if (!sself || sself->_pickerMode) return;
          for (UIView *v in sself->_scroll.subviews) {
              if (![v isKindOfClass:[SGTile class]]) continue;
              SGTile *t = (SGTile *)v;
              if (t.item && t.item.icon) t.iconView.image = t.item.icon;
          }
        });
    }
}

- (void)tileTapped:(SGTile *)tile {
    if (tile.addTile) {
        [self enterPicker];
        return;
    }
    if (_editing) {
        [self setEditingMode:NO];
        return;
    }
    SGCatalogItem *it = tile.item;
    SGPanelVibrate();
    NSString *bid = it.bundleID;
    [self hidePanelNow];
    // Give SpringBoard a couple of runloop turns after the window is hidden and
    // key status is restored - activating an app mid-transition is what made
    // the screen hang for 3-5 seconds.
    if (bid.length) {
        // openApplicationWithBundleID: BLOCKS until the app is activated - the
        // log measured 10039 ms on a cold start. Never call it on the main
        // thread or SpringBoard (and the whole screen) freezes for that long.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         dispatch_async(
                             dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                               NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
                               BOOL ok = NO;
                               @try {
                                   ok = SGLaunchApp(bid);
                               } @catch (NSException *e) {
                                   SGLog(@"launch %@ threw %@", bid, e);
                               }
                               SGLog(@"launch %@ done ok=%d in %.0f ms", bid, ok,
                                     ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
                             });
                       });
    }
}

- (void)removeTapped:(UIButton *)btn {
    UIView *sup = btn.superview;
    if (![sup isKindOfClass:[SGTile class]]) return;
    SGTile *tile = (SGTile *)sup;
    if (!tile.item.bundleID) return;
    NSString *bid = tile.item.bundleID;
    NSMutableArray *l = [gPanelApps mutableCopy];
    [l removeObject:bid];
    gPanelApps = l;
    SGSavePanelApps(gPanelApps);
    [self layoutGrid];
}

- (void)toggleEdit {
    if (_pickerMode) {
        [self exitPicker];
        return;
    }
    [self setEditingMode:!_editing];
}

- (void)setEditingMode:(BOOL)on {
    _editing = on;
    [_editBtn setTitle:(on ? @"完成" : @"编辑") forState:UIControlStateNormal];
    [self layoutGrid];
}

#pragma mark picker

- (void)enterPicker {
    _pickerMode = YES;
    _scroll.hidden = YES;
    _emptyLabel.hidden = YES;
    _table.hidden = NO;
    _titleLabel.text = @"添加应用";
    [_editBtn setTitle:@"完成" forState:UIControlStateNormal];
    [self layoutSheet];

    if (gCachedCatalog) {
        _catalog = gCachedCatalog;
        [self rebuildPickerRows];
        _loadingLabel.hidden = YES;
        [_table reloadData];
        return;
    }

    _loadingLabel.hidden = NO;
    _table.hidden = YES;
    __weak SGLauncherVC *weakSelf = self;
    SGLoadCatalogAsync(^(NSArray<SGCatalogItem *> *cat) {
      SGLauncherVC *sself = weakSelf;
      if (!sself) return;
      sself->_catalog = cat;
      sself->_loadingLabel.hidden = YES;
      sself->_table.hidden = !sself->_pickerMode;
      [sself rebuildPickerRows];
      [sself->_table reloadData];
      [sself layoutGrid];       // panel tiles can now show real names
    });
}

- (void)exitPicker {
    _pickerMode = NO;
    _scroll.hidden = NO;
    _table.hidden = YES;
    _loadingLabel.hidden = YES;
    _titleLabel.text = @"应用";
    [_editBtn setTitle:(_editing ? @"完成" : @"编辑") forState:UIControlStateNormal];
    [self layoutSheet];
}

- (void)rebuildPickerRows {
    NSMutableArray *out = [NSMutableArray array];
    for (SGCatalogItem *it in _catalog)
        if (![gPanelApps containsObject:it.bundleID]) [out addObject:it];
    _catalogSections = out;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _catalogSections.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"sgapp";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10.5];
        cell.imageView.layer.cornerRadius = 9;
        cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.imageView.clipsToBounds = YES;
    }
    if (ip.row < (NSInteger)_catalogSections.count) {
        SGCatalogItem *it = _catalogSections[ip.row];
        cell.textLabel.text = it.name;
        cell.detailTextLabel.text = it.bundleID;
        cell.imageView.image = SGIconQuick(it, CGSizeMake(38, 38));
        __weak UITableViewCell *wcell = cell;
        __weak SGLauncherVC *weakSelf = self;
        SGResolveIconsAsync(@[ it ], ^{
          if (weakSelf && wcell && it.icon) wcell.imageView.image = it.icon;
        });
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)_catalogSections.count) return;
    SGCatalogItem *it = _catalogSections[ip.row];
    if (![gPanelApps containsObject:it.bundleID]) {
        NSMutableArray *l = [gPanelApps mutableCopy];
        [l addObject:it.bundleID];
        gPanelApps = l;
        SGSavePanelApps(gPanelApps);
        SGPanelVibrate();
    }
    [self exitPicker];
    [self rebuildPickerRows];
}

#pragma mark lifecycle

- (void)tapOutside {
    if (_pickerMode) {
        [self exitPicker];
        return;
    }
    [self hidePanel];
}

- (void)onSheetPan:(UIPanGestureRecognizer *)g {
    // 2.0.0: the sheet sits against the right edge, so it is dismissed by
    // dragging it to the RIGHT, not down.
    CGPoint t = [g translationInView:self.view];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = MAX(0, t.x);
        _sheet.transform = CGAffineTransformMakeTranslation(dx, 0);
        _backdrop.alpha = MAX(0.1, 1.0 - dx / 240.0);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        CGFloat v = [g velocityInView:self.view].x;
        if (t.x > 110 || v > 700) {
            [self hidePanel];
        } else {
            [UIView animateWithDuration:0.22
                             animations:^{
                               self->_sheet.transform = CGAffineTransformIdentity;
                               self->_backdrop.alpha = 1.0;
                             }];
        }
    }
}

- (void)showPanel {
    _editing = NO;
    _pickerMode = NO;
    _scroll.hidden = NO;
    _table.hidden = YES;
    _loadingLabel.hidden = YES;
    _titleLabel.text = @"应用";
    [_editBtn setTitle:@"编辑" forState:UIControlStateNormal];
    [self layoutSheet];

    // Catalog already cached? use it. Otherwise show tiles by bundle id and fill
    // in names/icons when the background scan finishes.
    if (gCachedCatalog) {
        _catalog = gCachedCatalog;
        [self layoutSheet];
    } else {
        __weak SGLauncherVC *weakSelf = self;
        SGLoadCatalogAsync(^(NSArray<SGCatalogItem *> *cat) {
          SGLauncherVC *sself = weakSelf;
          if (!sself || !cat || sself->_pickerMode) return;
          sself->_catalog = cat;
          [sself layoutSheet];
        });
    }

    _backdrop.alpha = 0;
    // 2.0.0: the panel now lives against the right edge, so it slides in
    // horizontally from the right instead of rising from the bottom.
    _sheet.transform = CGAffineTransformMakeTranslation(_sheet.bounds.size.width + 40, 0);
    [UIView animateWithDuration:0.30
                          delay:0
         usingSpringWithDamping:0.92
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                       self->_backdrop.alpha = 1.0;
                       self->_sheet.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
}

// Instant close: no animation. Used when launching, so no high-level window is
// left on screen while the app is being activated.
- (void)hidePanelNow {
    self.view.userInteractionEnabled = NO;
    // 2.0.0: the panel now lives against the right edge, so it slides in
    // horizontally from the right instead of rising from the bottom.
    _sheet.transform = CGAffineTransformMakeTranslation(_sheet.bounds.size.width + 40, 0);
    _backdrop.alpha = 0;
    SGLauncherHide();
}

- (void)hidePanel {
    // Stop accepting touches at once, so a half-animated panel can never eat input.
    self.view.userInteractionEnabled = NO;
    __weak SGLauncherVC *weakSelf = self;
    [UIView animateWithDuration:0.18
        animations:^{
          SGLauncherVC *s = weakSelf;
          if (!s) return;
          s->_sheet.transform =
              CGAffineTransformMakeTranslation(s->_sheet.bounds.size.width + 40, 0);
          s->_backdrop.alpha = 0;
        }
        completion:^(BOOL f) {
          SGLauncherHide();     // sync when already on main
        }];
}

@end

#pragma mark - Launcher panel : SpringBoard host window

static UIWindowScene *SGPickScene(void) {
    if (gCachedScene) return gCachedScene;
    @try {
        UIWindowScene *any = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (!any) any = (UIWindowScene *)sc;
            if (sc.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)sc;
        }
        if (any) return any;
    } @catch (__unused NSException *e) {
    }
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (w.windowScene) return w.windowScene;
    } @catch (__unused NSException *e) {
    }
    Class sbClass = objc_getClass("SpringBoard");
    if (sbClass) {
        SEL sh = NSSelectorFromString(@"sharedInstance");
        id sb = [sbClass respondsToSelector:sh] ? ((id(*)(id, SEL))objc_msgSend)(sbClass, sh) : nil;
        for (NSString *selName in @[ @"_windowScene", @"_mainWindowScene", @"windowScene" ]) {
            SEL sel = NSSelectorFromString(selName);
            if (sb && [sb respondsToSelector:sel]) {
                @try {
                    id sc = ((id(*)(id, SEL))objc_msgSend)(sb, sel);
                    if ([sc isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)sc;
                } @catch (__unused NSException *e) {
                }
            }
        }
    }
    Class smClass = objc_getClass("SBSceneManager");
    if (smClass) {
        SEL sh = NSSelectorFromString(@"sharedInstance");
        id sm = [smClass respondsToSelector:sh] ? ((id(*)(id, SEL))objc_msgSend)(smClass, sh) : nil;
        for (NSString *selName in @[ @"_windowScene", @"mainWindowScene", @"currentWindowScene" ]) {
            SEL sel = NSSelectorFromString(selName);
            if (sm && [sm respondsToSelector:sel]) {
                @try {
                    id sc = ((id(*)(id, SEL))objc_msgSend)(sm, sel);
                    if ([sc isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)sc;
                } @catch (__unused NSException *e) {
                }
            }
        }
    }
    return nil;
}

static UIWindow *SGMakePanelWindow(void) {
    UIWindowScene *scene = SGPickScene();
    UIWindow *win = nil;

    if (scene) {
        @try {
            win = ((id(*)(id, SEL, id))objc_msgSend)([UIWindow alloc],
                                                     NSSelectorFromString(@"initWithWindowScene:"),
                                                     scene);
        } @catch (NSException *e) {
            SGLog(@"initWithWindowScene threw: %@", e);
            win = nil;
        }
    }
    if (!win) win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    if (!win.windowScene && scene) {
        SEL s2 = NSSelectorFromString(@"_setWindowScene:");
        if ([win respondsToSelector:s2]) ((void(*)(id, SEL, id))objc_msgSend)(win, s2, scene);
    }

    win.frame = [UIScreen mainScreen].bounds;
    win.windowLevel = 5000.0;
    win.backgroundColor = [UIColor clearColor];
    win.hidden = YES;
    // IMPORTANT: never let the panel window join SpringBoard's key-window
    // tracking. Taking key status from inside SpringBoard deadlocks the main
    // thread, which is what froze the device in 1.4.0.
    win.rootViewController = nil;
    SGLog(@"panel window: scene=%@ level=%.1f", win.windowScene ? @"yes" : @"NIL",
          (double)win.windowLevel);
    return win;
}

static void SGLauncherShow(void) {
    SGLog(@"SGLauncherShow enter isSpringBoard=%d enabled=%d", isSpringBoard(), gPanelEnabled);
    if (!isSpringBoard()) return;
    if (!gPanelEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gPanelWindow && !gPanelWindow.hidden) {
          [gPanelVC hidePanel];
          return;
      }
      if (!gPanelWindow) {
          @try {
              gPanelWindow = SGMakePanelWindow();
              gPanelVC = [[SGLauncherVC alloc] init];
              gPanelWindow.rootViewController = gPanelVC;
          } @catch (NSException *e) {
              SGLog(@"panel window creation FAILED: %@", e);
              gPanelWindow = nil;
              gPanelVC = nil;
              return;
          }
      }
      if (!gPanelWindow) { SGLog(@"no panel window -> abort"); return; }

      if (gPanelWindow.rootViewController != gPanelVC) gPanelWindow.rootViewController = gPanelVC;
      gPanelWindow.frame = [UIScreen mainScreen].bounds;
      gPanelVC.view.frame = gPanelWindow.bounds;

      gPanelVC.view.userInteractionEnabled = YES;
      gPanelWindow.hidden = NO;
      gPanelWindow.alpha = 1.0;

      // A window created inside SpringBoard is only composited after it has
      // been made visible through the normal path at least once. 1.5.0 dropped
      // this line and the panel stopped appearing; the freeze it was meant to
      // avoid came from the synchronous app enumeration, which is now async.
      // Guarded: a throw here must not take SpringBoard down.
      // Remember who owned the keyboard, so we can hand key status straight back.
      if (!gPanelPrevKey) {
          for (UIWindow *w in [UIApplication sharedApplication].windows) {
              if (w.isKeyWindow && w != gPanelWindow) { gPanelPrevKey = w; break; }
          }
      }
      @try {
          [gPanelWindow makeKeyAndVisible];
      } @catch (NSException *e) {
          SGLog(@"makeKeyAndVisible threw: %@", e);
      }
      // Hand key status back immediately. The call above is only needed so the
      // window gets composited; leaving our level-5000 window as the key window
      // makes SpringBoard stall for seconds when the next app is activated.
      if (gPanelPrevKey) {
          @try {
              [gPanelPrevKey makeKeyWindow];
          } @catch (__unused NSException *e) {
          }
      }

      [gPanelVC showPanel];

      // Prewarm shortly after the sheet finishes animating so it stays smooth.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{ SGPrewarmPanelApps(); });

      SGLog(@"panel shown level=%.1f vcView=%@ hidden=%d",
            (double)gPanelWindow.windowLevel, NSStringFromCGRect(gPanelVC.view.frame),
            gPanelWindow.hidden);
    });
}

static void SGLauncherHideNow(void) {
    if (!gPanelWindow) return;

    // Release key status BEFORE hiding, otherwise SpringBoard is left with no
    // key window and the next app activation blocks for several seconds.
    UIWindow *back = gPanelPrevKey;
    gPanelPrevKey = nil;
    if (back && back != gPanelWindow && !back.hidden) {
        @try {
            [back makeKeyWindow];
        } @catch (__unused NSException *e) {
        }
    } else if (gPanelWindow.isKeyWindow) {
        // fall back to any other visible window
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w == gPanelWindow || w.hidden || w.windowLevel >= 4000) continue;
            @try {
                [w makeKeyWindow];
            } @catch (__unused NSException *e) {
            }
            break;
        }
    }

    gPanelWindow.hidden = YES;
    gPanelWindow.alpha = 1.0;
    gPanelVC.view.alpha = 1.0;
    gPanelVC.view.transform = CGAffineTransformIdentity;
    gPanelVC.view.userInteractionEnabled = NO;
    SGLog(@"panel hidden (sync)");
}

static void SGLauncherHide(void) {
    if (!isSpringBoard()) return;
    if ([NSThread isMainThread]) { SGLauncherHideNow(); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ SGLauncherHideNow(); });
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

// 2.9.3: locking the device and turning the display off are separate things.
// Every lock path below returns as soon as it succeeds, so the backlight was
// never touched and the screen stayed lit. This runs unconditionally after
// whichever path wins.
static void sbSleepDisplay(void) {
    // 2.9.5: every class name tried so far was a guess, and on 17.3.1 NONE of
    // them existed (the log showed no line for steps 1/2/4 at all). So: first
    // report what actually exists, then drive it.
    SGLog(@"sbSleepDisplay enter");

    // ---- diagnostics: list the real class names once ----
    static BOOL dumped = NO;
    if (!dumped) {
        dumped = YES;
        unsigned int count = 0;
        Class *all = objc_copyClassList(&count);
        NSMutableString *hits = [NSMutableString string];
        for (unsigned int i = 0; i < count; i++) {
            const char *nm = class_getName(all[i]);
            if (!nm) continue;
            if (strcasestr(nm, "Backlight") || strcasestr(nm, "Sleep") ||
                strcasestr(nm, "Wake") || strcasestr(nm, "Blank")) {
                [hits appendFormat:@" %s", nm];
            }
            if (hits.length > 1500) break;
        }
        if (all) free(all);
        SGLog(@"sbSleepDisplay: candidates =%@", hits);
    }

    // ---- the real side-button path on iOS 14-17 ----
    NSArray *buttonClasses = @[ @"SBSleepWakeHardwareButtonInteraction",
                                @"SBLockHardwareButton",
                                @"SBHardwareButtonCoordinator" ];
    NSArray *buttonSels = @[ @"performSleepWakeButtonDown",
                             @"performSleepButtonDown",
                             @"sleepWakeButtonDown",
                             @"performLockButtonDown" ];

    for (NSString *cn in buttonClasses) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        id inst = nil;
        for (NSString *maker in @[ @"sharedInstance", @"new" ]) {
            SEL m = NSSelectorFromString(maker);
            if (![c respondsToSelector:m]) continue;
            id r = ((id(*)(id, SEL))objc_msgSend)(c, m);
            if ([maker isEqualToString:@"new"] && r)
                r = ((id(*)(id, SEL))objc_msgSend)(r, NSSelectorFromString(@"init"));
            if (r) { inst = r; break; }
        }
        if (!inst) { SGLog(@"sbSleepDisplay: %@ exists but no instance", cn); continue; }
        for (NSString *sn in buttonSels) {
            SEL sel = NSSelectorFromString(sn);
            if (![inst respondsToSelector:sel]) continue;
            ((void(*)(id, SEL))objc_msgSend)(inst, sel);
            SGLog(@"sbSleepDisplay: %@ -%@", cn, sn);
            break;
        }
    }

    // ---- backlight, whatever it is called now ----
    NSArray *blClasses = @[ @"SBBacklightController",
                            @"SBDisplayBrightnessController",
                            @"BKSDisplayBrightnessManager" ];
    NSArray *blSels = @[ @"setBacklightFactor:source:",
                         @"_setBacklightFactor:source:",
                         @"setDisplayBrightness:",
                         @"setBrightness:" ];
    for (NSString *cn in blClasses) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        id inst = nil;
        SEL sh = NSSelectorFromString(@"sharedInstance");
        if ([c respondsToSelector:sh])
            inst = ((id(*)(id, SEL))objc_msgSend)(c, sh);
        if (!inst) continue;
        for (NSString *sn in blSels) {
            SEL sel = NSSelectorFromString(sn);
            if (![inst respondsToSelector:sel]) continue;
            @try {
                if ([sn hasSuffix:@"source:"])
                    ((void(*)(id, SEL, float, int64_t))objc_msgSend)(inst, sel, 0.0f, 1);
                else
                    ((void(*)(id, SEL, float))objc_msgSend)(inst, sel, 0.0f);
                SGLog(@"sbSleepDisplay: %@ -%@ 0", cn, sn);
            } @catch (NSException *e) {
                SGLog(@"sbSleepDisplay: %@ -%@ threw %@", cn, sn, e.reason);
            }
            break;
        }
    }

    // ---- 2.9.6: real backlight off through BLSBacklight ----
    // The class dump showed the live names are BLS* (BacklightServices), not
    // the old SB* ones. BLSBacklightChangeRequest carries a requested activity
    // state; requesting inactive (0) is what actually stops the panel.
    @try {
        void *h = dlopen("/System/Library/PrivateFrameworks/"
                         "BacklightServices.framework/BacklightServices",
                         RTLD_NOW);
        SGLog(@"sbSleepDisplay: BacklightServices=%p", h);

        Class blCls  = NSClassFromString(@"BLSBacklight");
        Class reqCls = NSClassFromString(@"BLSBacklightChangeRequest");
        SGLog(@"sbSleepDisplay: BLSBacklight=%@ request=%@", blCls, reqCls);

        id backend = nil;
        if (blCls) {
            for (NSString *n in @[ @"sharedBacklight", @"sharedInstance" ]) {
                SEL sel = NSSelectorFromString(n);
                if ([blCls respondsToSelector:sel]) {
                    backend = ((id(*)(id, SEL))objc_msgSend)(blCls, sel);
                    if (backend) { SGLog(@"sbSleepDisplay: backlight +%@", n); break; }
                }
            }
        }

        if (backend && reqCls) {
            NSArray *sels = @[ @"requestBacklightChangeToState:sourceEvent:",
                               @"requestBacklightChangeToState:",
                               @"performBacklightChangeToState:" ];
            for (NSString *sn in sels) {
                SEL sel = NSSelectorFromString(sn);
                if (![backend respondsToSelector:sel]) continue;
                @try {
                    if ([sn hasSuffix:@"sourceEvent:"])
                        ((void(*)(id, SEL, int64_t, id))objc_msgSend)(backend, sel, 0, nil);
                    else
                        ((void(*)(id, SEL, int64_t))objc_msgSend)(backend, sel, 0);
                    SGLog(@"sbSleepDisplay: BLSBacklight -%@", sn);
                    break;
                } @catch (NSException *e) {
                    SGLog(@"sbSleepDisplay: -%@ threw %@", sn, e.reason);
                }
            }
        }

        if (reqCls) {
            SEL mk = NSSelectorFromString(
                @"requestWithRequestedActivityState:explanation:timestamp:sourceEvent:");
            if ([reqCls respondsToSelector:mk]) {
                id req = ((id(*)(id, SEL, int64_t, id, double, int64_t))
                          objc_msgSend)(reqCls, mk, 0, @"SquidGesture", 0.0, 0);
                SGLog(@"sbSleepDisplay: request=%@", req ? @"built" : @"nil");
                if (req && backend) {
                    SEL send = NSSelectorFromString(@"performChangeRequest:");
                    if ([backend respondsToSelector:send]) {
                        ((void(*)(id, SEL, id))objc_msgSend)(backend, send, req);
                        SGLog(@"sbSleepDisplay: performChangeRequest");
                    }
                }
            } else {
                SGLog(@"sbSleepDisplay: request factory missing");
            }
        }
    } @catch (NSException *e) {
        SGLog(@"sbSleepDisplay: BLS threw %@", e.reason);
    }

    // ---- guaranteed: zero the screen brightness ----
    // -[UIScreen brightness] is public API. Setting it to 0 blacks the panel
    // immediately, which is what "熄屏" looks like even when the private
    // backlight services are unavailable. It restores on any interaction.
    @try {
        [UIScreen mainScreen].brightness = 0.0;
        SGLog(@"sbSleepDisplay: UIScreen.brightness = 0");
    } @catch (NSException *e) {
        SGLog(@"sbSleepDisplay: brightness threw %@", e.reason);
    }

    // ---- last: SBDimScreen, harmless on 17 ----
    mach_port_t p = gGetPort ? gGetPort() : 0;
    if (p && gDimScreen) {
        gDimScreen(p, 1);
        SGLog(@"sbSleepDisplay: SBDimScreen called");
    }
    SGLog(@"sbSleepDisplay done");
}

static void sbLock(void) {
    SGLog(@"sbLock enter");

    // 1) iOS 15-17: the lock screen manager is still the owner of locking.
    //    -lockUIFromSource:withOptions: is gone on 17; the modern entry points
    //    are -lockScreenViewController / -lockUIFromSource: and, most reliably,
    //    -lockDeviceAnimated: on SBLockScreenManager.
    Class lm = objc_getClass("SBLockScreenManager");
    if (lm) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(lm, NSSelectorFromString(@"sharedInstance"));
        if (inst) {
            NSString *const sels[] = {
                @"lockDeviceAnimated:", @"lockUIFromSource:", @"lockScreenViewController"
            };
            const char *types[] = { "v@:B", "v@:q", "@@:" };
            for (int i = 0; i < 3; i++) {
                SEL sel = NSSelectorFromString(sels[i]);
                if (![inst respondsToSelector:sel]) continue;
                @try {
                    if (i == 0) {
                        ((void(*)(id, SEL, BOOL))objc_msgSend)(inst, sel, YES);
                    } else if (i == 1) {
                        ((void(*)(id, SEL, long))objc_msgSend)(inst, sel, 0);
                    } else {
                        ((id(*)(id, SEL))objc_msgSend)(inst, sel);
                    }
                    SGLog(@"sbLock: SBLockScreenManager %@ OK", sels[i]);
                    sbSleepDisplay();
                    return;
                } @catch (NSException *e) {
                    SGLog(@"sbLock: %@ threw %@", sels[i], e.reason);
                }
            }
            (void)types;
        }
        SGLog(@"sbLock: SBLockScreenManager without a usable selector");
    }

    // 2) SBLockDevice via SpringBoardServices (works on <=16)
    mach_port_t p = gGetPort ? gGetPort() : 0;
    if (p && gLockDevice) {
        gLockDevice(p, 1);
        if (gDimScreen) gDimScreen(p, 1);
        SGLog(@"sbLock: SBLockDevice OK");
        sbSleepDisplay();
        return;
    }

    // 3) The private SpringBoard "hardware button" path - same thing the
    //    physical side button triggers, so it works on every iOS version.
    Class hb = objc_getClass("SBLockHardwareButton");
    if (!hb) hb = objc_getClass("SBHardwareButtonCoordinator");
    if (hb) {
        id inst = nil;
        SEL sh = NSSelectorFromString(@"sharedInstance");
        if ([hb respondsToSelector:sh])
            inst = ((id(*)(id, SEL))objc_msgSend)(hb, sh);
        if (!inst && [hb respondsToSelector:NSSelectorFromString(@"new")])
            inst = ((id(*)(id, SEL))objc_msgSend)(hb, NSSelectorFromString(@"new"));
        for (NSString *n in @[ @"performLockButtonDown", @"lockButtonDown" ]) {
            SEL sel = NSSelectorFromString(n);
            if (inst && [inst respondsToSelector:sel]) {
                ((void(*)(id, SEL))objc_msgSend)(inst, sel);
                SGLog(@"sbLock: %@ -%@ OK", NSStringFromClass(hb), n);
                sbSleepDisplay();
                return;
            }
        }
    }

    // 4) Last resort: ask the lock screen view controller directly.  On 17 the
    //    manager hands out a controller whose -activate does the same thing
    //    the side button does.
    Class lvc = objc_getClass("SBLockScreenViewController");
    if (lvc) {
        SEL sh = NSSelectorFromString(@"sharedInstance");
        if ([lvc respondsToSelector:sh]) {
            id inst = ((id(*)(id, SEL))objc_msgSend)(lvc, sh);
            SEL act = NSSelectorFromString(@"activate");
            if (inst && [inst respondsToSelector:act]) {
                ((void(*)(id, SEL))objc_msgSend)(inst, act);
                SGLog(@"sbLock: SBLockScreenViewController -activate OK");
                sbSleepDisplay();
                return;
            }
        }
    }

    SGLog(@"sbLock: all paths failed");
    sbSleepDisplay();   // at least turn the screen off
}

// 2.1.0: power menu (log out / restart) for the left half of the status bar.
// SpringBoard already owns this UI, so ask it to present it rather than
// building our own - that keeps the icons, sliders and confirmations correct.
// 2.3.0: run a system command (reboot / halt / sbreload) as root.
// SpringBoard runs as mobile, so superuser privileges come from a setuid
// helper if one exists; otherwise try the plain path and report the result.
static void doLock(void);
static void doScreenshot(void);

static BOOL doSystemAction(NSString *tool) {
    const char *paths[] = {
        "/var/jb/usr/bin/", "/var/jb/usr/sbin/", "/usr/bin/", "/usr/sbin/", "/sbin/"
    };
    char full[256];
    for (int i = 0; i < 5; i++) {
        snprintf(full, sizeof(full), "%s%s", paths[i], tool.UTF8String);
        if (access(full, X_OK) != 0) continue;

        SGLog(@"doSystemAction: exec %s", full);
        pid_t pid = fork();
        if (pid == 0) {
            setsid();
            execl(full, tool.UTF8String, (char *)NULL);
            _exit(127);
        }
        return (pid > 0);
    }
    SGLog(@"doSystemAction: %@ not found", tool);
    return NO;
}

static void sbPowerMenu(void) {
    SGLog(@"sbPowerMenu enter -> own menu");


    // 2.3.0: a single self-contained menu that guarantees every action works,
    // whatever iOS renamed.  Presented on the main thread inside SpringBoard.
    dispatch_async(dispatch_get_main_queue(), ^{
      UIAlertController *ac =
          [UIAlertController alertControllerWithTitle:@"电源"
                                              message:nil
                                       preferredStyle:UIAlertControllerStyleActionSheet];

      [ac addAction:[UIAlertAction actionWithTitle:@"锁屏"
                                            style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *a) {
          SGLog(@"menu: lock");
          doLock();
      }]];

      [ac addAction:[UIAlertAction actionWithTitle:@"截图"
                                            style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *a) {
          SGLog(@"menu: screenshot");
          doScreenshot();
      }]];

      [ac addAction:[UIAlertAction actionWithTitle:@"注销"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *a) {
          SGLog(@"menu: logout");
          // Logging out == restarting SpringBoard as the same user.
          if (!doSystemAction(@"sbreload")) {
              Class sb = objc_getClass("SpringBoard");
              SEL rel = NSSelectorFromString(@"_relaunchSpringBoardNow");
              if (sb && [sb respondsToSelector:rel]) {
                  ((void(*)(id, SEL))objc_msgSend)(sb, rel);
              } else {
                  exit(0);
              }
          }
      }]];

      [ac addAction:[UIAlertAction actionWithTitle:@"重启"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *a) {
          SGLog(@"menu: reboot");
          if (!doSystemAction(@"reboot")) doSystemAction(@"sbreload");
      }]];

      [ac addAction:[UIAlertAction actionWithTitle:@"关机"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *a) {
          SGLog(@"menu: shutdown");
          if (!doSystemAction(@"halt")) doSystemAction(@"poweroff");
      }]];

      [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

      // Present from the top-most view controller so it works both in
      // SpringBoard and inside a normal app.
      UIWindow *win = [UIApplication sharedApplication].keyWindow;
      UIViewController *root = win.rootViewController;
      while (root.presentedViewController) root = root.presentedViewController;
      if (root) {
          [root presentViewController:ac animated:YES completion:nil];
      } else {
          UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
          w.windowLevel = 5000;
          UIViewController *vc = [UIViewController new];
          w.rootViewController = vc;
          [w makeKeyAndVisible];
          [vc presentViewController:ac animated:YES completion:nil];
      }
    });
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
        } else if (CFStringCompare(n, CFSTR(kNotifyPower), 0) == kCFCompareEqualTo) {
            vibrate(); sbPowerMenu();
        } else if (CFStringCompare(n, CFSTR(kNotifyShot), 0) == kCFCompareEqualTo) {
            doScreenshot();
        } else if (CFStringCompare(n, CFSTR(kNotifyHide), 0) == kCFCompareEqualTo) {
            SGLog(@"force hide received");
            SGLauncherHide();
        } else if (CFStringCompare(n, CFSTR(kNotifyPanel), 0) == kCFCompareEqualTo ||
                   CFStringCompare(n, CFSTR(kNotifyTest), 0) == kCFCompareEqualTo) {
            SGLog(@"panel notify received (%@)",
                  CFStringCompare(n, CFSTR(kNotifyTest), 0) == kCFCompareEqualTo ? @"manual" : @"gesture");
            if (gPanelWindow && !gPanelWindow.hidden) [gPanelVC hidePanel];
            else SGLauncherShow();
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

static void doPanel(void) {
    static NSTimeInterval lastFire = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastFire < 0.8) { SGLog(@"doPanel debounced"); return; }
    lastFire = now;
    SGLog(@"doPanel isSpringBoard=%d panelEnabled=%d", isSpringBoard(), gPanelEnabled);
    SGPanelVibrate();
    if (isSpringBoard()) {
        if (gPanelWindow && !gPanelWindow.hidden) [gPanelVC hidePanel];
        else SGLauncherShow();
        return;
    }
    notify_post(kNotifyPanel);
}

static void doSwitcher(void) {
    vibrate();
    if (isSpringBoard()) { sbSwitcher(); return; }
    notify_post(kNotifySwitcher);
}

static void doPowerMenu(void) {
    vibrate();
    SGLog(@"doPowerMenu isSpringBoard=%d", isSpringBoard());
    if (isSpringBoard()) { sbPowerMenu(); return; }
    // Apps cannot present SpringBoard's power UI; bounce through SpringBoard.
    notify_post(kNotifyPower);
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

// Uses the system screenshot service. Rendering the window ourselves inside
// SpringBoard only captures SpringBoard's own layers (never the frontmost app)
// and SpringBoard has no permission to write into Photos - that is why the
// top-right double tap appeared to do nothing.
static void doScreenshot(void) {
    vibrate();
    SGLog(@"doScreenshot enter isSpringBoard=%d", isSpringBoard());

    // 2.7.0 — the class dump settled it.
    //
    // SpringBoard had NO screenshot manager registered because they all live in
    // /System/Library/PrivateFrameworks/ScreenshotServices.framework, which
    // SpringBoard only loads on demand.  Confirmed present in the SDK:
    //   SSScreenCapturer, SSMainScreenSnapshotter, SSScreenSnapshotter
    // So: dlopen that framework first, then drive SSScreenCapturer.
    if (!isSpringBoard()) {
        notify_post(kNotifyShot);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        void *ss = dlopen("/System/Library/PrivateFrameworks/"
                          "ScreenshotServices.framework/ScreenshotServices",
                          RTLD_NOW);
        SGLog(@"doScreenshot: ScreenshotServices=%p (%s)", ss, ss ? "ok" : dlerror());

        Class capturerCls = NSClassFromString(@"SSScreenCapturer");
        Class snapCls     = NSClassFromString(@"SSMainScreenSnapshotter");
        SGLog(@"doScreenshot: capturer=%@ snapshotter=%@", capturerCls, snapCls);

        if (capturerCls) {
            id cap = nil;
            for (NSString *n in @[ @"sharedInstance", @"new", @"alloc" ]) {
                SEL sel = NSSelectorFromString(n);
                if (![capturerCls respondsToSelector:sel]) continue;
                id r = ((id(*)(id, SEL))objc_msgSend)(capturerCls, sel);
                if ([n isEqualToString:@"alloc"] && r)
                    r = ((id(*)(id, SEL))objc_msgSend)(r, NSSelectorFromString(@"init"));
                if (r) { cap = r; SGLog(@"doScreenshot: capturer via %@", n); break; }
            }

            if (cap) {
                // -_snapshotter is the ivar that actually grabs the screen.
                id snapper = nil;
                SEL getS = NSSelectorFromString(@"_snapshotter");
                SEL getS2 = NSSelectorFromString(@"snapshotter");
                if ([cap respondsToSelector:getS])
                    snapper = ((id(*)(id, SEL))objc_msgSend)(cap, getS);
                else if ([cap respondsToSelector:getS2])
                    snapper = ((id(*)(id, SEL))objc_msgSend)(cap, getS2);
                if (!snapper) snapper = snapCls;
                SGLog(@"doScreenshot: snapshotter instance=%@", snapper);

                // Try every known capture entry point on both objects.
                NSArray *targets = snapper ? @[ snapper, cap ] : @[ cap ];
                NSArray *sels = @[ @"takeScreenshot",
                                   @"captureScreen",
                                   @"snapshotScreen",
                                   @"takeSnapshot",
                                   @"captureWithOptions:" ];
                for (id t in targets) {
                    for (NSString *sn in sels) {
                        SEL sel = NSSelectorFromString(sn);
                        if (![t respondsToSelector:sel]) continue;
                        @try {
                            if ([sn hasSuffix:@":"])
                                ((void(*)(id, SEL, id))objc_msgSend)(t, sel, nil);
                            else
                                ((void(*)(id, SEL))objc_msgSend)(t, sel);
                            SGLog(@"doScreenshot: %@ -%@ OK",
                                  NSStringFromClass([t class]), sn);
                            return;
                        } @catch (NSException *e) {
                            SGLog(@"doScreenshot: %@ threw %@", sn, e.reason);
                        }
                    }
                }
                SGLog(@"doScreenshot: capturer had no usable selector");
            }
        }

        // Nothing worked — keep a copy so the gesture is not a no-op.
        UIScreen *scr = [UIScreen mainScreen];
        CGRect full = scr.bounds;
        UIGraphicsBeginImageContextWithOptions(full.size, NO, scr.scale);
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.windowLevel >= 4000) continue;
            @try { [w drawViewHierarchyInRect:full afterScreenUpdates:NO]; }
            @catch (__unused NSException *e) { }
        }
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSData *jpg = img ? UIImageJPEGRepresentation(img, 0.95) : nil;
        NSString *path = [NSString stringWithFormat:
            @"/var/mobile/Library/Preferences/SquidShot-%.0f.JPG",
            [[NSDate date] timeIntervalSince1970]];
        if (jpg && [jpg writeToFile:path atomically:YES])
            SGLog(@"doScreenshot: fallback capture -> %@", path);
        else
            SGLog(@"doScreenshot: fallback write failed");
      } @catch (NSException *e) {
          SGLog(@"doScreenshot: aborted %@", e.reason);
      }
    });
}

#pragma mark - Gesture Handler

@interface SGHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToWindow:(UIWindow *)window;
@end

static char kAttachedKey;
// A pan whose should-begin check runs after ~10pt of movement, so the location
// at that moment is already above where the user actually put their finger.
// On a tall box that never mattered; on a shallow bar-anchored band it pushes
// the start point out of the zone. Remember the real starting point instead.
// 2.8.3: UITapGestureRecognizer's -locationInView: returned (0,0) for every
// tap inside SpringBoard, so the zone test never saw a real coordinate.
// A tiny subclass keeps the screen-space point captured at touchesBegan,
// which is exactly what the panel gesture already relies on.
@interface SGTapRecognizer : UITapGestureRecognizer
@property (nonatomic, assign) CGPoint downPoint;
@property (nonatomic, assign) BOOL hasDown;
@end

@implementation SGTapRecognizer
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    if (t) {
        // -locationInWindow is the raw touch coordinate; it does not depend on
        // which view the recogniser is attached to.
        self.downPoint = [t locationInView:nil];
        self.hasDown = YES;
    }
    [super touchesBegan:touches withEvent:event];
}
@end

static char kPanelPanKey;

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
    if (window.windowScene && !gCachedScene) gCachedScene = window.windowScene;
    if (window.windowLevel >= 4000) return;   // our own panel window
    if (objc_getAssociatedObject(window, &kAttachedKey)) return;
    objc_setAssociatedObject(window, &kAttachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGLog(@"attach to window %@ level=%.1f", NSStringFromClass([window class]),
          (double)window.windowLevel);

    // 2.1.0: left-edge back gesture removed at the user's request.
    if (gCornerTapPower || gCornerTapLock) {
        SGTapRecognizer *g =
            [[SGTapRecognizer alloc] initWithTarget:self
                                             action:@selector(onCornerTap:)];
        g.numberOfTapsRequired = 2; g.delegate = self;
        g.cancelsTouchesInView = NO;   // don't eat app taps
        [window addGestureRecognizer:g];
    }
    if (gTwoFingerScreenshot) {
        // 2.1.0: two-finger swipe DOWN takes a screenshot.
        UISwipeGestureRecognizer *g =
            [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(onTwoFingerDown:)];
        g.direction = UISwipeGestureRecognizerDirectionDown;
        g.numberOfTouchesRequired = 2;
        g.cancelsTouchesInView = NO;
        g.delegate = self;
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
    if (gPanelEnabled) {
        // 2.0.0: panel is opened by swiping LEFT from the right screen edge.
        // The black-home-bar swipe and the corner box are gone.
        UIScreenEdgePanGestureRecognizer *g =
            [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self
                                                              action:@selector(onPanelEdge:)];
        g.edges = UIRectEdgeRight;
        g.minimumNumberOfTouches = 1;
        g.maximumNumberOfTouches = 1;
        g.cancelsTouchesInView = NO;
        g.delaysTouchesBegan = NO;
        g.delaysTouchesEnded = NO;
        g.delegate = self;
        objc_setAssociatedObject(g, &kPanelPanKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window addGestureRecognizer:g];
    }
}

#pragma mark - Home indicator (the black bar) as the anchor

// The trigger area must be anchored to the black home bar itself, not measured
// up from the screen edge: the bar's height and inset vary per device, so a
// screen-relative number never lines up with what the user actually sees.
//
// We look for SpringBoard's own affordance view (SBHomeGrabberView /
// _UIHomeAffordance* / SBHomeIndicatorView) and use its real frame. If nothing
// is found (view not loaded yet, renamed class) we fall back to the bottom
// safe-area inset, which is exactly the bar's reserved band.


- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v) return YES;

    // Screen-space corner box shared by the panel swipe and the right-edge
    // switcher, so the two can never fight over the same swipe.
    //
    // 2.0.0: the panel is a right-edge swipe now. UIScreenEdgePanGestureRecognizer
    // already only activates within ~20pt of the right edge, so the only thing
    // left to gate on is the vertical band (keep clear of Control Centre and
    // the very bottom, where the home gesture lives).
    CGPoint p = [g locationInView:v];
    UIWindow *win = v.window;
    CGPoint sp = (win ? [win convertPoint:p toWindow:nil] : p);
    CGSize screen = [UIScreen mainScreen].bounds.size;

    CGFloat top = screen.height * 0.10;
    CGFloat bot = screen.height * 0.90;
    BOOL inBand = (sp.y >= top) && (sp.y <= bot);

    if (!objc_getAssociatedObject(g, &kPanelPanKey)) return YES;
    SGLog(@"panelEdge begin %.0f,%.0f band y[%.0f..%.0f] -> %d",
          sp.x, sp.y, top, bot, inBand);
    return inBand;
}

- (void)onPanelEdge:(UIScreenEdgePanGestureRecognizer *)g {
    if (!gEnabled || !gPanelEnabled) return;

    static BOOL fired = NO;
    UIGestureRecognizerState st = g.state;

    if (st == UIGestureRecognizerStateBegan) {
        fired = NO;
        SGPanelVibrate();          // finger landed on the right edge
        return;
    }
    if (st != UIGestureRecognizerStateChanged &&
        st != UIGestureRecognizerStateEnded &&
        st != UIGestureRecognizerStateCancelled)
        return;
    if (fired) return;

    CGPoint t = [g translationInView:g.view];
    CGPoint vel = [g velocityInView:g.view];

    // Swipe LEFT (negative x) and predominantly horizontal.
    BOOL leftward = (t.x <= -25) || (vel.x <= -300);
    BOOL horizontal = (fabs(t.x) >= fabs(t.y) * 0.8) ||
                      (fabs(vel.x) >= fabs(vel.y) * 0.8 && fabs(vel.x) > 250);
    SGLog(@"panelEdge state=%ld t=%.0f,%.0f v=%.0f left=%d horiz=%d",
          (long)st, t.x, t.y, vel.x, leftward, horizontal);

    if (leftward && horizontal) {
        fired = YES;
        SGPanelVibrate();
        doPanel();
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

    // Gestures are attached to EVERY window, including small app-owned overlays
    // (QQ and friends). Comparing window-local coordinates against the window's
    // own bounds made a top-right tap inside a small window look like top-left,
    // which is why the top-right double tap locked the screen instead of taking
    // a screenshot. Always convert to SCREEN space first.
    // 2.8.2: the log showed "doubleTap 0,0" for every tap, so
    // -convertPoint:toWindow:nil returned zero. On iOS 17 that call is not
    // reliable inside SpringBoard. Compute screen coordinates directly:
    // for a full-screen window its own coordinate space IS the screen.
    UIWindow *win = g.view.window;
    if (!win) win = g.view.superview.window;
    if (!win) win = [UIApplication sharedApplication].keyWindow;

    // Prefer the point captured at touchesBegan: -locationInView: returns
    // (0,0) here, which is why the band test was always true.
    CGPoint p = CGPointZero;
    if ([g isKindOfClass:[SGTapRecognizer class]]) {
        SGTapRecognizer *tr = (SGTapRecognizer *)g;
        if (tr.hasDown) p = tr.downPoint;
    }
    if (p.x == 0 && p.y == 0) {
        CGRect scrB = [UIScreen mainScreen].bounds;
        if (win) {
            CGPoint inWin = [g locationInView:win];
            if (win.bounds.size.width >= scrB.size.width * 0.9) {
                p = inWin;
            } else {
                p = CGPointMake(inWin.x + win.frame.origin.x,
                                inWin.y + win.frame.origin.y);
            }
        }
    }

    // 2.8.0: the trigger is only the status-bar band, level with the Dynamic
    // Island - not the whole screen.  Height comes from the safe-area top
    // inset (falls back to a sane default when the window reports 0).
    // Height == the real status bar (== the Dynamic Island band), no padding.
    // onCornerTap fires for EVERY window, so take the tallest safe-area top
    // we can see rather than whichever window happened to own the tap.
    CGFloat bandH = 59.0;
    @try {
        CGFloat best = 0;
        for (UIWindow *_w in [UIApplication sharedApplication].windows) {
            CGFloat t = _w.safeAreaInsets.top;
            if (t > best) best = t;
        }
        if (best <= 0 && win) best = win.safeAreaInsets.top;
        if (best > 20.0) bandH = best;
    } @catch (__unused NSException *e) { }

    BOOL inBand = (p.y >= 0 && p.y <= bandH);
    SGLog(@"doubleTap %.0f,%.0f band[0..%.0f] -> %d (win=%@ %.0fx%.0f)",
          p.x, p.y, bandH, inBand, NSStringFromClass([win class]),
          win ? win.bounds.size.width : 0, win ? win.bounds.size.height : 0);

    if (inBand && gCornerTapPower) doPowerMenu();
}

- (void)onTwoFingerDown:(UISwipeGestureRecognizer *)g {
    if (!gEnabled || !gTwoFingerScreenshot) return;
    SGLog(@"twoFingerDown -> screenshot");
    doScreenshot();
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
- (id)initWithWindowScene:(UIWindowScene *)scene {
    id r = %orig;
    if (scene && !gCachedScene) gCachedScene = scene;
    return r;
}
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

#pragma mark - Home-gesture priority

// The region the user swipes from is the home-indicator strip, which belongs to
// the system home gesture. Attaching our pan there is not enough: the system
// recognizer claims the touch first and our pan is cancelled after ~40pt.
//

static void attachAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) {
        [[SGHandler shared] attachToWindow:w];
    }
    UIWindow *key = app.keyWindow;
    if (key) [[SGHandler shared] attachToWindow:key];

    // Keep re-latching: SpringBoard recreates its home gesture recognizer.
}

%ctor {
    // Filter is Bundles-limited, but guard anyway: touching UIKit from a
    // non-UI process crashes it.
    if (!NSClassFromString(@"UIApplication") ||
        !NSClassFromString(@"UIWindow")) {
        return;
    }
    loadPrefs();
    gDebugLog = YES;
    @try {
        NSString *m = [NSString stringWithFormat:@"loaded 2.9.6 sb=%d pid=%d %@\n",
                       (int)isSpringBoard(), (int)getpid(), [NSDate date]];
        NSString *path = isSpringBoard()
            ? @"/var/mobile/Library/Preferences/com.minis.squidgesture.loaded"
            : [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                NSUserDomainMask, YES) firstObject]
                stringByAppendingPathComponent:@"com.minis.squidgesture.loaded"];
        [m writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e) { }
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
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyPower), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyShot), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyPanel), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyTest), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyHide), NULL, CFNotificationSuspensionBehaviorCoalesce);
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