// Opt-in native panels own their responder chain. Falling back to a Metal
// window would redirect their keystrokes into the underlying application.
@protocol ZenitNativeEventWindow <NSObject>
- (BOOL)zenitHandlesNativeEvents;
@end
static __weak NSWindow *g_zenit_native_event_window = nil;
int macos_claim_native_event_window(void *raw) {
    NSWindow *window = (__bridge NSWindow *)raw;
    if (!window || ![window respondsToSelector:@selector(zenitHandlesNativeEvents)] ||
        ![(id<ZenitNativeEventWindow>)window zenitHandlesNativeEvents]) return 0;
    NSWindow *previous = g_zenit_native_event_window;
    if (previous && previous != window && previous.isVisible) return 0;
    g_zenit_native_event_window = window;
    return 1;
}
void macos_release_native_event_window(void *raw) {
    if (g_zenit_native_event_window == (__bridge NSWindow *)raw) g_zenit_native_event_window = nil;
}
static BOOL zenitDispatchNativePanelEvent(NSEvent *event) {
    const BOOL keyboard = event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged;
    NSWindow *owned = g_zenit_native_event_window;
    if (!owned || !owned.isVisible) return NO;
    NSWindow *window = keyboard ? owned : (event.window ?: NSApp.keyWindow);
    if (window != owned) return NO;
    if (![window respondsToSelector:@selector(zenitHandlesNativeEvents)] ||
        ![(id<ZenitNativeEventWindow>)window zenitHandlesNativeEvents]) return NO;
    [window sendEvent:event];
    [NSApp updateWindows];
    return YES;
}
