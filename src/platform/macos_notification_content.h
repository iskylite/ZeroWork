#ifndef ZEROWORK_MACOS_NOTIFICATION_CONTENT_H
#define ZEROWORK_MACOS_NOTIFICATION_CONTENT_H

#import <UserNotifications/UserNotifications.h>

#define ZWStartupFailureNotification @"zerowork.startup.failure"

/* All system notifications use the app name and a silent business summary. */
static inline UNMutableNotificationContent *zw_notification_content(NSString *summary) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"ZeroWork";
    content.body = summary;
    content.sound = nil;
    return content;
}

@interface ZWStartupNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

#endif
