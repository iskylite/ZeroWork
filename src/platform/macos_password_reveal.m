#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>

#ifndef ZW_AUTH_CONTEXT
#define ZW_AUTH_CONTEXT LAContext
#endif

@interface ZWPasswordRevealRequest : NSObject
@property(nonatomic, strong) ZW_AUTH_CONTEXT *context;
@property(atomic) NSInteger result;
@end
@implementation ZWPasswordRevealRequest
@end

void *zw_password_reveal_begin(void) {
    if (!NSThread.isMainThread) return NULL;
    ZWPasswordRevealRequest *request = [ZWPasswordRevealRequest new];
    request.context = [ZW_AUTH_CONTEXT new];
    request.context.localizedCancelTitle = @"取消";
    NSError *error = nil;
    if (![request.context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        request.result = 3;
    } else {
        // A new context for every reveal; never reuse the vault-unlock grant.
        [request.context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"查看此连接的密码"
            reply:^(BOOL success, NSError *failure) {
                request.result = success ? 1 :
                    (failure.code == LAErrorUserCancel || failure.code == LAErrorAppCancel || failure.code == LAErrorSystemCancel) ? 2 : 3;
            }];
    }
    return (__bridge_retained void *)request;
}

int zw_password_reveal_status(void *handle) {
    return (int)((__bridge ZWPasswordRevealRequest *)handle).result;
}

void zw_password_reveal_cancel(void *handle) {
    if (!handle) return;
    ZWPasswordRevealRequest *request = CFBridgingRelease(handle);
    [request.context invalidate];
}
