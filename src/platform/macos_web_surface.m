#import <AppKit/AppKit.h>
#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "macos_web_surface.h"

#ifdef ZW_WEB_SURFACE_ACCEPTANCE
static uint64_t zw_live_surface_owners;
static uint64_t zw_pending_completions;
static uint64_t zw_completed_handlers;

void zw_web_surface_acceptance_counts(uint64_t *owners, uint64_t *pending, uint64_t *completed) {
    *owners = zw_live_surface_owners;
    *pending = zw_pending_completions;
    *completed = zw_completed_handlers;
}

#define ZW_COMPLETE(...) do { \
    ++zw_pending_completions; \
    completion(__VA_ARGS__); \
    --zw_pending_completions; \
    ++zw_completed_handlers; \
} while (0)
#else
#define ZW_COMPLETE(...) completion(__VA_ARGS__)
#endif

// Main-thread process-wide identities prevent a reply from an old WebKit
// instance from matching a request in its replacement.
static uint64_t zw_next_request_token;
static const NSUInteger zw_request_capacity = 8;
#ifndef ZW_WEB_REQUEST_LIFETIME_NS
#define ZW_WEB_REQUEST_LIFETIME_NS (120 * NSEC_PER_SEC)
#endif
static const int64_t zw_request_lifetime = ZW_WEB_REQUEST_LIFETIME_NS;

@interface ZWWebPendingRequest : NSObject
@property (nonatomic) uint64_t token;
@property (nonatomic) uint64_t navigationId;
@property (nonatomic) int kind;
@property (nonatomic, copy) NSString *origin;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *defaultText;
@property (nonatomic, copy) NSString *realm;
@property (nonatomic, copy) NSString *tlsHost;
@property (nonatomic) uint16_t tlsPort;
@property (nonatomic, copy) NSArray<NSData *> *tlsChain;
@property (nonatomic, copy) void (^complete)(BOOL, NSString *, NSString *);
@end
@implementation ZWWebPendingRequest
@end

#if defined(ZW_WEB_SURFACE_HEADLESS)
static void *macos_get_metal_view(void *zenit_window) {
    (void)zenit_window;
    return NULL;
}
static int macos_set_embedded_input_view(void *view, int enabled, ZWWebHostKey host_key,
    ZWWebFocusEntered focus_entered, void *focus_context) {
    (void)view;
    (void)enabled;
    (void)host_key;
    (void)focus_entered;
    (void)focus_context;
    return 0;
}
#else
extern void *macos_get_metal_view(void *zenit_window);
extern int macos_set_embedded_input_view(void *view, int enabled, ZWWebHostKey host_key,
    ZWWebFocusEntered focus_entered, void *focus_context);
#endif

@interface ZWWebClipView : NSView
@property (nonatomic, copy) NSArray<NSValue *> *occlusions;
@property (nonatomic) NSRect maskedBounds;
- (BOOL)applyOcclusions:(NSArray<NSValue *> *)occlusions;
@end

static void zw_add_nonempty_rect(NSMutableArray<NSValue *> *rects, NSRect rect) {
    if (!NSIsEmptyRect(rect)) [rects addObject:[NSValue valueWithRect:rect]];
}

@implementation ZWWebClipView {
    BOOL _hasVisibleArea;
}
- (BOOL)applyOcclusions:(NSArray<NSValue *> *)occlusions {
    if ([self.occlusions isEqualToArray:occlusions] && NSEqualRects(self.maskedBounds, self.bounds)) {
        return _hasVisibleArea;
    }
    self.occlusions = occlusions;
    self.maskedBounds = self.bounds;
    if (occlusions.count == 0) {
        self.layer.mask = nil;
        _hasVisibleArea = YES;
        return YES;
    }

    // Subtract each cover from disjoint visible rectangles. Intersecting
    // overlays must remain covered where their rectangles overlap.
    NSMutableArray<NSValue *> *visible = [NSMutableArray arrayWithObject:[NSValue valueWithRect:self.bounds]];
    for (NSValue *cover in occlusions) {
        NSMutableArray<NSValue *> *remaining = [NSMutableArray array];
        for (NSValue *value in visible) {
            NSRect rect = value.rectValue;
            NSRect cut = NSIntersectionRect(rect, cover.rectValue);
            if (NSIsEmptyRect(cut)) {
                [remaining addObject:value];
                continue;
            }
            zw_add_nonempty_rect(remaining, NSMakeRect(NSMinX(rect), NSMinY(rect), NSWidth(rect), NSMinY(cut) - NSMinY(rect)));
            zw_add_nonempty_rect(remaining, NSMakeRect(NSMinX(rect), NSMaxY(cut), NSWidth(rect), NSMaxY(rect) - NSMaxY(cut)));
            zw_add_nonempty_rect(remaining, NSMakeRect(NSMinX(rect), NSMinY(cut), NSMinX(cut) - NSMinX(rect), NSHeight(cut)));
            zw_add_nonempty_rect(remaining, NSMakeRect(NSMaxX(cut), NSMinY(cut), NSMaxX(rect) - NSMaxX(cut), NSHeight(cut)));
        }
        visible = remaining;
        if (visible.count == 0) break;
    }
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSValue *value in visible) CGPathAddRect(path, NULL, NSRectToCGRect(value.rectValue));
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = self.layer.bounds;
    mask.path = path;
    CGPathRelease(path);
    self.layer.mask = mask;
    _hasVisibleArea = visible.count != 0;
    return _hasVisibleArea;
}

- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    for (NSValue *cover in self.occlusions) {
        if (NSPointInRect(local, cover.rectValue)) return nil;
    }
    return [super hitTest:point];
}
@end

@interface ZWWebSurfaceOwner : NSObject <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) ZWWebClipView *clipView;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) WKNavigation *activeNavigation;
@property (nonatomic, strong) WKNavigation *cancelledAuthNavigation;
@property (nonatomic, strong) NSHashTable<WKNavigation *> *retiredNavigations;
@property (nonatomic) ZWWebSurfaceChanged changed;
@property (nonatomic) uint64_t navigationId;
@property (nonatomic) uint64_t urlRevision;
@property (nonatomic) BOOL displayed;
@property (nonatomic) BOOL failed;
@property (nonatomic) BOOL tlsFailed;
@property (nonatomic) BOOL committed;
@property (nonatomic) BOOL committedGet;
@property (nonatomic, copy) NSURL *committedURL;
@property (nonatomic) BOOL activeGet;
@property (nonatomic) BOOL pendingGet;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL invalidatingRequests;
@property (nonatomic) BOOL tlsReview;
@property (nonatomic) NSUInteger tlsReviewsInFlight;
@property (nonatomic) uint64_t requestEpoch;
@property (nonatomic, copy) NSURL *mainFrameURL;
@property (nonatomic, strong) NSMutableArray<ZWWebPendingRequest *> *requests;
- (void)installWebView:(WKWebViewConfiguration *)configuration;
- (void)observeNavigation:(WKNavigation *)navigation explicitGet:(BOOL)explicitGet;
- (void)notifyChanged;
- (ZWWebPendingRequest *)enqueueKind:(int)kind origin:(NSString *)origin message:(NSString *)message
    defaultText:(NSString *)defaultText realm:(NSString *)realm
    completion:(void (^)(BOOL, NSString *, NSString *))completion;
- (BOOL)finishRequest:(uint64_t)token accepted:(BOOL)accepted value:(NSString *)value secret:(NSString *)secret;
- (void)cancelRequests;
- (void)notice:(NSString *)message origin:(NSString *)origin;
@end

static NSArray<NSString *> *zw_observed_properties(void) {
    return @[@"estimatedProgress", @"loading", @"URL", @"title"];
}

static BOOL zw_is_web_url(NSURL *url) {
    if (url.host.length == 0 || url.user || url.password) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static NSString *zw_origin(NSString *scheme, NSString *host, NSInteger port) {
    if (!scheme.length || !host.length) return @"不透明来源";
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]", host];
    BOOL defaultPort = port == 0 || ([scheme isEqualToString:@"https"] && port == 443)
        || ([scheme isEqualToString:@"http"] && port == 80);
    return defaultPort ? [NSString stringWithFormat:@"%@://%@", scheme, host]
        : [NSString stringWithFormat:@"%@://%@:%ld", scheme, host, (long)port];
}

static NSString *zw_frame_origin(WKFrameInfo *frame) {
    WKSecurityOrigin *origin = frame.securityOrigin;
    return zw_origin(origin.protocol, origin.host, origin.port);
}

static NSString *zw_url_origin(NSURL *url) {
    return zw_origin(url.scheme, url.host, url.port.integerValue);
}

