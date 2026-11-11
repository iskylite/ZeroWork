// Drive the production bridge with fixture endpoints and credentials over stdin.
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#include <stdlib.h>
#include "../src/platform/macos_web_surface.h"

// The disposable fixture CA is scoped to this probe's trust evaluations.
// Forward every navigation callback to the actual bridge.
@interface ProbeTrustDelegate : NSObject <WKNavigationDelegate>
@property (nonatomic, weak) id<WKNavigationDelegate> bridge;
@property (nonatomic, strong) NSArray *anchors;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *decisions;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@end

@implementation ProbeTrustDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.bridge respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.bridge respondsToSelector:selector] ? self.bridge : [super forwardingTargetForSelector:selector];
}
- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    [self.events addObject:@{@"event": @"auth", @"method": space.authenticationMethod, @"attempt": @(challenge.previousFailureCount)}];
    SecTrustRef trust = space.serverTrust;
    if (![space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] || !trust || !self.anchors.count) {
        [self.bridge webView:webView didReceiveAuthenticationChallenge:challenge completionHandler:completion];
        return;
    }
    // Keep the original SSL policy, including its hostname check.
    BOOL valid = SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)self.anchors) == errSecSuccess
        && SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        && SecTrustEvaluateWithError(trust, NULL);
    [self.decisions addObject:@{@"host": space.host, @"accepted": @(valid)}];
    if (valid) {
        completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.events addObject:@{@"event": @"start"}];
    [self.bridge webView:view didStartProvisionalNavigation:navigation];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.events addObject:@{@"event": @"fail", @"domain": error.domain, @"code": @(error.code)}];
    [self.bridge webView:view didFailProvisionalNavigation:navigation withError:error];
}
@end

@interface ProbeView : NSObject
@property (nonatomic) ZWWebSurface *surface;
@property (nonatomic, strong) ProbeTrustDelegate *trustDelegate;
@end

@implementation ProbeView
- (void)dealloc {
    zw_web_surface_destroy(self.surface);
}
@end

