#import "macos_notifications.h"
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct ZWNotificationNode {
    ZW_NOTIFICATION_EVENT value;
    struct ZWNotificationNode *next;
} ZWNotificationNode;

static NSString *const ZWNotificationPrefix = @"zerowork.notification.";

static BOOL valid_target(const ZW_NOTIFICATION_TARGET *target) {
    if (!target || !target->owner_id || !target->operation_id ||
        target->owner_kind < 1 || target->owner_kind > 3 || target->kind < 1 || target->kind > 3 ||
        target->has_attempt_or_turn > 1) return NO;
    if (target->owner_kind == 3 ? target->owner_revision != 0 : target->owner_revision == 0) return NO;
    return target->has_attempt_or_turn ? target->attempt_or_turn_id != 0 : target->attempt_or_turn_id == 0;
}

static ZW_NOTIFICATION_SETTINGS settings_value(UNNotificationSettings *settings) {
    ZW_NOTIFICATION_SETTINGS value = {0};
    switch (settings.authorizationStatus) {
        case UNAuthorizationStatusNotDetermined: value.authorization = ZW_NOTIFY_AUTH_NOT_DETERMINED; break;
        case UNAuthorizationStatusDenied: value.authorization = ZW_NOTIFY_AUTH_DENIED; break;
        case UNAuthorizationStatusAuthorized: value.authorization = ZW_NOTIFY_AUTH_AUTHORIZED; break;
        case UNAuthorizationStatusProvisional: value.authorization = ZW_NOTIFY_AUTH_PROVISIONAL; break;
        default: value.authorization = ZW_NOTIFY_AUTH_UNAVAILABLE; break;
    }
    value.alert_setting = (uint32_t)settings.alertSetting;
    value.center_setting = (uint32_t)settings.notificationCenterSetting;
    value.sound_setting = (uint32_t)settings.soundSetting;
    return value;
}

static void failure(ZWNotificationNode *node, int64_t code, NSString *domain, NSString *detail) {
    node->value.result = ZW_NOTIFY_RESULT_FAILED;
    node->value.error_code = code;
    strlcpy(node->value.error_domain, domain.UTF8String ?: "", sizeof(node->value.error_domain));
    strlcpy(node->value.error_detail, detail.UTF8String ?: "", sizeof(node->value.error_detail));
}

/* NSNumber carries the complete uint64, including values above 2^53. Payloads
 * from old process instances are decoded but never silently rebound as current. */
static NSDictionary *target_info(uint64_t event_id, ZW_NOTIFICATION_TARGET target, NSString *instance) {
    return @{
        @"zw_schema": @1, @"zw_instance": instance, @"event": @(event_id),
        @"owner_kind": @(target.owner_kind), @"kind": @(target.kind),
        @"owner_id": @(target.owner_id), @"owner_revision": @(target.owner_revision),
        @"operation": @(target.operation_id), @"attempt": @(target.attempt_or_turn_id),
        @"has_attempt": @(target.has_attempt_or_turn)
    };
}

