// Deterministic lifecycle checks against the production delegate and C ABI.
// Web traffic, redirects, Basic/Digest, and real JS use web_proxy_probe.m.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/platform/macos_web_surface.h"

extern void zw_web_surface_acceptance_counts(uint64_t *, uint64_t *, uint64_t *);
extern uint64_t zw_web_popup_acceptance_count(void);
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
@property (nonatomic, strong) NSURLRequest *request;
@end
@implementation FixtureAction
- (BOOL)shouldPerformDownload { return YES; }
- (WKFrameInfo *)sourceFrame { return (WKFrameInfo *)[[FixtureFrame alloc] init]; }
@end

@interface FixtureWindowFeatures : NSObject
@end
@implementation FixtureWindowFeatures
- (NSNumber *)width { return @560; }
- (NSNumber *)height { return @460; }
- (NSNumber *)x { return nil; }
- (NSNumber *)y { return nil; }
@end

static WKWebView *open_popup(WKWebView *view, WKWebViewConfiguration *configuration, NSString *url) {
    FixtureAction *action = [[FixtureAction alloc] init];
    action.request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    return [view.UIDelegate webView:view createWebViewWithConfiguration:configuration
        forNavigationAction:(WKNavigationAction *)action
        windowFeatures:(WKWindowFeatures *)[[FixtureWindowFeatures alloc] init]];
}

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
        if (@available(macOS 13.3, *)) {
            assert(zw_web_surface_supports_inspection());
            assert(!view.inspectable);
            assert(zw_web_surface_set_inspectable(surface, 1) && view.inspectable);
            assert(zw_web_surface_set_inspectable(surface, 0) && !view.inspectable);
        } else {
            assert(!zw_web_surface_supports_inspection());
            assert(!zw_web_surface_set_inspectable(surface, 1));
        }
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
        assert(!open_popup(view, view.configuration, @"file:///fixture-not-opened"));
        request = pending(surface, ZWWebRequestNotice);
        assert(strcmp(request.message, "暂不支持打开此类型的链接。") == 0);
        accept_request(surface, &request);
        assert(!open_popup(view, [[WKWebViewConfiguration alloc] init], @"about:blank"));
        request = pending(surface, ZWWebRequestNotice);
        assert(strcmp(request.message, "无法继承此网页会话的连接配置。") == 0);
        accept_request(surface, &request);
        puts("PASS: unsupported upload, download, popup schemes and unowned data stores retain explicit notices");

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
    @autoreleasepool {
        ZWWebSurface *surface = zw_web_surface_create();
        WKWebView *view = [(__bridge id)surface valueForKey:@"webView"];
        __block unsigned popupCallbacks = 0;
        @autoreleasepool {
            for (NSUInteger i = 0; i < 8; i++) {
                assert(open_popup(view, view.configuration, @"about:blank"));
            }
            assert(zw_web_surface_popup_count(surface) == 8);
            assert(!open_popup(view, view.configuration, @"about:blank"));
            ZWWebRequest cap = pending(surface, ZWWebRequestNotice);
            assert(strcmp(cap.message, "已达到单会话子窗口数量上限。") == 0);
            accept_request(surface, &cap);
        }
        assert(zw_web_popup_acceptance_count() == 8);
        @autoreleasepool {
            NSArray *registry = [(__bridge id)surface valueForKey:@"popups"];
            WKWebView *child = [registry[0] valueForKey:@"webView"];
            WKFrameInfo *frame = (WKFrameInfo *)[[FixtureFrame alloc] init];
            [child.UIDelegate webView:child runJavaScriptConfirmPanelWithMessage:@"Cancel on teardown"
                initiatedByFrame:frame completionHandler:^(BOOL accepted) {
                    assert(!accepted);
                    ++popupCallbacks;
                    // Simulate a reentrant WebKit callback from the retiring
                    // generation while one of its children is being closed.
                    assert(!open_popup(view, view.configuration, @"about:blank"));
                }];
            zw_web_surface_close_popups(surface);
            assert(!child.UIDelegate && !child.navigationDelegate);
            assert(!zw_web_surface_popup_count(surface));
            assert(!open_popup(view, view.configuration, @"about:blank"));
        }
        assert(popupCallbacks == 1 && zw_web_popup_acceptance_count() == 0);
        zw_web_surface_acceptance_counts(&owners, &handlers, &completed);
        assert(owners == 1 && handlers == 0);
        view = nil;
        zw_web_surface_destroy(surface);
    }
    zw_web_surface_acceptance_counts(&owners, &handlers, &completed);
    assert(owners == 0 && handlers == 0 && zw_web_popup_acceptance_count() == 0);
    puts("PASS: eight-child cap, synchronous popup retirement, callback cancellation and stale generation rejection");
    if (@available(macOS 14.0, *)) {
        @autoreleasepool {
            const uint8_t user[] = "popup-fixture";
            const uint8_t secret[] = "fixture-only";
            ZWWebSurface *surface = zw_web_surface_create_proxied(9, user, sizeof(user) - 1, secret, sizeof(secret) - 1);
            assert(surface);
            WKWebView *view = [(__bridge id)surface valueForKey:@"webView"];
            WKWebView *child = open_popup(view, view.configuration, @"about:blank");
            assert(child);
            WKWebsiteDataStore *parentStore = view.configuration.websiteDataStore;
            WKWebsiteDataStore *childStore = child.configuration.websiteDataStore;
            assert(parentStore == childStore && !childStore.isPersistent);
            assert(childStore.proxyConfigurations.count == 1);
            zw_web_surface_destroy(surface);
            assert(!child.UIDelegate && !child.navigationDelegate);
            view = nil;
            child = nil;
        }
        zw_web_surface_acceptance_counts(&owners, &handlers, &completed);
        assert(owners == 0 && handlers == 0 && zw_web_popup_acceptance_count() == 0);
        puts("PASS: popup shares the parent's exact isolated proxied WebsiteDataStore");
    }
    return 0;
}
