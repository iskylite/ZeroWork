#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stddef.h>

// UI-thread-only. Keep the running Dock tile and the file icon in sync: the
// latter is what Dock uses once the process exits. NSWorkspace stores a custom
// file icon without replacing resources inside the signed Contents directory.
bool zw_app_icon_apply(const unsigned char *bytes, size_t length) {
    @autoreleasepool {
        if (![NSThread isMainThread] || !NSApp || !bytes || !length) return false;
        NSData *data = [NSData dataWithBytes:bytes length:length];
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image || !image.valid) return false;
        image.size = NSMakeSize(512, 512);
        NSApp.applicationIconImage = image;
        NSBundle *bundle = NSBundle.mainBundle;
        if ([bundle.bundlePath.pathExtension isEqualToString:@"app"] &&
            [bundle.infoDictionary[@"CFBundlePackageType"] isEqualToString:@"APPL"]) {
            return [NSWorkspace.sharedWorkspace setIcon:image
                                               forFile:bundle.bundlePath
                                               options:0];
        }
        // Command-line and harness launches have no application file to update.
        return true;
    }
}