static UNMutableNotificationContent *notification_content(uint64_t event_id, ZW_NOTIFICATION_TARGET target,
        NSString *instance, const uint8_t *summary, size_t length) {
    NSString *text = [[NSString alloc] initWithBytes:summary length:length encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"ZeroWork";
    content.body = text;
    content.userInfo = target_info(event_id, target, instance);
    /* System event alerts are silent. The VT Bell policy has its own sound path. */
    content.sound = nil;
    return content;
}

static BOOL unsigned_value(NSDictionary *info, NSString *key, uint64_t *out) {
    id value = info[key];
    if (![value isKindOfClass:NSNumber.class]) return NO;
    const char *type = [value objCType];
    if (!type || !strchr("CSILQcsilq", type[0]) || type[1] || [value compare:@0] == NSOrderedAscending) return NO;
    *out = [value unsignedLongLongValue];
    return YES;
}

static BOOL decode_info(NSDictionary *info, NSString *instance, ZW_NOTIFICATION_EVENT *out) {
    if (![info isKindOfClass:NSDictionary.class] || ![info[@"zw_instance"] isKindOfClass:NSString.class]) return NO;
    uint64_t schema, owner_kind, kind, has_attempt;
    if (!unsigned_value(info, @"zw_schema", &schema) || schema != 1 ||
        !unsigned_value(info, @"event", &out->event_id) || !out->event_id ||
        !unsigned_value(info, @"owner_kind", &owner_kind) || owner_kind > UINT32_MAX ||
        !unsigned_value(info, @"kind", &kind) || kind > UINT32_MAX ||
        !unsigned_value(info, @"owner_id", &out->target.owner_id) ||
        !unsigned_value(info, @"owner_revision", &out->target.owner_revision) ||
        !unsigned_value(info, @"operation", &out->target.operation_id) ||
        !unsigned_value(info, @"attempt", &out->target.attempt_or_turn_id) ||
        !unsigned_value(info, @"has_attempt", &has_attempt) || has_attempt > 1) return NO;
    out->target.owner_kind = (uint32_t)owner_kind;
    out->target.kind = (uint32_t)kind;
    out->target.has_attempt_or_turn = (uint32_t)has_attempt;
    out->current_instance = [info[@"zw_instance"] isEqualToString:instance];
    return valid_target(&out->target);
}

@interface ZWNotificationBridge : NSObject <UNUserNotificationCenterDelegate> {
    pthread_mutex_t _lock;
    ZWNotificationNode *_head, *_tail;
    uint64_t _dropped;
    BOOL _closed;
    BOOL _lockInitialized;
}
@property(nonatomic, strong) UNUserNotificationCenter *center;
@property(nonatomic, copy) NSString *instance;
@property(nonatomic) ZW_NOTIFICATION_CAPABILITIES capabilities;
- (void)enqueue:(ZWNotificationNode *)node;
- (int)poll:(ZW_NOTIFICATION_EVENT *)event;
- (BOOL)isClosed;
- (void)close;
@end

@implementation ZWNotificationBridge
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    if (pthread_mutex_init(&_lock, NULL) != 0) return nil;
    _lockInitialized = YES;
    _instance = NSUUID.UUID.UUIDString;
    _capabilities.bell = 1;
    _capabilities.unavailable_reason = ZW_NOTIFY_NO_APP_BUNDLE;
    NSBundle *bundle = NSBundle.mainBundle;
    if (bundle.bundleIdentifier.length && [bundle.bundleURL.pathExtension.lowercaseString isEqualToString:@"app"]) {
        @try {
            _center = UNUserNotificationCenter.currentNotificationCenter;
            if (_center.delegate) {
                _center = nil;
                _capabilities.unavailable_reason = ZW_NOTIFY_DELEGATE_IN_USE;
            } else if (_center) {
                _center.delegate = self;
                _capabilities.system_notifications = 1;
                _capabilities.authorization_request = 1;
                _capabilities.activation = 1;
                _capabilities.unavailable_reason = ZW_NOTIFY_AVAILABLE;
            } else _capabilities.unavailable_reason = ZW_NOTIFY_CENTER_UNAVAILABLE;
        } @catch (NSException *exception) {
            (void)exception;
            _center = nil;
            _capabilities.unavailable_reason = ZW_NOTIFY_CENTER_UNAVAILABLE;
        }
    }
    return self;
}
- (BOOL)isClosed {
    pthread_mutex_lock(&_lock);
    BOOL value = _closed;
    pthread_mutex_unlock(&_lock);
    return value;
}
- (void)enqueue:(ZWNotificationNode *)node {
    pthread_mutex_lock(&_lock);
    if (_closed) free(node);
    else if (!node) _dropped += _dropped != UINT64_MAX;
    else {
        if (_tail) _tail->next = node;
        else _head = node;
        _tail = node;
    }
    pthread_mutex_unlock(&_lock);
}
- (int)poll:(ZW_NOTIFICATION_EVENT *)event {
    pthread_mutex_lock(&_lock);
    if (_closed) { pthread_mutex_unlock(&_lock); return -ZW_NOTIFY_CLOSED; }
    ZWNotificationNode *node = _head;
    if (node) {
        _head = node->next;
        if (!_head) _tail = NULL;
        *event = node->value;
    } else if (_dropped) {
        memset(event, 0, sizeof(*event));
        event->kind = ZW_NOTIFY_EVENT_QUEUE_FAILURE;
        event->result = ZW_NOTIFY_RESULT_FAILED;
        event->dropped_events = _dropped;
        _dropped = 0;
    }
    pthread_mutex_unlock(&_lock);
    if (node) { free(node); return 1; }
    return event->kind == ZW_NOTIFY_EVENT_QUEUE_FAILURE ? 1 : 0;
}
- (void)close {
    pthread_mutex_lock(&_lock);
    _closed = YES;
    ZWNotificationNode *node = _head;
    _head = _tail = NULL;
    _dropped = 0;
    pthread_mutex_unlock(&_lock);
    while (node) { ZWNotificationNode *next = node->next; free(node); node = next; }
    if (_center.delegate == self) _center.delegate = nil;
    /* OS-accepted notifications remain in Notification Center. There are no
     * future triggers to cancel. Async continuations only retain native self;
     * send's settings continuation checks closed on the main queue before add. */
}
- (void)dealloc {
    if (_lockInitialized) pthread_mutex_destroy(&_lock);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
        willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center;
    ZW_NOTIFICATION_EVENT value = {0};
    BOOL own = [notification.request.identifier hasPrefix:ZWNotificationPrefix] &&
        decode_info(notification.request.content.userInfo, self.instance, &value) && value.current_instance;
    completionHandler(own && ![self isClosed] ?
        UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList : UNNotificationPresentationOptionNone);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
        didReceiveNotificationResponse:(UNNotificationResponse *)response
        withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] &&
        [response.notification.request.identifier hasPrefix:ZWNotificationPrefix]) {
        ZWNotificationNode *node = calloc(1, sizeof(*node));
        if (!node) [self enqueue:NULL];
        else if (decode_info(response.notification.request.content.userInfo, self.instance, &node->value)) {
            node->value.kind = ZW_NOTIFY_EVENT_ACTIVATION;
            node->value.result = ZW_NOTIFY_RESULT_REPORTED;
            [self enqueue:node];
        } else free(node);
    }
    completionHandler();
}
@end

