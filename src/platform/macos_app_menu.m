#import <AppKit/AppKit.h>

extern void zw_update_open(void);
extern const char *zw_update_current_version(void);
static NSString *versionMetadata;
@interface ZWUpdateMenuAction : NSObject
- (void)check:(id)sender;
- (void)about:(id)sender;
@end
@implementation ZWUpdateMenuAction
- (void)check:(id)sender { zw_update_open(); }
- (void)about:(id)sender {
    NSString *version = [NSString stringWithFormat:@"%s · %@", zw_update_current_version(), versionMetadata];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: @"ZeroWork",
        NSAboutPanelOptionApplicationVersion: version,
        NSAboutPanelOptionVersion: @"",
        NSAboutPanelOptionCredits: [[NSAttributedString alloc] initWithString:@""]
    }];
}
@end
static ZWUpdateMenuAction *updateMenuAction;

// Keep the framework's native actions and shortcuts; only brand the app menu.
void zw_app_menu_apply_branding(const char *metadata) {
    if (![NSThread isMainThread] || !NSApp) return;
    NSMenu *appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
    if (!appMenu) return;
    versionMetadata = [NSString stringWithUTF8String:metadata];
    if (!updateMenuAction) updateMenuAction = [ZWUpdateMenuAction new];
    appMenu.title = @"ZeroWork";
    if (![appMenu itemWithTag:59301]) {
        NSMenuItem *update = [[NSMenuItem alloc] initWithTitle:@"检查更新…" action:@selector(check:) keyEquivalent:@""];
        update.target = updateMenuAction; update.tag = 59301; [appMenu insertItem:update atIndex:MIN(1, appMenu.numberOfItems)];
    }
    for (NSMenuItem *item in appMenu.itemArray) {
        if (item.action == @selector(orderFrontStandardAboutPanel:) || item.action == @selector(about:)) {
            item.title = @"关于 ZeroWork";
            item.target = updateMenuAction;
            item.action = @selector(about:);
        } else if (item.action == @selector(hide:)) {
            item.title = @"Hide ZeroWork";
        } else if (item.action == @selector(terminate:)) {
            item.title = @"Quit ZeroWork";
        }
    }
}
