// Deterministic lifecycle checks against the production delegate and C ABI.
// Web traffic, redirects, Basic/Digest, and real JS use web_proxy_probe.m.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/platform/macos_web_surface.h"

extern void zw_web_surface_acceptance_counts(uint64_t *, uint64_t *, uint64_t *);
static unsigned changes;
static void changed(void) { ++changes; }

@interface FixtureOrigin : NSObject
@property (nonatomic, readonly) NSString *protocol;
@property (nonatomic, readonly) NSString *host;
@property (nonatomic, readonly) NSInteger port;
@end
@implementation FixtureOrigin
- (NSString *)protocol { return @"https"; }
- (NSString *)host { return @"iframe.fixture.invalid"; }
- (NSInteger)port { return 8443; }
@end

@interface FixtureFrame : NSObject
@property (nonatomic, readonly) WKSecurityOrigin *securityOrigin;
@end
@implementation FixtureFrame
- (WKSecurityOrigin *)securityOrigin { return (WKSecurityOrigin *)[[FixtureOrigin alloc] init]; }
@end

@interface FixtureAction : NSObject
@property (nonatomic, readonly) BOOL shouldPerformDownload;
@property (nonatomic, readonly) WKFrameInfo *sourceFrame;
@end
@implementation FixtureAction
- (BOOL)shouldPerformDownload { return YES; }
- (WKFrameInfo *)sourceFrame { return (WKFrameInfo *)[[FixtureFrame alloc] init]; }
@end

static ZWWebRequest pending(ZWWebSurface *surface, int kind) {
    ZWWebRequest request;
    assert(zw_web_surface_copy_request(surface, &request) == 1);
    assert(request.token && request.kind == kind);
    assert(zw_web_surface_request_pending(surface, request.token));
    return request;
}

static void accept_request(ZWWebSurface *surface, ZWWebRequest *request) {
    assert(zw_web_surface_reply_request(surface, request->token, 1, NULL, 0, NULL, 0) == 1);
    assert(!zw_web_surface_reply_request(surface, request->token, 1, NULL, 0, NULL, 0));
    zw_web_request_dispose(request);
}

static NSURLAuthenticationChallenge *auth(NSString *method) {
    NSURLProtectionSpace *space = [[NSURLProtectionSpace alloc] initWithHost:@"login.fixture.invalid"
        port:8443 protocol:@"https" realm:@"Fixture realm" authenticationMethod:method];
    return [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space proposedCredential:nil
        previousFailureCount:0 failureResponse:nil error:nil sender:(id<NSURLAuthenticationChallengeSender>)[[NSObject alloc] init]];
}

