#include "window.h"
#include "../../window_chrome.h"
#include "../../../vendor/libdecor/libdecor.h"
#include <wayland-client.h>
#include <wayland-cursor.h>
#include "cursor-shape-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "text-input-unstable-v3-client-protocol.h"
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>

/* Use array marshalling directly: no variadic ABI forwarding and no linked
 * dependency on a particular libwayland-client build. Generated protocol
 * metadata is vendored; the host compositor client library is loaded at runtime. */
struct Dispatch {
    struct wl_display *(*connect)(const char *);
    void (*disconnect)(struct wl_display *);
    int (*get_fd)(struct wl_display *);
    int (*roundtrip)(struct wl_display *);
    int (*prepare_read)(struct wl_display *);
    void (*cancel_read)(struct wl_display *);
    int (*read_events)(struct wl_display *);
    int (*dispatch_pending)(struct wl_display *);
    int (*flush)(struct wl_display *);
    int (*add_listener)(struct wl_proxy *, void (**)(void), void *);
    void (*destroy_proxy)(struct wl_proxy *);
    uint32_t (*proxy_version)(struct wl_proxy *);
    struct wl_proxy *(*marshal)(struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t, uint32_t, union wl_argument *);
};
struct CursorDispatch {
    struct wl_cursor_theme *(*theme_load)(const char *, int, struct wl_shm *);
    void (*theme_destroy)(struct wl_cursor_theme *);
    struct wl_cursor *(*theme_cursor)(struct wl_cursor_theme *, const char *);
    struct wl_buffer *(*image_buffer)(struct wl_cursor_image *);
    int (*frame_duration)(struct wl_cursor *, uint32_t, uint32_t *);
};
struct DecorDispatch {
    struct libdecor *(*new_context)(struct wl_display *, const struct libdecor_interface *);
    void (*unref)(struct libdecor *);
    int (*get_fd)(struct libdecor *);
    int (*dispatch)(struct libdecor *, int);
    struct libdecor_frame *(*decorate)(struct libdecor *, struct wl_surface *, const struct libdecor_frame_interface *, void *);
    void (*frame_unref)(struct libdecor_frame *);
    void (*set_title)(struct libdecor_frame *, const char *);
    void (*set_app_id)(struct libdecor_frame *, const char *);
    void (*map)(struct libdecor_frame *);
    void (*commit)(struct libdecor_frame *, struct libdecor_state *, struct libdecor_configuration *);
    struct libdecor_state *(*state_new)(int, int);
    void (*state_free)(struct libdecor_state *);
    bool (*content_size)(struct libdecor_configuration *, struct libdecor_frame *, int *, int *);
    void (*visibility)(struct libdecor_frame *, bool);
    bool (*is_visible)(struct libdecor_frame *);
    void (*move)(struct libdecor_frame *, struct wl_seat *, uint32_t);
    void (*resize)(struct libdecor_frame *, struct wl_seat *, uint32_t, enum libdecor_resize_edge);
    void (*fullscreen)(struct libdecor_frame *, struct wl_output *);
    void (*unfullscreen)(struct libdecor_frame *);
    enum libdecor_wm_capabilities (*wm_capabilities)(struct libdecor_frame *);
    bool (*has_capability)(struct libdecor_frame *, enum libdecor_capabilities);
    bool (*window_state)(struct libdecor_configuration *, enum libdecor_window_state *);
    struct xdg_toplevel *(*get_toplevel)(struct libdecor_frame *);
    void (*maximize)(struct libdecor_frame *);
    void (*unmaximize)(struct libdecor_frame *);
    void (*minimize)(struct libdecor_frame *);
    void (*close)(struct libdecor_frame *);
    void (*translate)(struct libdecor_frame *, int, int, int *, int *);
};

