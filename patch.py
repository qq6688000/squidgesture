#!/usr/bin/env python3
"""Patch Tweak.x: convert panel from bottom pull-up grid to right-side vertical column."""
import re

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

# ── 1. SGTile layoutSubviews: vertical tile (icon top, name below) ──
edit('SGTile.layoutSubviews',
    """- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat iconSize = MIN(w - 6, 60.0);
    _iconView.frame = CGRectMake((w - iconSize) / 2, 0, iconSize, iconSize);
    _iconView.layer.cornerRadius = iconSize * 0.225;
    _nameLabel.frame = CGRectMake(-4, iconSize + 5, w + 8, 13);
    _removeBtn.frame = CGRectMake(_iconView.frame.origin.x - 6, -6, 22, 22);
}""",
    """- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat iconSize = MIN(w - 20, 46.0);
    if (iconSize < 24) iconSize = MIN(w - 8, 38.0);
    CGFloat offY = (h - iconSize - 16) / 2;
    _iconView.frame = CGRectMake((w - iconSize) / 2, offY, iconSize, iconSize);
    _iconView.layer.cornerRadius = iconSize * 0.225;
    _nameLabel.frame = CGRectMake(4, offY + iconSize + 2, w - 8, 14);
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _removeBtn.frame = CGRectMake(0, 0, 22, 22);
}""")

# ── 2. Title label: smaller font, centered ──
edit('titleLabel.font',
    """    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];""",
    """    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;""")

# ── 3. editBtn: centered text ──
edit('editBtn.align',
    """    _editBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];""",
    """    _editBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _editBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;""")

# ── 5. layoutSheet: right-side vertical panel ──
edit('layoutSheet',
    """- (void)layoutSheet {
    static BOOL inLayout = NO;
    if (inLayout) return;
    inLayout = YES;
    @try {
    CGSize s = self.view.bounds.size;
    if (s.width < 10 || s.height < 10) s = [UIScreen mainScreen].bounds.size;
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
        _table.frame = CGRectMake(0, top, w, contentH - top);
    } else {
        _scroll.frame = CGRectMake(0, top, w, contentH - top);
    }
    _emptyLabel.frame = CGRectMake(pad, (contentH - 60) / 2, w - pad * 2, 60);
    _loadingLabel.frame = _emptyLabel.frame;

    [self layoutGrid];
    } @finally {
        inLayout = NO;
    }
}""",
    """- (void)layoutSheet {
    static BOOL inLayout = NO;
    if (inLayout) return;
    inLayout = YES;
    @try {
    CGSize s = self.view.bounds.size;
    if (s.width < 10 || s.height < 10) s = [UIScreen mainScreen].bounds.size;
    if (s.width < 10) return;

    CGFloat panelW = 126;
    CGFloat pad = 10;
    CGFloat headerH = 54;
    CGFloat maxH = s.height * 0.88;
    CGFloat contentH;

    if (_pickerMode) {
        contentH = maxH;
    } else {
        NSInteger n = [self panelItems].count + 1;
        CGFloat rowH = 78;
        CGFloat addRowH = 54;
        contentH = headerH + n * rowH + addRowH + 10;
        contentH = MAX(MIN(contentH, maxH), headerH + rowH + 40);
    }

    // Right-side vertical strip, vertically centered.
    _sheet.frame = CGRectMake(s.width - panelW, (s.height - contentH) / 2.0,
                              panelW, contentH);
    _sheet.layer.cornerRadius = 24;

    CGFloat innerW = panelW - pad * 2;
    _titleLabel.frame = CGRectMake(pad, 8, innerW - 30, 22);
    _closeBtn.frame = CGRectMake(panelW - pad - 28, 6, 28, 28);
    _editBtn.frame = CGRectMake(pad, 30, innerW, 22);

    CGFloat top = headerH;
    if (_pickerMode) {
        _table.frame = CGRectMake(0, top, panelW, contentH - top);
    } else {
        _scroll.frame = CGRectMake(0, top, panelW, contentH - top);
    }
    _emptyLabel.frame = CGRectMake(pad, (contentH - 48) / 2, innerW, 48);
    _loadingLabel.frame = _emptyLabel.frame;

    [self layoutGrid];
    } @finally {
        inLayout = NO;
    }
}""")

