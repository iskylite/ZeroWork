/* Compositor-provided XKB map/state. Wayland evdev codes gain 8 only at the
 * xkbcommon boundary. Client state follows modifiers events, not update_key. */
static int64_t keyboard_now(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}
static uint32_t keyboard_modifiers(ZenitWaylandWindow *w) {
    if (!w->xkb_state) return 0;
    uint32_t result = 0;
    const char *names[] = {XKB_MOD_NAME_SHIFT, XKB_MOD_NAME_CTRL, XKB_MOD_NAME_ALT, XKB_MOD_NAME_LOGO};
    for (uint32_t i = 0; i < 4; ++i)
        if (w->xkb.mod_active(w->xkb_state, names[i], XKB_STATE_MODS_EFFECTIVE) > 0) result |= 1u << i;
    return result;
}
static int enqueue_input(ZenitWaylandWindow *w, ZenitWaylandInputEvent event) {
    if (w->event_count == 128) { free(event.owned_text); fprintf(stderr, "Wayland ordered input queue overflow\n"); w->closed = 1; return 0; }
    w->events[(w->event_head + w->event_count++) % 128] = event;
    return 1;
}
static void cancel_keyboard(ZenitWaylandWindow *w) {
    w->repeat_key = UINT32_MAX; w->repeat_deadline = 0;
    for (uint32_t key = 0; key < 768; ++key) if (w->held_keys[key]) {
        w->held_keys[key] = 0;
        enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 2, .keycode = key, .modifiers = keyboard_modifiers(w) });
    }
    if (w->compose_state) w->xkb.compose_reset(w->compose_state);
    if (w->xkb_state) w->xkb.update_mask(w->xkb_state, 0, 0, 0, 0, 0, 0);
}
static int init_keyboard_library(ZenitWaylandWindow *w) {
    if (w->xkb_library) return 1;
    w->xkb_library = dlopen("libxkbcommon.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!w->xkb_library) return 0;
#define XKB_LOAD(field, name) do { *(void **)(&w->xkb.field) = dlsym(w->xkb_library, name); if (!w->xkb.field) return 0; } while (0)
    XKB_LOAD(context_new, "xkb_context_new"); XKB_LOAD(context_unref, "xkb_context_unref");
    XKB_LOAD(keymap_new, "xkb_keymap_new_from_string"); XKB_LOAD(keymap_unref, "xkb_keymap_unref");
    XKB_LOAD(state_new, "xkb_state_new"); XKB_LOAD(state_unref, "xkb_state_unref");
    XKB_LOAD(update_mask, "xkb_state_update_mask"); XKB_LOAD(mod_active, "xkb_state_mod_name_is_active");
    XKB_LOAD(key_utf8, "xkb_state_key_get_utf8"); XKB_LOAD(key_sym, "xkb_state_key_get_one_sym");
    XKB_LOAD(key_repeats, "xkb_keymap_key_repeats");
    XKB_LOAD(compose_table_new, "xkb_compose_table_new_from_locale"); XKB_LOAD(compose_table_unref, "xkb_compose_table_unref");
    XKB_LOAD(compose_new, "xkb_compose_state_new"); XKB_LOAD(compose_unref, "xkb_compose_state_unref");
    XKB_LOAD(compose_feed, "xkb_compose_state_feed"); XKB_LOAD(compose_status, "xkb_compose_state_get_status");
    XKB_LOAD(compose_utf8, "xkb_compose_state_get_utf8"); XKB_LOAD(compose_reset, "xkb_compose_state_reset");
#undef XKB_LOAD
    w->xkb_context = w->xkb.context_new(XKB_CONTEXT_NO_FLAGS);
    if (!w->xkb_context) return 0;
    const char *locale = getenv("LC_ALL");
    if (!locale || !*locale) locale = getenv("LC_CTYPE");
    if (!locale || !*locale) locale = getenv("LANG");
    if (!locale || !*locale) locale = "C";
    w->compose_table = w->xkb.compose_table_new(w->xkb_context, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (!w->compose_table && strcmp(locale, "C") != 0)
        w->compose_table = w->xkb.compose_table_new(w->xkb_context, "C", XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (!w->compose_table) return 0;
    w->compose_state = w->xkb.compose_new(w->compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
    return w->compose_state != NULL;
}
static void keyboard_keymap(void *data, struct wl_keyboard *keyboard, uint32_t format, int32_t fd, uint32_t size) {
    (void)keyboard; ZenitWaylandWindow *w = data;
    cancel_keyboard(w);
    if (format == WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP) {
        if (fd >= 0) close(fd);
        if (w->xkb_state) w->xkb.state_unref(w->xkb_state);
        if (w->keymap) w->xkb.keymap_unref(w->keymap);
        w->xkb_state = NULL; w->keymap = NULL;
        return;
    }
    struct stat status;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || size < 1 || size > 64u * 1024 * 1024 ||
        fd < 0 || fstat(fd, &status) != 0 || status.st_size < size || !init_keyboard_library(w)) {
        if (fd >= 0) close(fd);
        w->closed = 1; return;
    }
    void *mapped = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) { w->closed = 1; return; }
    struct xkb_keymap *map = ((char *)mapped)[size - 1] == 0 ?
        w->xkb.keymap_new(w->xkb_context, mapped, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
    munmap(mapped, size);
    struct xkb_state *state = map ? w->xkb.state_new(map) : NULL;
    if (!state) { if (map) w->xkb.keymap_unref(map); w->closed = 1; return; }
    if (w->xkb_state) w->xkb.state_unref(w->xkb_state);
    if (w->keymap) w->xkb.keymap_unref(w->keymap);
    w->keymap = map; w->xkb_state = state;
}
static void keyboard_enter(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface, struct wl_array *keys) {
    (void)keyboard; (void)serial; ZenitWaylandWindow *w = data;
    if (surface != w->surface) return;
    cancel_keyboard(w); w->keyboard_focused = 1;
    if (getenv("ZENIT_WAYLAND_IME_TRACE")) fprintf(stderr, "IME keyboard enter\n");
    if (!keys || keys->size % sizeof(uint32_t)) { w->closed = 1; return; }
    for (size_t i = 0; i < keys->size / sizeof(uint32_t); ++i) {
        uint32_t key; memcpy(&key, (char *)keys->data + i * sizeof(key), sizeof(key));
        if (key < 768) w->held_keys[key] = 1;
    }
}
static void keyboard_leave(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface) {
    (void)keyboard; (void)serial; (void)surface; ZenitWaylandWindow *w = data;
    cancel_keyboard(w); w->keyboard_focused = 0; clipboard_focus_lost(w);
    if (getenv("ZENIT_WAYLAND_IME_TRACE")) fprintf(stderr, "IME keyboard leave\n");
}
static void emit_keyboard_press(ZenitWaylandWindow *w, uint32_t key, int repeat) {
    uint32_t modifiers = keyboard_modifiers(w);
    if (!enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 2, .keycode = key, .pressed = 1, .modifiers = modifiers })) return;
    if (modifiers & (2u | 4u | 8u)) { w->xkb.compose_reset(w->compose_state); return; }
    ZenitWaylandInputEvent text = {.kind = 3};
    int length = 0;
    if (!repeat) w->xkb.compose_feed(w->compose_state, w->xkb.key_sym(w->xkb_state, key + 8));
    enum xkb_compose_status status = w->xkb.compose_status(w->compose_state);
    if (status == XKB_COMPOSE_COMPOSING) return;
    if (status == XKB_COMPOSE_CANCELLED) { w->xkb.compose_reset(w->compose_state); return; }
    if (status == XKB_COMPOSE_COMPOSED) {
        length = w->xkb.compose_utf8(w->compose_state, (char *)text.text, sizeof(text.text));
        w->xkb.compose_reset(w->compose_state);
    } else length = w->xkb.key_utf8(w->xkb_state, key + 8, (char *)text.text, sizeof(text.text));
    if (length < 0 || length >= (int)sizeof(text.text)) { fprintf(stderr, "Wayland keyboard UTF-8 exceeds event capacity\n"); w->closed = 1; return; }
    /* Return/tab/backspace/escape are editing keys, never a duplicate text commit. */
    if (length && text.text[0] >= 32 && text.text[0] != 127) { text.text_length = (uint32_t)length; enqueue_input(w, text); }
}
static void keyboard_key(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)keyboard; (void)serial; (void)time; ZenitWaylandWindow *w = data;
    if (getenv("ZENIT_WAYLAND_IME_TRACE")) fprintf(stderr, "IME raw key received focused=%d pressed=%u\n", w->keyboard_focused, state);
    if (!w->keyboard_focused || !w->xkb_state || key >= 768) return;
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
        clipboard_input_serial(w, serial);
        w->held_keys[key] = 1; emit_keyboard_press(w, key, 0);
        if (w->repeat_rate > 0 && w->xkb.key_repeats(w->keymap, key + 8)) {
            w->repeat_key = key; w->repeat_deadline = keyboard_now() + (int64_t)w->repeat_delay * 1000000;
        }
    } else {
        w->held_keys[key] = 0;
        enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 2, .keycode = key, .modifiers = keyboard_modifiers(w) });
        if (w->repeat_key == key) { w->repeat_key = UINT32_MAX; w->repeat_deadline = 0; }
    }
}
static void keyboard_mods(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void)keyboard; (void)serial; ZenitWaylandWindow *w = data;
    if (w->xkb_state) w->xkb.update_mask(w->xkb_state, depressed, latched, locked, 0, 0, group);
}
static void keyboard_repeat_info(void *data, struct wl_keyboard *keyboard, int32_t rate, int32_t delay) {
    (void)keyboard; ZenitWaylandWindow *w = data;
    if (rate < 0 || rate > 1000 || delay < 0 || delay > 60000) { w->closed = 1; return; }
    w->repeat_rate = rate; w->repeat_delay = delay;
    if (!rate) { w->repeat_key = UINT32_MAX; w->repeat_deadline = 0; }
}
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap, .enter = keyboard_enter, .leave = keyboard_leave,
    .key = keyboard_key, .modifiers = keyboard_mods, .repeat_info = keyboard_repeat_info,
};
static int keyboard_poll_timeout(ZenitWaylandWindow *w, int timeout) {
    if (!w->repeat_deadline) return timeout;
    int64_t left = w->repeat_deadline - keyboard_now();
    int ms = left <= 0 ? 0 : (int)((left + 999999) / 1000000);
    return ms < timeout ? ms : timeout;
}
static void keyboard_repeat_due(ZenitWaylandWindow *w) {
    if (!w->repeat_deadline || !w->keyboard_focused || !w->repeat_rate) return;
    int64_t now = keyboard_now();
    if (now >= w->repeat_deadline) {
        emit_keyboard_press(w, w->repeat_key, 1);
        /* Bound catch-up after a stalled frame; do not flood the input ring. */
        w->repeat_deadline = now + 1000000000 / w->repeat_rate;
    }
}
static void destroy_keyboard_state(ZenitWaylandWindow *w) {
    if (w->xkb_state) w->xkb.state_unref(w->xkb_state);
    if (w->keymap) w->xkb.keymap_unref(w->keymap);
    if (w->compose_state) w->xkb.compose_unref(w->compose_state);
    if (w->compose_table) w->xkb.compose_table_unref(w->compose_table);
    if (w->xkb_context) w->xkb.context_unref(w->xkb_context);
    if (w->xkb_library) dlclose(w->xkb_library);
}
void zenit_wayland_enable_ordered_input(ZenitWaylandWindow *w) { if (w) w->ordered_input = 1; }
int zenit_wayland_peek_input(ZenitWaylandWindow *w) { return w && w->event_count ? (int)w->events[w->event_head].kind : 0; }
int zenit_wayland_peek_input_event(ZenitWaylandWindow *w, ZenitWaylandInputEvent *out) {
    if (!w || !out || !w->event_count) return 0;
    *out = w->events[w->event_head]; return 1;
}
int zenit_wayland_pop_input(ZenitWaylandWindow *w, ZenitWaylandInputEvent *out) {
    if (!w || !out || !w->event_count) return 0;
    *out = w->events[w->event_head];
    if (out->owned_text) { free(out->owned_text); out->owned_text = NULL; out->text_length = 0; }
    memset(&w->events[w->event_head], 0, sizeof(w->events[w->event_head]));
    w->event_head = (w->event_head + 1) % 128; --w->event_count; return 1;
}
