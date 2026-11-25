#import <AppKit/AppKit.h>
#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "macos_web_surface.h"

// WebKit exposes the local inspector through private selectors. Check availability before use.
@protocol ZWNativeWebInspector
- (void)showConsole;
- (void)close;
@end

@interface WKWebView (ZWNativeConsole)
- (id<ZWNativeWebInspector>)_inspector;
@end

@interface WKPreferences (ZWNativeConsole)
- (void)_setDeveloperExtrasEnabled:(BOOL)enabled;
@end

#ifdef ZW_WEB_SURFACE_ACCEPTANCE
static uint64_t zw_live_surface_owners;
static uint64_t zw_live_popup_owners;
static uint64_t zw_pending_completions;
static uint64_t zw_completed_handlers;

void zw_web_surface_acceptance_counts(uint64_t *owners, uint64_t *pending, uint64_t *completed) {
    *owners = zw_live_surface_owners;
    *pending = zw_pending_completions;
    *completed = zw_completed_handlers;
}

uint64_t zw_web_popup_acceptance_count(void) {
    return zw_live_popup_owners;
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
@property (nonatomic, strong) NSWindow *presentation;
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
    ZWWebInputCallback focus_entered, ZWWebInputCallback left_press, void *input_context) {
    (void)view;
    (void)enabled;
    (void)host_key;
    (void)focus_entered;
    (void)left_press;
    (void)input_context;
    return 0;
}
#else
extern void *macos_get_metal_view(void *zenit_window);
extern int macos_set_embedded_input_view(void *view, int enabled, ZWWebHostKey host_key,
    ZWWebInputCallback focus_entered, ZWWebInputCallback left_press, void *input_context);
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

@class ZWWebPopupOwner;

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
@property (nonatomic) BOOL popupsRetired;
@property (nonatomic) BOOL invalidatingRequests;
@property (nonatomic) BOOL tlsReview;
@property (nonatomic) NSUInteger tlsReviewsInFlight;
@property (nonatomic) uint64_t requestEpoch;
@property (nonatomic, copy) NSURL *mainFrameURL;
@property (nonatomic, strong) NSMutableArray<ZWWebPendingRequest *> *requests;
@property (nonatomic, strong) NSMutableArray<ZWWebPopupOwner *> *popups;
@property (nonatomic, copy) NSString *popupOwnerText;
@property (nonatomic, strong) id<ZWNativeWebInspector> nativeInspector;
- (void)installWebView:(WKWebViewConfiguration *)configuration;
- (void)observeNavigation:(WKNavigation *)navigation explicitGet:(BOOL)explicitGet;
- (void)notifyChanged;
- (ZWWebPendingRequest *)enqueueKind:(int)kind origin:(NSString *)origin message:(NSString *)message
    defaultText:(NSString *)defaultText realm:(NSString *)realm
    completion:(void (^)(BOOL, NSString *, NSString *))completion;
- (BOOL)finishRequest:(uint64_t)token accepted:(BOOL)accepted value:(NSString *)value secret:(NSString *)secret;
- (void)cancelRequests;
- (void)notice:(NSString *)message origin:(NSString *)origin;
- (void)forgetPopup:(ZWWebPopupOwner *)popup;
- (void)closeAllPopups;
- (BOOL)popupTlsReview;
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

static size_t zw_live_popup_count(ZWWebSurfaceOwner *owner);

static const NSUInteger zw_max_popups_per_session = 8;
static const CGFloat zw_popup_toolbar_height = 38.0;
static const CGFloat zw_popup_default_width = 1280.0;
static const CGFloat zw_popup_default_height = 800.0;
static const CGFloat zw_popup_min_width = 480.0;
static const CGFloat zw_popup_min_height = 360.0;

static NSImage *zw_popup_symbol(NSString *name, NSString *description) {
    if (@available(macOS 11.0, *)) {
        return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    }
    return nil;
}

static void zw_popup_set_button_symbol(NSButton *button, NSString *symbol, NSString *fallback) {
    NSImage *image = zw_popup_symbol(symbol, fallback);
    if (image) {
        button.image = image;
        button.title = @"";
        button.imagePosition = NSImageOnly;
    } else {
        button.image = nil;
        button.title = fallback;
        button.imagePosition = NSNoImage;
    }
}

static NSButton *zw_popup_button(NSString *symbol, NSString *fallback, NSString *accessibility) {
    NSButton *button = [NSButton buttonWithTitle:fallback target:nil action:nil];
    button.bordered = NO;
    button.focusRingType = NSFocusRingTypeNone;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = accessibility;
    button.imagePosition = NSNoImage;
    zw_popup_set_button_symbol(button, symbol, fallback);
    return button;
}

static NSTextField *zw_popup_label(NSString *value, CGFloat size, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:value ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:NSFontWeightMedium];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    label.cell.truncatesLastVisibleLine = YES;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    return label;
}

static BOOL zw_is_popup_initial_url(NSURL *url) {
    if (!url) return YES;
    if ([url.absoluteString isEqualToString:@"about:blank"]) return YES;
    return zw_is_web_url(url);
}

