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
#import <QuartzCore/QuartzCore.h>

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

// launcher panel
static BOOL gPanelEnabled = YES;
static BOOL gPanelVibrate = YES;
static NSMutableArray<NSString *> *gPanelApps = nil;

@class SGLauncherVC;
static UIWindow *gPanelWindow;
static SGLauncherVC *gPanelVC;
static __weak UIWindow *gPanelPrevKey;
static void SGLauncherShow(void);
static void SGLauncherHide(void);

@interface SGKeyboardOwner : NSObject
+ (void)take;
+ (void)restore;
@end

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
    LOAD("PanelEnabled", gPanelEnabled, boolValue);
    LOAD("PanelVibrate", gPanelVibrate, boolValue);
#undef LOAD

    NSArray *list = p[@"PanelApps"];
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
#define kNotifyPanel    "com.minis.squidgesture.action.panel"

static void vibrate(void) {
    if (gVibrationFeedback) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

static void SGPanelVibrate(void) {
    if (gPanelVibrate) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

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

static void SGInvalidateCatalog(void) { gCachedCatalog = nil; }

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

// Never returns nil.
static UIImage *SGIconForItem(SGCatalogItem *item) {
    if (item.triedIcon) return item.icon;
    item.triedIcon = YES;

    UIImage *img = nil;
    if (item.bundleID.length) {
        // 1) LSApplicationProxy -iconDataForVariant:
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

        // 2) UIImage private helper (still present in iOS 16 SpringBoard)
        if (!img) {
            SEL s2 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
            if ([UIImage respondsToSelector:s2]) {
                @try {
                    img = ((id(*)(id, SEL, id, int, CGFloat))objc_msgSend)(
                        [UIImage class], s2, item.bundleID, 2, [UIScreen mainScreen].scale);
                } @catch (__unused NSException *e) {
                }
            }
        }

        // 3) read the PNG straight out of the bundle (SpringBoard has access)
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

    if (!img) img = SGLetterIcon(item.name ?: item.bundleID ?: @"?", CGSizeMake(56, 56));
    item.icon = img;
    return img;
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

static BOOL SGLaunchApp(NSString *bundleID) {
    if (!bundleID.length) return NO;

    id ws = SGLookupWorkspace();
    if (ws) {
        SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([ws respondsToSelector:open]) {
            BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, open, bundleID);
            SGLog(@"launch %@ via workspace -> %d", bundleID, ok);
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
            SGLog(@"launch %@ via UIApplication", bundleID);
            return YES;
        } @catch (__unused NSException *e) {
        }
    }
    SGLog(@"launch %@ FAILED", bundleID);
    return NO;
}

static NSArray<SGCatalogItem *> *SGLoadCatalog(void) {
    if (gCachedCatalog) return gCachedCatalog;

    NSMutableArray *out = [NSMutableArray array];
    id ws = SGLookupWorkspace();
    SEL allSel = NSSelectorFromString(@"allInstalledApplications");
    NSArray *apps = (ws && [ws respondsToSelector:allSel])
                        ? ((id(*)(id, SEL))objc_msgSend)(ws, allSel)
                        : nil;

    for (id proxy in apps) {
        @try {
            SEL sBid = NSSelectorFromString(@"bundleIdentifier");
            SEL sName = NSSelectorFromString(@"localizedName");
            SEL sType = NSSelectorFromString(@"applicationType");
            SEL sHidden = NSSelectorFromString(@"isHidden");
            SEL sPlace = NSSelectorFromString(@"isPlaceholder");

            NSString *bid = [proxy respondsToSelector:sBid]
                                ? ((id(*)(id, SEL))objc_msgSend)(proxy, sBid)
                                : nil;
            if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
            if ([bid hasPrefix:@"com.apple.WebKit"]) continue;
            if ([bid isEqualToString:@"com.apple.SafariViewService"]) continue;

            NSString *name = [proxy respondsToSelector:sName]
                                 ? ((id(*)(id, SEL))objc_msgSend)(proxy, sName)
                                 : bid;
            if (![name isKindOfClass:[NSString class]] || !name.length) name = bid;

            NSString *type = [proxy respondsToSelector:sType]
                                 ? ((id(*)(id, SEL))objc_msgSend)(proxy, sType)
                                 : @"User";
            if ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"Internal"])
                continue;

            if ([proxy respondsToSelector:sHidden] &&
                ((BOOL(*)(id, SEL))objc_msgSend)(proxy, sHidden))
                continue;
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

    gCachedCatalog = out;
    SGLog(@"catalog: %lu apps", (unsigned long)out.count);
    return gCachedCatalog;
}

static SGCatalogItem *SGCatalogFind(NSArray<SGCatalogItem *> *catalog, NSString *bid) {
    for (SGCatalogItem *it in catalog)
        if ([it.bundleID isEqualToString:bid]) return it;
    SGCatalogItem *it = [SGCatalogItem new];
    it.bundleID = bid;
    it.name = bid;
    return it;
}

#pragma mark - Launcher panel : tile

@interface SGTile : UIControl
@property (nonatomic, strong) SGCatalogItem *item;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIButton *removeBtn;
@property (nonatomic, assign) BOOL addTile;
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
    CGFloat iconSize = MIN(w - 6, 60.0);
    _iconView.frame = CGRectMake((w - iconSize) / 2, 0, iconSize, iconSize);
    _iconView.layer.cornerRadius = iconSize * 0.225;
    _nameLabel.frame = CGRectMake(-4, iconSize + 5, w + 8, 13);
    _removeBtn.frame = CGRectMake(_iconView.frame.origin.x - 6, -6, 22, 22);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1.0;
}

@end

#pragma mark - Launcher panel : view controller

@interface SGLauncherVC : UIViewController <UITextFieldDelegate, UITableViewDataSource,
                                            UITableViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIControl *backdrop;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *editBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<SGCatalogItem *> *catalog;
@property (nonatomic, strong) NSArray<SGCatalogItem *> *filtered;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign) BOOL pickerMode;
@property (nonatomic, copy) NSString *filter;
- (void)showPanel;
- (void)hidePanel;
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
    _sheet.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.94];
    [self.view addSubview:_sheet];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    blur.frame = _sheet.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [_sheet addSubview:blur];

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

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.hidden = YES;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_sheet addSubview:_table];

    _searchField = [[UITextField alloc] init];
    _searchField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"搜索已安装的应用"
            attributes:@{ NSForegroundColorAttributeName : [UIColor colorWithWhite:0.55 alpha:1.0] }];
    _searchField.textColor = [UIColor whiteColor];
    _searchField.font = [UIFont systemFontOfSize:14];
    _searchField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _searchField.layer.cornerRadius = 10;
    _searchField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _searchField.leftViewMode = UITextFieldViewModeAlways;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.returnKeyType = UIReturnKeyDone;
    _searchField.delegate = self;
    _searchField.hidden = YES;
    [_searchField addTarget:self
                     action:@selector(searchChanged)
           forControlEvents:UIControlEventEditingChanged];
    [_sheet addSubview:_searchField];

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
    CGSize s = self.view.bounds.size;
    if (s.width < 10) return;

    CGFloat margin = 14;
    CGFloat w = s.width - margin * 2;
    CGFloat headerH = 46;
    CGFloat maxH = s.height * 0.74;
    CGFloat contentH;

    if (_pickerMode) {
        contentH = maxH;
    } else {
        NSInteger cols = 4;
        NSInteger n = [self panelItems].count + 1;
        NSInteger rows = MAX(1, (n + cols - 1) / cols);
        CGFloat tileW = (w - 32 - 12 * (cols - 1)) / cols;
        CGFloat rowH = (tileW - 6) + 5 + 13;
        contentH = headerH + 20 + rows * (rowH + 14) + 8;
        contentH = MAX(MIN(contentH, maxH), headerH + 96);
    }

    _sheet.frame = CGRectMake(margin, s.height - contentH - 22, w, contentH);

    CGFloat pad = 16;
    _titleLabel.frame = CGRectMake(pad, 13, 140, 22);
    _closeBtn.frame = CGRectMake(w - pad - 34, 9, 34, 30);
    _editBtn.frame = CGRectMake(w - pad - 34 - 56, 9, 56, 30);

    CGFloat top = headerH;
    if (_pickerMode) {
        _searchField.frame = CGRectMake(pad, top, w - pad * 2, 34);
        _table.frame = CGRectMake(0, top + 40, w, contentH - top - 40);
    } else {
        _scroll.frame = CGRectMake(0, top, w, contentH - top);
    }
    _emptyLabel.frame = CGRectMake(pad, (contentH - 60) / 2, w - pad * 2, 60);

    [self layoutGrid];
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

    NSInteger cols = 4;
    CGFloat pad = 16, gap = 12;
    CGFloat tileW = (w - pad * 2 - gap * (cols - 1)) / cols;
    CGFloat tileH = (tileW - 6) + 5 + 13;

    NSInteger total = items.count + 1;
    NSInteger rows = (total + cols - 1) / cols;

    for (NSInteger i = 0; i < total; i++) {
        BOOL isAdd = (i == (NSInteger)items.count);
        NSInteger r = i / cols, c = i % cols;
        CGRect f = CGRectMake(pad + c * (tileW + gap), 10 + r * (tileH + 14), tileW, tileH);

        SGTile *tile = [[SGTile alloc] initWithFrame:f];
        if (isAdd) {
            tile.addTile = YES;
            tile.iconView.image = [self plusIcon:60];
            tile.iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            tile.nameLabel.text = @"添加";
        } else {
            SGCatalogItem *it = items[i];
            tile.item = it;
            tile.iconView.image = SGIconForItem(it);
            tile.nameLabel.text = it.name ?: it.bundleID;
            tile.removeBtn.hidden = !_editing;
            [tile.removeBtn addTarget:self
                               action:@selector(removeTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
        }
        [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:tile];
    }

    _scroll.contentSize = CGSizeMake(w, 10 + rows * (tileH + 14) + 8);
    _emptyLabel.hidden = (items.count != 0);
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
    [self hidePanel];
    if (it.bundleID.length) {
        NSString *bid = it.bundleID;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SGLaunchApp(bid); });
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
    [SGKeyboardOwner take];
    _scroll.hidden = YES;
    _emptyLabel.hidden = YES;
    _table.hidden = NO;
    _searchField.hidden = NO;
    _searchField.text = @"";
    _filter = @"";
    _titleLabel.text = @"添加应用";
    [_editBtn setTitle:@"完成" forState:UIControlStateNormal];
    SGInvalidateCatalog();
    _catalog = SGLoadCatalog();
    [self reloadFiltered];
    [self layoutSheet];
}

