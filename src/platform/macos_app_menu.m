#import <AppKit/AppKit.h>

// Keep the framework's native actions and shortcuts; only brand the app menu.
void zw_app_menu_apply_branding(void) {
    if (![NSThread isMainThread] || !NSApp) return;
    NSMenu *appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
    if (!appMenu) return;
    appMenu.title = @"ZeroWork";
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