int main(void) {
    uint64_t expectedCompletions = 0;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        ZWWebSurface *surface = zw_web_surface_create();
        assert(surface);
        zw_web_surface_set_change_callback(surface, changed);
        WKWebView *view = [(__bridge id)surface valueForKey:@"webView"];
        id<WKUIDelegate> ui = view.UIDelegate;
        id<WKNavigationDelegate> nav = view.navigationDelegate;
        WKFrameInfo *frame = (WKFrameInfo *)[[FixtureFrame alloc] init];
        __block unsigned callbacks = 0;
        [ui webView:view runJavaScriptAlertPanelWithMessage:@"Hello" initiatedByFrame:frame completionHandler:^{ ++callbacks; }];
        ZWWebRequest request = pending(surface, ZWWebRequestAlert);
        assert(callbacks == 0 && strcmp(request.origin, "https://iframe.fixture.invalid:8443") == 0);
        uint64_t old_token = request.token;
        accept_request(surface, &request);
        assert(callbacks == 1);
        puts("PASS: alert waits for its exact reply and preserves frame origin");

        [ui webView:view runJavaScriptConfirmPanelWithMessage:@"Continue?" initiatedByFrame:frame completionHandler:^(BOOL value) {
            assert(!value); ++callbacks;
        }];
        request = pending(surface, ZWWebRequestConfirm);
        assert(request.token > old_token);
        assert(zw_web_surface_reply_request(surface, request.token, 0, NULL, 0, NULL, 0));
        zw_web_request_dispose(&request);
        [ui webView:view runJavaScriptTextInputPanelWithPrompt:@"Name" defaultText:@"Default text" initiatedByFrame:frame
            completionHandler:^(NSString *value) { assert(value && value.length == 0); ++callbacks; }];
        request = pending(surface, ZWWebRequestPrompt);
        assert(strcmp(request.default_text, "Default text") == 0);
        accept_request(surface, &request);
        [ui webView:view runJavaScriptTextInputPanelWithPrompt:@"Name" defaultText:@"Default text" initiatedByFrame:frame
            completionHandler:^(NSString *value) { assert(value == nil); ++callbacks; }];
        request = pending(surface, ZWWebRequestPrompt);
        assert(zw_web_surface_reply_request(surface, request.token, 0, NULL, 0, NULL, 0));
        zw_web_request_dispose(&request);
        assert(callbacks == 4);
        puts("PASS: confirm cancellation and prompt default/empty/cancel remain distinct");

        for (NSString *method in @[NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest]) {
            [nav webView:view didReceiveAuthenticationChallenge:auth(method)
                completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                    assert(disposition == NSURLSessionAuthChallengeUseCredential);
                    assert([credential.user isEqualToString:@"operator"] && [credential.password isEqualToString:@"fixture-secret"]);
                    assert(credential.persistence == NSURLCredentialPersistenceNone);
                    ++callbacks;
                }];
            request = pending(surface, ZWWebRequestHTTPAuth);
            assert(strcmp(request.origin, "https://login.fixture.invalid:8443") == 0);
            assert(strcmp(request.realm, "Fixture realm") == 0);
            assert(zw_web_surface_reply_request(surface, request.token, 1,
                (const uint8_t *)"operator", 8, (const uint8_t *)"fixture-secret", 14));
            assert(!zw_web_surface_reply_request(surface, request.token, 1, NULL, 0, NULL, 0));
            zw_web_request_dispose(&request);
        }
        [nav webView:view didReceiveAuthenticationChallenge:auth(NSURLAuthenticationMethodServerTrust)
            completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                assert(disposition == NSURLSessionAuthChallengePerformDefaultHandling && !credential); ++callbacks;
            }];
        assert(callbacks == 7 && zw_web_surface_copy_request(surface, &request) == 0);
        puts("PASS: Basic/Digest credentials are consumed once without persistence; TLS remains system-controlled");

        unsigned before = callbacks;
        for (unsigned i = 0; i < 10; ++i) {
            [ui webView:view runJavaScriptConfirmPanelWithMessage:@"Bounded" initiatedByFrame:frame
                completionHandler:^(BOOL accepted) { assert(!accepted); ++callbacks; }];
        }
        assert(callbacks == before + 2);
        uint64_t owners, handlers, completed;
        zw_web_surface_acceptance_counts(&owners, &handlers, &completed);
        assert(owners == 1 && handlers == 8);
        zw_web_surface_cancel_requests(surface);
        assert(callbacks == before + 10);
        zw_web_surface_acceptance_counts(&owners, &handlers, &completed);
        assert(handlers == 0);
        puts("PASS: callback queue is bounded at eight and cancellation completes every handler once");

        [ui webView:view runJavaScriptAlertPanelWithMessage:@"Retire on navigation" initiatedByFrame:frame completionHandler:^{ ++callbacks; }];
        request = pending(surface, ZWWebRequestAlert);
        old_token = request.token;
        const char *url = "http://127.0.0.1:9/";
        assert(zw_web_surface_navigate(surface, (const uint8_t *)url, strlen(url)));
        assert(!zw_web_surface_request_pending(surface, old_token));
        assert(!zw_web_surface_reply_request(surface, old_token, 1, NULL, 0, NULL, 0));
        zw_web_request_dispose(&request);
        [ui webView:view runJavaScriptAlertPanelWithMessage:@"Retire on stop" initiatedByFrame:frame completionHandler:^{ ++callbacks; }];
        request = pending(surface, ZWWebRequestAlert);
        zw_web_surface_stop(surface);
        assert(!zw_web_surface_request_pending(surface, request.token));
        zw_web_request_dispose(&request);
        puts("PASS: navigation and stop reject late replies to cancelled requests");

        [ui webView:view runOpenPanelWithParameters:(WKOpenPanelParameters *)[[NSObject alloc] init] initiatedByFrame:frame completionHandler:^(NSArray<NSURL *> *files) {
            assert(!files); ++callbacks;
        }];
        request = pending(surface, ZWWebRequestNotice);
        assert(strcmp(request.message, "暂不支持上传文件。") == 0);
        accept_request(surface, &request);
        [nav webView:view decidePolicyForNavigationAction:(WKNavigationAction *)[[FixtureAction alloc] init]
            decisionHandler:^(WKNavigationActionPolicy policy) { assert(policy == WKNavigationActionPolicyCancel); ++callbacks; }];
        request = pending(surface, ZWWebRequestNotice);
        assert(strcmp(request.message, "暂不支持下载文件。") == 0);
        accept_request(surface, &request);
        assert(![ui webView:view createWebViewWithConfiguration:[[WKWebViewConfiguration alloc] init] forNavigationAction:(WKNavigationAction *)[[FixtureAction alloc] init] windowFeatures:(WKWindowFeatures *)[[NSObject alloc] init]]);
        request = pending(surface, ZWWebRequestNotice);
        assert(strcmp(request.message, "暂不支持此网页弹窗。") == 0);
        accept_request(surface, &request);
        puts("PASS: unsupported upload, download and popup retain explicit notices");

        before = callbacks;
        [ui webView:view runJavaScriptAlertPanelWithMessage:@"Timeout" initiatedByFrame:frame completionHandler:^{ ++callbacks; }];
        request = pending(surface, ZWWebRequestAlert);
        unsigned priorChanges = changes;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (callbacks == before && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        assert(callbacks == before + 1 && changes > priorChanges);
        assert(!zw_web_surface_request_pending(surface, request.token));
        zw_web_request_dispose(&request);
        puts("PASS: native timeout completes and actively wakes the host without UI polling");

        before = callbacks;
        [ui webView:view runJavaScriptAlertPanelWithMessage:@"Destroy" initiatedByFrame:frame completionHandler:^{ ++callbacks; }];
        request = pending(surface, ZWWebRequestAlert);
        old_token = request.token;
        zw_web_request_dispose(&request);
        // Do not let test references extend the delegate owner's lifetime.
        ui = nil;
        nav = nil;
        view = nil;
        zw_web_surface_destroy(surface);
        assert(callbacks == before + 1);
        surface = zw_web_surface_create();
        assert(!zw_web_surface_reply_request(surface, old_token, 1, NULL, 0, NULL, 0));
        zw_web_surface_destroy(surface);
        expectedCompletions = callbacks;
    }
    uint64_t owners, handlers, completed;
    zw_web_surface_acceptance_counts(&owners, &handlers, &completed);
    assert(owners == 0 && handlers == 0 && completed >= expectedCompletions);
    puts("PASS: destruction releases every callback and replacement instances reject old tokens");
    return 0;
}