- (void)exitPicker {
    _pickerMode = NO;
    [SGKeyboardOwner restore];
    _scroll.hidden = NO;
    _table.hidden = YES;
    _searchField.hidden = YES;
    [_searchField resignFirstResponder];
    _titleLabel.text = @"应用";
    [_editBtn setTitle:(_editing ? @"完成" : @"编辑") forState:UIControlStateNormal];
    [self layoutSheet];
}

- (void)reloadFiltered {
    if (!_catalog) _catalog = SGLoadCatalog();
    NSString *f = _filter ?: @"";
    NSMutableArray *out = [NSMutableArray array];
    for (SGCatalogItem *it in _catalog) {
        if ([gPanelApps containsObject:it.bundleID]) continue;
        if (f.length) {
            BOOL hit = [it.name rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [it.bundleID rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!hit) continue;
        }
        [out addObject:it];
    }
    _filtered = out;
    [_table reloadData];
}

- (void)searchChanged {
    _filter = _searchField.text ?: @"";
    [self reloadFiltered];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _filtered.count;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 54;
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
    if (ip.row < (NSInteger)_filtered.count) {
        SGCatalogItem *it = _filtered[ip.row];
        cell.textLabel.text = it.name;
        cell.detailTextLabel.text = it.bundleID;
        cell.imageView.image = SGIconForItem(it);
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)_filtered.count) return;
    SGCatalogItem *it = _filtered[ip.row];
    if (![gPanelApps containsObject:it.bundleID]) {
        NSMutableArray *l = [gPanelApps mutableCopy];
        [l addObject:it.bundleID];
        gPanelApps = l;
        SGSavePanelApps(gPanelApps);
        SGPanelVibrate();
    }
    [self exitPicker];
    [self reloadFiltered];
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
    CGPoint t = [g translationInView:self.view];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat dy = MAX(0, t.y);
        _sheet.transform = CGAffineTransformMakeTranslation(0, dy);
        _backdrop.alpha = MAX(0.1, 1.0 - dy / 240.0);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        CGFloat v = [g velocityInView:self.view].y;
        if (t.y > 110 || v > 700) {
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
    _searchField.hidden = YES;
    _titleLabel.text = @"应用";
    [_editBtn setTitle:@"编辑" forState:UIControlStateNormal];

    SGInvalidateCatalog();
    _catalog = SGLoadCatalog();
    [self layoutSheet];

    _backdrop.alpha = 0;
    _sheet.transform = CGAffineTransformMakeTranslation(0, _sheet.bounds.size.height + 40);
    [UIView animateWithDuration:0.32
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

- (void)hidePanel {
    [self.view endEditing:YES];
    [SGKeyboardOwner restore];
    [UIView animateWithDuration:0.2
        animations:^{
          self->_sheet.transform =
              CGAffineTransformMakeTranslation(0, self->_sheet.bounds.size.height + 40);
          self->_backdrop.alpha = 0;
        }
        completion:^(BOOL f) {
          SGLauncherHide();
        }];
}

@end

#pragma mark - Launcher panel : key window ownership

@implementation SGKeyboardOwner
+ (void)take {
    if (!gPanelWindow || gPanelWindow.isKeyWindow) return;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && w.windowLevel < 4000) {
            gPanelPrevKey = w;
            break;
        }
    }
    [gPanelWindow makeKeyWindow];
}
+ (void)restore {
    UIWindow *back = gPanelPrevKey;
    gPanelPrevKey = nil;
    if (!back || back.hidden || back == gPanelWindow) return;
    [back makeKeyWindow];
}
@end


#pragma mark - Launcher panel : SpringBoard host window

static UIWindow *SBCurrentKeyWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow && w.windowLevel < 4000) return w;
    return nil;
}

