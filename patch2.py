#!/usr/bin/env python3
"""Patch Tweak.x: add haptic feedback back + improve gesture logging."""

with open('/tmp/squidgesture/Tweak.x', 'r') as f:
    src = f.read()
orig = src
edits = []

def edit(name, old, new, count=1):
    global src
    n = src.count(old)
    assert n == count, f"[{name}] expected {count} match, found {n}"
    src = src.replace(old, new, count)
    edits.append(name)

# 1. vibrate(): actual haptic feedback
edit('vibrate',
    """static void vibrate(void) {
    // v1.6.4: all haptic feedback disabled at the user's request.
    (void)0;
}""",
    """static void vibrate(void) {
    if (!gVibrationFeedback) return;
    UIImpactFeedbackGenerator *gen =
        [UIImpactFeedbackGenerator generatorWithStyle:UIImpactFeedbackStyleLight];
    [gen prepare];
    [gen impactOccurred];
}""")

# 2. SGPanelVibrate(): actual haptic feedback
edit('SGPanelVibrate',
    """static void SGPanelVibrate(void) {
    // v1.6.4: all haptic feedback disabled at the user's request.
    (void)0;
}""",
    """static void SGPanelVibrate(void) {
    if (!gVibrationFeedback || !gPanelVibrate) return;
    UIImpactFeedbackGenerator *gen =
        [UIImpactFeedbackGenerator generatorWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare];
    [gen impactOccurred];
}""")

# 3. gestureRecognizerShouldBegin: add logging
edit('gestureRecognizerShouldBegin',
    """- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v) return YES;

    if (!objc_getAssociatedObject(g, &kPanelPanKey)) return YES;
    if (!gPanelEnabled) return NO;

    CGPoint p = [g locationInView:v];
    UIWindow *win = v.window;
    CGPoint sp = (win ? [win convertPoint:p toWindow:nil] : p);

    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat top = scr.height * 0.12;            // keep clear of Control Centre
    CGFloat bot = scr.height * 0.88;

    BOOL inZone = (sp.y >= top) && (sp.y <= bot);
    SGLog(@"panelEdge begin %.0f,%.0f x[%.0f..%.0f] y[%.0f..%.0f] -> %d",
          sp.x, sp.y, scr.width - 30.0, scr.width, top, bot, inZone);
    return inZone;
}""",
    """- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!objc_getAssociatedObject(g, &kPanelPanKey)) return YES;
    if (!gPanelEnabled) return NO;

    UIView *v = g.view;
    if (!v) return YES;

    CGPoint p = [g locationInView:v];
    UIWindow *win = v.window;
    CGPoint sp = (win ? [win convertPoint:p toWindow:nil] : p);

    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat top = scr.height * 0.12;            // keep clear of Control Centre
    CGFloat bot = scr.height * 0.88;

    BOOL inZone = (sp.y >= top) && (sp.y <= bot);
    SGLog(@"panelEdge shouldBegin p=(%.0f,%.0f) sp=(%.0f,%.0f) y[%.0f..%.0f] -> %d",
          p.x, p.y, sp.x, sp.y, top, bot, inZone);
    return inZone;
}""")

# 4. onPanelPan: add haptic on start + on recognition, more logging
edit('onPanelPan',
    """- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    if (!gEnabled || !gPanelEnabled) return;

    static BOOL fired = NO;
    UIGestureRecognizerState st = g.state;

    if ((st == UIGestureRecognizerStateEnded ||
         st == UIGestureRecognizerStateCancelled ||
         st == UIGestureRecognizerStateFailed) &&
        [g isKindOfClass:[SGPanelPan class]]) {
        ((SGPanelPan *)g).hasStart = NO;
    }

    if (st == UIGestureRecognizerStateBegan) { fired = NO; return; }
    if (st != UIGestureRecognizerStateChanged &&
        st != UIGestureRecognizerStateEnded &&
        st != UIGestureRecognizerStateCancelled) return;
    if (fired) return;

    CGPoint t = [g translationInView:g.view];
    CGPoint vel = [g velocityInView:g.view];

    // leftward, and clearly more horizontal than vertical
    BOOL leftward = (t.x <= -30) || (vel.x <= -300);
    BOOL horizontal = (fabs(t.x) >= fabs(t.y) * 0.85) ||
                      (fabs(vel.x) >= fabs(vel.y) * 0.9 && fabs(vel.x) > 200);
    SGLog(@"panelEdge state=%ld t=%.0f,%.0f v=%.0f left=%d horiz=%d",
          (long)st, t.x, t.y, vel.x, leftward, horizontal);

    if (leftward && horizontal) {
        fired = YES;
        doPanel();
    }
}""",
    """- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    if (!gEnabled || !gPanelEnabled) return;

    static BOOL fired = NO;
    UIGestureRecognizerState st = g.state;

    if ((st == UIGestureRecognizerStateEnded ||
         st == UIGestureRecognizerStateCancelled ||
         st == UIGestureRecognizerStateFailed) &&
        [g isKindOfClass:[SGPanelPan class]]) {
        ((SGPanelPan *)g).hasStart = NO;
    }

    if (st == UIGestureRecognizerStateBegan) {
        fired = NO;
        SGLog(@"panelEdge Began");
        SGPanelVibrate();   // haptic: gesture started
        return;
    }
    if (st != UIGestureRecognizerStateChanged &&
        st != UIGestureRecognizerStateEnded &&
        st != UIGestureRecognizerStateCancelled) return;
    if (fired) return;

    CGPoint t = [g translationInView:g.view];
    CGPoint vel = [g velocityInView:g.view];

    BOOL leftward = (t.x <= -30) || (vel.x <= -300);
    BOOL horizontal = (fabs(t.x) >= fabs(t.y) * 0.85) ||
                      (fabs(vel.x) >= fabs(vel.y) * 0.9 && fabs(vel.x) > 200);
    SGLog(@"panelEdge state=%ld t=(%.0f,%.0f) v=(%.0f,%.0f) left=%d horiz=%d",
          (long)st, t.x, t.y, vel.x, vel.y, leftward, horizontal);

    if (leftward && horizontal) {
        fired = YES;
        SGPanelVibrate();   // haptic: gesture recognized
        doPanel();
    }
}""")

# 5. attachToWindow: add logging for gesture creation
edit('attachToWindow.panelGesture',
    """        [gPanelPans addObject:g];
        [window addGestureRecognizer:g];
    }""",
    """        [gPanelPans addObject:g];
        [window addGestureRecognizer:g];
        SGLog(@"panelEdge recognizer attached to %@ level=%.1f",
              NSStringFromClass([window class]), (double)window.windowLevel);
    }""")

with open('/tmp/squidgesture/Tweak.x', 'w') as f:
    f.write(src)

print(f"Applied {len(edits)} edits:")
for e in edits:
    print(f"  \u2713 {e}")
print(f"File size: {len(src)} bytes (was {len(orig)})")