static NSString *zw_bounded_text(NSString *text, NSUInteger maxBytes) {
    NSData *bytes = [(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length <= maxBytes) return text ?: @"";
    const uint8_t *raw = bytes.bytes;
    NSUInteger length = maxBytes;
    while (length && (raw[length] & 0xc0) == 0x80) --length;
    return [[NSString alloc] initWithBytes:raw length:length encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation ZWWebSurfaceOwner
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
- (void)dealloc {
    --zw_live_surface_owners;
}
#endif
- (void)installWebView:(WKWebViewConfiguration *)configuration {
    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    for (NSString *key in zw_observed_properties()) {
        [self.webView addObserver:self forKeyPath:key options:0 context:NULL];
    }
    [self.clipView addSubview:self.webView];
}
- (void)notifyChanged {
    if (self.changed) self.changed();
}
- (ZWWebPendingRequest *)enqueueKind:(int)kind origin:(NSString *)origin message:(NSString *)message
    defaultText:(NSString *)defaultText realm:(NSString *)realm
    completion:(void (^)(BOOL, NSString *, NSString *))completion {
    if (self.closing || self.invalidatingRequests || self.requests.count >= zw_request_capacity || zw_next_request_token == UINT64_MAX) {
        if (completion) completion(NO, nil, nil);
        return nil;
    }
    ZWWebPendingRequest *request = [[ZWWebPendingRequest alloc] init];
    request.token = ++zw_next_request_token;
    request.navigationId = self.navigationId;
    request.kind = kind;
    request.origin = zw_bounded_text(origin, 4096);
    request.message = zw_bounded_text(message, 8192);
    request.defaultText = zw_bounded_text(defaultText, 8192);
    request.realm = zw_bounded_text(realm, 4096);
    request.complete = completion;
    [self.requests addObject:request];
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    if (completion) ++zw_pending_completions;
#endif
    uint64_t token = request.token;
    __weak ZWWebSurfaceOwner *weakOwner = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, zw_request_lifetime), dispatch_get_main_queue(), ^{
        [weakOwner finishRequest:token accepted:NO value:nil secret:nil];
    });
    [self notifyChanged];
    return request;
}
- (BOOL)finishRequest:(uint64_t)token accepted:(BOOL)accepted value:(NSString *)value secret:(NSString *)secret {
    NSUInteger index = [self.requests indexOfObjectPassingTest:^BOOL(ZWWebPendingRequest *request, NSUInteger i, BOOL *stop) {
        return request.token == token;
    }];
    if (index == NSNotFound) return NO;
    ZWWebPendingRequest *request = self.requests[index];
    // Remove before invoking WebKit: a completion can cause a new callback.
    [self.requests removeObjectAtIndex:index];
    BOOL rejectedNavigationAuth = (request.kind == ZWWebRequestHTTPAuth || request.kind == ZWWebRequestServerTrust) && !accepted && !self.closing
        && !self.invalidatingRequests && !self.committed && request.navigationId == self.navigationId;
    if (rejectedNavigationAuth) {
        self.cancelledAuthNavigation = self.activeNavigation;
        if (request.kind == ZWWebRequestServerTrust) {
            self.failed = YES;
            self.tlsFailed = YES;
        }
    }
    void (^completion)(BOOL, NSString *, NSString *) = request.complete;
    request.complete = nil;
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    if (completion) --zw_pending_completions;
#endif
    if (completion) completion(accepted, value, secret);
    if (rejectedNavigationAuth) {
        // WebKit may keep a cancelled provisional authentication loader alive
        // until its next run-loop turn. Stop it before a subsequent user load.
        // Cancelling authentication for a committed page's subresource does
        // not discard that page.
        [self.webView stopLoading];
    }
    [self notifyChanged];
    return YES;
}
- (void)cancelRequests {
    // Complete only the original set; a reentrant callback belongs to its own
    // token and must not make cancellation an unbounded loop.
    self.requestEpoch += 1;
    BOOL invalidating = self.invalidatingRequests;
    self.invalidatingRequests = YES;
    NSArray<ZWWebPendingRequest *> *requests = [self.requests copy];
    for (ZWWebPendingRequest *request in requests) {
        [self finishRequest:request.token accepted:NO value:nil secret:nil];
    }
    self.invalidatingRequests = invalidating;
}
- (void)notice:(NSString *)message origin:(NSString *)origin {
    [self enqueueKind:ZWWebRequestNotice origin:origin message:message defaultText:nil realm:nil completion:nil];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"URL"]) self.urlRevision += 1;
    [self notifyChanged];
}
- (void)observeNavigation:(WKNavigation *)navigation explicitGet:(BOOL)explicitGet {
    if (!navigation) return;
    if (self.activeNavigation == navigation) {
        if (explicitGet) self.activeGet = YES;
        return;
    }
    if ([self.retiredNavigations containsObject:navigation]) return;
    if (self.activeNavigation) [self.retiredNavigations addObject:self.activeNavigation];
    [self cancelRequests];
    self.activeNavigation = navigation;
    self.cancelledAuthNavigation = nil;
    self.navigationId += 1;
    self.activeGet = explicitGet || self.pendingGet;
    self.pendingGet = NO;
    self.committed = NO;
    self.committedGet = NO;
    self.committedURL = nil;
    self.failed = NO;
    self.tlsFailed = NO;
    [self notifyChanged];
}
- (void)webView:(WKWebView *)view decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))completion {
    if (action.shouldPerformDownload) {
        [self notice:@"暂不支持下载文件。" origin:zw_frame_origin(action.sourceFrame)];
        ZW_COMPLETE(WKNavigationActionPolicyCancel);
        return;
    }
    if (action.targetFrame && !action.targetFrame.mainFrame) {
        ZW_COMPLETE(WKNavigationActionPolicyAllow);
        return;
    }
    BOOL allowed = zw_is_web_url(action.request.URL);
    BOOL isGet = [action.request.HTTPMethod isEqualToString:@"GET"];
    if (allowed && action.targetFrame) {
        self.mainFrameURL = action.request.URL;
        self.pendingGet = isGet;
        if (!self.committed) self.activeGet = isGet;
    }
    ZW_COMPLETE(allowed && action.targetFrame ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    if (allowed && !action.targetFrame && action.navigationType == WKNavigationTypeLinkActivated && isGet) {
        [self observeNavigation:[view loadRequest:action.request] explicitGet:YES];
    } else if (!action.targetFrame || !allowed) {
        [self notice:!action.targetFrame ? @"暂不支持此网页弹窗。" : @"暂不支持打开此类型的链接。"
            origin:zw_frame_origin(action.sourceFrame)];
    }
}
- (void)webView:(WKWebView *)view decidePolicyForNavigationResponse:(WKNavigationResponse *)response
    decisionHandler:(void (^)(WKNavigationResponsePolicy))completion {
    NSHTTPURLResponse *http = [response.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)response.response : nil;
    NSString *disposition = [http valueForHTTPHeaderField:@"Content-Disposition"];
    BOOL attachment = [[[disposition stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
        lowercaseString] hasPrefix:@"attachment"];
    if (!response.canShowMIMEType || attachment) {
        [self notice:@"暂不支持下载文件。" origin:zw_url_origin(response.response.URL)];
        ZW_COMPLETE(WKNavigationResponsePolicyCancel);
        if (response.isForMainFrame) {
            self.failed = YES;
            [self notifyChanged];
        }
    } else {
        ZW_COMPLETE(WKNavigationResponsePolicyAllow);
    }
}
- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self observeNavigation:navigation explicitGet:NO];
    self.pendingGet = NO;
}
- (void)webView:(WKWebView *)view didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
    // A redirect does not by itself change GET into an unsafe method. Any
    // redirected action supplies its actual method through the policy callback.
    if (navigation == self.activeNavigation) [self notifyChanged];
}
- (void)webView:(WKWebView *)view didCommitNavigation:(WKNavigation *)navigation {
    if (navigation != self.activeNavigation) return;
    if (navigation == self.cancelledAuthNavigation) self.cancelledAuthNavigation = nil;
    self.displayed = YES;
    self.committed = YES;
    self.committedGet = self.activeGet;
    self.committedURL = view.URL;
    self.pendingGet = NO;
    [self notifyChanged];
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
    if (navigation == self.activeNavigation) [self notifyChanged];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    BOOL cancelledAuthentication = navigation == self.cancelledAuthNavigation;
    if (cancelledAuthentication) self.cancelledAuthNavigation = nil;
    if (navigation == self.activeNavigation && (cancelledAuthentication || error.code != NSURLErrorCancelled)) {
        self.failed = YES;
        self.tlsFailed = self.tlsFailed || ([error.domain isEqualToString:NSURLErrorDomain] &&
            (error.code == NSURLErrorServerCertificateUntrusted ||
             error.code == NSURLErrorServerCertificateHasUnknownRoot ||
             error.code == NSURLErrorServerCertificateHasBadDate ||
             error.code == NSURLErrorServerCertificateNotYetValid));
        [self notifyChanged];
    }
}
- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:view didFailProvisionalNavigation:navigation withError:error];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view {
    [self cancelRequests];
    self.displayed = NO;
    self.failed = YES;
    [self notifyChanged];
}
- (void)webView:(WKWebView *)view runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completion {
    [self enqueueKind:ZWWebRequestAlert origin:zw_frame_origin(frame) message:message defaultText:nil realm:nil
        completion:^(BOOL accepted, NSString *value, NSString *secret) { ZW_COMPLETE(); }];
}
- (void)webView:(WKWebView *)view runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completion {
    [self enqueueKind:ZWWebRequestConfirm origin:zw_frame_origin(frame) message:message defaultText:nil realm:nil
        completion:^(BOOL accepted, NSString *value, NSString *secret) { ZW_COMPLETE(accepted); }];
}
- (void)webView:(WKWebView *)view runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(NSString *))completion {
    [self enqueueKind:ZWWebRequestPrompt origin:zw_frame_origin(frame) message:prompt defaultText:defaultText realm:nil
        completion:^(BOOL accepted, NSString *value, NSString *secret) { ZW_COMPLETE(accepted ? (value ?: @"") : nil); }];
}
- (void)webView:(WKWebView *)view runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completion {
    [self notice:@"暂不支持上传文件。" origin:zw_frame_origin(frame)];
    ZW_COMPLETE(nil);
}
- (WKWebView *)webView:(WKWebView *)view createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    [self notice:@"暂不支持此网页弹窗。" origin:zw_frame_origin(action.sourceFrame)];
    return nil;
}
- (void)webView:(WKWebView *)view didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if ([space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSString *origin = zw_origin(space.protocol, space.host, space.port);
        NSURL *target = self.mainFrameURL;
        SecTrustRef trust = space.serverTrust;
        if (!self.tlsReview || !trust || space.isProxy || challenge.previousFailureCount ||
            !target || ![target.scheme.lowercaseString isEqualToString:@"https"] ||
            ![origin.lowercaseString isEqualToString:zw_url_origin(target).lowercaseString] ||
            space.port < 1 || space.port > UINT16_MAX) {
            ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            return;
        }
        // Copy the peer data off the AppKit thread. Reject late completions
        // after navigation or surface teardown.
        if (self.invalidatingRequests || self.tlsReviewsInFlight >= zw_request_capacity) {
            ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }
        self.tlsReviewsInFlight += 1;
        uint64_t requestEpoch = self.requestEpoch;
        uint64_t navigationId = self.navigationId;
        id retainedTrust = (__bridge id)trust;
        __weak ZWWebSurfaceOwner *weakOwner = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SecTrustRef peer = (__bridge SecTrustRef)retainedTrust;
            SecTrustSetNetworkFetchAllowed(peer, false);
            NSArray *certs = CFBridgingRelease(SecTrustCopyCertificateChain(peer));
            NSMutableArray<NSData *> *chain = [NSMutableArray array];
            size_t total = 0;
            if (certs.count <= 16) for (id cert in certs) {
                NSData *der = CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)cert));
                if (!der.length || der.length > 1024 * 1024 - total) { [chain removeAllObjects]; break; }
                total += der.length;
                [chain addObject:der];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                ZWWebSurfaceOwner *owner = weakOwner;
                if (owner) owner.tlsReviewsInFlight -= 1;
                if (!owner || owner.closing || owner.requestEpoch != requestEpoch || owner.navigationId != navigationId ||
                    ![origin.lowercaseString isEqualToString:zw_url_origin(owner.mainFrameURL).lowercaseString]) {
                    ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
                    return;
                }
                if (chain.count == 0) {
                    ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
                    return;
                }
                ZWWebPendingRequest *request = [owner enqueueKind:ZWWebRequestServerTrust origin:origin message:nil
                    defaultText:nil realm:nil completion:^(BOOL accepted, NSString *value, NSString *secret) {
                        if (accepted && [value isEqualToString:@"exception"]) {
                            NSURLCredential *credential = [NSURLCredential credentialForTrust:(__bridge SecTrustRef)retainedTrust];
                            ZW_COMPLETE(NSURLSessionAuthChallengeUseCredential, credential);
                        } else if (accepted && [value isEqualToString:@"system"]) {
                            ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
                        } else {
                            ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
                        }
                    }];
                request.tlsHost = space.host;
                request.tlsPort = (uint16_t)space.port;
                request.tlsChain = chain;
            });
        });
        return;
    }
    BOOL passwordAuth = [space.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]
        || [space.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPDigest];
    if (!passwordAuth || space.isProxy) {
        ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    if (challenge.previousFailureCount >= 3) {
        [self notice:@"网站认证失败，请重新加载后重试。"
            origin:zw_origin(space.protocol, space.host, space.port)];
        ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }
    [self enqueueKind:ZWWebRequestHTTPAuth origin:zw_origin(space.protocol, space.host, space.port)
        message:challenge.previousFailureCount ? @"用户名或密码不正确，请重试。" : @"此网站需要用户名和密码。"
        defaultText:nil realm:space.realm completion:^(BOOL accepted, NSString *value, NSString *secret) {
            NSURLCredential *credential = accepted ? [NSURLCredential credentialWithUser:value ?: @""
                password:secret ?: @"" persistence:NSURLCredentialPersistenceNone] : nil;
            ZW_COMPLETE(accepted ? NSURLSessionAuthChallengeUseCredential : NSURLSessionAuthChallengeCancelAuthenticationChallenge, credential);
        }];
}
@end

