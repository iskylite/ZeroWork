/* Compile this translation unit instead of macos_notifications.m. It exercises
 * the production payload and queue without creating NSApplication, obtaining a
 * notification center, querying/requesting authorization, posting or ringing. */
#import "macos_notifications.m"
#include <assert.h>
#include <stdio.h>

@interface ZWNotificationBridge (HeadlessTests)
- (instancetype)initQueueOnly;
@end
@implementation ZWNotificationBridge (HeadlessTests)
- (instancetype)initQueueOnly {
    self = [super init];
    if (!self) return nil;
    assert(pthread_mutex_init(&_lock, NULL) == 0);
    _lockInitialized = YES;
    self.instance = @"test-instance";
    return self;
}
@end

static ZWNotificationNode *node(uint64_t request) {
    ZWNotificationNode *value = calloc(1, sizeof(*value));
    assert(value);
    value->value.kind = ZW_NOTIFY_EVENT_SETTINGS;
    value->value.request_id = request;
    return value;
}

static void payload_roundtrip(void) {
    ZW_NOTIFICATION_TARGET target = { .owner_kind = 1, .kind = 3,
        .owner_id = UINT64_MAX, .owner_revision = UINT64_MAX - 1,
        .operation_id = UINT64_MAX - 2, .attempt_or_turn_id = UINT64_MAX - 3, .has_attempt_or_turn = 1 };
    ZW_NOTIFICATION_EVENT result = {0};
    NSDictionary *payload = target_info(UINT64_MAX - 4, target, @"test-instance");
    assert(decode_info(payload, @"test-instance", &result));
    assert(result.event_id == UINT64_MAX - 4 && result.current_instance);
    assert(result.target.owner_id == target.owner_id && result.target.owner_revision == target.owner_revision);
    assert(result.target.operation_id == target.operation_id && result.target.attempt_or_turn_id == target.attempt_or_turn_id);
    assert(decode_info(payload, @"later-instance", &result) && !result.current_instance);
    for (uint32_t kind = 1; kind <= 3; ++kind) {
        target.owner_kind = kind;
        target.owner_revision = kind == 3 ? 0 : UINT64_MAX;
        target.has_attempt_or_turn = 0;
        target.attempt_or_turn_id = 0;
        assert(decode_info(target_info(7, target, @"test-instance"), @"test-instance", &result));
        assert(result.target.owner_kind == kind && result.target.owner_revision == target.owner_revision);
    }
    NSMutableDictionary *invalid = payload.mutableCopy;
    invalid[@"owner_id"] = @(-1);
    assert(!decode_info(invalid, @"test-instance", &result));
    invalid[@"owner_id"] = @1.5;
    assert(!decode_info(invalid, @"test-instance", &result));
    invalid[@"owner_id"] = @1;
    invalid[@"owner_revision"] = @0;
    assert(!decode_info(invalid, @"test-instance", &result));
    invalid[@"owner_revision"] = @1;
    invalid[@"has_attempt"] = @2;
    assert(!decode_info(invalid, @"test-instance", &result));
}

static void borrowed_text_copy(void) {
    ZW_NOTIFICATION_TARGET target = { .owner_kind = 1, .kind = 3, .owner_id = 21, .owner_revision = 4, .operation_id = 50 };
    uint8_t text[] = "original";
    UNMutableNotificationContent *content = notification_content(7, target, @"test-instance", text, sizeof(text) - 1);
    assert(content);
    memset(text, 'x', sizeof(text) - 1);
    assert([content.body isEqualToString:@"original"] && content.sound == nil);
    const uint8_t invalid[] = {0xff};
    assert(notification_content(8, target, @"test-instance", invalid, sizeof(invalid)) == nil);
}

static void queue_fifo_overflow_close(void) {
    ZWNotificationBridge *value = [[ZWNotificationBridge alloc] initQueueOnly];
    assert(value.center == nil);
    [value enqueue:node(1)];
    [value enqueue:node(2)];
    ZW_NOTIFICATION_EVENT event = {0};
    assert([value poll:&event] == 1 && event.request_id == 1);
    assert([value poll:&event] == 1 && event.request_id == 2);
    memset(&event, 0, sizeof(event));
    assert([value poll:&event] == 0);
    [value enqueue:NULL];
    assert([value poll:&event] == 1 && event.kind == ZW_NOTIFY_EVENT_QUEUE_FAILURE && event.dropped_events == 1);
    memset(&event, 0, sizeof(event));
    assert([value poll:&event] == 0);
    [value enqueue:node(3)];
    [value close];
    [value enqueue:node(4)];
    assert([value poll:&event] == -ZW_NOTIFY_CLOSED);
    [value close];
}

typedef struct {
    void *retained_owner;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    int proceed;
} LateCallback;
static void *late_callback(void *raw) {
    LateCallback *context = raw;
    @autoreleasepool {
        ZWNotificationBridge *owner = (__bridge_transfer ZWNotificationBridge *)context->retained_owner;
        pthread_mutex_lock(&context->lock);
        while (!context->proceed) pthread_cond_wait(&context->condition, &context->lock);
        pthread_mutex_unlock(&context->lock);
        for (unsigned i = 0; i < 1000; ++i) [owner enqueue:node(i + 1)];
    }
    return NULL;
}
static void close_before_async_receipt(void) {
    LateCallback context = {0};
    assert(pthread_mutex_init(&context.lock, NULL) == 0);
    assert(pthread_cond_init(&context.condition, NULL) == 0);
    __weak ZWNotificationBridge *weak;
    pthread_t thread;
    @autoreleasepool {
        ZWNotificationBridge *owner = [[ZWNotificationBridge alloc] initQueueOnly];
        weak = owner;
        context.retained_owner = (__bridge_retained void *)owner;
        assert(pthread_create(&thread, NULL, late_callback, &context) == 0);
        [owner close];
    }
    pthread_mutex_lock(&context.lock);
    context.proceed = 1;
    pthread_cond_signal(&context.condition);
    pthread_mutex_unlock(&context.lock);
    assert(pthread_join(thread, NULL) == 0);
    assert(weak == nil);
    pthread_cond_destroy(&context.condition);
    pthread_mutex_destroy(&context.lock);
}

int main(void) {
    @autoreleasepool {
        payload_roundtrip();
        borrowed_text_copy();
        queue_fifo_overflow_close();
        close_before_async_receipt();
        puts("4/4 production Objective-C payload/queue tests passed; no notification center, permission, send, Bell or window used");
    }
    return 0;
}
