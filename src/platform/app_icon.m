#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stddef.h>
#import "dock_icon_preferences.h"

// UI-thread-only. Update the running Dock tile and publish its style to the
// Dock plug-in for use while the app is stopped, without mutating the signed app.
// NSWorkspace.setIcon adds Icon\r / FinderInfo / ResourceFork to the bundle,
// which fails strict codesign verification after startup. The installed file
// icon is supplied by the packaged CFBundleIconFile resource.
bool zw_app_icon_apply(const unsigned char *bytes, size_t length, const char *background) {
    @autoreleasepool {
        if (![NSThread isMainThread] || !NSApp || !bytes || !length) return false;
        NSData *data = [NSData dataWithBytes:bytes length:length];
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image || !image.valid) return false;
        image.size = NSMakeSize(512, 512);
        NSApp.applicationIconImage = image;
        NSString *domain = NSBundle.mainBundle.bundleIdentifier;
        NSString *style = background ? [NSString stringWithUTF8String:background] : nil;
        if (domain.length && ([style isEqualToString:@"transparent"] || [style isEqualToString:@"light"] || [style isEqualToString:@"dark"])) {
            CFPreferencesSetAppValue((__bridge CFStringRef)ZWDockIconPreference, (__bridge CFStringRef)style, (__bridge CFStringRef)domain);
            if (!CFPreferencesAppSynchronize((__bridge CFStringRef)domain)) return false;
            [NSDistributedNotificationCenter.defaultCenter postNotificationName:ZWDockIconNotification object:domain userInfo:nil deliverImmediately:YES];
        }
        return true;
    }
}
