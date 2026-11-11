// In-process native input/AX regression. No global key events, clipboard
// changes, application data, or user input-source changes.
#import "../vendor/zenit/native/macos/window_bridge.m"
#import "../src/platform/macos_web_surface.m"
#import "../src/platform/macos_file_sheet.m"
#include "../vendor/zenit/native/macos/tests/no_render_copy.inc"
#define zenit_a11y_root_count empty_root_count
#define zenit_a11y_root_at empty_root_at
#define zenit_a11y_exists empty_exists
#define zenit_a11y_hit_test empty_hit_test
#include "../vendor/zenit/native/macos/tests/empty_a11y.inc"
#undef zenit_a11y_root_count
#undef zenit_a11y_root_at
#undef zenit_a11y_exists
#undef zenit_a11y_hit_test
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL: %s (%s:%d)\n", #condition, __FILE__, __LINE__); exit(1); } } while (0)
static BOOL virtualTree = YES;
int zenit_a11y_root_count(uint32_t window) { return virtualTree ? 1 : 0; }
uint64_t zenit_a11y_root_at(uint32_t window, int index) { return 1; }
int zenit_a11y_exists(uint32_t window, uint64_t handle) { return virtualTree && handle == 1; }
uint64_t zenit_a11y_hit_test(uint32_t window, float x, float y) { return virtualTree ? 1 : UINT32_MAX; }
uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w, uint64_t s, char *b, int n) { return 0; }
int zenit_text_input_selection(uint32_t w, uint32_t *s, uint32_t *e, uint32_t *c) { return 0; }
int zenit_text_input_frame(uint32_t w, uint32_t s, uint32_t e, float *x, float *y, float *a, float *b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w, float x, float y, uint32_t *s, uint32_t *e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w, uint64_t n) { return n; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w, uint64_t n) { return n; }

@interface EmbeddedProbe : NSView
@property NSUInteger nativeKeys;
@property NSUInteger nativeFlags;
@property NSUInteger nativeEdits;
@property BOOL askParent;
@end
@implementation EmbeddedProbe
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Native page"; }
- (id)accessibilityFocusedUIElement {
    return self.askParent ? [self.superview.superview accessibilityFocusedUIElement] : self;
}
- (id)accessibilityHitTest:(NSPoint)point {
    return self.askParent ? [self.superview.superview accessibilityHitTest:point] : self;
}
- (void)keyDown:(NSEvent *)event { self.nativeKeys++; }
- (void)keyUp:(NSEvent *)event { self.nativeKeys++; }
- (BOOL)performKeyEquivalent:(NSEvent *)event { self.nativeKeys++; return YES; }
- (void)flagsChanged:(NSEvent *)event { self.nativeFlags++; }
- (void)undo:(id)sender { self.nativeEdits++; }
- (void)redo:(id)sender { self.nativeEdits++; }
- (void)cut:(id)sender { self.nativeEdits++; }
- (void)copy:(id)sender { self.nativeEdits++; }
- (void)paste:(id)sender { self.nativeEdits++; }
- (void)selectAll:(id)sender { self.nativeEdits++; }
@end

typedef struct { uint16_t key; NSUInteger calls; } HostKeys;
static int hostKey(void *context, uint16_t key, uint32_t modifiers) {
    HostKeys *host = context;
    CHECK(host);
    host->calls++;
    return key == host->key && modifiers == NSEventModifierFlagCommand;
}
static void dispatch(WindowWrapper *window, NSEventType type, uint16_t code, NSString *text, NSEventModifierFlags modifiers) {
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint
        modifierFlags:modifiers timestamp:0 windowNumber:window.window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
    [NSApp postEvent:event atStart:YES];
    pumpAppEventsWithTimeout(0);
}