static BOOL zw_is_popup_navigation_url(NSURL *url, BOOL committed) {
    if (zw_is_web_url(url)) return YES;
    return !committed && [url.absoluteString isEqualToString:@"about:blank"];
}

static BOOL zw_is_popup_subframe_url(NSURL *url) {
    if (zw_is_web_url(url)) return YES;
    return [url.scheme.lowercaseString isEqualToString:@"about"];
}

static NSRect zw_popup_window_frame(NSWindow *parent, WKWindowFeatures *features) {
    NSScreen *screen = parent.screen ?: NSScreen.mainScreen;
    if (!screen && NSScreen.screens.count) screen = NSScreen.screens.firstObject;
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, zw_popup_default_width, zw_popup_default_height);
    CGFloat width = features.width ? features.width.doubleValue : zw_popup_default_width;
    CGFloat height = features.height ? features.height.doubleValue : zw_popup_default_height;
    if (!isfinite(width)) width = zw_popup_default_width;
    if (!isfinite(height)) height = zw_popup_default_height;
    width = MIN(MAX(width, zw_popup_min_width), MAX(zw_popup_min_width, NSWidth(visible)));
    height = MIN(MAX(height, zw_popup_min_height), MAX(zw_popup_min_height, NSHeight(visible)));
    NSRect frame = NSMakeRect(0, 0, width, height);
    CGFloat x = features.x ? features.x.doubleValue : NAN;
    CGFloat y = features.y ? features.y.doubleValue : NAN;
    if (isfinite(x) && isfinite(y)) {
        // WKWindowFeatures reports screen-space x/y with a top-left origin.
        frame.origin.x = x;
        frame.origin.y = NSMaxY(visible) - y - height;
    } else if (parent) {
        frame.origin.x = NSMidX(parent.frame) - width / 2;
        frame.origin.y = NSMaxY(parent.frame) - height - 48;
    } else {
        frame.origin.x = NSMidX(visible) - width / 2;
        frame.origin.y = NSMidY(visible) - height / 2;
    }
    frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)), NSMaxX(visible) - width);
    frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)), NSMaxY(visible) - height);
    return NSIntegralRect(frame);
}

@class ZWWebPopupOwner;

@interface ZWWebPopupWindow : NSWindow
@property (nonatomic, weak) ZWWebPopupOwner *popupOwner;
@end

@interface ZWWebPopupToolbarView : NSVisualEffectView
@property (nonatomic, strong) NSView *ownerBadge;
@property (nonatomic, strong) NSTextField *ownerLabel;
@property (nonatomic, strong) NSView *urlPill;
@property (nonatomic, strong) NSImageView *tlsIcon;
@property (nonatomic, strong) NSTextField *urlLabel;
@property (nonatomic, strong) NSButton *urlCopyButton;
@property (nonatomic, strong) NSButton *reloadButton;
@property (nonatomic, strong) NSButton *fullScreenButton;
@property (nonatomic, strong) NSButton *closeButton;
- (void)layoutNow;
- (void)applyAppearance;
@end

