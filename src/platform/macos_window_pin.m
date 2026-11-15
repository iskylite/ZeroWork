#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stdint.h>

bool zw_window_set_pinned(uint32_t window_number, bool pinned) {
    NSWindow *window = [NSApp windowWithWindowNumber:window_number];
    if (!window) return false;
    window.level = pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    return true;
}
