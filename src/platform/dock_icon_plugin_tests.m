#import "dock_icon_preferences.h"
#include <stdbool.h>
#include <string.h>

extern bool zw_app_icon_apply(const unsigned char *, size_t, const char *);

// Exercise the real signed plug-in with a tile that records its rendering.
@interface ZWTestDockTile : NSObject
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic) NSUInteger draws;
- (NSSize)size;
- (void)display;
@end
@implementation ZWTestDockTile
- (NSSize)size { return NSMakeSize(64, 64); }
- (void)display { self.draws++; }
@end

static BOOL samePixels(NSImage *actual, NSImage *expected) {
    NSBitmapImageRep *a = [NSBitmapImageRep imageRepWithData:actual.TIFFRepresentation];
    NSBitmapImageRep *b = [NSBitmapImageRep imageRepWithData:expected.TIFFRepresentation];
    if (!a || !b || a.pixelsWide != b.pixelsWide || a.pixelsHigh != b.pixelsHigh ||
        a.bitsPerSample != b.bitsPerSample || a.samplesPerPixel != b.samplesPerPixel ||
        a.bytesPerRow != b.bytesPerRow || a.planar || b.planar) return NO;
    return memcmp(a.bitmapData, b.bitmapData, a.bytesPerRow * a.pixelsHigh) == 0;
}

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp finishLaunching];
        NSString *domain = NSBundle.mainBundle.bundleIdentifier;
        require([domain hasPrefix:@"com.zerowork.docktest."], @"Tests require an isolated bundle identifier");
        CFPreferencesSetAppValue((__bridge CFStringRef)ZWDockIconPreference, NULL, (__bridge CFStringRef)domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        NSString *path = [NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"ZeroWorkDockIcon.docktileplugin"];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        require([bundle load], @"Signed Dock plug-in failed to load");
        id<NSDockTilePlugIn> plugin = [[bundle principalClass] new];
        ZWTestDockTile *tile = [ZWTestDockTile new];
        [plugin setDockTile:(NSDockTile *)tile];
        require(tile.draws == 1, @"Initial tile was not drawn");
        NSImage *(^expected)(NSString *) = ^NSImage *(NSString *style) {
            return [[NSImage alloc] initWithContentsOfFile:[bundle pathForResource:ZWDockIconResource(style) ofType:@"png"]];
        };
        require(samePixels(((NSImageView *)tile.contentView).image, expected(@"transparent")), @"Default tile is not transparent");
        for (NSString *style in @[@"light", @"dark", @"transparent"]) {
            NSData *png = [NSData dataWithContentsOfFile:[bundle pathForResource:ZWDockIconResource(style) ofType:@"png"]];
            NSUInteger previous = tile.draws;
            require(zw_app_icon_apply(png.bytes, png.length, style.UTF8String), @"Runtime icon publication failed");
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
            while (tile.draws == previous && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            require(tile.draws > previous, @"Dock plug-in did not receive style notification");
            require([ZWDockIconReadStyle(domain) isEqual:style], @"Shared style did not persist");
            // AppKit color-manages the runtime icon. Compare plug-in pixels to
            // the original asset, and verify runtime assignment independently.
            require(NSApp.applicationIconImage.valid && NSEqualSizes(NSApp.applicationIconImage.size, NSMakeSize(512, 512)), @"Running Dock icon was not assigned");
            require(samePixels(((NSImageView *)tile.contentView).image, expected(style)), @"Stopped Dock icon pixels do not match selection");
            printf("PASS: %s runtime, persisted preference and plug-in pixels\n", style.UTF8String);
        }
        // A newly loaded tile must restore the saved style without the app publishing again.
        CFPreferencesSetAppValue((__bridge CFStringRef)ZWDockIconPreference, CFSTR("dark"), (__bridge CFStringRef)domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        [plugin setDockTile:nil];
        ZWTestDockTile *restored = [ZWTestDockTile new];
        [plugin setDockTile:(NSDockTile *)restored];
        require(samePixels(((NSImageView *)restored.contentView).image, expected(@"dark")), @"New tile did not restore saved selection");
        [plugin setDockTile:nil];
        NSUInteger previous = restored.draws;
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:ZWDockIconNotification object:domain userInfo:nil deliverImmediately:YES];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        require(restored.draws == previous, @"Removed tile still receives updates");
        CFPreferencesSetAppValue((__bridge CFStringRef)ZWDockIconPreference, NULL, (__bridge CFStringRef)domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        puts("PASS: restoration and tile removal");
    }
    return 0;
}
