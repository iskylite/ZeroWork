#import <Cocoa/Cocoa.h>
#import "macos_notification_content.h"
#include <string.h>

@implementation ZWStartupNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
        willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center;
    BOOL startup_failure = [notification.request.identifier isEqualToString:ZWStartupFailureNotification];
    completionHandler(startup_failure ?
        UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList : UNNotificationPresentationOptionNone);
}
@end

static NSString *zw_startup_notification_reason(NSString *message, NSString *fallback) {
    NSString *reason = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!reason.length) reason = fallback.length ? fallback : @"无法完成启动。";
    // Keep the reason useful in Notification Center without splitting emoji or
    // other composed characters. The supplied text must contain no config values.
    const NSUInteger limit = 240;
    if (reason.length > limit) {
        NSRange prefix = [reason rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)];
        reason = [[reason substringWithRange:prefix] stringByAppendingString:@"…"];
    }
    return [@"启动失败：" stringByAppendingString:reason];
}

static NSString *zw_startup_notification_summary(NSString *message, BOOL config_failed) {
    return config_failed ? [message componentsSeparatedByString:@"\n\n"].firstObject : message;
}

static UNUserNotificationCenter *zw_startup_notification_center(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    // currentNotificationCenter is not available to a bare command-line build.
    if (!bundle.bundleIdentifier.length || ![bundle.bundleURL.pathExtension.lowercaseString isEqualToString:@"app"]) return nil;
    @try {
        return UNUserNotificationCenter.currentNotificationCenter;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

// Only consult an existing authorization: startup must never prompt for it.
// Reusing one identifier also replaces an earlier delivered failure notification.
static dispatch_semaphore_t zw_queue_startup_notification(UNUserNotificationCenter *center, NSString *reason) {
    if (!center) return nil;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    UNMutableNotificationContent *content = zw_notification_content(reason);
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:ZWStartupFailureNotification content:content trigger:nil];
    @try {
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            if (settings.authorizationStatus != UNAuthorizationStatusAuthorized &&
                settings.authorizationStatus != UNAuthorizationStatusProvisional) {
                dispatch_semaphore_signal(completed);
                return;
            }
            @try {
                [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
                    (void)error;
                    dispatch_semaphore_signal(completed);
                }];
            } @catch (NSException *exception) {
                (void)exception;
                dispatch_semaphore_signal(completed);
            }
        }];
    } @catch (NSException *exception) {
        (void)exception;
        dispatch_semaphore_signal(completed);
    }
    return completed;
}

static void zw_wait_for_startup_notification(dispatch_semaphore_t completed) {
    if (!completed) return;
    // The process may exit immediately after the alert. Give the asynchronous
    // settings query and request a bounded chance to reach the system first.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (dispatch_semaphore_wait(completed, DISPATCH_TIME_NOW) != 0 && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

// The startup error window can outlive this call. Keep its delegate alive until
// the normal notification bridge takes over or the process exits.
void zw_data_notify_startup_failure(const unsigned char *message, size_t message_length) {
    @autoreleasepool {
        UNUserNotificationCenter *center = zw_startup_notification_center();
        if (!center) return;
        if (!center.delegate) {
            static ZWStartupNotificationDelegate *delegate;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ delegate = [ZWStartupNotificationDelegate new]; });
            center.delegate = delegate;
        }
        NSString *text = message ? [[NSString alloc] initWithBytes:message length:message_length encoding:NSUTF8StringEncoding] : nil;
        zw_wait_for_startup_notification(zw_queue_startup_notification(center, zw_startup_notification_reason(text, nil)));
    }
}

// Startup failures precede the Zenit window. Never include configuration values.
int zw_data_startup_alert(const char *code, const unsigned char *message, size_t message_length, int reset_pending, const unsigned char *icon_bytes, size_t icon_length) {
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
        BOOL authentication_failed = code &&
            (strcmp(code, "CredentialAuthenticationCanceled") == 0 || strcmp(code, "CredentialAuthenticationFailed") == 0);
        BOOL config_failed = code && strcmp(code, "StartupConfigFailure") == 0;
        BOOL startup_failed = code && strcmp(code, "StartupFailure") == 0;
        alert.messageText = authentication_failed ? @"已保存的凭据尚未解锁" : credential_access ? @"需要授权访问已保存的凭据" : already_running ? @"此应用数据已在使用中" : reset_pending ? @"应用数据清除尚未完成" : config_failed ? @"无法读取配置" : startup_failed ? @"ZeroWork 启动失败" : @"无法安全打开应用数据";
        alert.informativeText = authentication_failed
            ? @"身份验证已取消或未通过，应用已停止启动。原有配置和凭据会保留，重新打开应用可再次使用 Touch ID 或系统提供的验证方式解锁。"
            : credential_access
            ? @"首次使用凭据辅助程序、辅助程序更新或钥匙串锁定时，macOS 可能要求输入钥匙串密码。点击“授权钥匙串并重试”，在系统窗口中完成授权；如提供“始终允许”，选择后可保存对辅助程序的授权。日常主程序更新继续复用该授权。原有配置和凭据会保留；取消授权将停止启动。"
            : authorization_failed
            ? @"钥匙串授权或凭据加载未完成，应用已停止启动。原有配置和凭据会保留。可重新打开应用并重试；如果仍被拒绝，请在“钥匙串访问”中检查本应用凭据的访问权限。"
            : already_running
            ? @"另一个 ZeroWork 进程正在使用同一应用数据或默认钥匙串凭据。请先退出该进程，再打开此应用。独立数据目录仍可同时运行。"
            : reset_pending
            ? @"上次清除未完成。可继续清除本应用的数据及钥匙串凭据，完成后退出。共享 SSH 文件、外部私钥、下载与导出文件会保留。"
            : [[NSString alloc] initWithBytes:message length:message_length encoding:NSUTF8StringEncoding];
        [alert addButtonWithTitle:credential_access ? @"授权钥匙串并重试" : reset_pending ? @"继续清除并退出" : @"退出"];
        if (reset_pending || credential_access) [alert addButtonWithTitle:credential_access ? @"退出" : @"取消"];

        UNUserNotificationCenter *center = zw_startup_notification_center();
        __attribute__((objc_precise_lifetime)) ZWStartupNotificationDelegate *delegate = nil;
        dispatch_semaphore_t notification_completed = nil;
        if (!reset_pending && !credential_access && center) {
            if (!center.delegate) {
                delegate = [ZWStartupNotificationDelegate new];
                center.delegate = delegate;
            }
            NSString *summary = zw_startup_notification_summary(alert.informativeText, config_failed);
            notification_completed = zw_queue_startup_notification(center,
                zw_startup_notification_reason(summary, alert.messageText));
        }
        [NSApp activateIgnoringOtherApps:YES];
        NSModalResponse response = [alert runModal];
        if ((reset_pending || credential_access) && response != NSAlertFirstButtonReturn && center) {
            if (!center.delegate) {
                delegate = [ZWStartupNotificationDelegate new];
                center.delegate = delegate;
            }
            NSString *reason = credential_access ? @"尚未完成钥匙串授权，启动已停止。" : @"应用数据清除尚未完成，启动已停止。";
            notification_completed = zw_queue_startup_notification(center, zw_startup_notification_reason(reason, nil));
        }
        zw_wait_for_startup_notification(notification_completed);
        if (delegate && center.delegate == delegate) center.delegate = nil;
        return (reset_pending || credential_access) && response == NSAlertFirstButtonReturn ? 1 : 0;
    }
}