static void reply(NSDictionary *result) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static BOOL wait_until(BOOL (^finished)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    while (!finished() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return finished();
}

static NSString *copy_text(char *value) {
    if (!value) return nil;
    NSString *text = [NSString stringWithUTF8String:value];
    free(value);
    return text;
}

static NSDictionary *process(NSDictionary *command, NSMutableDictionary<NSString *, ProbeView *> *views, NSArray *anchors) {
    NSString *operation = command[@"operation"];
    NSString *name = command[@"view"];
    if ([operation isEqual:@"create"]) {
        ProbeView *probe = [[ProbeView alloc] init];
        NSNumber *port = command[@"proxyPort"];
        if (port) {
            NSData *username = [command[@"username"] dataUsingEncoding:NSUTF8StringEncoding];
            NSData *password = [command[@"password"] dataUsingEncoding:NSUTF8StringEncoding];
            probe.surface = zw_web_surface_create_proxied(port.unsignedShortValue, username.bytes,
                username.length, password.bytes, password.length);
        } else {
            probe.surface = zw_web_surface_create();
        }
        if (!probe.surface) return @{@"status": @"configurationRejected"};
        if (!zw_web_surface_state(probe.surface).ready) return @{@"status": @"notReady"};
        {
            if ([command[@"fixtureCA"] boolValue] && !anchors.count) return @{@"status": @"missingFixtureCA"};
            WKWebView *view = [(__bridge id)probe.surface valueForKey:@"webView"];
            ProbeTrustDelegate *delegate = [[ProbeTrustDelegate alloc] init];
            delegate.bridge = view.navigationDelegate;
            delegate.anchors = [command[@"fixtureCA"] boolValue] ? anchors : nil;
            delegate.decisions = [NSMutableArray array];
            delegate.events = [NSMutableArray array];
            probe.trustDelegate = delegate;
            view.navigationDelegate = delegate;
        }
        views[name] = probe;
        return @{@"status": @"created"};
    }
    ProbeView *probe = views[name];
    NSString *url = command[@"url"];
    if (!probe) return @{@"status": @"invalidCommand"};
    WKWebView *view = [(__bridge id)probe.surface valueForKey:@"webView"];
    [probe.trustDelegate.decisions removeAllObjects];
    [probe.trustDelegate.events removeAllObjects];
    const uint64_t before = zw_web_surface_state(probe.surface).navigation_id;
    int accepted = 0;
    __block BOOL scriptFinished = NO;
    __block NSError *scriptError = nil;
    if ([operation isEqual:@"load"] && url) {
        const uint8_t *bytes = (const uint8_t *)url.UTF8String;
        accepted = zw_web_surface_navigate(probe.surface, bytes, [url lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    } else if ([operation isEqual:@"reload"]) {
        accepted = zw_web_surface_reload(probe.surface);
    } else if ([operation isEqual:@"script"] && command[@"script"]) {
        accepted = 1;
        [view evaluateJavaScript:command[@"script"] completionHandler:^(id value, NSError *error) {
            scriptFinished = YES;
            scriptError = error;
        }];
    }
    if (accepted != 1) return @{@"status": @"rejected"};
    NSString *expectedTitle = command[@"expectedTitle"];
    NSArray<NSDictionary *> *answers = command[@"answers"] ?: @[];
    NSMutableArray *requests = [NSMutableArray array];
    __block NSUInteger answerIndex = 0;
    __block BOOL repliesValid = YES;
    BOOL settled = wait_until(^BOOL {
        ZWWebRequest request;
        if (answerIndex < answers.count && zw_web_surface_copy_request(probe.surface, &request) == 1) {
            [requests addObject:@{@"kind": @(request.kind), @"origin": @(request.origin),
                @"message": @(request.message), @"default": @(request.default_text), @"realm": @(request.realm)}];
            NSDictionary *answer = answers[answerIndex++];
            NSData *value = [(answer[@"value"] ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
            NSData *secret = [(answer[@"secret"] ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
            int consumed = zw_web_surface_reply_request(probe.surface, request.token, [answer[@"accepted"] boolValue],
                value.bytes, value.length, secret.bytes, secret.length);
            repliesValid = repliesValid && consumed == 1
                && zw_web_surface_reply_request(probe.surface, request.token, 1, NULL, 0, NULL, 0) == 0;
            zw_web_request_dispose(&request);
        }
        ZWWebSurfaceState state = zw_web_surface_state(probe.surface);
        if (state.failed) return YES;
        if (answerIndex < answers.count || !state.committed || state.loading) return NO;
        if (![operation isEqual:@"script"] && state.navigation_id == before) return NO;
        if ([operation isEqual:@"script"] && !scriptFinished) return NO;
        return !expectedTitle || [copy_text(zw_web_surface_copy_title(probe.surface)) isEqual:expectedTitle];
    });
    if (!settled) {
        ZWWebSurfaceState state = zw_web_surface_state(probe.surface);
        NSString *lastURL = copy_text(zw_web_surface_copy_url(probe.surface)) ?: @"";
        NSString *lastTitle = copy_text(zw_web_surface_copy_title(probe.surface)) ?: @"";
        zw_web_surface_stop(probe.surface);
        return @{@"status": @"timeout", @"requests": requests, @"url": lastURL, @"title": lastTitle,
            @"committed": @(state.committed), @"loading": @(state.loading), @"events": probe.trustDelegate.events};
    }
    ZWWebSurfaceState state = zw_web_surface_state(probe.surface);
    NSArray *trustDecisions = probe.trustDelegate.anchors.count ? probe.trustDelegate.decisions : nil;
    if (state.failed) {
        NSMutableDictionary *result = [@{@"status": @"failed", @"requests": requests, @"repliesValid": @(repliesValid), @"events": probe.trustDelegate.events} mutableCopy];
        if (trustDecisions) result[@"trust"] = trustDecisions;
        return result;
    }
    NSString *displayed = copy_text(zw_web_surface_copy_url(probe.surface));
    NSMutableDictionary *result = [@{@"status": @"loaded", @"url": displayed ?: @"", @"get": @(state.committed_get != 0)} mutableCopy];
    result[@"title"] = copy_text(zw_web_surface_copy_title(probe.surface)) ?: @"";
    if (answers.count) {
        result[@"requests"] = requests;
        result[@"repliesValid"] = @(repliesValid && answerIndex == answers.count);
    }
    if (scriptError) result[@"scriptError"] = scriptError.localizedDescription;
    if (trustDecisions) result[@"trust"] = trustDecisions;
    return result;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!zw_web_surface_supports_proxy()) {
            reply(@{@"status": @"requiresMacOS14"});
            return 1;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSArray *anchors = nil;
        if (argc == 2) {
            NSData *der = [NSData dataWithContentsOfFile:@(argv[1])];
            SecCertificateRef anchor = der ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der) : NULL;
            if (!anchor) return 1;
            anchors = @[CFBridgingRelease(anchor)];
        }
        NSMutableDictionary<NSString *, ProbeView *> *views = [NSMutableDictionary dictionary];
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length;
        while ((length = getline(&line, &capacity, stdin)) >= 0) {
            @autoreleasepool {
                NSData *data = [NSData dataWithBytes:line length:(NSUInteger)length];
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if (![command isKindOfClass:NSDictionary.class]) {
                    reply(@{@"status": @"invalidCommand"});
                    continue;
                }
                reply(process(command, views, anchors));
            }
        }
        free(line);
        [views removeAllObjects];
        return 0;
    }
}
