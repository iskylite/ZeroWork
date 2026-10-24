#import <Cocoa/Cocoa.h>
#include <string.h>

// Startup failures precede the Zenit window. Never include configuration values.
int zw_data_startup_alert(const char *code, int reset_pending) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        // Startup errors occur before Zenit creates its first window. Finish
        // AppKit launch so the modal is reachable by Dock and accessibility.
        [NSApp finishLaunching];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        BOOL already_running = code && strcmp(code, "AlreadyRunning") == 0;
        alert.messageText = already_running ? @"此应用数据已在使用中" : reset_pending ? @"应用数据清除尚未完成" : @"无法安全打开应用数据";
        NSString *reason = code ? [NSString stringWithUTF8String:code] : @"UnknownError";
        alert.informativeText = already_running
            ? @"另一个 ZeroWork 进程正在使用同一应用数据或默认钥匙串凭据。请先退出该进程，再打开此应用。独立数据目录仍可同时运行。"
            : reset_pending
            ? @"上次清除未完成。可继续清除本应用的数据及钥匙串凭据，完成后退出。共享 SSH 文件、外部私钥、下载与导出文件会保留。"
            : [NSString stringWithFormat:@"应用已停止加载配置，原有数据会保留。请处理目录冲突、权限或钥匙串访问问题后重试。\n错误：%@", reason];
        [alert addButtonWithTitle:reset_pending ? @"继续清除并退出" : @"退出"];
        if (reset_pending) [alert addButtonWithTitle:@"取消"];
        [NSApp activateIgnoringOtherApps:YES];
        NSModalResponse response = [alert runModal];
        return reset_pending && response == NSAlertFirstButtonReturn ? 1 : 0;
    }
}
