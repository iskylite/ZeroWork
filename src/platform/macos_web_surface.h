#ifndef ZW_MACOS_WEB_SURFACE_H
#define ZW_MACOS_WEB_SURFACE_H

#include <stddef.h>
#include <stdint.h>

typedef struct ZWWebSurface ZWWebSurface;
typedef int (*ZWWebHostKey)(void *context, uint16_t keycode, uint32_t modifiers);
typedef void (*ZWWebFocusEntered)(void *context);
typedef void (*ZWWebSurfaceChanged)(void);

typedef struct {
    float x, y, w, h;
} ZWWebRect;

typedef struct {
    double progress;
    uint64_t navigation_id;
    uint64_t url_revision;
    int can_go_back;
    int can_go_forward;
    int loading;
    int displayed;
    int failed;
    int ready;
    int committed;
    int committed_get;
} ZWWebSurfaceState;

enum ZWWebRequestKind {
    ZWWebRequestAlert = 1,
    ZWWebRequestConfirm,
    ZWWebRequestPrompt,
    ZWWebRequestHTTPAuth,
    ZWWebRequestNotice,
};

typedef struct {
    uint64_t token;
    uint64_t navigation_id;
    int kind;
    char *origin;
    char *message;
    char *default_text;
    char *realm;
} ZWWebRequest;

// All calls, including destruction, are confined to the AppKit main thread.
int zw_web_surface_supports_proxy(void);
ZWWebSurface *zw_web_surface_create(void);
ZWWebSurface *zw_web_surface_create_proxied(uint16_t port, const uint8_t *username,
    size_t username_len, const uint8_t *password, size_t password_len);
void zw_web_surface_destroy(ZWWebSurface *surface);
void zw_web_surface_set_change_callback(ZWWebSurface *surface, ZWWebSurfaceChanged callback);
int zw_web_surface_sync(ZWWebSurface *surface, void *zenit_window, ZWWebRect slot,
    ZWWebRect clip, const ZWWebRect *occlusions, size_t occlusion_count, int visible, ZWWebHostKey host_key,
    ZWWebFocusEntered focus_entered, void *focus_context);
void zw_web_surface_detach(ZWWebSurface *surface);
void zw_web_surface_release_focus(ZWWebSurface *surface);
int zw_web_surface_navigate(ZWWebSurface *surface, const uint8_t *url, size_t len);
int zw_web_surface_go_back(ZWWebSurface *surface);
int zw_web_surface_go_forward(ZWWebSurface *surface);
int zw_web_surface_reload(ZWWebSurface *surface);
void zw_web_surface_stop(ZWWebSurface *surface);
// Requests are bounded, expire after two minutes, and are cancelled by a new
// main-frame navigation, stop, or destruction. Tokens never repeat.
// Returns 1 for a copied request, 0 when empty, -1 on allocation failure.
int zw_web_surface_copy_request(ZWWebSurface *surface, ZWWebRequest *request);
void zw_web_request_dispose(ZWWebRequest *request);
int zw_web_surface_request_pending(ZWWebSurface *surface, uint64_t token);
// Accepted prompt with zero value_len is an empty string; rejected is null.
// HTTP auth uses value as username and secret as password, with no persistence.
// Returns 1 only when the still-pending token was consumed exactly once.
int zw_web_surface_reply_request(ZWWebSurface *surface, uint64_t token, int accepted,
    const uint8_t *value, size_t value_len, const uint8_t *secret, size_t secret_len);
void zw_web_surface_cancel_requests(ZWWebSurface *surface);
ZWWebSurfaceState zw_web_surface_state(ZWWebSurface *surface);
// The caller frees these UTF-8 copies with free(). NULL means unavailable.
char *zw_web_surface_copy_url(ZWWebSurface *surface);
char *zw_web_surface_copy_title(ZWWebSurface *surface);

#endif
