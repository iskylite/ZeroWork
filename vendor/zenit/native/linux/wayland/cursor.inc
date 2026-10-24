/* Fixed cursor shapes are negotiated independently of renderer/window pixels.
 * Prefer compositor-owned themes. wl_shm/libwayland-cursor is the fallback for
 * compositors without cursor-shape-v1; buffers remain owned by the theme. */
static const uint32_t cursor_protocol_shapes[18] = {
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COL_RESIZE,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ROW_RESIZE, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT,
    WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS, WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP,
};
static const char *cursor_theme_names[18][2] = {
    {"default", "left_ptr"}, {"default", "left_ptr"}, {"pointer", "hand2"},
    {"text", "xterm"}, {"crosshair", "cross"}, {"move", "fleur"},
    {"not-allowed", "crossed_circle"}, {"grab", "openhand"}, {"grabbing", "closedhand"},
    {"ew-resize", "sb_h_double_arrow"}, {"ns-resize", "sb_v_double_arrow"},
    {"nwse-resize", "size_fdiag"}, {"nesw-resize", "size_bdiag"},
    {"col-resize", "sb_h_double_arrow"}, {"row-resize", "sb_v_double_arrow"},
    {"wait", "watch"}, {"progress", "left_ptr_watch"}, {"help", "question_arrow"},
};
static void init_cursor_device(ZenitWaylandWindow *w) {
    if (!w->cursor_manager || !w->pointer || w->cursor_device) return;
    union wl_argument args[] = {{.o = NULL}, {.o = (struct wl_object *)w->pointer}};
    w->cursor_device = (struct wp_cursor_shape_device_v1 *)request(w, w->cursor_manager,
        WP_CURSOR_SHAPE_MANAGER_V1_GET_POINTER, &wp_cursor_shape_device_v1_interface, 1, 0, args);
    if (!w->cursor_device) w->closed = 1;
}
static int load_cursor_library(ZenitWaylandWindow *w) {
    if (w->cursor_library) return w->cursor_api.theme_load != NULL;
    w->cursor_library = dlopen("libwayland-cursor.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!w->cursor_library) return 0;
#define CURSOR_LOAD(field, symbol) do { *(void **)(&w->cursor_api.field) = dlsym(w->cursor_library, symbol); if (!w->cursor_api.field) { memset(&w->cursor_api, 0, sizeof(w->cursor_api)); return 0; } } while (0)
    CURSOR_LOAD(theme_load, "wl_cursor_theme_load"); CURSOR_LOAD(theme_destroy, "wl_cursor_theme_destroy");
    CURSOR_LOAD(theme_cursor, "wl_cursor_theme_get_cursor"); CURSOR_LOAD(image_buffer, "wl_cursor_image_get_buffer");
    CURSOR_LOAD(frame_duration, "wl_cursor_frame_and_duration");
#undef CURSOR_LOAD
    return 1;
}
static int load_cursor_theme(ZenitWaylandWindow *w) {
    if (!w->shm || !load_cursor_library(w)) return 0;
    uint32_t preferred = w->preferred_scale ? w->preferred_scale : (uint32_t)w->scale * 120;
    int scale = (int)((preferred + 119) / 120);
    if (scale < 1) scale = 1;
    if (w->compositor_version < 3) scale = 1;
    if (w->cursor_theme && w->cursor_scale == scale) return 1;
    int size = 24;
    const char *size_env = getenv("XCURSOR_SIZE");
    if (size_env && *size_env) {
        char *end = NULL; long value = strtol(size_env, &end, 10);
        if (end && !*end && value >= 1 && value <= 256) size = (int)value;
    }
    if (scale > 16) return 0;
    struct wl_cursor_theme *theme = w->cursor_api.theme_load(getenv("XCURSOR_THEME"), size * scale, w->shm);
    if (!theme) return 0;
    w->theme_cursor = NULL; w->cursor_deadline = 0;
    if (w->cursor_theme) w->cursor_api.theme_destroy(w->cursor_theme);
    w->cursor_theme = theme; w->cursor_scale = scale;
    return 1;
}
static int render_cursor_image(ZenitWaylandWindow *w, struct wl_cursor_image *image) {
    struct wl_buffer *buffer = w->cursor_api.image_buffer(image);
    if (!buffer || !image->width || !image->height || image->width > 16384 || image->height > 16384) return 0;
    if (!w->cursor_surface) {
        union wl_argument args[] = {{.o = NULL}};
        w->cursor_surface = (struct wl_surface *)request(w, w->compositor, WL_COMPOSITOR_CREATE_SURFACE,
            &wl_surface_interface, w->compositor_version, 0, args);
        if (!w->cursor_surface) return 0;
    }
    union wl_argument cursor[] = {{.u = w->pointer_enter_serial}, {.o = (struct wl_object *)w->cursor_surface},
        {.i = (int32_t)(image->hotspot_x / (uint32_t)w->cursor_scale)}, {.i = (int32_t)(image->hotspot_y / (uint32_t)w->cursor_scale)}};
    request(w, w->pointer, WL_POINTER_SET_CURSOR, NULL, 1, 0, cursor);
    if (w->compositor_version >= 3) {
        union wl_argument scale[] = {{.i = w->cursor_scale}};
        request(w, w->cursor_surface, WL_SURFACE_SET_BUFFER_SCALE, NULL, w->compositor_version, 0, scale);
    }
    union wl_argument attach[] = {{.o = (struct wl_object *)buffer}, {.i = 0}, {.i = 0}};
    request(w, w->cursor_surface, WL_SURFACE_ATTACH, NULL, w->compositor_version, 0, attach);
    union wl_argument damage[] = {{.i = 0}, {.i = 0}, {.i = (int32_t)image->width}, {.i = (int32_t)image->height}};
    request(w, w->cursor_surface, w->compositor_version >= 4 ? WL_SURFACE_DAMAGE_BUFFER : WL_SURFACE_DAMAGE,
        NULL, w->compositor_version, 0, damage);
    request(w, w->cursor_surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
    return 1;
}
/* Set `shape` (an index below 18, or 18 = hidden) for the latest pointer enter. */
static int apply_cursor_shape(ZenitWaylandWindow *w, uint32_t shape) {
    w->cursor_deadline = 0; w->theme_cursor = NULL;
    if (shape == 18) {
        union wl_argument args[] = {{.u = w->pointer_enter_serial}, {.o = NULL}, {.i = 0}, {.i = 0}};
        request(w, w->pointer, WL_POINTER_SET_CURSOR, NULL, 1, 0, args);
    } else if (w->cursor_device) {
        union wl_argument args[] = {{.u = w->pointer_enter_serial}, {.u = cursor_protocol_shapes[shape]}};
        request(w, w->cursor_device, WP_CURSOR_SHAPE_DEVICE_V1_SET_SHAPE, NULL, 1, 0, args);
    } else {
        if (!load_cursor_theme(w)) return 0;
        struct wl_cursor *cursor = w->cursor_api.theme_cursor(w->cursor_theme, cursor_theme_names[shape][0]);
        if (!cursor) cursor = w->cursor_api.theme_cursor(w->cursor_theme, cursor_theme_names[shape][1]);
        if (!cursor || !cursor->image_count || !cursor->images || !render_cursor_image(w, cursor->images[0])) return 0;
        w->theme_cursor = cursor; w->cursor_epoch = keyboard_now();
        if (cursor->image_count > 1) w->cursor_deadline = w->cursor_epoch + (int64_t)(cursor->images[0]->delay ? cursor->images[0]->delay : 16) * 1000000;
    }
    return 1;
}
static int apply_cursor(ZenitWaylandWindow *w) {
    w->cursor_deadline = 0; w->theme_cursor = NULL;
    if (!w->pointer_focused || !w->pointer || w->cursor_shape == 20) return 1;
    if (!apply_cursor_shape(w, w->cursor_shape)) return 0;
    w->cursor_apply_count++; w->cursor_applied_shape = w->cursor_shape;
    return 1;
}
static int cursor_poll_timeout(ZenitWaylandWindow *w, int timeout) {
    if (!w->cursor_deadline) return timeout;
    int64_t left = w->cursor_deadline - keyboard_now();
    int ms = left <= 0 ? 0 : (int)((left + 999999) / 1000000);
    return ms < timeout ? ms : timeout;
}
static void cursor_animation_due(ZenitWaylandWindow *w) {
    if (!w->cursor_deadline || keyboard_now() < w->cursor_deadline || !w->pointer_focused || !w->theme_cursor) return;
    uint32_t duration = 0;
    uint32_t elapsed = (uint32_t)((keyboard_now() - w->cursor_epoch) / 1000000);
    int frame = w->cursor_api.frame_duration(w->theme_cursor, elapsed, &duration);
    if (frame < 0 || (unsigned)frame >= w->theme_cursor->image_count || !render_cursor_image(w, w->theme_cursor->images[frame])) {
        w->cursor_deadline = 0; return;
    }
    w->cursor_deadline = keyboard_now() + (int64_t)(duration ? duration : 16) * 1000000;
}
int zenit_wayland_cursor_available(ZenitWaylandWindow *w) {
    if (!w || w->closed || !w->pointer) return 0;
    init_cursor_device(w);
    return w->cursor_device != NULL || load_cursor_theme(w);
}
int zenit_wayland_set_cursor(ZenitWaylandWindow *w, uint32_t shape) {
    if (!w || w->closed || shape > 20 || shape == 19) return 0;
    if (shape != 20 && !zenit_wayland_cursor_available(w)) return 0;
    w->cursor_shape = shape;
    return apply_cursor(w);
}
int zenit_wayland_cursor_state(ZenitWaylandWindow *w, ZenitWaylandCursorState *out) {
    if (!w || !out) return 0;
    *out = (ZenitWaylandCursorState){w->cursor_shape, w->cursor_applied_shape, w->cursor_apply_count,
        (uint32_t)w->pointer_focused, (uint32_t)(w->cursor_device != NULL), (uint32_t)w->cursor_scale};
    return 1;
}
static void destroy_cursor_device(ZenitWaylandWindow *w) {
    destroy_request(w, w->cursor_device, 1); w->cursor_device = NULL;
    w->pointer_focused = 0; w->cursor_deadline = 0;
}
static void destroy_cursor_state(ZenitWaylandWindow *w) {
    destroy_cursor_device(w);
    destroy_request(w, w->cursor_surface, w->compositor_version); w->cursor_surface = NULL;
    if (w->cursor_theme) w->cursor_api.theme_destroy(w->cursor_theme);
    if (w->cursor_library) dlclose(w->cursor_library);
    destroy_request(w, w->cursor_manager, 1);
    if (w->shm) w->api.destroy_proxy((struct wl_proxy *)w->shm);
}

static void shm_format(void *data, struct wl_shm *shm, uint32_t format) {
    (void)data; (void)shm; (void)format;
}
static const struct wl_shm_listener shm_listener = {.format = shm_format};
