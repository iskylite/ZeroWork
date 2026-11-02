#import <AppKit/AppKit.h>

extern void zw_update_open(void);
@interface ZWUpdateMenuAction : NSObject
- (void)check:(id)sender;
@end
@implementation ZWUpdateMenuAction
- (void)check:(id)sender { zw_update_open(); }
@end
static ZWUpdateMenuAction *updateMenuAction;

// Keep the framework's native actions and shortcuts; only brand the app menu.
void zw_app_menu_apply_branding(void) {
    if (![NSThread isMainThread] || !NSApp) return;
    NSMenu *appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
    if (!appMenu) return;
    appMenu.title = @"ZeroWork";
    if (![appMenu itemWithTag:59301]) {
        updateMenuAction = [ZWUpdateMenuAction new];
        NSMenuItem *update = [[NSMenuItem alloc] initWithTitle:@"检查更新…" action:@selector(check:) keyEquivalent:@""];
        update.target = updateMenuAction; update.tag = 59301; [appMenu insertItem:update atIndex:MIN(1, appMenu.numberOfItems)];
    }
    for (NSMenuItem *item in appMenu.itemArray) {
        if (item.action == @selector(orderFrontStandardAboutPanel:)) {
            item.title = @"About ZeroWork";
        } else if (item.action == @selector(hide:)) {
            item.title = @"Hide ZeroWork";
        } else if (item.action == @selector(terminate:)) {
            item.title = @"Quit ZeroWork";
        }
    }
}