@implementation ZWWebPopupToolbarView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.material = NSVisualEffectMaterialHeaderView;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.state = NSVisualEffectStateActive;
    self.wantsLayer = YES;

    _ownerBadge = [[NSView alloc] initWithFrame:NSZeroRect];
    _ownerBadge.wantsLayer = YES;
    _ownerBadge.layer.cornerRadius = 10;
    [self addSubview:_ownerBadge];
    _ownerLabel = zw_popup_label(@"关联自: 浏览器", 11, NSColor.secondaryLabelColor);
    [_ownerBadge addSubview:_ownerLabel];

    _urlPill = [[NSView alloc] initWithFrame:NSZeroRect];
    _urlPill.wantsLayer = YES;
    _urlPill.layer.cornerRadius = 8;
    [self addSubview:_urlPill];
    _tlsIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _tlsIcon.imageScaling = NSImageScaleProportionallyDown;
    [_urlPill addSubview:_tlsIcon];
    _urlLabel = zw_popup_label(@"about:blank", 11, NSColor.labelColor);
    _urlLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_urlPill addSubview:_urlLabel];
    _urlCopyButton = zw_popup_button(@"doc.on.doc", @"⧉", @"复制网址");
    _urlCopyButton.contentTintColor = NSColor.secondaryLabelColor;
    [_urlPill addSubview:_urlCopyButton];

    _reloadButton = zw_popup_button(@"arrow.clockwise", @"↻", @"刷新");
    _fullScreenButton = zw_popup_button(@"arrow.up.left.and.arrow.down.right", @"⤢", @"全屏");
    _closeButton = zw_popup_button(@"xmark", @"×", @"关闭子窗口");
    for (NSButton *button in @[_reloadButton, _fullScreenButton, _closeButton]) [self addSubview:button];
    [self applyAppearance];
    [self layoutNow];
    return self;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyAppearance];
}
- (void)applyAppearance {
    self.ownerBadge.layer.backgroundColor = [NSColor.controlBackgroundColor colorWithAlphaComponent:0.55].CGColor;
    self.urlPill.layer.backgroundColor = [NSColor.textBackgroundColor colorWithAlphaComponent:0.45].CGColor;
}
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutNow];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}
- (void)layoutNow {
    CGFloat width = self.bounds.size.width;
    CGFloat bar = NSHeight(self.bounds);
    CGFloat button = 24;
    CGFloat gap = 2;
    CGFloat right = width - 8;
    CGFloat closeX = right - button;
    CGFloat fullX = closeX - gap - button;
    CGFloat reloadX = fullX - gap - button;
    self.closeButton.frame = NSMakeRect(closeX, (bar - button) / 2, button, button);
    self.fullScreenButton.frame = NSMakeRect(fullX, (bar - button) / 2, button, button);
    self.reloadButton.frame = NSMakeRect(reloadX, (bar - button) / 2, button, button);

    CGFloat left = 78;
    [self.ownerLabel sizeToFit];
    CGFloat badge = MIN(MAX((CGFloat)72, MIN((CGFloat)280, width * 0.34)), MAX((CGFloat)72, self.ownerLabel.frame.size.width + 16));
    self.ownerBadge.frame = NSMakeRect(left, (bar - 22) / 2, badge, 22);
    self.ownerLabel.frame = NSMakeRect(8, 2, MAX((CGFloat)0, badge - 16), 18);

    CGFloat urlX = NSMaxX(self.ownerBadge.frame) + 8;
    CGFloat urlWidth = MAX((CGFloat)80, reloadX - 8 - urlX);
    self.urlPill.frame = NSMakeRect(urlX, (bar - 28) / 2, urlWidth, 28);
    self.tlsIcon.frame = NSMakeRect(8, 6, 16, 16);
    self.urlCopyButton.frame = NSMakeRect(urlWidth - 8 - 22, 3, 22, 22);
    self.urlLabel.frame = NSMakeRect(28, 5, MAX((CGFloat)0, urlWidth - 28 - 8 - 22 - 4), 18);
}
@end

@interface ZWWebPopupOwner : NSObject <WKNavigationDelegate, WKUIDelegate, NSWindowDelegate>
@property (nonatomic, weak) ZWWebSurfaceOwner *surface;
@property (nonatomic, strong) ZWWebPopupWindow *window;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) ZWWebPopupToolbarView *toolbar;
@property (nonatomic, strong) NSMutableArray<ZWWebPendingRequest *> *requests;
@property (nonatomic, copy) NSString *ownerText;
@property (nonatomic, strong) NSURL *pendingURL;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL committed;
@property (nonatomic) BOOL tlsReview;
- (instancetype)initWithSurface:(ZWWebSurfaceOwner *)surface configuration:(WKWebViewConfiguration *)configuration
    action:(WKNavigationAction *)action features:(WKWindowFeatures *)features;
- (void)present;
- (void)closePopup;
- (void)releasePopupClosingWindow:(BOOL)closeWindow;
- (void)updateOwnerText:(NSString *)text;
- (void)refreshToolbar;
- (void)copyURL:(id)sender;
- (void)reloadOrStop:(id)sender;
- (void)toggleFullScreen:(id)sender;
- (void)closePressed:(id)sender;
@end

@implementation ZWWebPopupWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)performClose:(id)sender {
    if (self.popupOwner) {
        [self.popupOwner closePopup];
    } else {
        [super performClose:sender];
    }
}
@end