int main(void) {
    @autoreleasepool {
        macos_init_app_with_delegate();
        void *ptr = macos_create_window(400, 260, "embedded host regression");
        CHECK(ptr);
        WindowWrapper *window = (__bridge WindowWrapper *)ptr;
        ZWWebClipView *clip = [[ZWWebClipView alloc] initWithFrame:NSMakeRect(40, 40, 240, 160)];
        clip.wantsLayer = YES;
        EmbeddedProbe *page = [[EmbeddedProbe alloc] initWithFrame:clip.bounds];
        [clip addSubview:page];
        [window.metalView addSubview:clip];
        HostKeys first = { .key = 17 }, second = { .key = 14 };
        CHECK(macos_set_embedded_input_view((__bridge void *)clip, 1, hostKey, NULL, &first));
        for (int i = 0; i < 16; i++) pumpAppEventsWithTimeout(0);
        NSMenu *defaultMenu = NSApp.mainMenu;
        NSApp.mainMenu = [[NSMenu alloc] initWithTitle:@"Test"];
        [NSApp.mainMenu addItemWithTitle:@"Host test" action:nil keyEquivalent:@""];
        CHECK([window.window makeFirstResponder:page]);
        [window.keyEventQueue removeAllObjects];
        page.nativeKeys = page.nativeFlags = 0;

        dispatch(window, NSEventTypeKeyDown, 17, @"t", NSEventModifierFlagCommand);
        CHECK(first.calls == 1 && window.keyEventQueue.count == 1 && page.nativeKeys == 0);
        [window.keyEventQueue removeAllObjects];
        dispatch(window, NSEventTypeKeyDown, 0, @"a", 0);
        CHECK(first.calls == 2 && window.keyEventQueue.count == 0 && page.nativeKeys == 1);
        dispatch(window, NSEventTypeKeyDown, 8, @"c", NSEventModifierFlagCommand);
        CHECK(first.calls == 3 && window.keyEventQueue.count == 0 && page.nativeKeys == 2);
        dispatch(window, NSEventTypeFlagsChanged, 59, @"", 0);
        CHECK(page.nativeFlags == 1 && window.keyEventQueue.count == 1);
        KeyEventPacket flags;
        [window.keyEventQueue.firstObject getValue:&flags];
        CHECK(flags.keycode == 59 && !flags.pressed && flags.modifiers == 0);
        [window.keyEventQueue removeAllObjects];
        CHECK(macos_set_embedded_input_view((__bridge void *)clip, 1, hostKey, NULL, &second));
        dispatch(window, NSEventTypeKeyDown, 14, @"e", NSEventModifierFlagCommand);
        CHECK(second.calls == 1 && first.calls == 3 && window.keyEventQueue.count == 1);
        [window.keyEventQueue removeAllObjects];
        NSApp.mainMenu = defaultMenu;
        [defaultMenu update];
        dispatch(window, NSEventTypeKeyDown, 8, @"c", NSEventModifierFlagCommand);
        dispatch(window, NSEventTypeKeyDown, 9, @"v", NSEventModifierFlagCommand);
        dispatch(window, NSEventTypeKeyDown, 0, @"a", NSEventModifierFlagCommand);
        dispatch(window, NSEventTypeKeyDown, 7, @"x", NSEventModifierFlagCommand);
        dispatch(window, NSEventTypeKeyDown, 6, @"z", NSEventModifierFlagCommand);
        dispatch(window, NSEventTypeKeyDown, 6, @"z", NSEventModifierFlagCommand | NSEventModifierFlagShift);
        if (page.nativeEdits != 6 || window.keyEventQueue.count || second.calls != 1)
            fprintf(stderr, "Edit menu: native=%lu queued=%lu classified=%lu page keys=%lu\n", page.nativeEdits, window.keyEventQueue.count, second.calls, page.nativeKeys);
        CHECK(page.nativeEdits == 6 && window.keyEventQueue.count == 0 && second.calls == 1);

        NSArray *children = window.metalView.accessibilityChildren;
        CHECK(children.count == 2 && [children containsObject:page]);
        CHECK(window.metalView.accessibilityChildrenInNavigationOrder.count == 2);
        CHECK(window.metalView.accessibilityVisibleChildren.count == 2);
        CHECK(window.metalView.accessibilityFocusedUIElement == page);
        NSPoint point = [window.window convertPointToScreen:[page convertPoint:NSMakePoint(20, 20) toView:nil]];
        CHECK([window.metalView accessibilityHitTest:point] == page);
        NSArray<NSValue *> *covers = @[[NSValue valueWithRect:NSMakeRect(10, 10, 40, 60)],
                                      [NSValue valueWithRect:NSMakeRect(15, 15, 100, 40)]];
        CHECK([clip applyOcclusions:covers]);
        CAShapeLayer *mask = (CAShapeLayer *)clip.layer.mask;
        CHECK(!CGPathContainsPoint(mask.path, NULL, CGPointMake(20, 20), false));
        CHECK(CGPathContainsPoint(mask.path, NULL, CGPointMake(200, 20), false));
        CHECK([window.metalView accessibilityHitTest:point] != page);
        CHECK([clip hitTest:[clip convertPoint:NSMakePoint(200, 20) toView:clip.superview]] == page);
        CHECK(![clip applyOcclusions:@[[NSValue valueWithRect:clip.bounds]]]);
        CHECK([clip hitTest:[clip convertPoint:NSMakePoint(200, 20) toView:clip.superview]] == nil);
        CHECK([clip applyOcclusions:@[]] && clip.layer.mask == nil);
        CHECK([window.metalView accessibilityHitTest:point] == page);
        NSView *overlay = [[NSView alloc] initWithFrame:clip.frame];
        [window.metalView addSubview:overlay positioned:NSWindowAbove relativeTo:clip];
        CHECK([window.metalView accessibilityHitTest:point] != page);
        [overlay removeFromSuperview];
        page.askParent = YES;
        CHECK(window.metalView.accessibilityFocusedUIElement != page);
        CHECK([window.metalView accessibilityHitTest:point] != page);
        page.askParent = NO;
        clip.hidden = YES;
        CHECK(window.metalView.accessibilityChildren.count == 1);
        CHECK(window.metalView.accessibilityFocusedUIElement != page);
        CHECK([window.metalView accessibilityHitTest:point] != page);
        clip.hidden = NO;
        virtualTree = NO;
        CHECK([window.metalView.accessibilityChildren isEqualToArray:@[page]]);
        CHECK([window.window makeFirstResponder:page]);
        CHECK(macos_set_embedded_input_view((__bridge void *)clip, 0, NULL, NULL, NULL));
        CHECK(window.window.firstResponder == window.metalView);
        CHECK(window.metalView.accessibilityChildren.count == 0);
        [clip removeFromSuperview];
        CHECK(window.metalView.accessibilityChildren.count == 0);
        void *other = macos_create_window(400, 260, "file sheet owner regression");
        CHECK(other);
        WindowWrapper *sibling = (__bridge WindowWrapper *)other;
        void *sheet = zw_file_sheet_begin((uint32_t)window.window.windowNumber, 0, "Select fixture", NULL, NULL, NULL);
        CHECK(sheet && zw_file_sheet_count(sheet) == -1);
        CHECK(window.window.attachedSheet && !sibling.window.attachedSheet);
        CHECK(!zw_file_sheet_begin((uint32_t)window.window.windowNumber, 0, NULL, NULL, NULL, NULL));
        void *siblingSheet = zw_file_sheet_begin((uint32_t)sibling.window.windowNumber, 1, "Select directory", NULL, NULL, NULL);
        CHECK(siblingSheet && sibling.window.attachedSheet && window.window.attachedSheet != sibling.window.attachedSheet);
        zw_file_sheet_destroy(sheet);
        CHECK(sibling.window.attachedSheet);
        zw_file_sheet_destroy(siblingSheet);
        macos_destroy_window(other);
        macos_destroy_window(ptr);
        fprintf(stderr, "PASS: host/native key and AX routing, overlapping clipping and hit testing, unbind cleanup, file sheets scoped to each window\n");
    }
    return 0;
}
