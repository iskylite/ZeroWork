#import <AppKit/AppKit.h>

extern void zw_update_open(void);
extern const char *zw_update_current_version(void);
static NSString *versionMetadata;
static void applyMenuBranding(void);
static char mainMenuObservation;
static BOOL observingMainMenu;
@interface ZWUpdateMenuAction : NSObject
- (void)check:(id)sender;
- (void)about:(id)sender;
@end
@implementation ZWUpdateMenuAction
- (void)check:(id)sender { zw_update_open(); }
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == &mainMenuObservation) {
        applyMenuBranding();
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}
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

// AppKit caches the top-level item separately from its submenu title.
// Keep native actions and shortcuts, but do not expose the framework's CLI.
static void applyMenuBranding(void) {
    if (![NSThread isMainThread] || !NSApp) return;
    NSProcessInfo.processInfo.processName = @"ZeroWork";
    NSMenuItem *appMenuItem = NSApp.mainMenu.itemArray.firstObject;
    NSMenu *appMenu = appMenuItem.submenu;
    if (!appMenu) return;
    appMenuItem.title = @"ZeroWork";
    appMenu.title = @"ZeroWork";
    if (![appMenu itemWithTag:59301]) {
        NSMenuItem *update = [[NSMenuItem alloc] initWithTitle:@"检查更新…" action:@selector(check:) keyEquivalent:@""];
        update.target = updateMenuAction; update.tag = 59301; [appMenu insertItem:update atIndex:MIN(1, appMenu.numberOfItems)];
    }
    for (NSMenuItem *item in appMenu.itemArray.copy) {
        if (item.action == NSSelectorFromString(@"zenitInstallCli:")) {
            [appMenu removeItem:item];
        }
    }
    // Removing the framework-only action can leave adjacent separators.
    for (NSInteger i = appMenu.numberOfItems - 1; i > 0; --i) {
        if ([appMenu itemAtIndex:i].isSeparatorItem && [appMenu itemAtIndex:i - 1].isSeparatorItem) {
            [appMenu removeItemAtIndex:i];
        }
    }
    for (NSMenuItem *item in appMenu.itemArray) {
        if (item.action == @selector(orderFrontStandardAboutPanel:) || item.action == @selector(about:)) {
            item.title = @"关于 ZeroWork";
            item.target = updateMenuAction;
            item.action = @selector(about:);
        } else if (item.action == @selector(hide:)) {
            item.title = @"隐藏 ZeroWork";
        } else if (item.action == @selector(hideOtherApplications:)) {
            item.title = @"隐藏其他";
        } else if (item.action == @selector(unhideAllApplications:)) {
            item.title = @"显示全部";
        } else if (item.action == @selector(terminate:)) {
            item.title = @"退出 ZeroWork";
        }
    }
}

// The framework replaces mainMenu again when AppKit finishes launching.
// Reapply branding to that menu and any later replacement, without polling.
void zw_app_menu_apply_branding(const char *metadata) {
    if (![NSThread isMainThread] || !NSApp) return;
    versionMetadata = [NSString stringWithUTF8String:metadata];
    if (!updateMenuAction) updateMenuAction = [ZWUpdateMenuAction new];
    if (!observingMainMenu) {
        [NSApp addObserver:updateMenuAction forKeyPath:@"mainMenu" options:0 context:&mainMenuObservation];
        observingMainMenu = YES;
    }
    applyMenuBranding();
}