static UIWindow *SGMakePanelWindow(void) {
    UIWindow *win = nil;
    UIWindowScene *scene = nil;

    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        if (!scene) scene = (UIWindowScene *)sc;
        if (sc.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)sc;
            break;
        }
    }
    if (!scene) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.windowScene) {
                scene = w.windowScene;
                break;
            }
        }
    }

    if (scene && [UIWindow instancesRespondToSelector:NSSelectorFromString(@"initWithWindowScene:")])
        win = ((id(*)(id, SEL, id))objc_msgSend)([UIWindow alloc],
                                                 NSSelectorFromString(@"initWithWindowScene:"), scene);
    else
        win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    if (!win.windowScene && scene) {
        SEL s2 = NSSelectorFromString(@"_setWindowScene:");
        if ([win respondsToSelector:s2]) ((void(*)(id, SEL, id))objc_msgSend)(win, s2, scene);
    }

    win.frame = [UIScreen mainScreen].bounds;
    win.windowLevel = 5000.0;
    win.backgroundColor = [UIColor clearColor];
    win.hidden = YES;
    SGLog(@"panel window ready level=%.1f scene=%@", (double)win.windowLevel,
          win.windowScene ? @"yes" : @"no");
    return win;
}

static void SGLauncherShow(void) {
    if (!isSpringBoard()) return;
    if (!gPanelEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gPanelWindow && !gPanelWindow.hidden) {
          [gPanelVC hidePanel];   // toggle off
          return;
      }
      if (!gPanelWindow) {
          gPanelWindow = SGMakePanelWindow();
          gPanelVC = [[SGLauncherVC alloc] init];
          gPanelWindow.rootViewController = gPanelVC;
      }
      // Deliberately not makeKeyAndVisible: the frontmost app keeps keyboard focus
      // and text input. SGKeyboardOwner takes key status only for the search field.
      if (gPanelWindow.rootViewController != gPanelVC) gPanelWindow.rootViewController = gPanelVC;
      gPanelWindow.hidden = NO;
      gPanelWindow.alpha = 1.0;
      [gPanelVC showPanel];
      SGLog(@"panel shown");
    });
}

