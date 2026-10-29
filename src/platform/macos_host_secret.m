// Dedicated native collector. Secret characters never enter Zenit, NSText,
// undo, pasteboard, accessibility text APIs or app diagnostics. AppKit events
// still belong to the OS; this is not a defence against a compromised host.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
extern int macos_claim_native_event_window(void *);
extern void macos_release_native_event_window(void *);
#include <sys/mman.h>
#include <string.h>
#include <stdint.h>

#define ZW_SECRET_MAX 1024
static void zw_secret_zero(void *p, size_t n) { volatile unsigned char *v = p; while (n--) *v++ = 0; }
typedef struct { uint32_t background, foreground, secondary, well, accent; } ZWSecretTheme;
static NSColor *zw_secret_color(uint32_t c, BOOL foreground) {
    return [NSColor colorWithSRGBRed:((c >> 24) & 255)/255.0 green:((c >> 16) & 255)/255.0 blue:((c >> 8) & 255)/255.0 alpha:foreground ? 1.0 : (c & 255)/255.0];
}
@interface ZWSecretField : NSView {
@public unsigned char *_secret;
@public size_t _length;
}
@property(nonatomic, copy) void (^finish)(BOOL);
@property(nonatomic, strong) NSColor *ink;
@property(nonatomic, strong) NSColor *well;
- (void)erase;
@end
@implementation ZWSecretField
- (instancetype)initWithFrame:(NSRect)rect {
    self = [super initWithFrame:rect];
    if (self) {
        _secret = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
        if (_secret == MAP_FAILED) { _secret = NULL; return nil; }
        if (mlock(_secret, 4096) != 0) { munmap(_secret, 4096); _secret = NULL; return nil; }
        self.accessibilityLabel = @"本次宿主安全输入";
    }
    return self;
}
- (void)erase { if (_secret) zw_secret_zero(_secret, 4096); _length = 0; self.needsDisplay = YES; }
- (void)dealloc { [self erase]; if (_secret) { munlock(_secret, 4096); munmap(_secret, 4096); } }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSTextInputContext *)inputContext { return nil; } // No composition/IME storage.
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityTextFieldRole; }
- (NSString *)accessibilitySubrole { return NSAccessibilitySecureTextFieldSubrole; }
- (id)accessibilityValue { return _length ? @"••••••••" : @""; }
- (BOOL)isAccessibilityFocused { return self.window.firstResponder == self; }
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(setAccessibilityValue:) || selector == @selector(accessibilitySelectedText) || selector == @selector(accessibilityStringForRange:)) return NO;
    return [super isAccessibilitySelectorAllowed:selector];
}
- (void)mouseDown:(NSEvent *)event { (void)event; [self.window makeFirstResponder:self]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event { (void)event; return NO; }
- (void)keyDown:(NSEvent *)event {
    if (event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)) return;
    if (event.keyCode == 53) { if (self.finish) self.finish(NO); return; }
    if (event.keyCode == 36 || event.keyCode == 76) { if (_length && self.finish) self.finish(YES); return; }
    if (event.keyCode == 48) {
        if (event.modifierFlags & NSEventModifierFlagShift) [self.window selectPreviousKeyView:nil]; else [self.window selectNextKeyView:nil];
        return;
    }
    if (event.keyCode == 51) {
        if (_length) { do { _length--; } while (_length && (_secret[_length] & 0xC0) == 0x80); zw_secret_zero(_secret + _length, ZW_SECRET_MAX - _length); }
        self.needsDisplay = YES; return;
    }
    // Read OS-owned event characters into a bounded ephemeral byte array. No
    // app-owned NSString/Data is ever made from the secret or kept for drawing.
    unsigned char bytes[ZW_SECRET_MAX + 1] = {0};
    NSUInteger used = 0;
    NSString *characters = event.characters;
    BOOL ok = [characters getBytes:bytes maxLength:ZW_SECRET_MAX usedLength:&used encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, characters.length) remainingRange:NULL];
    if (ok && used && _length + used <= ZW_SECRET_MAX) {
        BOOL printable = YES;
        for (NSUInteger i=0; i<used; i++) if (bytes[i] < 0x20 || bytes[i] == 0x7f || (bytes[i] == 0xc2 && i+1 < used && bytes[i+1] >= 0x80 && bytes[i+1] <= 0x9f)) printable = NO;
        // Private-use function key values cannot be used as secret text.
        for (NSUInteger i=0; i<characters.length; i++) if ([characters characterAtIndex:i] >= 0xf700 && [characters characterAtIndex:i] <= 0xf8ff) printable = NO;
        if (printable) { memcpy(_secret + _length, bytes, used); _length += used; }
    }
    zw_secret_zero(bytes, sizeof bytes);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [self.well setFill]; [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill];
    NSString *display = _length ? @"••••••••" : @"在此键入秘密";
    [display drawAtPoint:NSMakePoint(12, 11) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13], NSForegroundColorAttributeName:self.ink}];
    if (self.window.firstResponder == self && self.window.isKeyWindow) {
        [self.ink setFill]; NSRectFill(NSMakeRect(_length ? 80 : 12, 10, 1, 18));
    }
}
@end

