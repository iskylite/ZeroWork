#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stddef.h>

// UI-thread-only. Decode before publishing so failure preserves the current icon.
bool zw_app_icon_apply(const unsigned char *bytes, size_t length) {
    @autoreleasepool {
        if (![NSThread isMainThread] || !NSApp || !bytes || !length) return false;
        NSData *data = [NSData dataWithBytes:bytes length:length];
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image || !image.valid) return false;
        image.size = NSMakeSize(512, 512);
        NSApp.applicationIconImage = image;
        return true;
    }
}
