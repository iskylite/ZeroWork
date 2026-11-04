#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

static NSString *ActivityBadgeLabel(uint64_t count) {
    if (!count) return nil;
    return count > 99 ? @"99+" : [NSString stringWithFormat:@"%llu", (unsigned long long)count];
}

@interface ZWSessionMenuItem : NSMenuItem
@property(nonatomic, strong) NSImage *sourceIcon;
@property(nonatomic, strong) NSColor *iconColor;
@property(nonatomic) uint32_t iconTint;
@property(nonatomic) uint32_t iconBackdrop;
@property(nonatomic) BOOL originalColors;
@property(nonatomic) BOOL bouncing;
- (NSImage *)iconAtOffset:(CGFloat)offset;
@end
@implementation ZWSessionMenuItem
- (NSImage *)iconAtOffset:(CGFloat)offset {
    NSImage *source = self.sourceIcon;
    NSColor *color = self.iconColor;
    BOOL original = self.originalColors;
    BOOL bouncing = self.bouncing;
    uint32_t backdrop = self.iconBackdrop;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(14, bouncing ? 20 : 14) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        NSRect target = NSMakeRect(0, bouncing ? 3 + offset : 0, 14, 14);
        [source drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        if (!original) { [color setFill]; NSRectFillUsingOperation(bounds, NSCompositingOperationSourceIn); }
        if (backdrop & 255) {
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationDestinationOver;
            [[NSColor colorWithSRGBRed:((backdrop >> 24) & 255)/255.0 green:((backdrop >> 16) & 255)/255.0 blue:((backdrop >> 8) & 255)/255.0 alpha:(backdrop & 255)/255.0] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:target] fill];
            [NSGraphicsContext restoreGraphicsState];
        }
        return YES;
    }];
    image.template = NO;
    return image;
}
@end

@interface ZWMenuBar : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic) uint64_t action;
@property(nonatomic, strong) NSImage *logo;
@property(nonatomic) uint64_t count;
@property(nonatomic) void *actionContext;
@property(nonatomic) void (*actionHandler)(void *, uint64_t);
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic) NSTimeInterval animationStart;
- (NSImage *)imageForCount:(uint64_t)count;
@end
@implementation ZWMenuBar
- (void)animateSessionIcons {
    // Menu tracking runs its own loop, so the workspace cannot be relied on
    // to expire this snapshot while the native menu remains open.
    double phase = MAX(0, (NSProcessInfo.processInfo.systemUptime - self.animationStart) * 1000);
    CGFloat offset = phase < 480 ? (phase < 240 ? 3 : 1.5) * sin(fmod(phase, 240) / 240 * M_PI) : 0;
    for (NSMenuItem *candidate in self.menu.itemArray) if ([candidate isKindOfClass:ZWSessionMenuItem.class]) {
        ZWSessionMenuItem *item = (ZWSessionMenuItem *)candidate;
        if (item.bouncing) {
            if (phase >= 480) item.bouncing = NO;
            item.image = [item iconAtOffset:offset];
        }
    }
    if (phase >= 480) {
        [self.animationTimer invalidate];
        self.animationTimer = nil;
    }
}
- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    BOOL animate = NO;
    for (NSMenuItem *candidate in self.menu.itemArray) if ([candidate isKindOfClass:ZWSessionMenuItem.class] && ((ZWSessionMenuItem *)candidate).bouncing) animate = YES;
    if (!animate) return;
    [self.animationTimer invalidate];
    self.animationStart = NSProcessInfo.processInfo.systemUptime;
    __weak ZWMenuBar *weakSelf = self;
    self.animationTimer = [NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf animateSessionIcons]; }];
    [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSEventTrackingRunLoopMode];
}
- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}
- (NSImage *)imageForCount:(uint64_t)count {
    NSString *label = ActivityBadgeLabel(count);
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightBold], NSForegroundColorAttributeName: NSColor.whiteColor};
    NSMutableDictionary *outlineAttributes = [attributes mutableCopy];
    outlineAttributes[NSStrokeColorAttributeName] = [NSColor colorWithSRGBRed:41/255.0 green:44/255.0 blue:50/255.0 alpha:1];
    outlineAttributes[NSStrokeWidthAttributeName] = @(10);
    NSSize textSize = [label sizeWithAttributes:attributes];
    CGFloat badgeWidth = MAX(13, ceil(textSize.width) + 6);
    NSSize size = NSMakeSize(count ? 16 + badgeWidth + 1 : 21, 22);
    NSImage *logo = self.logo;
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        (void)bounds;
        // AppIcon.png main alpha bounds: (63, 41)-(997, 984), top-left pixels.
        // Trim transparent padding while preserving the artwork and aspect ratio.
        NSRect source = NSMakeRect(logo.size.width * 63/1024.0, logo.size.height * 40/1024.0,
                                   logo.size.width * 934/1024.0, logo.size.height * 943/1024.0);
        CGFloat logoWidth = 21 * 934/943.0;
        [logo drawInRect:NSMakeRect((21 - logoWidth)/2, .5, logoWidth, 21) fromRect:source operation:NSCompositingOperationSourceOver fraction:1];
        if (count) {
            NSRect badge = NSMakeRect(16, 8, badgeWidth, 13);
            NSPoint origin = NSMakePoint(NSMidX(badge) - textSize.width / 2, NSMidY(badge) - textSize.height / 2);
            [label drawAtPoint:origin withAttributes:outlineAttributes];
            [label drawAtPoint:origin withAttributes:attributes];
        }
        return YES;
    }];
    image.template = NO;
    return image;
}
- (void)clicked:(id)sender {
    NSEvent *event = NSApp.currentEvent;
    if (event.type == NSEventTypeRightMouseUp) {
        [NSMenu popUpContextMenu:self.menu withEvent:event forView:self.item.button];
    } else {
        [self open:sender];
    }
}
- (void)selectSession:(NSMenuItem *)sender {
    uint64_t token = [sender.representedObject unsignedLongLongValue];
    if (self.actionHandler) self.actionHandler(self.actionContext, token);
    else self.action = token;
}
- (void)quit:(id)sender { (void)sender; self.action = 2; }
- (void)open:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    NSWindow *window = NSApp.mainWindow;
    if (!window) for (NSWindow *candidate in NSApp.windows) {
        if (candidate.canBecomeMainWindow) { window = candidate; break; }
    }
    [window deminiaturize:nil];
    [window makeKeyAndOrderFront:nil];
    if (self.actionHandler) self.actionHandler(self.actionContext, 1);
}
@end
static ZWMenuBar *menuBar;