static void SGLauncherHide(void) {
    if (!isSpringBoard()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      gPanelWindow.hidden = YES;
      gPanelVC.view.alpha = 0;
      gPanelVC.view.transform = CGAffineTransformIdentity;
      UIWindow *back = SBCurrentKeyWindow();
      if (back && back != gPanelWindow && !back.hidden) {
          [back makeKeyWindow];
      } else {
          Class sbClass = NSClassFromString(@"SpringBoard");
          if (sbClass) {
              SEL sh = NSSelectorFromString(@"sharedInstance");
              if ([sbClass respondsToSelector:sh]) {
                  id sb = ((id(*)(id, SEL))objc_msgSend)(sbClass, sh);
                  SEL mkw = NSSelectorFromString(@"_keyWindow");
                  if (sb && [sb respondsToSelector:mkw]) {
                      UIWindow *kw = ((id(*)(id, SEL))objc_msgSend)(sb, mkw);
                      if (kw && kw != gPanelWindow) [kw makeKeyWindow];
                  }
              }
          }
      }
      SGLog(@"panel hidden");
    });
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
        } else if (CFStringCompare(n, CFSTR(kNotifyPanel), 0) == kCFCompareEqualTo) {
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
    if (window.windowLevel >= 4000) return;   // our own panel window
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
    if (gPanelEnabled) {
        UIPanGestureRecognizer *g =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(onPanelPan:)];
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

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!objc_getAssociatedObject(g, &kPanelPanKey)) return YES;
    UIView *v = g.view;
    if (!v) return NO;
    CGPoint p = [g locationInView:v];
    CGSize s = v.bounds.size;
    CGFloat boxW = MAX(gCornerSize * 1.6, 140.0);
    CGFloat boxH = MAX(gCornerSize * 2.4, 220.0);
    if (p.x < s.width - boxW || p.y < s.height - boxH) return NO;
    CGPoint t = [(UIPanGestureRecognizer *)g translationInView:v];
    if (t.y > 2) return NO;
    return YES;
}

- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    if (!gEnabled || !gPanelEnabled) return;
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint t = [g translationInView:g.view];
    CGPoint vel = [g velocityInView:g.view];
    BOOL upward = (t.y < -55 || vel.y < -650);
    BOOL vertical = fabs(t.y) > fabs(t.x) * 1.2;
    SGLog(@"panelPan t=%.0f,%.0f v=%.0f up=%d vert=%d", t.x, t.y, vel.y, upward, vertical);
    if (upward && vertical) doPanel();
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
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, actionNotifyCb,
            CFSTR(kNotifyPanel), NULL, CFNotificationSuspensionBehaviorCoalesce);
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