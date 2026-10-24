/* text-input-v3 v1. Raw keys remain independent; SDK integration must consume
 * kinds 6 (preedit), 7 (commit), 8 (surrounding deletion) in this same FIFO. */
#define IME_TRACE(...) do { if (getenv("ZENIT_WAYLAND_IME_TRACE")) fprintf(stderr, __VA_ARGS__); } while (0)
struct TextInputState {
    struct zwp_text_input_manager_v3 *manager;
    struct zwp_text_input_v3 *proxy;
    uint32_t manager_name, serial, session_serial;
    int secure, entered, enabled, active, updating, dirty, has_rect, has_surrounding;
    int32_t x, y, width, height, begin, end;
    char *surrounding, *preedit, *commit;
    uint32_t cursor, anchor, before, after;
};
static void ime_pending_clear(struct TextInputState *c) {
    free(c->preedit); free(c->commit); c->preedit = c->commit = NULL;
    c->begin = c->end = 0; c->before = c->after = 0;
}
static int ime_boundary(const char *text, size_t length, uint32_t index) {
    return index <= length && (index == length || ((unsigned char)text[index] & 0xc0) != 0x80);
}
/* Reject overlong forms, surrogates, truncated sequences and > U+10FFFF. */
static int ime_utf8(const char *text, size_t length) {
    const unsigned char *s = (const unsigned char *)text;
    for (size_t i = 0; i < length;) {
        unsigned char b = s[i++];
        if (b < 0x80) continue;
        unsigned count; uint32_t value, minimum;
        if (b >= 0xc2 && b <= 0xdf) { count = 1; value = b & 0x1f; minimum = 0x80; }
        else if (b >= 0xe0 && b <= 0xef) { count = 2; value = b & 0x0f; minimum = 0x800; }
        else if (b >= 0xf0 && b <= 0xf4) { count = 3; value = b & 7; minimum = 0x10000; }
        else return 0;
        if (count > length - i) return 0;
        while (count--) {
            b = s[i++]; if ((b & 0xc0) != 0x80) return 0;
            value = (value << 6) | (b & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    return 1;
}
/* Compact the wrapped FIFO in place without changing raw input ordering. */
static void ime_purge_queue(ZenitWaylandWindow *w) {
    uint32_t kept = 0;
    for (uint32_t i = 0; i < w->event_count; ++i) {
        uint32_t index = (w->event_head + i) % 128;
        ZenitWaylandInputEvent event = w->events[index];
        memset(&w->events[index], 0, sizeof(event));
        if (event.kind >= 6 && event.kind <= 8) free(event.owned_text);
        else w->events[(w->event_head + kept++) % 128] = event;
    }
    w->event_count = kept;
}
static void ime_commit_request(ZenitWaylandWindow *w) {
    request(w, w->text_input->proxy, ZWP_TEXT_INPUT_V3_COMMIT, NULL, 1, 0, NULL);
    ++w->text_input->serial;
}
static void ime_send_state(ZenitWaylandWindow *w) {
    struct TextInputState *c = w->text_input;
    if (!c->proxy || !c->entered || !c->enabled || !c->updating || !c->dirty) return;
    union wl_argument content[] = {{.u = c->secure ? ZWP_TEXT_INPUT_V3_CONTENT_HINT_HIDDEN_TEXT | ZWP_TEXT_INPUT_V3_CONTENT_HINT_SENSITIVE_DATA : ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE}, {.u = c->secure ? ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PASSWORD : ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL}};
    request(w, c->proxy, ZWP_TEXT_INPUT_V3_SET_CONTENT_TYPE, NULL, 1, 0, content);
    if (c->has_surrounding) {
        union wl_argument args[] = {{.s = c->surrounding}, {.i = (int32_t)c->cursor}, {.i = (int32_t)c->anchor}};
        request(w, c->proxy, ZWP_TEXT_INPUT_V3_SET_SURROUNDING_TEXT, NULL, 1, 0, args);
    }
    if (c->has_rect) {
        union wl_argument args[] = {{.i = c->x}, {.i = c->y}, {.i = c->width}, {.i = c->height}};
        request(w, c->proxy, ZWP_TEXT_INPUT_V3_SET_CURSOR_RECTANGLE, NULL, 1, 0, args);
    }
    c->dirty = 0; ime_commit_request(w);
    IME_TRACE("IME state serial=%u secure=%d surrounding_bytes=%zu rect=%d,%d,%d,%d\n", c->serial, c->secure, c->surrounding ? strlen(c->surrounding) : 0, c->x, c->y, c->width, c->height);
}
static void ime_clear_visible(ZenitWaylandWindow *w) {
    struct TextInputState *c = w->text_input;
    ime_purge_queue(w);
    if (c->active) enqueue_input(w, (ZenitWaylandInputEvent){.kind = 6});
    c->active = 0; ime_pending_clear(c);
}
static void ime_enable_entered(ZenitWaylandWindow *w) {
    struct TextInputState *c = w->text_input;
    if (!c->proxy || !c->entered) return;
    request(w, c->proxy, c->enabled ? ZWP_TEXT_INPUT_V3_ENABLE : ZWP_TEXT_INPUT_V3_DISABLE, NULL, 1, 0, NULL);
    c->updating = 1; c->dirty = 1;
    if (c->enabled) {
        ime_send_state(w);
    } else { c->dirty = 0; ime_commit_request(w); }
    c->session_serial = c->serial;
    IME_TRACE("IME session enabled=%d serial=%u\n", c->enabled, c->session_serial);
}
static void ime_enter(void *data, struct zwp_text_input_v3 *proxy, struct wl_surface *surface) {
    (void)proxy; ZenitWaylandWindow *w = data;
    if (surface != w->surface) return;
    ime_clear_visible(w); w->text_input->entered = 1;
    IME_TRACE("IME enter enabled=%d\n", w->text_input->enabled);
    ime_enable_entered(w);
}
static void ime_leave(void *data, struct zwp_text_input_v3 *proxy, struct wl_surface *surface) {
    (void)proxy; ZenitWaylandWindow *w = data;
    if (surface != w->surface) return;
    w->text_input->entered = 0; w->text_input->updating = 0; ime_clear_visible(w);
    IME_TRACE("IME leave\n");
}
static char *ime_copy(ZenitWaylandWindow *w, const char *text) {
    if (!text) text = "";
    size_t length = strlen(text);
    if (length > 65535 || !ime_utf8(text, length)) { w->closed = 1; return NULL; }
    char *copy = malloc(length + 1);
    if (!copy) { w->closed = 1; return NULL; }
    memcpy(copy, text, length + 1); return copy;
}
static void ime_preedit(void *data, struct zwp_text_input_v3 *proxy, const char *text, int32_t begin, int32_t end) {
    (void)proxy; ZenitWaylandWindow *w = data; struct TextInputState *c = w->text_input;
    if (!c->entered || !c->enabled) return;
    char *copy = ime_copy(w, text); if (!copy) return;
    size_t length = strlen(copy);
    if (!((begin == -1 && end == -1) || (begin >= 0 && end >= 0 && ime_boundary(copy, length, (uint32_t)begin) && ime_boundary(copy, length, (uint32_t)end)))) {
        free(copy); w->closed = 1; return;
    }
    free(c->preedit); c->preedit = copy; c->begin = begin; c->end = end;
}
static void ime_commit(void *data, struct zwp_text_input_v3 *proxy, const char *text) {
    (void)proxy; ZenitWaylandWindow *w = data; struct TextInputState *c = w->text_input;
    if (!c->entered || !c->enabled) return;
    char *copy = ime_copy(w, text); if (!copy) return;
    free(c->commit); c->commit = copy;
}
static void ime_delete(void *data, struct zwp_text_input_v3 *proxy, uint32_t before, uint32_t after) {
    (void)proxy; ZenitWaylandWindow *w = data; struct TextInputState *c = w->text_input;
    if (!c->entered || !c->enabled) return;
    c->before = before; c->after = after;
}
static void ime_done(void *data, struct zwp_text_input_v3 *proxy, uint32_t serial) {
    (void)proxy; ZenitWaylandWindow *w = data; struct TextInputState *c = w->text_input;
    /* Serial wrapping is modulo 2^32; a session cannot span 2^31 commits.
     * Older updates in this same session still apply, but the previous client's
     * outstanding batch must never be redirected into its replacement. */
    if (!c->entered || !c->enabled || (int32_t)(serial - c->session_serial) < 0) { ime_pending_clear(c); return; }
    /* Publish one batch atomically. Strings transfer ownership without a
     * second allocation and remain borrowed by peek until successful SDK push. */
    /* A pure preedit update replaces the composition in one UI event. Sending
     * an intermediate empty preedit makes the caret jump to the document and
     * back, which can trigger an endless cursor-rectangle/done feedback loop.
     * Document edits still require the protocol's clear/delete/commit order. */
    int clear_active = c->active && (c->before || c->after || c->commit != NULL);
    /* An idle done acknowledgement has no native composition to cancel.
     * Publishing an empty preedit anyway can erase a composition owned by
     * another producer (for example the harness) after a caret-state update.
     * An omitted preedit still cancels a live native composition, and explicit
     * empty preedit/document edits preserve their protocol ordering. */
    int publish_preedit = c->active || c->preedit != NULL || c->commit != NULL || c->before || c->after;
    uint32_t needed = publish_preedit + clear_active + (c->before || c->after) + (c->commit != NULL);
    if (needed > 128u - w->event_count) { w->closed = 1; ime_pending_clear(c); return; }
    if (clear_active) enqueue_input(w, (ZenitWaylandInputEvent){.kind = 6});
    if (c->before || c->after) enqueue_input(w, (ZenitWaylandInputEvent){.kind = 8, .delete_before = c->before, .delete_after = c->after});
    if (c->commit) {
        enqueue_input(w, (ZenitWaylandInputEvent){.kind = 7, .owned_text = (unsigned char *)c->commit, .text_length = (uint32_t)strlen(c->commit)});
        c->commit = NULL;
    }
    size_t length = c->preedit ? strlen(c->preedit) : 0;
    if (publish_preedit) enqueue_input(w, (ZenitWaylandInputEvent){.kind = 6, .owned_text = (unsigned char *)c->preedit, .text_length = (uint32_t)length, .cursor_begin = c->begin, .cursor_end = c->end});
    c->preedit = NULL; c->active = length != 0; c->updating = serial == c->serial;
    IME_TRACE("IME done serial=%u expected=%u preedit_bytes=%zu\n", serial, c->serial, length);
    ime_pending_clear(c); ime_send_state(w);
}
static const struct zwp_text_input_v3_listener ime_listener = {
    .enter = ime_enter, .leave = ime_leave, .preedit_string = ime_preedit,
    .commit_string = ime_commit, .delete_surrounding_text = ime_delete, .done = ime_done,
};
static int init_text_input(ZenitWaylandWindow *w) {
    struct TextInputState *c = w->text_input;
    if (!c || !c->manager || !w->seat || c->proxy) return 1;
    union wl_argument args[] = {{.o = NULL}, {.o = (struct wl_object *)w->seat}};
    c->proxy = (struct zwp_text_input_v3 *)request(w, c->manager, ZWP_TEXT_INPUT_MANAGER_V3_GET_TEXT_INPUT, &zwp_text_input_v3_interface, 1, 0, args);
    return c->proxy && listen(w, c->proxy, &ime_listener, w) == 0;
}
static void destroy_text_input_device(ZenitWaylandWindow *w) {
    struct TextInputState *c = w->text_input; if (!c) return;
    ime_clear_visible(w);
    if (c->proxy) destroy_request(w, c->proxy, 1);
    c->proxy = NULL; c->entered = c->updating = 0; c->serial = 0;
}
static void destroy_text_input(ZenitWaylandWindow *w) {
    struct TextInputState *c = w->text_input; if (!c) return;
    destroy_text_input_device(w);
    destroy_request(w, c->manager, 1); free(c->surrounding); free(c); w->text_input = NULL;
}
int zenit_wayland_ime_available(ZenitWaylandWindow *w) { return w && w->text_input && w->text_input->proxy && !w->closed; }
static int ime_check(ZenitWaylandWindow *w) {
    if (!zenit_wayland_ime_available(w)) return -3;
    return pthread_equal(w->clipboard->thread, pthread_self()) ? 0 : -7;
}
int zenit_wayland_ime_set_enabled(ZenitWaylandWindow *w, int enabled) {
    int rc = ime_check(w); if (rc) return rc;
    struct TextInputState *c = w->text_input;
    if (c->enabled == !!enabled) return 0;
    ime_clear_visible(w); c->enabled = !!enabled;
    /* A different editable client must not inherit the preceding document. */
    free(c->surrounding); c->surrounding = NULL; c->has_surrounding = c->has_rect = 0;
    ime_enable_entered(w); return 0;
}
int zenit_wayland_ime_discard(ZenitWaylandWindow *w) {
    int rc = ime_check(w); if (rc) return rc;
    struct TextInputState *c = w->text_input; ime_clear_visible(w);
    free(c->surrounding); c->surrounding = NULL; c->has_surrounding = c->has_rect = 0;
    if (c->entered && c->enabled) {
        request(w, c->proxy, ZWP_TEXT_INPUT_V3_DISABLE, NULL, 1, 0, NULL); ime_commit_request(w);
        ime_enable_entered(w);
    }
    return 0;
}
int zenit_wayland_ime_set_cursor_rect(ZenitWaylandWindow *w, int32_t x, int32_t y, int32_t width, int32_t height) {
    int rc = ime_check(w); if (rc) return rc;
    if (width < 0 || height < 0) return -6;
    struct TextInputState *c = w->text_input;
    if (c->has_rect && c->x == x && c->y == y && c->width == width && c->height == height) return 0;
    c->x = x; c->y = y; c->width = width; c->height = height; c->has_rect = c->dirty = 1;
    ime_send_state(w); return 0;
}
int zenit_wayland_ime_set_surrounding(ZenitWaylandWindow *w, const char *text, size_t length, uint32_t cursor, uint32_t anchor) {
    int rc = ime_check(w); if (rc) return rc;
    if (w->text_input->secure && (length || cursor || anchor)) return -6;
    if (!text || length > 4000 || memchr(text, 0, length) || !ime_utf8(text, length) || !ime_boundary(text, length, cursor) || !ime_boundary(text, length, anchor)) return -6;
    struct TextInputState *c = w->text_input;
    if (c->has_surrounding && c->cursor == cursor && c->anchor == anchor && strlen(c->surrounding) == length && !memcmp(c->surrounding, text, length)) return 0;
    char *copy = malloc(length + 1); if (!copy) return -4;
    memcpy(copy, text, length); copy[length] = 0;
    free(c->surrounding); c->surrounding = copy;
    c->cursor = cursor; c->anchor = anchor; c->has_surrounding = c->dirty = 1;
    ime_send_state(w); return 0;
}

int zenit_wayland_ime_set_secure(ZenitWaylandWindow *w, int secure) {
    int rc = ime_check(w); if (rc) return rc;
    struct TextInputState *c = w->text_input;
    if (c->secure == !!secure) return 0;
    if (secure) {
        char *empty = malloc(1); if (!empty) return -4; *empty = 0;
        free(c->surrounding); c->surrounding = empty;
        c->has_surrounding = 1; c->cursor = c->anchor = 0;
    }
    c->secure = !!secure; c->dirty = 1; ime_send_state(w); return 0;
}