@implementation ZWWebPopupOwner {
    BOOL _observing;
}
- (instancetype)initWithSurface:(ZWWebSurfaceOwner *)surface configuration:(WKWebViewConfiguration *)configuration
    action:(WKNavigationAction *)action features:(WKWindowFeatures *)features {
    if (!surface || !configuration) return nil;
    self = [super init];
    if (!self) return nil;
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    ++zw_live_popup_owners;
#endif
    _surface = surface;
    _requests = [NSMutableArray array];
    _ownerText = [surface.popupOwnerText copy] ?: @"关联自: 浏览器";
    _tlsReview = [surface popupTlsReview];
    _pendingURL = action.request.URL;

    _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    for (NSString *key in @[@"loading", @"title", @"URL", @"estimatedProgress"]) {
        [_webView addObserver:self forKeyPath:key options:0 context:NULL];
    }
    _observing = YES;

    NSRect frame = zw_popup_window_frame(surface.webView.window, features);
    _window = [[ZWWebPopupWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
        backing:NSBackingStoreBuffered defer:NO];
    _window.popupOwner = self;
    _window.delegate = self;
    _window.releasedWhenClosed = NO;
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    _window.backgroundColor = NSColor.windowBackgroundColor;
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.minSize = NSMakeSize(zw_popup_min_width, zw_popup_min_height);
    _window.title = @"子窗口";

    _toolbar = [[ZWWebPopupToolbarView alloc] initWithFrame:NSMakeRect(0, frame.size.height - zw_popup_toolbar_height,
        frame.size.width, zw_popup_toolbar_height)];
    _toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _toolbar.ownerLabel.stringValue = _ownerText;
    _toolbar.urlCopyButton.target = self;
    _toolbar.urlCopyButton.action = @selector(copyURL:);
    _toolbar.reloadButton.target = self;
    _toolbar.reloadButton.action = @selector(reloadOrStop:);
    _toolbar.fullScreenButton.target = self;
    _toolbar.fullScreenButton.action = @selector(toggleFullScreen:);
    _toolbar.closeButton.target = self;
    _toolbar.closeButton.action = @selector(closePressed:);

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _webView.frame = NSMakeRect(0, 0, frame.size.width, MAX((CGFloat)0, frame.size.height - zw_popup_toolbar_height));
    _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_webView];
    [content addSubview:_toolbar];
    _window.contentView = content;
    [self refreshToolbar];
    return self;
}
- (void)dealloc {
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    --zw_live_popup_owners;
#endif
    if (self.requests.count) [self cancelRequests];
    if (_observing) {
        for (NSString *key in @[@"loading", @"title", @"URL", @"estimatedProgress"]) {
            [_webView removeObserver:self forKeyPath:key];
        }
        _observing = NO;
    }
    if (_webView) {
        _webView.navigationDelegate = nil;
        _webView.UIDelegate = nil;
        [_webView stopLoading];
    }
    if (_window) {
        _window.popupOwner = nil;
        _window.delegate = nil;
        [_window close];
    }
}
- (void)present {
    if (self.closing || !self.window) return;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeFirstResponder:self.webView];
    [self refreshToolbar];
}
- (void)updateOwnerText:(NSString *)text {
    self.ownerText = text.length ? text : @"关联自: 浏览器";
    self.toolbar.ownerLabel.stringValue = self.ownerText;
    [self.toolbar layoutNow];
}
- (void)copyURL:(id)sender {
    NSString *value = (self.webView.URL ?: self.pendingURL).absoluteString;
    if (!value.length) return;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:value forType:NSPasteboardTypeString];
}
- (void)reloadOrStop:(id)sender {
    if (self.webView.loading) {
        [self.webView stopLoading];
    } else {
        [self.webView reload];
    }
}
- (void)toggleFullScreen:(id)sender {
    if (!self.window) return;
    [self.window toggleFullScreen:nil];
    [self refreshToolbar];
}
- (void)closePressed:(id)sender {
    [self closePopup];
}
- (void)refreshToolbar {
    NSURL *url = self.webView.URL ?: self.pendingURL;
    NSString *display = url.absoluteString.length ? url.absoluteString : @"about:blank";
    self.toolbar.urlLabel.stringValue = display;
    BOOL secure = [url.scheme.lowercaseString isEqualToString:@"https"];
    NSString *symbol = secure ? @"lock.fill" : (url.host.length ? @"lock.open" : @"globe");
    NSImage *tls = zw_popup_symbol(symbol, secure ? @"TLS 已连接" : @"连接状态");
    if (tls) self.toolbar.tlsIcon.image = tls;
    zw_popup_set_button_symbol(self.toolbar.reloadButton, self.webView.loading ? @"xmark" : @"arrow.clockwise",
        self.webView.loading ? @"×" : @"↻");
    NSString *title = self.webView.title.length ? self.webView.title : (url.host.length ? url.host : @"子窗口");
    self.window.title = title;
    self.window.representedURL = url;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    [self refreshToolbar];
    [self.surface notifyChanged];
}
- (ZWWebPendingRequest *)enqueueKind:(int)kind origin:(NSString *)origin message:(NSString *)message
    defaultText:(NSString *)defaultText realm:(NSString *)realm
    completion:(void (^)(BOOL, NSString *, NSString *))completion {
    if (self.closing || self.requests.count >= zw_request_capacity || zw_next_request_token == UINT64_MAX) {
        if (completion) completion(NO, nil, nil);
        return nil;
    }
    ZWWebPendingRequest *request = [[ZWWebPendingRequest alloc] init];
    request.token = ++zw_next_request_token;
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
    __weak ZWWebPopupOwner *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, zw_request_lifetime), dispatch_get_main_queue(), ^{
        [weakSelf finishRequest:token accepted:NO value:nil secret:nil];
    });
    return request;
}
- (BOOL)finishRequest:(uint64_t)token accepted:(BOOL)accepted value:(NSString *)value secret:(NSString *)secret {
    NSUInteger index = [self.requests indexOfObjectPassingTest:^BOOL(ZWWebPendingRequest *request, NSUInteger i, BOOL *stop) {
        return request.token == token;
    }];
    if (index == NSNotFound) return NO;
    ZWWebPendingRequest *request = self.requests[index];
    [self.requests removeObjectAtIndex:index];
    NSWindow *presentation = request.presentation;
    request.presentation = nil;
    if (presentation.sheetParent) [presentation.sheetParent endSheet:presentation returnCode:NSModalResponseCancel];
    void (^completion)(BOOL, NSString *, NSString *) = request.complete;
    request.complete = nil;
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    if (completion) --zw_pending_completions;
#endif
    if (completion) completion(accepted, value, secret);
    return YES;
}
- (void)cancelRequests {
    NSArray<ZWWebPendingRequest *> *requests = [self.requests copy];
    for (ZWWebPendingRequest *request in requests) {
        [self finishRequest:request.token accepted:NO value:nil secret:nil];
    }
}
- (void)notice:(NSString *)message {
    if (self.closing || !self.window) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = message ?: @"";
    [alert addButtonWithTitle:@"好"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)closePopup {
    [self releasePopupClosingWindow:YES];
}
- (void)releasePopupClosingWindow:(BOOL)closeWindow {
    if (self.closing) return;
    // Removing this popup from its parent's registry may release the final
    // owning reference. Keep it alive only until this delegate/action unwinds.
    __attribute__((objc_precise_lifetime)) ZWWebPopupOwner *lease = self;
    self.closing = YES;
    [self cancelRequests];
    if (_observing) {
        for (NSString *key in @[@"loading", @"title", @"URL", @"estimatedProgress"]) {
            [_webView removeObserver:self forKeyPath:key];
        }
        _observing = NO;
    }
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
    self.webView = nil;
    ZWWebPopupWindow *window = self.window;
    self.window = nil;
    window.popupOwner = nil;
    window.delegate = nil;
    if (closeWindow) [window close];
    self.toolbar = nil;
    ZWWebSurfaceOwner *surface = self.surface;
    self.surface = nil;
    [surface forgetPopup:lease];
    [surface notifyChanged];
}
- (void)windowWillClose:(NSNotification *)notification {
    [self releasePopupClosingWindow:NO];
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    zw_popup_set_button_symbol(self.toolbar.fullScreenButton, @"arrow.down.right.and.arrow.up.left", @"退出全屏");
}
- (void)windowDidExitFullScreen:(NSNotification *)notification {
    zw_popup_set_button_symbol(self.toolbar.fullScreenButton, @"arrow.up.left.and.arrow.down.right", @"全屏");
}
- (void)webView:(WKWebView *)view decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))completion {
    if (action.shouldPerformDownload) {
        if (self.surface) [self.surface notice:@"暂不支持下载文件。" origin:zw_url_origin(action.request.URL)];
        ZW_COMPLETE(WKNavigationActionPolicyCancel);
        return;
    }
    NSURL *url = action.request.URL;
    if (action.targetFrame && !action.targetFrame.mainFrame) {
        BOOL allowed = zw_is_popup_subframe_url(url);
        if (!allowed) [self notice:@"暂不支持打开此类型的链接。"];
        ZW_COMPLETE(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
        return;
    }
    BOOL allowed = zw_is_popup_navigation_url(url, self.committed);
    if (allowed && url && action.targetFrame) self.pendingURL = url;
    ZW_COMPLETE(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    if (!allowed) [self notice:@"暂不支持打开此类型的链接。"];
}
- (void)webView:(WKWebView *)view decidePolicyForNavigationResponse:(WKNavigationResponse *)response
    decisionHandler:(void (^)(WKNavigationResponsePolicy))completion {
    NSHTTPURLResponse *http = [response.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)response.response : nil;
    NSString *disposition = [http valueForHTTPHeaderField:@"Content-Disposition"];
    BOOL attachment = [[[disposition stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
        lowercaseString] hasPrefix:@"attachment"];
    if (!response.canShowMIMEType || attachment) {
        if (self.surface) [self.surface notice:@"暂不支持下载文件。" origin:zw_url_origin(response.response.URL)];
        ZW_COMPLETE(WKNavigationResponsePolicyCancel);
    } else {
        ZW_COMPLETE(WKNavigationResponsePolicyAllow);
    }
}
- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self refreshToolbar];
}
- (void)webView:(WKWebView *)view didCommitNavigation:(WKNavigation *)navigation {
    self.committed = YES;
    self.pendingURL = view.URL;
    [self refreshToolbar];
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
    [self refreshToolbar];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self refreshToolbar];
}
- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self refreshToolbar];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view {
    [self notice:@"网页内容进程已终止，请重新加载。"];
}
- (void)webViewDidClose:(WKWebView *)view {
    [self closePopup];
}
- (void)webView:(WKWebView *)view runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completion {
    if (self.closing || !self.window) { ZW_COMPLETE(); return; }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = message ?: @"";
    NSString *origin = zw_frame_origin(frame);
    if (origin.length) alert.informativeText = origin;
    [alert addButtonWithTitle:@"好"];
    ZWWebPendingRequest *request = [self enqueueKind:ZWWebRequestAlert origin:origin message:message defaultText:nil realm:nil
        completion:^(BOOL accepted, NSString *value, NSString *secret) { ZW_COMPLETE(); }];
    if (!request) return;
    request.presentation = alert.window;
    uint64_t token = request.token;
    __weak ZWWebPopupOwner *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        [weakSelf finishRequest:token accepted:YES value:nil secret:nil];
    }];
}
- (void)webView:(WKWebView *)view runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completion {
    if (self.closing || !self.window) { ZW_COMPLETE(NO); return; }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = message ?: @"";
    NSString *origin = zw_frame_origin(frame);
    if (origin.length) alert.informativeText = origin;
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    ZWWebPendingRequest *request = [self enqueueKind:ZWWebRequestConfirm origin:origin message:message defaultText:nil realm:nil
        completion:^(BOOL accepted, NSString *value, NSString *secret) { ZW_COMPLETE(accepted); }];
    if (!request) return;
    request.presentation = alert.window;
    uint64_t token = request.token;
    __weak ZWWebPopupOwner *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        [weakSelf finishRequest:token accepted:response == NSAlertFirstButtonReturn value:nil secret:nil];
    }];
}
- (void)webView:(WKWebView *)view runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(NSString *))completion {
    if (self.closing || !self.window) { ZW_COMPLETE(nil); return; }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = prompt ?: @"";
    NSString *origin = zw_frame_origin(frame);
    if (origin.length) alert.informativeText = origin;
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 22)];
    input.stringValue = defaultText ?: @"";
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    ZWWebPendingRequest *request = [self enqueueKind:ZWWebRequestPrompt origin:origin message:prompt defaultText:defaultText realm:nil
        completion:^(BOOL accepted, NSString *value, NSString *secret) { ZW_COMPLETE(accepted ? (value ?: @"") : nil); }];
    if (!request) return;
    request.presentation = alert.window;
    [alert.window setInitialFirstResponder:input];
    uint64_t token = request.token;
    __weak ZWWebPopupOwner *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        BOOL accepted = response == NSAlertFirstButtonReturn;
        [weakSelf finishRequest:token accepted:accepted value:accepted ? input.stringValue : nil secret:nil];
    }];
}
- (void)webView:(WKWebView *)view runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completion {
    [self notice:@"暂不支持上传文件。"];
    ZW_COMPLETE(nil);
}
- (WKWebView *)webView:(WKWebView *)view createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!self.closing) [self notice:@"暂不支持此网页弹窗。"];
    return nil;
}
- (void)webView:(WKWebView *)view didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if ([space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = space.serverTrust;
        NSURL *target = self.pendingURL ?: self.webView.URL;
        NSString *origin = zw_origin(space.protocol, space.host, space.port);
        BOOL sameOrigin = target && [origin.lowercaseString isEqualToString:zw_url_origin(target).lowercaseString];
        if (!self.tlsReview || !trust || space.isProxy || challenge.previousFailureCount || !sameOrigin ||
            ![target.scheme.lowercaseString isEqualToString:@"https"] || space.port < 1 || space.port > UINT16_MAX) {
            ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            return;
        }
        id retainedTrust = (__bridge id)trust;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"无法验证网站证书";
        alert.informativeText = [NSString stringWithFormat:@"%@:%ld\n继续访问仅对本次有效。", space.host ?: @"", (long)space.port];
        [alert addButtonWithTitle:@"继续访问（本次）"];
        [alert addButtonWithTitle:@"使用系统验证"];
        [alert addButtonWithTitle:@"取消"];
        ZWWebPendingRequest *request = [self enqueueKind:ZWWebRequestServerTrust origin:origin message:@"无法验证网站证书" defaultText:nil realm:nil
            completion:^(BOOL accepted, NSString *value, NSString *secret) {
                if (accepted && [value isEqualToString:@"exception"]) {
                    NSURLCredential *credential = [NSURLCredential credentialForTrust:(__bridge SecTrustRef)retainedTrust];
                    ZW_COMPLETE(NSURLSessionAuthChallengeUseCredential, credential);
                } else if (accepted && [value isEqualToString:@"system"]) {
                    ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
                } else {
                    ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
                }
            }];
        if (!request) return;
        request.presentation = alert.window;
        uint64_t token = request.token;
        __weak ZWWebPopupOwner *weakSelf = self;
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            NSString *choice = response == NSAlertFirstButtonReturn ? @"exception"
                : (response == NSAlertSecondButtonReturn ? @"system" : nil);
            [weakSelf finishRequest:token accepted:choice != nil value:choice secret:nil];
        }];
        return;
    }
    BOOL passwordAuth = [space.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]
        || [space.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPDigest];
    if (!passwordAuth || space.isProxy) {
        ZW_COMPLETE(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    if (challenge.previousFailureCount >= 3) {
        [self notice:@"网站认证失败，请重新加载后重试。"];
        ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }
    if (self.closing || !self.window) {
        ZW_COMPLETE(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = challenge.previousFailureCount ? @"用户名或密码不正确，请重试。" : @"此网站需要用户名和密码。";
    if (space.realm.length) alert.informativeText = space.realm;
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 52)];
    NSTextField *username = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 280, 22)];
    username.placeholderString = @"用户名";
    NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 22)];
    password.placeholderString = @"密码";
    [accessory addSubview:username];
    [accessory addSubview:password];
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"登录"];
    [alert addButtonWithTitle:@"取消"];
    ZWWebPendingRequest *request = [self enqueueKind:ZWWebRequestHTTPAuth origin:zw_origin(space.protocol, space.host, space.port)
        message:alert.messageText defaultText:nil realm:space.realm
        completion:^(BOOL accepted, NSString *value, NSString *secret) {
            NSURLCredential *credential = accepted ? [NSURLCredential credentialWithUser:value ?: @""
                password:secret ?: @"" persistence:NSURLCredentialPersistenceNone] : nil;
            ZW_COMPLETE(accepted ? NSURLSessionAuthChallengeUseCredential : NSURLSessionAuthChallengeCancelAuthenticationChallenge, credential);
        }];
    if (!request) return;
    request.presentation = alert.window;
    [alert.window setInitialFirstResponder:username];
    uint64_t token = request.token;
    __weak ZWWebPopupOwner *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        BOOL accepted = response == NSAlertFirstButtonReturn;
        [weakSelf finishRequest:token accepted:accepted value:username.stringValue secret:password.stringValue];
    }];
}
@end

