// Explicit synthetic secrets only. No test or report prints the value.
#import "macos_host_secret.m"
#include "../../vendor/zenit/native/macos/native_event_window.inc"
#include <assert.h>
static NSEvent *key(NSString *text, unsigned short code, NSEventModifierFlags modifiers) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:0 windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}
static void type_fixture(ZWSecretCollector *c) { [c.field keyDown:key(@"fixture-only-secret",0,0)]; }
static void pump(void) { NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.25]; while ([end timeIntervalSinceNow] > 0) { NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:end inMode:NSDefaultRunLoopMode dequeue:YES]; if(event) [NSApp sendEvent:event]; } }
int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp finishLaunching]; [NSApp activateIgnoringOtherApps:YES];
        ZWSecretTheme theme = {0x202124ff,0xeef1f6ff,0xb4bac4ff,0x303134ff,0x365f9bff};
        void *raw = zw_host_secret_open("终端 1/1 · 受控 zerowork_secret_consume\n授权 1 · 等待 1",&theme); assert(raw);
        ZWSecretCollector *c = (__bridge ZWSecretCollector *)raw; pump();
        assert(IsSecureEventInputEnabled()); assert(c.panel.isVisible); assert(c.panel.firstResponder == c.field);
        NSInteger changes = NSPasteboard.generalPasteboard.changeCount;
        // A queued key packet may carry the Metal window number. Its native
        // secure key window must own delivery, rather than the Metal fallback.
        NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,10,10) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        NSEvent *typed = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:other.windowNumber context:nil characters:@"fixture-only-secret" charactersIgnoringModifiers:@"fixture-only-secret" isARepeat:NO keyCode:0];
        assert(zenitDispatchNativePanelEvent(typed)); assert(c.field->_length == 19);
        [c.field keyDown:key(@"c",8,NSEventModifierFlagCommand)]; [c.field keyDown:key(@"x",7,NSEventModifierFlagCommand)]; [c.field keyDown:key(@"v",9,NSEventModifierFlagCommand)]; [c.field keyDown:key(@"z",6,NSEventModifierFlagCommand)];
        assert(NSPasteboard.generalPasteboard.changeCount == changes); assert(c.field->_length == 19);
        assert([c.field.accessibilityValue isEqual:@"••••••••"]); assert(![c.field isAccessibilitySelectorAllowed:@selector(setAccessibilityValue:)]); assert(c.field.inputContext == nil);
        [c.panel displayIfNeeded]; pump();
        c.field.needsDisplay = YES; [c.field display];
        assert(c.field->_length == 19);
        if (argc > 1) { NSBitmapImageRep *rep = [c.panel.contentView bitmapImageRepForCachingDisplayInRect:c.panel.contentView.bounds]; [c.panel.contentView cacheDisplayInRect:c.panel.contentView.bounds toBitmapImageRep:rep]; [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]; }
        unsigned char out[1024] = {0}; size_t length = 0;
        assert(zw_host_secret_poll(raw,out,sizeof out,&length) == 0 && length == 0);
        [c submit:nil]; assert(!IsSecureEventInputEnabled()); assert(!c.panel.isVisible);
        assert(!zenitDispatchNativePanelEvent(typed));
        assert(zw_host_secret_poll(raw,out,sizeof out,&length) == 1 && length == 19);
        assert(memcmp(out,"fixture-only-secret",19) == 0); zw_secret_zero(out,sizeof out);
        assert(c.field->_length == 0); for (size_t i=0;i<4096;i++) assert(c.field->_secret[i] == 0);
        assert(zw_host_secret_poll(raw,out,sizeof out,&length) == 2 && length == 0);
        zw_host_secret_close(raw); c = nil;
        raw = zw_host_secret_open("synthetic cancellation",&theme); assert(raw); c = (__bridge ZWSecretCollector *)raw; pump(); type_fixture(c); [c cancel:nil]; assert(c.field->_length == 0); assert(!IsSecureEventInputEnabled()); zw_host_secret_close(raw); c = nil;
        raw = zw_host_secret_open("synthetic timeout",&theme); assert(raw); c = (__bridge ZWSecretCollector *)raw; pump(); type_fixture(c); [c submit:nil]; [c expire]; assert(c.field->_length == 0); assert(zw_host_secret_poll(raw,out,sizeof out,&length) == 2); zw_host_secret_close(raw); c = nil;
        raw = zw_host_secret_open("synthetic revocation",&theme); assert(raw); c = (__bridge ZWSecretCollector *)raw; pump(); type_fixture(c); [c windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:c.panel]]; assert(c.field->_length == 0); assert(!IsSecureEventInputEnabled()); zw_host_secret_close(raw); c = nil;
        puts("native collector: secure focus, fixed mask AX, no clipboard/undo/IME, single use, submit/cancel/expiry/revocation zero: PASS");
    }
    return 0;
}