@interface ZWSecretBody : NSView
@property(nonatomic, strong) NSColor *background;
@end
@implementation ZWSecretBody
- (void)drawRect:(NSRect)dirty { [self.background setFill]; NSRectFill(dirty); }
@end

@interface ZWSecretPanel : NSPanel
@property(nonatomic, copy) void (^cancelled)(void);
@end
@implementation ZWSecretPanel
- (BOOL)zenitHandlesNativeEvents { return YES; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender { (void)sender; if (self.cancelled) self.cancelled(); }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // No menu shortcuts, paste, cut, copy, undo or automatic key recording.
    if (event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)) return YES;
    return [super performKeyEquivalent:event];
}
@end
@interface ZWSecretCollector : NSObject <NSWindowDelegate>
@property(nonatomic, strong) ZWSecretPanel *panel;
@property(nonatomic, strong) ZWSecretField *field;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) NSInteger state; // 0 pending, 1 submitted, 2 cancelled
@property(nonatomic) BOOL secureEvents;
- (void)finish:(BOOL)submit;
- (void)expire;
@end
@implementation ZWSecretCollector
- (void)finish:(BOOL)submit {
    if (self.state) return;
    self.state = submit && self.field->_length ? 1 : 2;
    macos_release_native_event_window((__bridge void *)self.panel);
    if (self.state == 2) [self.field erase];
    if (self.state == 2) { [self.timer invalidate]; self.timer = nil; }
    if (self.secureEvents) { DisableSecureEventInput(); self.secureEvents = NO; }
    [self.panel orderOut:nil];
}
- (void)expire {
    [self finish:NO]; [self.field erase]; self.state = 2;
    [self.timer invalidate]; self.timer = nil;
}
- (void)windowDidResignKey:(NSNotification *)n { (void)n; if (!self.state) [self finish:NO]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self finish:NO]; return NO; }
- (void)cancel:(id)sender { (void)sender; [self finish:NO]; }
- (void)submit:(id)sender { (void)sender; [self finish:YES]; }
- (void)dealloc { [self finish:NO]; [self.field erase]; self.panel.delegate = nil; self.panel.cancelled = nil; self.field.finish = nil; [self.panel close]; }
@end
static NSTextField *zw_secret_label(NSView *parent, NSString *text, NSRect frame, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text]; label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:weight]; label.textColor = color;
    label.maximumNumberOfLines = 2; [parent addSubview:label]; return label;
}
static NSButton *zw_secret_button(ZWSecretCollector *owner, NSString *title, SEL action, NSRect rect, NSColor *bg, NSColor *fg) {
    NSButton *button = [NSButton buttonWithTitle:title target:owner action:action];
    button.frame = rect; button.bordered = NO; button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    button.contentTintColor = fg; button.wantsLayer = YES; button.layer.backgroundColor = bg.CGColor;
    button.layer.cornerRadius = 8; button.focusRingType = NSFocusRingTypeNone; [owner.panel.contentView addSubview:button]; return button;
}
void *zw_host_secret_open(const char *metadata, const ZWSecretTheme *theme) {
    if (![NSThread isMainThread] || !NSApp || !theme || !metadata) return NULL;
    ZWSecretCollector *collector = [ZWSecretCollector new];
    collector.panel = [[ZWSecretPanel alloc] initWithContentRect:NSMakeRect(0,0,420,254) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    collector.panel.title = @"安全输入"; collector.panel.releasedWhenClosed = NO;
    collector.panel.delegate = collector; collector.panel.level = NSModalPanelWindowLevel;
    collector.panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    collector.panel.opaque = NO; collector.panel.backgroundColor = zw_secret_color(theme->background, NO);
    collector.panel.sharingType = NSWindowSharingNone;
    ZWSecretBody *body = [[ZWSecretBody alloc] initWithFrame:NSMakeRect(0,0,420,254)];
    body.background = zw_secret_color(theme->background, NO); collector.panel.contentView = body;
    NSColor *fg = zw_secret_color(theme->foreground, YES), *secondary = zw_secret_color(theme->secondary, YES);
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(20,209,18,18)];
    icon.image = [NSImage imageWithSystemSymbolName:@"lock.shield" accessibilityDescription:@"安全输入"]; icon.contentTintColor = fg; [body addSubview:icon];
    zw_secret_label(body,@"本次宿主安全输入",NSMakeRect(46,207,354,22),15,NSFontWeightSemibold,fg);
    zw_secret_label(body,[NSString stringWithUTF8String:metadata],NSMakeRect(20,163,380,36),11,NSFontWeightRegular,secondary);
    zw_secret_label(body,@"仅消费并清除，不执行认证。AI 不可见，60 秒过期。",NSMakeRect(20,135,380,20),12,NSFontWeightRegular,secondary);
    collector.field = [[ZWSecretField alloc] initWithFrame:NSMakeRect(20,85,380,40)];
    if (!collector.field) return NULL;
    collector.field.ink = fg; collector.field.well = zw_secret_color(theme->well, NO); [body addSubview:collector.field];
    zw_secret_label(body,@"直接键入；不支持粘贴、复制或输入法组合。",NSMakeRect(20,59,380,18),11,NSFontWeightRegular,secondary);
    zw_secret_button(collector,@"取消",@selector(cancel:),NSMakeRect(224,17,80,28),zw_secret_color(theme->well,NO),fg);
    zw_secret_button(collector,@"安全提交",@selector(submit:),NSMakeRect(312,17,88,28),zw_secret_color(theme->accent,NO),fg);
    __weak ZWSecretCollector *weak = collector;
    collector.field.finish = ^(BOOL submit) { [weak finish:submit]; };
    collector.panel.cancelled = ^{ [weak finish:NO]; };
    collector.timer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer *timer) { (void)timer; [weak expire]; }];
    if (!macos_claim_native_event_window((__bridge void *)collector.panel)) return NULL;
    if (EnableSecureEventInput() != noErr) { macos_release_native_event_window((__bridge void *)collector.panel); return NULL; }
    collector.secureEvents = YES;
    [collector.panel center]; [collector.panel makeKeyAndOrderFront:nil]; [collector.panel makeFirstResponder:collector.field];
    return (__bridge_retained void *)collector;
}
int zw_host_secret_poll(void *raw, unsigned char *out, size_t capacity, size_t *length) {
    if (![NSThread isMainThread] || !raw || !out || !length) return 2;
    ZWSecretCollector *collector = (__bridge ZWSecretCollector *)raw; *length = 0;
    if (collector.state == 1) {
        [collector.timer invalidate]; collector.timer = nil;
        if (capacity < collector.field->_length) { [collector.field erase]; collector.state = 2; return 2; }
        *length = collector.field->_length; memcpy(out,collector.field->_secret,*length); [collector.field erase]; collector.state = 2; return 1;
    }
    return (int)collector.state;
}
void zw_host_secret_close(void *raw) {
    if (![NSThread isMainThread] || !raw) return;
    ZWSecretCollector *collector = (__bridge_transfer ZWSecretCollector *)raw;
    [collector finish:NO]; [collector.field erase];
}