bool zw_menu_bar_start(const unsigned char *bytes, size_t length) {
    if (!NSThread.isMainThread || !NSApp || !bytes || !length) return false;
    if (menuBar) return true;
    NSImage *logo = [[NSImage alloc] initWithData:[NSData dataWithBytes:bytes length:length]];
    if (!logo.valid) return false;
    ZWMenuBar *value = [ZWMenuBar new];
    value.logo = logo;
    value.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    if (!value.item.button) return false;
    value.item.button.image = [value imageForCount:0];
    value.item.button.imagePosition = NSImageOnly;
    value.item.button.toolTip = @"ZeroWork · 没有新活动的会话";
    [value.item.button setAccessibilityLabel:value.item.button.toolTip];
    value.menu = [NSMenu new];
    value.menu.delegate = value;
    value.item.button.target = value;
    value.item.button.action = @selector(clicked:);
    [value.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    menuBar = value;
    NSApp.dockTile.badgeLabel = nil;
    return true;
}
void zw_menu_bar_set_action_handler(void *context, void (*handler)(void *, uint64_t)) {
    if (!NSThread.isMainThread || !menuBar) return;
    menuBar.actionContext = context;
    menuBar.actionHandler = handler;
}
void zw_menu_bar_stop(void) {
    if (!NSThread.isMainThread || !menuBar) return;
    [menuBar.animationTimer invalidate];
    [NSStatusBar.systemStatusBar removeStatusItem:menuBar.item];
    NSApp.dockTile.badgeLabel = nil;
    menuBar = nil;
}
bool zw_menu_bar_active(void) { return NSApp.isActive; }
void zw_menu_bar_update(uint64_t count) {
    if (!NSThread.isMainThread || !menuBar) return;
    menuBar.count = count;
    menuBar.item.button.image = [menuBar imageForCount:count];
    // Both surfaces consume the same activity projection and clear together.
    NSApp.dockTile.badgeLabel = ActivityBadgeLabel(count);
    NSString *summary = count == 0 ? @"没有新活动的会话" : [NSString stringWithFormat:@"%llu 个会话有新活动", (unsigned long long)count];
    [menuBar.menu removeAllItems];
    NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:count ? @"活动会话" : @"没有新活动的会话" action:nil keyEquivalent:@""];
    [menuBar.menu addItem:heading];
    menuBar.item.button.toolTip = [@"ZeroWork · " stringByAppendingString:summary];
    [menuBar.item.button setAccessibilityLabel:menuBar.item.button.toolTip];
}

