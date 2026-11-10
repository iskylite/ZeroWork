// clang -fobjc-arc ... -framework Foundation -framework LocalAuthentication
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <assert.h>

@interface ZWTestAuthContext : NSObject
@property(nonatomic, copy) NSString *localizedCancelTitle;
@property(nonatomic, copy) void (^reply)(BOOL, NSError *);
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error;
- (void)evaluatePolicy:(LAPolicy)policy localizedReason:(NSString *)reason reply:(void (^)(BOOL, NSError *))reply;
- (void)invalidate;
@end
static ZWTestAuthContext *latest;
static BOOL available = YES;
static NSUInteger created, invalidated;
@implementation ZWTestAuthContext
- (instancetype)init { if ((self = [super init])) { latest = self; created++; } return self; }
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error {
    assert(policy == LAPolicyDeviceOwnerAuthentication);
    return available;
}
- (void)evaluatePolicy:(LAPolicy)policy localizedReason:(NSString *)reason reply:(void (^)(BOOL, NSError *))reply {
    assert(policy == LAPolicyDeviceOwnerAuthentication && reason.length);
    self.reply = reply;
}
- (void)invalidate { invalidated++; self.reply = nil; }
@end
#define ZW_AUTH_CONTEXT ZWTestAuthContext
#import "macos_password_reveal.m"

int main(void) { @autoreleasepool {
    void *first = zw_password_reveal_begin();
    assert(first && zw_password_reveal_status(first) == 0);
    latest.reply(YES, nil);
    assert(zw_password_reveal_status(first) == 1);
    ZWTestAuthContext *firstContext = latest;
    zw_password_reveal_cancel(first);
    void *second = zw_password_reveal_begin();
    assert(created == 2 && latest != firstContext && zw_password_reveal_status(second) == 0);
    latest.reply(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorUserCancel userInfo:nil]);
    assert(zw_password_reveal_status(second) == 2);
    zw_password_reveal_cancel(second);
    available = NO;
    void *unavailable = zw_password_reveal_begin();
    assert(zw_password_reveal_status(unavailable) == 3);
    zw_password_reveal_cancel(unavailable);
    available = YES;
    void *closing = zw_password_reveal_begin();
    void (^lateReply)(BOOL, NSError *) = latest.reply;
    zw_password_reveal_cancel(closing);
    lateReply(YES, nil); // A cancelled request may finish late; no view is retained.
    assert(invalidated == 4);
    puts("PASS: fresh device-owner verification, success, cancellation, unavailable policy, late completion");
} return 0; }