struct XkbDispatch {
    struct xkb_context *(*context_new)(enum xkb_context_flags);
    void (*context_unref)(struct xkb_context *);
    struct xkb_keymap *(*keymap_new)(struct xkb_context *, const char *, enum xkb_keymap_format, enum xkb_keymap_compile_flags);
    void (*keymap_unref)(struct xkb_keymap *);
    struct xkb_state *(*state_new)(struct xkb_keymap *);
    void (*state_unref)(struct xkb_state *);
    enum xkb_state_component (*update_mask)(struct xkb_state *, xkb_mod_mask_t, xkb_mod_mask_t, xkb_mod_mask_t, xkb_layout_index_t, xkb_layout_index_t, xkb_layout_index_t);
    int (*mod_active)(struct xkb_state *, const char *, enum xkb_state_component);
    int (*key_utf8)(struct xkb_state *, xkb_keycode_t, char *, size_t);
    xkb_keysym_t (*key_sym)(struct xkb_state *, xkb_keycode_t);
    int (*key_repeats)(struct xkb_keymap *, xkb_keycode_t);
    struct xkb_compose_table *(*compose_table_new)(struct xkb_context *, const char *, enum xkb_compose_compile_flags);
    void (*compose_table_unref)(struct xkb_compose_table *);
    struct xkb_compose_state *(*compose_new)(struct xkb_compose_table *, enum xkb_compose_state_flags);
    void (*compose_unref)(struct xkb_compose_state *);
    enum xkb_compose_feed_result (*compose_feed)(struct xkb_compose_state *, xkb_keysym_t);
    enum xkb_compose_status (*compose_status)(struct xkb_compose_state *);
    int (*compose_utf8)(struct xkb_compose_state *, char *, size_t);
    void (*compose_reset)(struct xkb_compose_state *);
};
struct Output {
    struct ZenitWaylandWindow *window;
    struct wl_output *proxy;
    uint32_t name;
    int scale;
    int entered;
    int refresh_millihz;
};
struct ClipboardState;
struct TextInputState;
struct ZenitWaylandWindow {
    struct ClipboardState *clipboard;
    struct TextInputState *text_input;
    void *library;
    struct Dispatch api;
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_surface *surface;
    struct xdg_wm_base *shell;
    struct xdg_surface *xdg;
    struct xdg_toplevel *toplevel; /* Borrowed when decor_frame owns the role. */
    void *decor_library;
    struct DecorDispatch decor_api;
    uint32_t decoration_manager_name;
    int decoration_manager_seen;
    uint32_t chrome_state_generation;
    int chrome_mode, close_requested;
    uint32_t chrome_appearance, chrome_last_press_time;
    float chrome_last_press_x, chrome_last_press_y;
    int chrome_last_press_valid;
    char chrome_button_layout[128], chrome_double_click[64], chrome_middle_click[64];
    int (*chrome_hit)(void *, float, float);
    void *chrome_context;
    struct libdecor *decor;
    struct libdecor_frame *decor_frame;
    struct wl_callback *frame;
    struct wl_seat *seat;
    struct wl_pointer *pointer;
    struct wl_keyboard *keyboard;
    struct wp_cursor_shape_manager_v1 *cursor_manager;
    struct wp_cursor_shape_device_v1 *cursor_device;
    struct wl_shm *shm;
    struct wl_surface *cursor_surface;
    void *cursor_library;
    struct CursorDispatch cursor_api;
    struct wl_cursor_theme *cursor_theme;
    struct wl_cursor *theme_cursor;
    int cursor_scale, pointer_focused;
    uint32_t pointer_enter_serial, cursor_shape, cursor_applied_shape, cursor_apply_count;
    int64_t cursor_epoch, cursor_deadline;
    uint32_t seat_version;
    void *xkb_library;
    struct XkbDispatch xkb;
    struct xkb_context *xkb_context;
    struct xkb_keymap *keymap;
    struct xkb_state *xkb_state;
    struct xkb_compose_table *compose_table;
    struct xkb_compose_state *compose_state;
    unsigned char held_keys[768];
    int keyboard_focused, repeat_rate, repeat_delay, ordered_input;
    uint32_t repeat_key;
    int64_t repeat_deadline;
    ZenitWaylandInputEvent events[128];
    uint32_t event_head, event_count;
    uint32_t seat_name;
    struct wp_viewporter *viewporter;
    struct wp_viewport *viewport;
    struct wp_fractional_scale_manager_v1 *fractional_manager;
    struct wp_fractional_scale_v1 *fractional;
    uint32_t preferred_scale;
    /* Client-side shadow strips for custom chrome (shadow.inc). */
    struct wl_subcompositor *subcompositor;
    struct ShadowStrip *shadow; /* SHADOW_STRIPS entries */
    int shadow_shown;
    uint32_t shadow_width, shadow_height, shadow_pixel_scale;
    struct ShadowLook *shadow_look;
    /* Pointer over a shadow strip: the margin is the resize border (as in GTK). */
    int edge_active, edge_strip;
    float edge_x, edge_y; /* content-surface coordinates */
    uint32_t edge_cursor;
    ZenitWaylandInputState input;
    ZenitWaylandButtonEvent buttons[32];
    uint32_t button_head, button_count;
    float scroll_x, scroll_y;
    float axis_delta[2], axis_steps[2], axis_v120[2];
    uint32_t axis_present, axis_steps_present, axis_v120_present, axis_stopped;
    uint32_t axis_source, gesture_axes;
    int axis_source_known, gesture_active;
    struct Output outputs[16];
    uint32_t compositor_version;
    uint32_t width, height, pending_width, pending_height;
    /* Viewport destination follows the presented buffer, not configure: a
     * destination committed with an older buffer stretches it. metric_* is
     * the last logical/pixel pair handed to the renderer. */
    uint32_t metric_logical_width, metric_logical_height, metric_pixel_width, metric_pixel_height;
    uint32_t viewport_width, viewport_height;
    uint32_t requested_width, requested_height;
    int size_requested, maximized;
    uint32_t decor_window_state;
    int scale, configured, closed, frame_ready;
    uint64_t frame_tick;
};
/* Windows by wl_surface for zenit_wayland_before_present (render thread = UI thread). */
static ZenitWaylandWindow *live_windows[32];