# ── 6. layoutGrid: single column ──
edit('layoutGrid',
    """- (void)layoutGrid {
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
            tile.nameLabel.text = @"\u6dfb\u52a0";
        } else {
            SGCatalogItem *it = items[i];
            tile.item = it;
            CGFloat iconSize = MIN(tileW - 6, 60.0);
            tile.iconView.image = SGIconQuick(it, CGSizeMake(iconSize, iconSize));
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
    _emptyLabel.hidden = (items.count != 0) || _catalog != nil;

    // upgrade placeholders to real icons off the main thread
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
}""",
    """- (void)layoutGrid {
    if (_pickerMode) return;
    for (UIView *v in [_scroll.subviews copy]) [v removeFromSuperview];

    NSArray<SGCatalogItem *> *items = [self panelItems];
    CGFloat w = _sheet.bounds.size.width;
    if (w < 10) return;

    CGFloat pad = 10, gap = 6;
    CGFloat tileW = w - pad * 2;
    CGFloat tileH = 78;
    CGFloat addTileH = 52;
    NSInteger total = items.count + 1;

    CGFloat y = 8;
    for (NSInteger i = 0; i < total; i++) {
        BOOL isAdd = (i == (NSInteger)items.count);
        CGFloat h = isAdd ? addTileH : tileH;
        CGRect f = CGRectMake(pad, y, tileW, h);

        SGTile *tile = [[SGTile alloc] initWithFrame:f];
        if (isAdd) {
            tile.addTile = YES;
            tile.iconView.image = [self plusIcon:40];
            tile.iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            tile.nameLabel.text = @"\u6dfb\u52a0\u5e94\u7528";
        } else {
            SGCatalogItem *it = items[i];
            tile.item = it;
            CGFloat iconSize = MIN(tileW - 16, 44.0);
            tile.iconView.image = SGIconQuick(it, CGSizeMake(iconSize, iconSize));
            tile.nameLabel.text = it.name ?: it.bundleID;
            tile.removeBtn.hidden = !_editing;
            [tile.removeBtn addTarget:self
                               action:@selector(removeTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
        }
        [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:tile];
        y += h + gap;
    }

    _scroll.contentSize = CGSizeMake(w, y - gap + 8);
    _emptyLabel.hidden = (items.count != 0) || _catalog != nil;

    // upgrade placeholders to real icons off the main thread
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
}""")

# ── 7. Table cell: narrower fonts for right strip ──
edit('tableCell.fonts',
    """        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10.5];
        cell.imageView.layer.cornerRadius = 9;""",
    """        cell.textLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:8.5];
        cell.imageView.layer.cornerRadius = 7;""")

# ── 8. onSheetPan: horizontal swipe to dismiss ──
edit('onSheetPan',
    """- (void)onSheetPan:(UIPanGestureRecognizer *)g {
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
}""",
    """- (void)onSheetPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = MAX(0, t.x);
        _sheet.transform = CGAffineTransformMakeTranslation(dx, 0);
        _backdrop.alpha = MAX(0.1, 1.0 - dx / 140.0);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        CGFloat v = [g velocityInView:self.view].x;
        if (t.x > 80 || v > 550) {
            [self hidePanel];
        } else {
            [UIView animateWithDuration:0.22
                             animations:^{
                               self->_sheet.transform = CGAffineTransformIdentity;
                               self->_backdrop.alpha = 1.0;
                             }];
        }
    }
}""")

# ── 9. showPanel: slide in from right ──
edit('showPanel.transform',
    """    _backdrop.alpha = 0;
    _sheet.transform = CGAffineTransformMakeTranslation(0, _sheet.bounds.size.height + 40);""",
    """    _backdrop.alpha = 0;
    _sheet.transform = CGAffineTransformMakeTranslation(_sheet.bounds.size.width + 40, 0);""")

# ── 10. hidePanelNow: slide out to right ──
edit('hidePanelNow.transform',
    """    self.view.userInteractionEnabled = NO;
    _sheet.transform = CGAffineTransformMakeTranslation(0, _sheet.bounds.size.height + 40);""",
    """    self.view.userInteractionEnabled = NO;
    _sheet.transform = CGAffineTransformMakeTranslation(_sheet.bounds.size.width + 40, 0);""")

# ── 11. hidePanel: slide out to right ──
edit('hidePanel.transform',
    """          s->_sheet.transform =
              CGAffineTransformMakeTranslation(0, s->_sheet.bounds.size.height + 40);""",
    """          s->_sheet.transform =
              CGAffineTransformMakeTranslation(s->_sheet.bounds.size.width + 40, 0);""")

# ── 12. Table row height: narrower ──
edit('table.rowHeight',
    """    _table.rowHeight = 54;""",
    """    _table.rowHeight = 44;""")

# ── 13. Content inset ──
edit('table.contentInset',
    """    _table.contentInset = UIEdgeInsetsMake(0, 0, 20, 0);""",
    """    _table.contentInset = UIEdgeInsetsMake(0, 0, 16, 0);""")

with open('/tmp/squidgesture/Tweak.x', 'w') as f:
    f.write(src)

print(f"Applied {len(edits)} edits:")
for e in edits:
    print(f"  \u2713 {e}")
print(f"File size: {len(src)} bytes (was {len(orig)})")
