#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stdint.h>

@interface ZWMenuBar : NSObject
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic) uint64_t action;
@property(nonatomic, strong) NSImage *logo;
@property(nonatomic) uint64_t count;
@property(nonatomic) void *actionContext;
@property(nonatomic) void (*actionHandler)(void *, uint64_t);
- (NSImage *)imageForCount:(uint64_t)count;
@end
@implementation ZWMenuBar
- (NSImage *)imageForCount:(uint64_t)count {
    NSString *label = count > 99 ? @"99+" : [NSString stringWithFormat:@"%llu", (unsigned long long)count];
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightBold], NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize textSize = [label sizeWithAttributes:attributes];
    CGFloat badgeWidth = MAX(11, ceil(textSize.width) + 4);
    NSSize size = NSMakeSize(count ? 12 + badgeWidth : 20, 22);
    NSImage *logo = self.logo;
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        (void)bounds;
        [logo drawInRect:NSMakeRect(0, 1, 20, 20) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        if (count) {
            NSRect badge = NSMakeRect(12, 11, badgeWidth, 11);
            [NSColor.systemRedColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:5.5 yRadius:5.5] fill];
            [label drawAtPoint:NSMakePoint(NSMidX(badge) - textSize.width / 2, NSMidY(badge) - textSize.height / 2) withAttributes:attributes];
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
    value.item.button.target = value;
    value.item.button.action = @selector(clicked:);
    [value.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    menuBar = value;
    return true;
}
void zw_menu_bar_set_action_handler(void *context, void (*handler)(void *, uint64_t)) {
    if (!NSThread.isMainThread || !menuBar) return;
    menuBar.actionContext = context;
    menuBar.actionHandler = handler;
}
void zw_menu_bar_stop(void) {
    if (!NSThread.isMainThread || !menuBar) return;
    [NSStatusBar.systemStatusBar removeStatusItem:menuBar.item];
    menuBar = nil;
}
bool zw_menu_bar_active(void) { return NSApp.isActive; }
void zw_menu_bar_update(uint64_t count) {
    if (!NSThread.isMainThread || !menuBar) return;
    menuBar.count = count;
    menuBar.item.button.image = [menuBar imageForCount:count];
    NSString *summary = count == 0 ? @"没有新活动的会话" : [NSString stringWithFormat:@"%llu 个会话有新活动", (unsigned long long)count];
    [menuBar.menu removeAllItems];
    NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:count ? @"活动会话" : @"没有新活动的会话" action:nil keyEquivalent:@""];
    [menuBar.menu addItem:heading];
    menuBar.item.button.toolTip = [@"ZeroWork · " stringByAppendingString:summary];
    [menuBar.item.button setAccessibilityLabel:menuBar.item.button.toolTip];
}

void zw_menu_bar_add_session(uint64_t token, const unsigned char *title, size_t length, const unsigned char *svg, size_t svg_length, uint32_t tint, bool current, const unsigned char *status, size_t status_length) {
    if (!NSThread.isMainThread || !menuBar || !title) return;
    NSString *name = [[NSString alloc] initWithBytes:title length:length encoding:NSUTF8StringEncoding];
    if (!name.length) name = @"会话";
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectSession:) keyEquivalent:@""];
    item.state = current ? NSControlStateValueOn : NSControlStateValueOff;
    if (status && status_length) item.toolTip = [[NSString alloc] initWithBytes:status length:status_length encoding:NSUTF8StringEncoding];
    if (svg && svg_length) {
        NSImage *source = [[NSImage alloc] initWithData:[NSData dataWithBytes:svg length:svg_length]];
        if (source.valid) {
            NSColor *color = [NSColor colorWithSRGBRed:((tint >> 24) & 255)/255.0 green:((tint >> 16) & 255)/255.0 blue:((tint >> 8) & 255)/255.0 alpha:(tint & 255)/255.0];
            item.image = [NSImage imageWithSize:NSMakeSize(14, 14) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
                [source drawInRect:bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
                [color setFill]; NSRectFillUsingOperation(bounds, NSCompositingOperationSourceIn);
                return YES;
            }];
            item.image.template = NO;
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
        [rows addObject:@{@"token":item.representedObject, @"title":item.title,
            @"current":@(item.state == NSControlStateValueOn), @"has_icon":@(item.image.valid),
            @"icon_width":@(item.image.size.width), @"status":item.toolTip ?: @""}];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"count":@(menuBar.count), @"foreground":@(NSApp.isActive), @"rows":rows} options:0 error:nil];
    if (!json || json.length > capacity) return 0;
    memcpy(buffer, json.bytes, json.length);
    return json.length;
}
#endif
