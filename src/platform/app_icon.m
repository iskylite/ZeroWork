#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stddef.h>

// UI-thread-only. Update the running Dock tile without mutating the signed app.
// NSWorkspace.setIcon adds Icon\r / FinderInfo / ResourceFork to the bundle,
// which fails strict codesign verification after startup. The installed file
// icon is supplied by the packaged CFBundleIconFile resource.
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