static struct wl_proxy *request(ZenitWaylandWindow *w, void *proxy, uint32_t opcode,
    const struct wl_interface *interface, uint32_t version, uint32_t flags, union wl_argument *args) {
    return w->api.marshal(proxy, opcode, interface, version, flags, args);
}
static int listen(ZenitWaylandWindow *w, void *proxy, const void *listener, void *context) {
    return w->api.add_listener(proxy, (void (**)(void))listener, context);
}
static void destroy_request(ZenitWaylandWindow *w, void *proxy, uint32_t version) {
    if (proxy) request(w, proxy, 0, NULL, version, WL_MARSHAL_FLAG_DESTROY, NULL);
}
static void clipboard_focus_lost(ZenitWaylandWindow *w);
static void clipboard_input_serial(ZenitWaylandWindow *w, uint32_t serial);
#include "keyboard.inc"
#include "cursor.inc"
#include "chrome_settings.inc"
#include "pointer.inc"
static void shadow_sync(ZenitWaylandWindow *w);
#include "scaling.inc"
#include "shadow.inc"
#include "clipboard.inc"
#include "png_decode.inc"
#include "text_input.inc"
static void update_scale(ZenitWaylandWindow *w) {
    if (w->fractional) return;
    int scale = 1;
    for (size_t i = 0; i < 16; ++i)
        if (w->outputs[i].entered && w->outputs[i].scale > scale) scale = w->outputs[i].scale;
    if (scale != w->scale && w->compositor_version >= 3 && w->surface) {
        w->scale = scale;
        if (w->pointer_focused) (void)apply_cursor(w);
        union wl_argument args[] = { { .i = scale } };
        request(w, w->surface, WL_SURFACE_SET_BUFFER_SCALE, NULL, w->compositor_version, 0, args);
        shadow_sync(w);
    }
}
static void output_geometry(void *data, struct wl_output *o, int32_t x, int32_t y,
    int32_t pw, int32_t ph, int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
    (void)o; (void)width; (void)height;
    if ((flags & WL_OUTPUT_MODE_CURRENT) && refresh > 0)
        ((struct Output *)data)->refresh_millihz = refresh;
}
static void output_done(void *data, struct wl_output *o) { (void)o; struct Output *output = data; update_scale(output->window); }
static void output_scale(void *data, struct wl_output *o, int32_t factor) {
    (void)o; struct Output *output = data;
    if (factor > 0 && factor <= 16) output->scale = factor;
}
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done, .scale = output_scale,
};
static void surface_enter(void *data, struct wl_surface *surface, struct wl_output *output) {
    (void)surface; ZenitWaylandWindow *w = data;
    for (size_t i = 0; i < 16; ++i) if (w->outputs[i].proxy == output) w->outputs[i].entered = 1;
    update_scale(w);
}
static void surface_leave(void *data, struct wl_surface *surface, struct wl_output *output) {
    (void)surface; ZenitWaylandWindow *w = data;
    for (size_t i = 0; i < 16; ++i) if (w->outputs[i].proxy == output) w->outputs[i].entered = 0;
    update_scale(w);
}
static const struct wl_surface_listener surface_listener = { .enter = surface_enter, .leave = surface_leave };
static void shell_ping(void *data, struct xdg_wm_base *shell, uint32_t serial) {
    ZenitWaylandWindow *w = data; union wl_argument args[] = { { .u = serial } };
    request(w, shell, XDG_WM_BASE_PONG, NULL, 1, 0, args);
}
static const struct xdg_wm_base_listener shell_listener = { .ping = shell_ping };
static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    ZenitWaylandWindow *w = data;
    const struct wl_interface *type = NULL;
    if (strcmp(interface, "zxdg_decoration_manager_v1") == 0) {
        w->decoration_manager_name = name;
        w->decoration_manager_seen = 1;
        /* Stock libdecor does not expose the negotiated SSD mode. Restore
         * platform decorations if the desktop gains this protocol later. */
        if (w->chrome_mode && w->decor_frame && w->decor_api.visibility)
            w->decor_api.visibility(w->decor_frame, true);
        shadow_sync(w);
        return;
    }
    uint32_t bind_version = 1;
    if (strcmp(interface, "wl_compositor") == 0 && !w->compositor) {
        type = &wl_compositor_interface; bind_version = version < 4 ? version : 4;
    } else if (strcmp(interface, "xdg_wm_base") == 0 && !w->shell) {
        type = &xdg_wm_base_interface;
    } else if (strcmp(interface, "wl_data_device_manager") == 0 && !w->clipboard->manager) {
        type = &wl_data_device_manager_interface; bind_version = version < 3 ? version : 3;
    } else if (strcmp(interface, "zwp_text_input_manager_v3") == 0 && !w->text_input->manager) {
        type = &zwp_text_input_manager_v3_interface;
    } else if (strcmp(interface, "wl_shm") == 0 && !w->shm) {
        type = &wl_shm_interface;
    } else if (strcmp(interface, "wp_cursor_shape_manager_v1") == 0 && !w->cursor_manager &&
        (!getenv("ZENIT_WAYLAND_CURSOR_BACKEND") || strcmp(getenv("ZENIT_WAYLAND_CURSOR_BACKEND"), "theme") != 0)) {
        type = &wp_cursor_shape_manager_v1_interface;
    } else if (strcmp(interface, "wl_seat") == 0 && !w->seat) {
        type = &wl_seat_interface; bind_version = version < 8 ? version : 8;
    } else if (strcmp(interface, "wl_subcompositor") == 0 && !w->subcompositor) {
        type = &wl_subcompositor_interface;
    } else if (strcmp(interface, "wp_viewporter") == 0 && !w->viewporter) {
        type = &wp_viewporter_interface;
    } else if (strcmp(interface, "wp_fractional_scale_manager_v1") == 0 && !w->fractional_manager) {
        type = &wp_fractional_scale_manager_v1_interface;
    } else if (strcmp(interface, "wl_output") == 0 && version >= 2) {
        type = &wl_output_interface; bind_version = 2;
    }
    if (!type) return;
    union wl_argument args[] = { { .u = name }, { .s = type->name }, { .u = bind_version }, { .o = NULL } };
    struct wl_proxy *proxy = request(w, registry, WL_REGISTRY_BIND, type, bind_version, 0, args);
    if (!proxy) { w->closed = 1; return; }
    if (type == &wl_compositor_interface) {
        w->compositor = (struct wl_compositor *)proxy; w->compositor_version = bind_version;
    } else if (type == &xdg_wm_base_interface) {
        w->shell = (struct xdg_wm_base *)proxy;
        if (listen(w, proxy, &shell_listener, w) != 0) w->closed = 1;
    } else if (type == &wl_data_device_manager_interface) {
        w->clipboard->manager = (struct wl_data_device_manager *)proxy;
        w->clipboard->version = bind_version; w->clipboard->manager_name = name;
    } else if (type == &zwp_text_input_manager_v3_interface) {
        w->text_input->manager = (struct zwp_text_input_manager_v3 *)proxy;
        w->text_input->manager_name = name;
    } else if (type == &wl_shm_interface) {
        w->shm = (struct wl_shm *)proxy;
        if (listen(w, proxy, &shm_listener, w) != 0) w->closed = 1;
    } else if (type == &wp_cursor_shape_manager_v1_interface) {
        w->cursor_manager = (struct wp_cursor_shape_manager_v1 *)proxy; init_cursor_device(w);
    } else if (type == &wl_seat_interface) {
        w->seat = (struct wl_seat *)proxy; w->seat_name = name; w->seat_version = bind_version;
        if (listen(w, proxy, &seat_listener, w) != 0) w->closed = 1;
    } else if (type == &wl_subcompositor_interface) {
        w->subcompositor = (struct wl_subcompositor *)proxy;
    } else if (type == &wp_viewporter_interface) {
        w->viewporter = (struct wp_viewporter *)proxy;
    } else if (type == &wp_fractional_scale_manager_v1_interface) {
        w->fractional_manager = (struct wp_fractional_scale_manager_v1 *)proxy;
    } else {
        for (size_t i = 0; i < 16; ++i) if (!w->outputs[i].proxy) {
            w->outputs[i] = (struct Output){ .window = w, .proxy = (struct wl_output *)proxy, .name = name, .scale = 1 };
            if (listen(w, proxy, &output_listener, &w->outputs[i]) != 0) w->closed = 1;
            return;
        }
        w->api.destroy_proxy(proxy);
    }
    if (!init_clipboard(w)) w->closed = 1;
    if (!init_text_input(w)) w->closed = 1;
}
static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry; ZenitWaylandWindow *w = data;
    if (name == w->decoration_manager_name) w->decoration_manager_name = 0;
    if (w->seat && w->seat_name == name) {
        destroy_text_input_device(w);
        destroy_clipboard_device(w);
        cancel_pointer_buttons(w); cancel_keyboard(w); w->keyboard_focused = 0;
        if (w->keyboard) w->api.destroy_proxy((struct wl_proxy *)w->keyboard);
        w->keyboard = NULL;
        destroy_cursor_device(w);
        if (w->pointer) w->api.destroy_proxy((struct wl_proxy *)w->pointer);
        w->pointer = NULL;
        w->api.destroy_proxy((struct wl_proxy *)w->seat); w->seat = NULL;
        w->seat_name = 0;
    }
    if (w->clipboard->manager && w->clipboard->manager_name == name) {
        destroy_clipboard_device(w); w->api.destroy_proxy((struct wl_proxy *)w->clipboard->manager); w->clipboard->manager = NULL;
    }
    if (w->text_input->manager && w->text_input->manager_name == name) {
        destroy_text_input_device(w); destroy_request(w, w->text_input->manager, 1); w->text_input->manager = NULL;
    }
    for (size_t i = 0; i < 16; ++i) if (w->outputs[i].proxy && w->outputs[i].name == name) {
        w->api.destroy_proxy((struct wl_proxy *)w->outputs[i].proxy);
        memset(&w->outputs[i], 0, sizeof(w->outputs[i])); update_scale(w);
    }
}
static const struct wl_registry_listener registry_listener = { .global = registry_global, .global_remove = registry_remove };
/* libdecor owns the xdg role and decorations; GPU buffers remain on our
 * content surface. Never install a competing listener or acknowledge its role. */