static ZWWebSurfaceOwner *zw_surface_owner(void) {
    ZWWebSurfaceOwner *owner = [[ZWWebSurfaceOwner alloc] init];
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    if (owner) ++zw_live_surface_owners;
#endif
    owner.retiredNavigations = [NSHashTable weakObjectsHashTable];
    owner.requests = [NSMutableArray array];
    owner.clipView = [[ZWWebClipView alloc] initWithFrame:NSZeroRect];
    owner.clipView.wantsLayer = YES;
    owner.clipView.layer.masksToBounds = YES;
    owner.clipView.hidden = YES;
    return owner;
}

int zw_web_surface_supports_proxy(void) {
    if (@available(macOS 14.0, *)) return 1;
    return 0;
}

ZWWebSurface *zw_web_surface_create(void) {
    if (!NSThread.isMainThread) return NULL;
    @autoreleasepool {
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        ZWWebSurfaceOwner *owner = zw_surface_owner();
        [owner installWebView:configuration];
        return (__bridge_retained ZWWebSurface *)owner;
    }
}

ZWWebSurface *zw_web_surface_create_proxied(uint16_t port, const uint8_t *username,
    size_t username_len, const uint8_t *password, size_t password_len) {
    if (!NSThread.isMainThread || !port || !username || !password || !username_len ||
        !password_len || username_len > 255 || password_len > 255 ||
        memchr(username, 0, username_len) || memchr(password, 0, password_len)) return NULL;
    if (@available(macOS 14.0, *)) {
        @autoreleasepool {
            NSString *user = [[NSString alloc] initWithBytes:username length:username_len encoding:NSUTF8StringEncoding];
            NSString *secret = [[NSString alloc] initWithBytes:password length:password_len encoding:NSUTF8StringEncoding];
            if (!user || !secret) return NULL;
            char service[6];
            snprintf(service, sizeof(service), "%u", (unsigned int)port);
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", service);
            if (!endpoint) return NULL;
            nw_proxy_config_t proxy = nw_proxy_config_create_socksv5(endpoint);
            if (!proxy) return NULL;
            nw_proxy_config_set_username_and_password(proxy, user.UTF8String, secret.UTF8String);
            nw_proxy_config_set_failover_allowed(proxy, false);
            WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
            configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
            configuration.websiteDataStore.proxyConfigurations = @[proxy];
            ZWWebSurfaceOwner *owner = zw_surface_owner();
            [owner installWebView:configuration];
            return (__bridge_retained ZWWebSurface *)owner;
        }
    }
    return NULL;
}