void zw_menu_bar_add_session(uint64_t token, const unsigned char *title, size_t length, const unsigned char *svg, size_t svg_length, const unsigned char *rgba, size_t rgba_length, uint32_t tint, uint32_t backdrop, bool original, bool bouncing, bool current, const unsigned char *status, size_t status_length) {
    if (!NSThread.isMainThread || !menuBar || !title) return;
    NSString *name = [[NSString alloc] initWithBytes:title length:length encoding:NSUTF8StringEncoding];
    if (!name.length) name = @"会话";
    ZWSessionMenuItem *item = [[ZWSessionMenuItem alloc] initWithTitle:name action:@selector(selectSession:) keyEquivalent:@""];
    item.iconTint = tint;
    item.iconBackdrop = backdrop;
    item.originalColors = original;
    item.bouncing = bouncing;
    item.state = current ? NSControlStateValueOn : NSControlStateValueOff;
    if (status && status_length) item.toolTip = [[NSString alloc] initWithBytes:status length:status_length encoding:NSUTF8StringEncoding];
    {
        NSImage *source = nil;
        if (rgba && rgba_length == 72 * 72 * 4) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:72 pixelsHigh:72 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:72*4 bitsPerPixel:32];
            if (rep) {
                memcpy(rep.bitmapData, rgba, rgba_length);
                source = [[NSImage alloc] initWithSize:NSMakeSize(14, 14)];
                [source addRepresentation:rep];
            }
        } else if (svg && svg_length) source = [[NSImage alloc] initWithData:[NSData dataWithBytes:svg length:svg_length]];
        if (source.valid) {
            item.sourceIcon = source;
            item.iconColor = [NSColor colorWithSRGBRed:((tint >> 24) & 255)/255.0 green:((tint >> 16) & 255)/255.0 blue:((tint >> 8) & 255)/255.0 alpha:(tint & 255)/255.0];
            item.image = [item iconAtOffset:0];
        }
    }
    item.target = menuBar;
    item.representedObject = @(token);
    [menuBar.menu addItem:item];
}
void zw_menu_bar_finish(void) {
    if (!NSThread.isMainThread || !menuBar) return;
    [menuBar.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 ZeroWork" action:@selector(quit:) keyEquivalent:@""];
    quit.target = menuBar; [menuBar.menu addItem:quit];
}
uint64_t zw_menu_bar_take_action(void) {
    if (!NSThread.isMainThread || !menuBar) return 0;
    uint64_t action = menuBar.action;
    menuBar.action = 0;
    return action;
}

#ifdef ZW_MENU_BAR_TEST
// Read-only probe for the opt-in native test harness; absent from production.
size_t zw_menu_bar_snapshot(unsigned char *buffer, size_t capacity) {
    if (!NSThread.isMainThread || !menuBar || !buffer) return 0;
    NSMutableArray *rows = [NSMutableArray new];
    for (NSMenuItem *item in menuBar.menu.itemArray) {
        if (![item.representedObject isKindOfClass:NSNumber.class]) continue;
        ZWSessionMenuItem *session = (ZWSessionMenuItem *)item;
        [rows addObject:@{@"token":item.representedObject, @"title":item.title,
            @"current":@(item.state == NSControlStateValueOn), @"has_icon":@(item.image.valid),
            @"icon_tint":@(session.iconTint), @"icon_backdrop":@(session.iconBackdrop), @"original_colours":@(session.originalColors), @"bouncing":@(session.bouncing),
            @"icon_width":@(item.image.size.width), @"status":item.toolTip ?: @""}];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"count":@(menuBar.count), @"dock_badge":NSApp.dockTile.badgeLabel ?: @"", @"foreground":@(NSApp.isActive), @"rows":rows} options:0 error:nil];
    if (!json || json.length > capacity) return 0;
    memcpy(buffer, json.bytes, json.length);
    return json.length;
}
#endif
