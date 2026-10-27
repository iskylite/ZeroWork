#import <Cocoa/Cocoa.h>
#include <string.h>

// Startup failures precede the Zenit window. Never include configuration values.
int zw_data_startup_alert(const char *code, int reset_pending, const unsigned char *icon_bytes, size_t icon_length) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        // Startup errors occur before Zenit creates its first window. Finish
        // AppKit launch so the modal is reachable by Dock and accessibility.
        [NSApp finishLaunching];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        // Startup can fail before the configured Dock icon is applied. Use the
        // embedded current asset rather than LaunchServices' cached bundle icon.
        NSImage *icon = [[NSImage alloc] initWithData:[NSData dataWithBytes:icon_bytes length:icon_length]];
        if (icon && icon.valid) {
            NSApp.applicationIconImage = icon;
            alert.icon = icon;
        }
        BOOL already_running = code && strcmp(code, "AlreadyRunning") == 0;
        BOOL credential_access = !reset_pending && code &&
            (strcmp(code, "CredentialDenied") == 0 || strcmp(code, "CredentialLocked") == 0);
        BOOL authorization_failed = code && strcmp(code, "CredentialAuthorizationFailed") == 0;
        alert.messageText = credential_access ? @"需要授权访问已保存的凭据" : already_running ? @"此应用数据已在使用中" : reset_pending ? @"应用数据清除尚未完成" : @"无法安全打开应用数据";
        NSString *reason = code ? [NSString stringWithUTF8String:code] : @"UnknownError";
        alert.informativeText = credential_access
            ? @"此版本尚未获准访问已保存的钥匙串凭据，或钥匙串处于锁定状态。点击“授权钥匙串并重试”，在 macOS 系统窗口中完成授权或解锁。原有配置和凭据会保留；取消授权将停止启动。"
            : authorization_failed
            ? @"钥匙串授权或凭据加载未完成，应用已停止启动。原有配置和凭据会保留。可重新打开应用并重试；如果仍被拒绝，请在“钥匙串访问”中检查本应用凭据的访问权限。"
            : already_running
            ? @"另一个 ZeroWork 进程正在使用同一应用数据或默认钥匙串凭据。请先退出该进程，再打开此应用。独立数据目录仍可同时运行。"
            : reset_pending
            ? @"上次清除未完成。可继续清除本应用的数据及钥匙串凭据，完成后退出。共享 SSH 文件、外部私钥、下载与导出文件会保留。"
            : [NSString stringWithFormat:@"应用已停止加载配置，原有数据会保留。请处理目录冲突、权限或钥匙串访问问题后重试。\n错误：%@", reason];
        [alert addButtonWithTitle:credential_access ? @"授权钥匙串并重试" : reset_pending ? @"继续清除并退出" : @"退出"];
        if (reset_pending || credential_access) [alert addButtonWithTitle:credential_access ? @"退出" : @"取消"];
        [NSApp activateIgnoringOtherApps:YES];
        NSModalResponse response = [alert runModal];
        return (reset_pending || credential_access) && response == NSAlertFirstButtonReturn ? 1 : 0;
    }
}