void zw_web_surface_set_change_callback(ZWWebSurface *surface, ZWWebSurfaceChanged callback) {
    if (!NSThread.isMainThread || !surface) return;
    ((__bridge ZWWebSurfaceOwner *)surface).changed = callback;
}

static NSRect zw_view_rect(NSView *view, ZWWebRect logical) {
    NSRect bounds = view.bounds;
    return NSMakeRect(NSMinX(bounds) + logical.x,
        NSMaxY(bounds) - logical.y - logical.h, logical.w, logical.h);
}

int zw_web_surface_sync(ZWWebSurface *surface, void *zenit_window, ZWWebRect slot,
    ZWWebRect clip, const ZWWebRect *occlusions, size_t occlusion_count, int visible, ZWWebHostKey host_key,
    ZWWebFocusEntered focus_entered, void *focus_context) {
    if (!NSThread.isMainThread || !surface || !zenit_window) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        ZWWebClipView *container = owner.clipView;
        NSView *parent = (__bridge NSView *)macos_get_metal_view(zenit_window);
        if (!parent.window || (container.superview && container.superview != parent)) return 0;

        NSRect document = zw_view_rect(parent, slot);
        NSRect clipped = NSIntersectionRect(NSIntersectionRect(document, zw_view_rect(parent, clip)), parent.bounds);
        if (!owner.webView || !visible || NSIsEmptyRect(clipped)) {
            if (container.superview) macos_set_embedded_input_view((__bridge void *)container, 0, NULL, NULL, NULL);
            container.hidden = YES;
            return 1;
        }

        if (!container.superview) [parent addSubview:container positioned:NSWindowAbove relativeTo:nil];
        if (!NSEqualRects(container.frame, clipped)) container.frame = clipped;
        NSRect webFrame = [container convertRect:document fromView:parent];
        if (!NSEqualRects(owner.webView.frame, webFrame)) owner.webView.frame = webFrame;
        NSMutableArray<NSValue *> *covers = [NSMutableArray array];
        for (size_t i = 0; i < occlusion_count; ++i) {
            NSRect cover = NSIntersectionRect(clipped, zw_view_rect(parent, occlusions[i]));
            zw_add_nonempty_rect(covers, [container convertRect:cover fromView:parent]);
        }
        BOOL exposed = [container applyOcclusions:covers];
        if (!macos_set_embedded_input_view((__bridge void *)container, exposed, host_key, focus_entered, focus_context)) return 0;
        container.hidden = !exposed;
        return 1;
    }
}