static ZWNotificationBridge *bridge(ZW_NOTIFICATIONS *notifications) {
    return (__bridge ZWNotificationBridge *)(void *)notifications;
}
static int valid_bridge(ZW_NOTIFICATIONS *notifications) {
    if (!NSThread.isMainThread) return ZW_NOTIFY_WRONG_THREAD;
    if (!notifications) return ZW_NOTIFY_INVALID_ARGUMENT;
    return [bridge(notifications) isClosed] ? ZW_NOTIFY_CLOSED : ZW_NOTIFY_OK;
}

ZW_NOTIFICATIONS *zw_notifications_create(int *status) {
    if (status) *status = ZW_NOTIFY_OK;
    if (!NSThread.isMainThread) { if (status) *status = ZW_NOTIFY_WRONG_THREAD; return NULL; }
    @autoreleasepool {
        ZWNotificationBridge *value = [ZWNotificationBridge new];
        if (!value) { if (status) *status = ZW_NOTIFY_FAILED; return NULL; }
        return (ZW_NOTIFICATIONS *)(__bridge_retained void *)value;
    }
}
void zw_notifications_destroy(ZW_NOTIFICATIONS *notifications) {
    if (!notifications || !NSThread.isMainThread) return;
    ZWNotificationBridge *value = (__bridge_transfer ZWNotificationBridge *)(void *)notifications;
    [value close];
}
int zw_notifications_capabilities(ZW_NOTIFICATIONS *notifications, ZW_NOTIFICATION_CAPABILITIES *out) {
    int status = valid_bridge(notifications);
    if (status) return status;
    if (!out) return ZW_NOTIFY_INVALID_ARGUMENT;
    *out = bridge(notifications).capabilities;
    return ZW_NOTIFY_OK;
}
int zw_notifications_query_settings(ZW_NOTIFICATIONS *notifications, uint64_t request_id) {
    int status = valid_bridge(notifications);
    if (status) return status;
    if (!request_id) return ZW_NOTIFY_INVALID_ARGUMENT;
    ZWNotificationBridge *value = bridge(notifications);
    if (!value.center) return ZW_NOTIFY_UNAVAILABLE;
    ZWNotificationNode *node = calloc(1, sizeof(*node));
    if (!node) return ZW_NOTIFY_FAILED;
    node->value.kind = ZW_NOTIFY_EVENT_SETTINGS;
    node->value.request_id = request_id;
    [value.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        node->value.settings = settings_value(settings);
        node->value.result = ZW_NOTIFY_RESULT_REPORTED;
        [value enqueue:node];
    }];
    return ZW_NOTIFY_OK;
}
int zw_notifications_request_authorization(ZW_NOTIFICATIONS *notifications, uint64_t request_id, uint32_t explicit_ui_action) {
    int status = valid_bridge(notifications);
    if (status) return status;
    if (!request_id || explicit_ui_action != 1) return ZW_NOTIFY_INVALID_ARGUMENT;
    ZWNotificationBridge *value = bridge(notifications);
    if (!value.center) return ZW_NOTIFY_UNAVAILABLE;
    ZWNotificationNode *node = calloc(1, sizeof(*node));
    if (!node) return ZW_NOTIFY_FAILED;
    node->value.kind = ZW_NOTIFY_EVENT_PERMISSION;
    node->value.request_id = request_id;
    [value.center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError *error) {
        node->value.granted = granted;
        if (error) failure(node, error.code, error.domain, error.localizedDescription);
        [value.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            node->value.settings = settings_value(settings);
            if (!error) node->value.result = ZW_NOTIFY_RESULT_REPORTED;
            [value enqueue:node];
        }];
    }];
    return ZW_NOTIFY_OK;
}
int zw_notifications_send(ZW_NOTIFICATIONS *notifications, uint64_t request_id, uint64_t event_id,
        const ZW_NOTIFICATION_TARGET *target, const uint8_t *summary, size_t summary_length) {
    int status = valid_bridge(notifications);
    if (status) return status;
    if (!request_id || !event_id || !valid_target(target) || !summary || !summary_length) return ZW_NOTIFY_INVALID_ARGUMENT;
    ZWNotificationBridge *value = bridge(notifications);
    if (!value.center) return ZW_NOTIFY_UNAVAILABLE;
    UNMutableNotificationContent *content = notification_content(event_id, *target, value.instance, summary, summary_length);
    if (!content) return ZW_NOTIFY_INVALID_ARGUMENT;
    ZWNotificationNode *node = calloc(1, sizeof(*node));
    if (!node) return ZW_NOTIFY_FAILED;
    node->value.kind = ZW_NOTIFY_EVENT_SEND;
    node->value.request_id = request_id;
    node->value.event_id = event_id;
    node->value.target = *target;
    NSString *identifier = [NSString stringWithFormat:@"%@%@.%llu", ZWNotificationPrefix, value.instance, (unsigned long long)event_id];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [value.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        node->value.settings = settings_value(settings);
        dispatch_async(dispatch_get_main_queue(), ^{
            /* Serialize this last check/add with main-thread destruction. A
             * permission query that finishes after shutdown cannot send. */
            if ([value isClosed]) { free(node); return; }
            if (node->value.settings.authorization != ZW_NOTIFY_AUTH_AUTHORIZED &&
                node->value.settings.authorization != ZW_NOTIFY_AUTH_PROVISIONAL) {
                failure(node, ZW_NOTIFY_UNAVAILABLE, @"ZeroWorkNotificationBridge", @"System notification authorization is not granted");
                [value enqueue:node];
                return;
            }
            __weak ZWNotificationBridge *completionOwner = value;
            [value.center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
                if (error) failure(node, error.code, error.domain, error.localizedDescription);
                else node->value.result = ZW_NOTIFY_RESULT_SCHEDULED;
                ZWNotificationBridge *owner = completionOwner;
                if (owner) [owner enqueue:node];
                else free(node);
            }];
        });
    }];
    return ZW_NOTIFY_OK;
}
int zw_notifications_poll(ZW_NOTIFICATIONS *notifications, ZW_NOTIFICATION_EVENT *event) {
    int status = valid_bridge(notifications);
    if (status) return -status;
    if (!event) return -ZW_NOTIFY_INVALID_ARGUMENT;
    memset(event, 0, sizeof(*event));
    return [bridge(notifications) poll:event];
}
int zw_notifications_ring(ZW_NOTIFICATIONS *notifications) {
    int status = valid_bridge(notifications);
    if (status) return status;
    NSBeep();
    return ZW_NOTIFY_OK;
}