static void decor_error(struct libdecor *context, enum libdecor_error error, const char *message) {
    (void)context;
    fprintf(stderr, "Wayland decoration error %d: %s\n", error, message ? message : "unknown");
}
static const struct libdecor_interface decor_interface = { .error = decor_error };
static void decor_commit(struct libdecor_frame *frame, void *data) {
    (void)frame; ZenitWaylandWindow *w = data;
    if (!w->closed) request(w, w->surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
}
static void decor_close(struct libdecor_frame *frame, void *data) {
    (void)frame; ((ZenitWaylandWindow *)data)->close_requested = 1;
}
static void decor_configure(struct libdecor_frame *frame, struct libdecor_configuration *configuration, void *data) {
    ZenitWaylandWindow *w = data;
    int width = (int)w->width, height = (int)w->height;
    enum libdecor_window_state flags;
    if (w->decor_api.window_state(configuration, &flags)) {
        w->decor_window_state = (uint32_t)flags;
        int focused = (flags & LIBDECOR_WINDOW_STATE_ACTIVE) != 0;
        if (w->input.focused && !focused) cancel_pointer_buttons(w);
        w->input.focused = (uint32_t)focused;
        w->maximized = (flags & LIBDECOR_WINDOW_STATE_MAXIMIZED) != 0;
    }
    w->decor_api.content_size(configuration, frame, &width, &height);
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) { w->closed = 1; return; }
    struct libdecor_state *state = w->decor_api.state_new(width, height);
    if (!state) { w->closed = 1; return; }
    w->decor_api.commit(frame, state, configuration);
    w->decor_api.state_free(state);
    w->width = w->pending_width = (uint32_t)width;
    w->height = w->pending_height = (uint32_t)height;
    w->toplevel = w->decor_api.get_toplevel(frame);
    w->configured = 1;
    w->chrome_state_generation++;
    shadow_sync(w);
}
static void decor_dismiss_popup(struct libdecor_frame *frame, const char *seat_name, void *data) {
    /* Zenit popovers are rendered in the content surface, not native xdg_popup
     * grabs. There is no separate compositor popup grab to release here. */
    (void)frame; (void)seat_name; (void)data;
}
static const struct libdecor_frame_interface decor_frame_interface = {
    .configure = decor_configure, .close = decor_close, .commit = decor_commit, .dismiss_popup = decor_dismiss_popup,
};
static int init_decor(ZenitWaylandWindow *w, const char *title) {
    w->decor_library = dlopen("libdecor-0.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!w->decor_library) { fprintf(stderr, "Linux windows require libdecor-0 and a decoration plugin\n"); return 0; }
#define DECOR_LOAD(field, symbol) do { *(void **)(&w->decor_api.field) = dlsym(w->decor_library, symbol); if (!w->decor_api.field) return 0; } while (0)
    DECOR_LOAD(new_context, "libdecor_new"); DECOR_LOAD(unref, "libdecor_unref");
    DECOR_LOAD(get_fd, "libdecor_get_fd"); DECOR_LOAD(dispatch, "libdecor_dispatch");
    DECOR_LOAD(decorate, "libdecor_decorate"); DECOR_LOAD(frame_unref, "libdecor_frame_unref");
    DECOR_LOAD(set_title, "libdecor_frame_set_title"); DECOR_LOAD(set_app_id, "libdecor_frame_set_app_id");
    DECOR_LOAD(map, "libdecor_frame_map"); DECOR_LOAD(commit, "libdecor_frame_commit");
    DECOR_LOAD(state_new, "libdecor_state_new"); DECOR_LOAD(state_free, "libdecor_state_free");
    DECOR_LOAD(content_size, "libdecor_configuration_get_content_size");
    DECOR_LOAD(window_state, "libdecor_configuration_get_window_state");
    DECOR_LOAD(get_toplevel, "libdecor_frame_get_xdg_toplevel");
    DECOR_LOAD(maximize, "libdecor_frame_set_maximized"); DECOR_LOAD(unmaximize, "libdecor_frame_unset_maximized");
    DECOR_LOAD(translate, "libdecor_frame_translate_coordinate");
    DECOR_LOAD(minimize, "libdecor_frame_set_minimized"); DECOR_LOAD(close, "libdecor_frame_close");
    /* Optional chrome extensions must not break native-window startup. */
    *(void **)(&w->decor_api.visibility) = dlsym(w->decor_library, "libdecor_frame_set_visibility");
    *(void **)(&w->decor_api.is_visible) = dlsym(w->decor_library, "libdecor_frame_is_visible");
    *(void **)(&w->decor_api.move) = dlsym(w->decor_library, "libdecor_frame_move");
    *(void **)(&w->decor_api.resize) = dlsym(w->decor_library, "libdecor_frame_resize");
    *(void **)(&w->decor_api.fullscreen) = dlsym(w->decor_library, "libdecor_frame_set_fullscreen");
    *(void **)(&w->decor_api.unfullscreen) = dlsym(w->decor_library, "libdecor_frame_unset_fullscreen");
    *(void **)(&w->decor_api.wm_capabilities) = dlsym(w->decor_library, "libdecor_frame_get_wm_capabilities");
    *(void **)(&w->decor_api.has_capability) = dlsym(w->decor_library, "libdecor_frame_has_capability");
#undef DECOR_LOAD
    w->decor = w->decor_api.new_context(w->display, &decor_interface);
    if (!w->decor) return 0;
    w->decor_frame = w->decor_api.decorate(w->decor, w->surface, &decor_frame_interface, w);
    if (!w->decor_frame) return 0;
    w->decor_api.set_title(w->decor_frame, title);
    w->decor_api.set_app_id(w->decor_frame, "engineering.zenit");
    w->decor_api.map(w->decor_frame);
    return 1;
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
    (void)time; ZenitWaylandWindow *w = data;
    w->api.destroy_proxy((struct wl_proxy *)callback); w->frame = NULL; w->frame_ready = 1;
    ++w->frame_tick;
}
static const struct wl_callback_listener frame_listener = { .done = frame_done };
uint64_t zenit_wayland_frame_tick(const ZenitWaylandWindow *w) {
    return w ? w->frame_tick : 0;
}
float zenit_wayland_refresh_rate(const ZenitWaylandWindow *w) {
    if (w) for (size_t i = 0; i < 16; ++i)
        if (w->outputs[i].entered && w->outputs[i].refresh_millihz > 0)
            return (float)w->outputs[i].refresh_millihz / 1000.0f;
    return 60.0f;
}

int zenit_wayland_poll(ZenitWaylandWindow *w, int timeout_ms) {
    if (!w || w->closed || timeout_ms < 0) return 0;
    clipboard_io(w);
    if (w->decor && w->decor_api.dispatch(w->decor, 0) < 0) { w->closed = 1; return -1; }
    if (w->closed) return 0;
    while (w->api.prepare_read(w->display) != 0)
        if (w->api.dispatch_pending(w->display) < 0) { w->closed = 1; return -1; }
    // Decoration dispatch may already have delivered input. Do not sleep an
    // extra idle interval before handing that input to the UI.
    if (w->event_count || w->button_count || w->scroll_x != 0 || w->scroll_y != 0) timeout_ms = 0;
    int flush = w->api.flush(w->display);
    if (flush < 0 && errno != EAGAIN) { w->api.cancel_read(w->display); w->closed = 1; return -1; }
    struct pollfd fds[11] = {{ .fd = w->api.get_fd(w->display), .events = POLLIN | (flush < 0 ? POLLOUT : 0) }};
    size_t fd_count = 1 + clipboard_pollfds(w, fds + 1);
    if (w->decor) fds[fd_count++] = (struct pollfd){ .fd = w->decor_api.get_fd(w->decor), .events = POLLIN };
    if (fd_count > 1 && timeout_ms > 100) timeout_ms = 100;
    int result;
    timeout_ms = cursor_poll_timeout(w, keyboard_poll_timeout(w, timeout_ms));
    do { result = poll(fds, fd_count, timeout_ms); } while (result < 0 && errno == EINTR);
    if (result < 0 || (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL))) {
        w->api.cancel_read(w->display); w->closed = 1; return -1;
    }
    if (fds[0].revents & POLLIN) {
        if (w->api.read_events(w->display) < 0) { w->closed = 1; return -1; }
    } else w->api.cancel_read(w->display);
    if (fds[0].revents & POLLOUT) {
        if (w->api.flush(w->display) < 0 && errno != EAGAIN) { w->closed = 1; return -1; }
    }
    if (w->api.dispatch_pending(w->display) < 0) { w->closed = 1; return -1; }
    if (w->decor && w->decor_api.dispatch(w->decor, 0) < 0) { w->closed = 1; return -1; }
    clipboard_io(w);
    keyboard_repeat_due(w); cursor_animation_due(w);
    return w->closed ? 0 : 1;
}