void zw_web_surface_detach(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        macos_set_embedded_input_view((__bridge void *)owner.clipView, 0, NULL, NULL, NULL);
        owner.clipView.hidden = YES;
        [owner.clipView removeFromSuperview];
    }
}

void zw_web_surface_release_focus(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool {
        NSView *container = ((__bridge ZWWebSurfaceOwner *)surface).clipView;
        NSWindow *window = container.window;
        NSResponder *responder = window.firstResponder;
        if ([responder isKindOfClass:[NSView class]] && [(NSView *)responder isDescendantOf:container]) {
            [window makeFirstResponder:container.superview];
        }
    }
}

void zw_web_surface_destroy(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool {
        zw_web_surface_detach(surface);
        ZWWebSurfaceOwner *owner = (__bridge_transfer ZWWebSurfaceOwner *)surface;
        owner.closing = YES;
        owner.changed = NULL;
        [owner cancelRequests];
        owner.webView.navigationDelegate = nil;
        owner.webView.UIDelegate = nil;
        for (NSString *key in zw_observed_properties()) {
            [owner.webView removeObserver:owner forKeyPath:key];
        }
        [owner.webView stopLoading];
        [owner.webView removeFromSuperview];
        owner.webView = nil;
        owner.clipView = nil;
    }
}

