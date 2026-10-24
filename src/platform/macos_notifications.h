#ifndef ZEROWORK_MACOS_NOTIFICATIONS_H
#define ZEROWORK_MACOS_NOTIFICATIONS_H

#include <stddef.h>
#include <stdint.h>

typedef struct zw_notifications ZW_NOTIFICATIONS;

enum {
    ZW_NOTIFY_OK = 0,
    ZW_NOTIFY_WRONG_THREAD = 1,
    ZW_NOTIFY_INVALID_ARGUMENT = 2,
    ZW_NOTIFY_UNAVAILABLE = 3,
    ZW_NOTIFY_CLOSED = 4,
    ZW_NOTIFY_FAILED = 5
};
enum {
    ZW_NOTIFY_AUTH_UNAVAILABLE = 0,
    ZW_NOTIFY_AUTH_NOT_DETERMINED = 1,
    ZW_NOTIFY_AUTH_DENIED = 2,
    ZW_NOTIFY_AUTH_AUTHORIZED = 3,
    ZW_NOTIFY_AUTH_PROVISIONAL = 4
};
enum {
    ZW_NOTIFY_EVENT_SETTINGS = 1,
    ZW_NOTIFY_EVENT_PERMISSION = 2,
    ZW_NOTIFY_EVENT_SEND = 3,
    ZW_NOTIFY_EVENT_ACTIVATION = 4,
    ZW_NOTIFY_EVENT_QUEUE_FAILURE = 5
};
enum {
    ZW_NOTIFY_RESULT_REPORTED = 1,
    /* addNotificationRequest succeeded. This is not proof of a visible banner. */
    ZW_NOTIFY_RESULT_SCHEDULED = 2,
    ZW_NOTIFY_RESULT_FAILED = 3
};
enum {
    ZW_NOTIFY_AVAILABLE = 0,
    ZW_NOTIFY_NO_APP_BUNDLE = 1,
    ZW_NOTIFY_CENTER_UNAVAILABLE = 2,
    ZW_NOTIFY_DELEGATE_IN_USE = 3
};

typedef struct {
    uint32_t system_notifications;
    uint32_t authorization_request;
    uint32_t activation;
    uint32_t bell;
    uint32_t unavailable_reason;
} ZW_NOTIFICATION_CAPABILITIES;

/* Numeric values are stable wire identities, never display names or addresses.
 * owner_kind: 1=session, 2=group, 3=history; kind: 1=transfer, 2=reconnect, 3=AI.
 * owner_revision is generation/revision for session/group and zero for history. */
typedef struct {
    uint32_t owner_kind;
    uint32_t kind;
    uint64_t owner_id;
    uint64_t owner_revision;
    uint64_t operation_id;
    uint64_t attempt_or_turn_id;
    uint32_t has_attempt_or_turn;
} ZW_NOTIFICATION_TARGET;

typedef struct {
    uint32_t authorization;
    /* UNNotificationSetting: 0=unsupported, 1=disabled, 2=enabled. */
    uint32_t alert_setting;
    uint32_t center_setting;
    uint32_t sound_setting;
} ZW_NOTIFICATION_SETTINGS;

typedef struct {
    uint32_t kind;
    uint32_t result;
    uint64_t request_id;
    uint64_t event_id;
    ZW_NOTIFICATION_TARGET target;
    ZW_NOTIFICATION_SETTINGS settings;
    uint32_t current_instance;
    uint32_t granted;
    uint64_t dropped_events;
    int64_t error_code;
    char error_domain[64];
    char error_detail[192];
} ZW_NOTIFICATION_EVENT;

/* All public functions are main-thread only. Platform completion handlers retain
 * their native owner and queue value copies; they never call into Zig/UI memory.
 * Creation and settings queries NEVER request permission. Bare CLI binaries keep
 * Bell but explicitly report no system-notification capability. */
ZW_NOTIFICATIONS *zw_notifications_create(int *status);
void zw_notifications_destroy(ZW_NOTIFICATIONS *notifications);
int zw_notifications_capabilities(ZW_NOTIFICATIONS *, ZW_NOTIFICATION_CAPABILITIES *);
int zw_notifications_query_settings(ZW_NOTIFICATIONS *, uint64_t request_id);
/* explicit_ui_action must be 1, supplied only by the enable-notifications action. */
int zw_notifications_request_authorization(ZW_NOTIFICATIONS *, uint64_t request_id, uint32_t explicit_ui_action);
/* Borrowed UTF-8 text is copied before return. OK means queued, not delivered. */
int zw_notifications_send(ZW_NOTIFICATIONS *, uint64_t request_id, uint64_t event_id,
    const ZW_NOTIFICATION_TARGET *, const uint8_t *summary, size_t summary_length);
/* 1=value, 0=empty, negative=-ZW_NOTIFY_*. Polling never prompts or sends. */
int zw_notifications_poll(ZW_NOTIFICATIONS *, ZW_NOTIFICATION_EVENT *);
/* Calls NSBeep on the main thread. OS volume/mute still applies. */
int zw_notifications_ring(ZW_NOTIFICATIONS *);

#endif