void zenit_wayland_set_title(ZenitWaylandWindow *w, const char *title) {
    if (!w || !title || !w->decor_frame || !w->decor_api.set_title) return;
    w->decor_api.set_title(w->decor_frame, title);
}

void zenit_wayland_destroy(ZenitWaylandWindow *w) {
    if (!w) return;
    for (size_t i = 0; i < sizeof(live_windows) / sizeof(live_windows[0]); ++i)
        if (live_windows[i] == w) live_windows[i] = NULL;
    destroy_text_input(w);
    destroy_clipboard(w);
    for (uint32_t i = 0; i < w->event_count; ++i) free(w->events[(w->event_head + i) % 128].owned_text);
    if (w->display) {
        destroy_cursor_state(w);
        if (w->keyboard) w->api.destroy_proxy((struct wl_proxy *)w->keyboard);
        if (w->pointer) w->api.destroy_proxy((struct wl_proxy *)w->pointer);
        if (w->seat) w->api.destroy_proxy((struct wl_proxy *)w->seat);
        if (w->frame) w->api.destroy_proxy((struct wl_proxy *)w->frame);
        shadow_destroy(w);
        destroy_request(w, w->subcompositor, 1);
        destroy_request(w, w->fractional, 1); destroy_request(w, w->viewport, 1);
        destroy_request(w, w->fractional_manager, 1); destroy_request(w, w->viewporter, 1);
        if (w->decor_frame) { w->decor_api.frame_unref(w->decor_frame); w->decor_frame = NULL; w->toplevel = NULL; }
        if (w->decor) { w->decor_api.unref(w->decor); w->decor = NULL; }
        destroy_request(w, w->toplevel, 1); destroy_request(w, w->xdg, 1);
        destroy_request(w, w->surface, w->compositor_version); destroy_request(w, w->shell, 1);
        for (size_t i = 0; i < 16; ++i) if (w->outputs[i].proxy)
            w->api.destroy_proxy((struct wl_proxy *)w->outputs[i].proxy);
        if (w->compositor) w->api.destroy_proxy((struct wl_proxy *)w->compositor);
        if (w->registry) w->api.destroy_proxy((struct wl_proxy *)w->registry);
        w->api.flush(w->display); w->api.disconnect(w->display);
    }
    destroy_keyboard_state(w);
    free(w->shadow); free(w->shadow_look);
    if (w->decor_library) dlclose(w->decor_library);
    if (w->library) dlclose(w->library);
    free(w);
}