int zw_web_surface_navigate(ZWWebSurface *surface, const uint8_t *url, size_t len) {
    if (!NSThread.isMainThread || !surface || !url || !len) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        NSString *value = [[NSString alloc] initWithBytes:url length:len encoding:NSUTF8StringEncoding];
        NSURL *target = value ? [NSURL URLWithString:value] : nil;
        if (!owner.webView || !zw_is_web_url(target)) return 0;
        owner.mainFrameURL = target;
        WKNavigation *navigation = [owner.webView loadRequest:[NSURLRequest requestWithURL:target]];
        [owner observeNavigation:navigation explicitGet:YES];
        return navigation != nil;
    }
}

int zw_web_surface_go_back(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        owner.mainFrameURL = owner.webView.backForwardList.backItem.URL;
        WKNavigation *navigation = [owner.webView goBack];
        [owner observeNavigation:navigation explicitGet:NO];
        return navigation != nil;
    }
}

int zw_web_surface_go_forward(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        owner.mainFrameURL = owner.webView.backForwardList.forwardItem.URL;
        WKNavigation *navigation = [owner.webView goForward];
        [owner observeNavigation:navigation explicitGet:NO];
        return navigation != nil;
    }
}

int zw_web_surface_reload(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        WKNavigation *navigation = [owner.webView reload];
        [owner observeNavigation:navigation explicitGet:NO];
        return navigation != nil;
    }
}

void zw_web_surface_stop(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        [owner cancelRequests];
        [owner.webView stopLoading];
    }
}

void zw_web_request_dispose(ZWWebRequest *request) {
    if (!request) return;
    free(request->origin);
    free(request->message);
    free(request->default_text);
    free(request->realm);
    *request = (ZWWebRequest){0};
}

static char *zw_copy_request_text(NSString *text) {
    const char *utf8 = text.UTF8String;
    return strdup(utf8 ?: "");
}