@implementation ZWWebSurfaceOwner
- (void)dealloc {
#ifdef ZW_WEB_SURFACE_ACCEPTANCE
    --zw_live_surface_owners;
#endif
    for (ZWWebPopupOwner *popup in [self.popups copy]) {
        popup.surface = nil;
        [popup closePopup];
    }
    [self.popups removeAllObjects];
}
- (void)forgetPopup:(ZWWebPopupOwner *)popup {
    if (popup) [self.popups removeObjectIdenticalTo:popup];
}
- (void)closeAllPopups {
    // This data-store/proxy generation is being retired. A completion can
    // synchronously invoke WebKit again, and the old parent view can survive
    // until reconnection. Neither may create another child of this surface.
    self.popupsRetired = YES;
    for (ZWWebPopupOwner *popup in [self.popups copy]) [popup closePopup];
    [self.popups removeAllObjects];
}
- (BOOL)popupTlsReview {
    return self.tlsReview;
}
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
    BOOL targetless = action.targetFrame == nil;
    BOOL allowed = targetless ? zw_is_popup_initial_url(action.request.URL) : zw_is_web_url(action.request.URL);
    BOOL isGet = [action.request.HTTPMethod isEqualToString:@"GET"];
    if (allowed && action.targetFrame) {
        self.mainFrameURL = action.request.URL;
        self.pendingGet = isGet;
        if (!self.committed) self.activeGet = isGet;
    }
    // A targetless action is the WebKit hand-off to
    // webView:createWebViewWithConfiguration:...; allow it so the child
    // window can be created with the configuration WebKit supplied.
    ZW_COMPLETE(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    if (!allowed) {
        [self notice:targetless ? @"暂不支持此网页弹窗。" : @"暂不支持打开此类型的链接。"
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
    // WebKit hands us the exact configuration for the child. Reusing it keeps
    // window.opener, the non-persistent data store and the parent proxy intact.
    if (self.closing || self.popupsRetired) return nil;
    if (action.request.URL && !zw_is_popup_initial_url(action.request.URL)) {
        [self notice:@"暂不支持打开此类型的链接。" origin:zw_frame_origin(action.sourceFrame)];
        return nil;
    }
    if (zw_live_popup_count(self) >= zw_max_popups_per_session) {
        [self notice:@"已达到单会话子窗口数量上限。" origin:zw_frame_origin(action.sourceFrame)];
        return nil;
    }
    WKWebsiteDataStore *store = self.webView.configuration.websiteDataStore;
    if (!store || store.isPersistent || configuration.websiteDataStore != store) {
        [self notice:@"无法继承此网页会话的连接配置。" origin:zw_frame_origin(action.sourceFrame)];
        return nil;
    }
    ZWWebPopupOwner *popup = [[ZWWebPopupOwner alloc] initWithSurface:self configuration:configuration
        action:action features:features];
    if (!popup) {
        [self notice:@"无法创建网页子窗口。" origin:zw_frame_origin(action.sourceFrame)];
        return nil;
    }
    [self.popups addObject:popup];
    [popup present];
    [self notifyChanged];
    return popup.webView;
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
    owner.popups = [NSMutableArray array];
    owner.popupOwnerText = @"关联自: 浏览器";
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
    ZWWebInputCallback focus_entered, ZWWebInputCallback left_press, void *input_context) {
    if (!NSThread.isMainThread || !surface || !zenit_window) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        ZWWebClipView *container = owner.clipView;
        NSView *parent = (__bridge NSView *)macos_get_metal_view(zenit_window);
        if (!parent.window || (container.superview && container.superview != parent)) return 0;

        NSRect document = zw_view_rect(parent, slot);
        NSRect clipped = NSIntersectionRect(NSIntersectionRect(document, zw_view_rect(parent, clip)), parent.bounds);
        if (!owner.webView || !visible || NSIsEmptyRect(clipped)) {
            if (container.superview) macos_set_embedded_input_view((__bridge void *)container, 0, NULL, NULL, NULL, NULL);
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
        if (!macos_set_embedded_input_view((__bridge void *)container, exposed, host_key, focus_entered, left_press, input_context)) return 0;
        container.hidden = !exposed;
        return 1;
    }
}

void zw_web_surface_detach(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        [owner.nativeInspector close];
        owner.nativeInspector = nil;
        macos_set_embedded_input_view((__bridge void *)owner.clipView, 0, NULL, NULL, NULL, NULL);
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
        ZWWebSurfaceOwner *owner = (__bridge_transfer ZWWebSurfaceOwner *)surface;
        owner.closing = YES;
        owner.changed = NULL;
        [owner closeAllPopups];
        zw_web_surface_detach(surface);
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

int zw_web_surface_supports_inspection(void) {
    if (@available(macOS 13.3, *)) return 1;
    return 0;
}

int zw_web_surface_supports_native_console(void) {
    Class inspector = NSClassFromString(@"_WKInspector");
    return [WKWebView instancesRespondToSelector:@selector(_inspector)] &&
        [WKPreferences instancesRespondToSelector:@selector(_setDeveloperExtrasEnabled:)] &&
        [inspector instancesRespondToSelector:@selector(showConsole)] &&
        [inspector instancesRespondToSelector:@selector(close)];
}

int zw_web_surface_open_native_console(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface || !zw_web_surface_supports_native_console()) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        WKWebView *view = owner.webView;
        if (owner.closing || !view.window) return 0;
        id<ZWNativeWebInspector> inspector = [view _inspector];
        if (!inspector) return 0;
        [view.configuration.preferences _setDeveloperExtrasEnabled:YES];
        owner.nativeInspector = inspector;
        [inspector showConsole];
        return 1;
    }
}

int zw_web_surface_set_inspectable(ZWWebSurface *surface, int enabled) {
    if (!NSThread.isMainThread || !surface) return 0;
    if (@available(macOS 13.3, *)) {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        if (!owner.webView) return 0;
        owner.webView.inspectable = enabled != 0;
        return 1;
    }
    return 0;
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
    ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
    owner.tlsReview = enabled != 0;
    for (ZWWebPopupOwner *popup in owner.popups) popup.tlsReview = enabled != 0;
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

// Closing a popup can invoke WebKit completions before the registry removal.
// Public accessors therefore skip closing entries and index only live windows.
static ZWWebPopupOwner *zw_live_popup(ZWWebSurfaceOwner *owner, size_t index) {
    for (ZWWebPopupOwner *popup in owner.popups) {
        if (popup.closing || !popup.window) continue;
        if (index == 0) return popup;
        index -= 1;
    }
    return nil;
}

static size_t zw_live_popup_count(ZWWebSurfaceOwner *owner) {
    size_t count = 0;
    for (ZWWebPopupOwner *popup in owner.popups) {
        if (!popup.closing && popup.window) count += 1;
    }
    return count;
}

size_t zw_web_surface_popup_count(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return 0;
    @autoreleasepool {
        return zw_live_popup_count((__bridge ZWWebSurfaceOwner *)surface);
    }
}

int zw_web_surface_focus_popup(ZWWebSurface *surface, size_t index) {
    if (!NSThread.isMainThread || !surface) return 0;
    @autoreleasepool {
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        if (owner.closing) return 0;
        ZWWebPopupOwner *popup = zw_live_popup(owner, index);
        if (!popup) return 0;
        if (popup.window.isMiniaturized) [popup.window deminiaturize:nil];
        [popup.window makeKeyAndOrderFront:nil];
        [popup.window orderFrontRegardless];
        [NSApp activateIgnoringOtherApps:YES];
        [popup refreshToolbar];
        return 1;
    }
}

char *zw_web_surface_copy_popup_title(ZWWebSurface *surface, size_t index) {
    if (!NSThread.isMainThread || !surface) return NULL;
    @autoreleasepool {
        ZWWebPopupOwner *popup = zw_live_popup((__bridge ZWWebSurfaceOwner *)surface, index);
        if (!popup) return NULL;
        NSString *title = popup.webView.title.length ? popup.webView.title : popup.window.title;
        const char *value = (title ?: @"").UTF8String;
        return value ? strdup(value) : NULL;
    }
}

void zw_web_surface_close_popups(ZWWebSurface *surface) {
    if (!NSThread.isMainThread || !surface) return;
    @autoreleasepool {
        [(__bridge ZWWebSurfaceOwner *)surface closeAllPopups];
    }
}

int zw_web_surface_set_popup_context(ZWWebSurface *surface, const uint8_t *label, size_t label_len) {
    if (!NSThread.isMainThread || !surface || (!label && label_len) || label_len > 1024) return 0;
    @autoreleasepool {
        NSString *text = label_len ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : nil;
        if (label_len && !text) return 0;
        ZWWebSurfaceOwner *owner = (__bridge ZWWebSurfaceOwner *)surface;
        NSString *value = zw_bounded_text(text, 1024);
        if (!value.length) value = @"关联自: 浏览器";
        owner.popupOwnerText = value;
        for (ZWWebPopupOwner *popup in owner.popups) [popup updateOwnerText:value];
        return 1;
    }
}