ZenitWaylandWindow *zenit_wayland_create(const char *title, uint32_t width, uint32_t height) {
    if (!title || !width || !height || width > 16384 || height > 16384) return NULL;
    ZenitWaylandWindow *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    chrome_settings_read(w);
    w->clipboard = calloc(1, sizeof(*w->clipboard));
    if (!w->clipboard) { free(w); return NULL; }
    w->text_input = calloc(1, sizeof(*w->text_input));
    if (!w->text_input) { free(w->clipboard); free(w); return NULL; }
    w->clipboard->thread = pthread_self(); w->clipboard->receive_fd = -1;
    for (size_t i = 0; i < 8; ++i) w->clipboard->sends[i].fd = -1;
    w->scale = 1; w->width = w->pending_width = width; w->height = w->pending_height = height;
    w->shadow = calloc(SHADOW_STRIPS, sizeof(*w->shadow)); w->shadow_look = calloc(1, sizeof(*w->shadow_look));
    if (!w->shadow || !w->shadow_look) goto fail;
    w->frame_ready = 1; w->repeat_key = UINT32_MAX;
    w->library = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!w->library) goto fail;
#define LOAD(field, symbol) do { *(void **)(&w->api.field) = dlsym(w->library, symbol); if (!w->api.field) goto fail; } while (0)
    LOAD(connect, "wl_display_connect"); LOAD(disconnect, "wl_display_disconnect");
    LOAD(get_fd, "wl_display_get_fd"); LOAD(roundtrip, "wl_display_roundtrip");
    LOAD(prepare_read, "wl_display_prepare_read"); LOAD(cancel_read, "wl_display_cancel_read");
    LOAD(read_events, "wl_display_read_events"); LOAD(dispatch_pending, "wl_display_dispatch_pending");
    LOAD(flush, "wl_display_flush"); LOAD(add_listener, "wl_proxy_add_listener");
    LOAD(proxy_version, "wl_proxy_get_version");
    LOAD(destroy_proxy, "wl_proxy_destroy"); LOAD(marshal, "wl_proxy_marshal_array_flags");
#undef LOAD
    w->display = w->api.connect(NULL);
    if (!w->display) goto fail;
    union wl_argument new_id[] = { { .o = NULL } };
    w->registry = (struct wl_registry *)request(w, w->display, WL_DISPLAY_GET_REGISTRY, &wl_registry_interface, 1, 0, new_id);
    if (!w->registry || listen(w, w->registry, &registry_listener, w) != 0) goto fail;
    if (w->api.roundtrip(w->display) < 0 || w->closed || !w->compositor || !w->shell) goto fail;
    if (!init_clipboard(w)) goto fail;
    if (!init_text_input(w)) goto fail;
    w->surface = (struct wl_surface *)request(w, w->compositor, WL_COMPOSITOR_CREATE_SURFACE, &wl_surface_interface, w->compositor_version, 0, new_id);
    if (!w->surface || listen(w, w->surface, &surface_listener, w) != 0) goto fail;
    if (!init_fractional_scaling(w)) goto fail;
    if (!init_decor(w, title)) goto fail;
    // Bound initial configure wait; never attach a buffer before ack_configure.
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!w->configured) {
        if (zenit_wayland_poll(w, 100) <= 0) goto fail;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5) goto fail;
    }
    for (size_t i = 0; i < sizeof(live_windows) / sizeof(live_windows[0]); ++i)
        if (!live_windows[i]) { live_windows[i] = w; break; }
    return w;