int zw_web_surface_copy_request(ZWWebSurface *surface, ZWWebRequest *result) {
    if (!NSThread.isMainThread || !surface || !result) return 0;
    *result = (ZWWebRequest){0};
    @autoreleasepool {
        ZWWebPendingRequest *request = ((__bridge ZWWebSurfaceOwner *)surface).requests.firstObject;
        if (!request) return 0;
        *result = (ZWWebRequest){
            .token = request.token,
            .navigation_id = request.navigationId,
            .kind = request.kind,
            .origin = zw_copy_request_text(request.origin),
            .message = zw_copy_request_text(request.message),
            .default_text = zw_copy_request_text(request.defaultText),
            .realm = zw_copy_request_text(request.realm),
        };
        if (!result->origin || !result->message || !result->default_text || !result->realm) {
            zw_web_request_dispose(result);
            return -1;
        }
        return 1;
    }
}

int zw_web_surface_set_tls_review(ZWWebSurface *surface, int enabled) {
    if (!NSThread.isMainThread || !surface) return 0;
    ((__bridge ZWWebSurfaceOwner *)surface).tlsReview = enabled != 0;
    return 1;
}

size_t zw_web_surface_tls_peer(ZWWebSurface *surface, uint64_t token, const char **host,
    uint16_t *port, ZWWebCertificate *certificates, size_t capacity) {
    if (!NSThread.isMainThread || !surface || !host || !port || !certificates) return 0;
    for (ZWWebPendingRequest *request in ((__bridge ZWWebSurfaceOwner *)surface).requests) {
        if (request.token != token || request.kind != ZWWebRequestServerTrust) continue;
        if (!request.tlsChain.count || request.tlsChain.count > capacity) return 0;
        *host = request.tlsHost.UTF8String;
        *port = request.tlsPort;
        for (size_t i = 0; i < request.tlsChain.count; ++i) {
            NSData *der = request.tlsChain[i];
            certificates[i] = (ZWWebCertificate){ der.bytes, der.length };
        }
        return request.tlsChain.count;
    }
    return 0;
}

int zw_web_surface_request_pending(ZWWebSurface *surface, uint64_t token) {
    if (!NSThread.isMainThread || !surface || !token) return 0;
    for (ZWWebPendingRequest *request in ((__bridge ZWWebSurfaceOwner *)surface).requests) {
        if (request.token == token) return 1;
    }
    return 0;
}

int zw_web_surface_reply_request(ZWWebSurface *surface, uint64_t token, int accepted,
    const uint8_t *value, size_t value_len, const uint8_t *secret, size_t secret_len) {
    if (!NSThread.isMainThread || !surface || !token || value_len > 8192 || secret_len > 8192
        || (!value && value_len) || (!secret && secret_len)) return 0;
    @autoreleasepool {
        NSString *text = value_len ? [[NSString alloc] initWithBytes:value length:value_len encoding:NSUTF8StringEncoding] : @"";
        NSString *password = secret_len ? [[NSString alloc] initWithBytes:secret length:secret_len encoding:NSUTF8StringEncoding] : @"";
        if (accepted && (!text || !password)) return 0;
        return [(__bridge ZWWebSurfaceOwner *)surface finishRequest:token accepted:accepted != 0 value:text secret:password];
    }
}

void zw_web_surface_cancel_requests(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool { [(__bridge ZWWebSurfaceOwner *)surface cancelRequests]; }
}

ZWWebSurfaceState zw_web_surface_state(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return (ZWWebSurfaceState){0};
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        WKWebView *view = owner.webView;
        return (ZWWebSurfaceState){
            .progress = view.estimatedProgress,
            .navigation_id = owner.navigationId,
            .url_revision = owner.urlRevision,
            .can_go_back = view.canGoBack,
            .can_go_forward = view.canGoForward,
            .loading = view.loading,
            .displayed = owner.displayed,
            .failed = owner.failed,
            .ready = view != nil,
            .committed = owner.committed,
            .committed_get = owner.committedGet && [owner.committedURL isEqual:view.URL],
            .tls_failed = owner.tlsFailed,
        };
    }
}

char *zw_web_surface_copy_url(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return NULL;
    @autoreleasepool {
        const char *value = ((__bridge ZWWebSurfaceOwner *)surface).webView.URL.absoluteString.UTF8String;
        return value ? strdup(value) : NULL;
    }
}

char *zw_web_surface_copy_title(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return NULL;
    @autoreleasepool {
        const char *value = ((__bridge ZWWebSurfaceOwner *)surface).webView.title.UTF8String;
        return value ? strdup(value) : NULL;
    }
}
