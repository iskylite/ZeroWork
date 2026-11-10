#import <AppKit/AppKit.h>

// Only this public appearance value is shared with the Dock process. Never
// expose the app configuration or credential scope to the Dock tile plug-in.
static NSString *const ZWDockIconPreference = @"DockIconBackground";
static NSString *const ZWDockIconNotification = @"com.zerowork.dockIconDidChange";

static inline NSString *ZWDockIconResource(NSString *style) {
    if ([style isEqualToString:@"light"]) return @"AppIcon-light";
    if ([style isEqualToString:@"dark"]) return @"AppIcon-dark";
    return @"AppIcon";
}

static inline NSString *ZWDockIconReadStyle(NSString *domain) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)ZWDockIconPreference, (__bridge CFStringRef)domain));
    return [value isEqual:@"light"] || [value isEqual:@"dark"] ? value : @"transparent";
}