fail:
    zenit_wayland_destroy(w);
    return NULL;
}

int zenit_wayland_metrics(ZenitWaylandWindow *w, ZenitWaylandSurface *out) {
    if (!w || !out || !w->configured || w->closed) return 0;
    *out = (ZenitWaylandSurface){ .display = w->display, .surface = w->surface,
        .logical_width = w->width, .logical_height = w->height,
        .pixel_width = scaled_dimension(w, w->width),
        .pixel_height = scaled_dimension(w, w->height),
        .scale = w->fractional ? (float)w->preferred_scale / 120.0f : (float)w->scale };
    w->metric_logical_width = out->logical_width; w->metric_logical_height = out->logical_height;
    w->metric_pixel_width = out->pixel_width; w->metric_pixel_height = out->pixel_height;
    return 1;
}
/* Called by the GPU backends right before a buffer of pixel_width x
 * pixel_height is committed to wl_surface: the destination is sent first on
 * the same connection, so the compositor applies both in that one commit. */
void zenit_wayland_before_present(void *wl_surface, uint32_t pixel_width, uint32_t pixel_height) {
    ZenitWaylandWindow *w = NULL;
    for (size_t i = 0; i < sizeof(live_windows) / sizeof(live_windows[0]); ++i)
        if (live_windows[i] && live_windows[i]->surface == wl_surface) { w = live_windows[i]; break; }
    if (!w || !w->viewport || w->closed || !pixel_width || !pixel_height) return;
    uint32_t width, height;
    if (pixel_width == w->metric_pixel_width && pixel_height == w->metric_pixel_height) {
        width = w->metric_logical_width; height = w->metric_logical_height;
    } else {
        uint32_t scale = w->preferred_scale ? w->preferred_scale : 120;
        width = (uint32_t)(((uint64_t)pixel_width * 120 + scale / 2) / scale);
        height = (uint32_t)(((uint64_t)pixel_height * 120 + scale / 2) / scale);
    }
    if (!width || !height || (width == w->viewport_width && height == w->viewport_height)) return;
    w->viewport_width = width; w->viewport_height = height;
    union wl_argument args[] = { { .i = (int32_t)width }, { .i = (int32_t)height } };
    request(w, w->viewport, WP_VIEWPORT_SET_DESTINATION, NULL, 1, 0, args);
}
int zenit_wayland_request_frame(ZenitWaylandWindow *w) {
    if (!w || !w->configured || w->closed || !w->frame_ready || w->frame) return 0;
    union wl_argument args[] = { { .o = NULL } };
    w->frame = (struct wl_callback *)request(w, w->surface, WL_SURFACE_FRAME, &wl_callback_interface, 1, 0, args);
    if (!w->frame || listen(w, w->frame, &frame_listener, w) != 0) { w->closed = 1; return -1; }
    w->frame_ready = 0;
    return 1;
}
void zenit_wayland_cancel_frame(ZenitWaylandWindow *w) {
    if (!w) return;
    if (w->frame) w->api.destroy_proxy((struct wl_proxy *)w->frame);
    w->frame = NULL; w->frame_ready = 1;
}
int zenit_wayland_request_frame_clock(ZenitWaylandWindow *w) {
    int result = zenit_wayland_request_frame(w);
    // A clock restarted after an idle period must advance even when the
    // runtime's duplicate-tick gate has not admitted a new GPU frame yet.
    if (result == 1) request(w, w->surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
    return result;
}
int zenit_wayland_set_maximized(ZenitWaylandWindow *w, int maximized) {
    if (!w || !w->toplevel || w->closed) return 0;
    if (w->decor_frame) {
        if (maximized) w->decor_api.maximize(w->decor_frame); else w->decor_api.unmaximize(w->decor_frame);
        return 1;
    }
    request(w, w->toplevel, maximized ? XDG_TOPLEVEL_SET_MAXIMIZED : XDG_TOPLEVEL_UNSET_MAXIMIZED,
        NULL, 1, 0, NULL);
    return 1;
}

int zenit_wayland_set_minimized(ZenitWaylandWindow *w) {
    if (!w || !w->decor_frame || w->closed) return 0;
    w->decor_api.minimize(w->decor_frame);
    return 1;
}
int zenit_wayland_close(ZenitWaylandWindow *w) {
    if (!w || !w->decor_frame || w->closed) return 0;
    w->decor_api.close(w->decor_frame);
    return 1;
}
int zenit_wayland_decoration_height(ZenitWaylandWindow *w) {
    if (!w || !w->decor_frame || !w->configured) return 0;
    int x = 0, y = 0;
    w->decor_api.translate(w->decor_frame, 0, 0, &x, &y);
    return y;
}
uint32_t zenit_wayland_window_state(ZenitWaylandWindow *w) { return w ? w->decor_window_state : 0; }
int zenit_wayland_has_decorations(ZenitWaylandWindow *w) {
    return w && w->decor_frame && w->configured && !w->closed && (!w->chrome_mode || w->decoration_manager_seen);
}
int zenit_wayland_set_size(ZenitWaylandWindow *w, uint32_t width, uint32_t height) {
    if (!w || !w->toplevel || w->closed || !width || !height || width > 16384 || height > 16384) return 0;
    if (w->decor_frame) {
        if (w->maximized) w->decor_api.unmaximize(w->decor_frame);
        struct libdecor_state *state = w->decor_api.state_new((int)width, (int)height);
        if (!state) return 0;
        w->decor_api.commit(w->decor_frame, state, NULL);
        w->decor_api.state_free(state);
        w->width = w->pending_width = width; w->height = w->pending_height = height;
        shadow_sync(w);
        request(w, w->surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
        return 1;
    }
    w->size_requested = 1;
    w->requested_width = width;
    w->requested_height = height;
    /* Clear old constraints before installing both new bounds: no transient
     * min > max state when changing either dimension. */
    union wl_argument clear[] = { { .i = 0 }, { .i = 0 } };
    request(w, w->toplevel, XDG_TOPLEVEL_SET_MAX_SIZE, NULL, 1, 0, clear);
    request(w, w->toplevel, XDG_TOPLEVEL_SET_MIN_SIZE, NULL, 1, 0, clear);
    union wl_argument bounds[] = { { .i = (int32_t)width }, { .i = (int32_t)height } };
    request(w, w->toplevel, XDG_TOPLEVEL_SET_MAX_SIZE, NULL, 1, 0, bounds);
    request(w, w->toplevel, XDG_TOPLEVEL_SET_MIN_SIZE, NULL, 1, 0, bounds);
    /* A maximized compositor ignores normal-size constraints. Restore first;
     * the configure acknowledgement still owns the actual resulting extent. */
    if (w->maximized) request(w, w->toplevel, XDG_TOPLEVEL_UNSET_MAXIMIZED, NULL, 1, 0, NULL);
    request(w, w->surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
    return 1;
}

/* Configure before UI mount. 2: SSD negotiation unobservable; 3: API missing. */
int zenit_wayland_chrome_configure(ZenitWaylandWindow *w, int mode) {
    if (!w || !w->decor_frame || w->closed) return 3;
    if (mode && w->decoration_manager_seen) return 2;
    if (mode && (!w->decor_api.visibility || !w->decor_api.move || !w->decor_api.resize)) return 3;
    w->chrome_mode = mode;
    if (w->decor_api.visibility) w->decor_api.visibility(w->decor_frame, mode == 0);
    shadow_sync(w);
    return 0;
}
void zenit_wayland_chrome_hit(ZenitWaylandWindow *w, int (*hit)(void *, float, float), void *context) {
    if (w) { w->chrome_hit = hit; w->chrome_context = hit ? context : NULL; }
}
int zenit_wayland_chrome_minimum(ZenitWaylandWindow *w,uint32_t width,uint32_t height) {
    if(!w||!w->decor_frame)return 0;
    void (*set_min)(struct libdecor_frame *,int,int)=dlsym(w->decor_library,"libdecor_frame_set_min_content_size");
    if(!set_min)return 0;set_min(w->decor_frame,(int)width,(int)height);return 1;
}
void zenit_wayland_chrome_state(ZenitWaylandWindow *w, ZenitChromeState *out) {
    memset(out, 0, sizeof(*out));
    if (!w || w->closed) return;
    out->state_generation = w->chrome_state_generation;
    out->appearance=w->chrome_appearance;
    chrome_button_layout(w->chrome_button_layout,out->button_layout);
    out->flags = ((w->decor_window_state & 2) ? 1 : 0) | ((w->decor_window_state & 4) ? 2 : 0) | ((w->decor_window_state & 1) ? 4 : 0);
    out->corner_radius = shadow_corner_radius(w);
    if(w->decor_window_state & (LIBDECOR_WINDOW_STATE_TILED_LEFT|LIBDECOR_WINDOW_STATE_TILED_RIGHT|LIBDECOR_WINDOW_STATE_TILED_TOP|LIBDECOR_WINDOW_STATE_TILED_BOTTOM))out->flags|=32;
    if (!w->decoration_manager_seen && w->decor_api.visibility && w->decor_api.move && w->decor_api.resize) out->capabilities |= 3;
    /* 0.2.x ignores wm_capabilities and has no getter. Report request APIs
     * from its application mask, explicitly marking WM support as unknown. */
    int minimize=0, maximize=0, fullscreen=0;
    if (w->decor_api.wm_capabilities && w->toplevel && w->configured && w->api.proxy_version((struct wl_proxy *)w->toplevel)>=5) {
        enum libdecor_wm_capabilities caps=w->decor_api.wm_capabilities(w->decor_frame);
        out->flags |= 16;
        minimize=!!(caps & LIBDECOR_WM_CAPABILITIES_MINIMIZE);
        maximize=!!(caps & LIBDECOR_WM_CAPABILITIES_MAXIMIZE);
        fullscreen=!!(caps & LIBDECOR_WM_CAPABILITIES_FULLSCREEN);
    } else if (w->decor_api.has_capability) {
        minimize=w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_MINIMIZE);
        maximize=w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_RESIZE);
        fullscreen=w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_FULLSCREEN);
    }
    if (w->decor_api.has_capability) {
        minimize &= w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_MINIMIZE);
        maximize &= w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_RESIZE);
        fullscreen &= w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_FULLSCREEN);
    }
    if (minimize && w->decor_api.minimize) out->capabilities |= 4;
    if (maximize && w->decor_api.maximize && w->decor_api.unmaximize) out->capabilities |= 8;
    if (fullscreen && w->decor_api.fullscreen && w->decor_api.unfullscreen) out->capabilities |= 16;
    if (w->decor_api.move && (!w->decor_api.has_capability || w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_MOVE))) out->capabilities |= 32;
    if (w->decor_api.resize && (!w->decor_api.has_capability || w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_RESIZE))) out->capabilities |= 64;
}
int zenit_wayland_chrome_action(ZenitWaylandWindow *w, int action, int value) {
    if (!w || !w->decor_frame || w->closed) return 0;
    switch (action) {
    case 0: w->close_requested = 1; return 1;
    case 1: return zenit_wayland_set_minimized(w);
    case 2: return zenit_wayland_set_maximized(w, value);
    case 3:
        if (!w->decor_api.fullscreen || !w->decor_api.unfullscreen) return 0;
        if (value) w->decor_api.fullscreen(w->decor_frame, NULL); else w->decor_api.unfullscreen(w->decor_frame);
        return 1;
    default: return 0;
    }
}
int zenit_wayland_close_requested(ZenitWaylandWindow *w) { return w && w->close_requested; }
void zenit_wayland_reset_close(ZenitWaylandWindow *w) { if (w) w->close_requested = 0; }
