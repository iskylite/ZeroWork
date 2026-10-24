/* Wayland data-device clipboard. Pipe I/O progresses alongside display I/O;
 * callbacks never block on another client's reader. The existing synchronous
 * SDK is a bounded veneer over this transfer state, not a blocking pipe read. */
#define CLIPBOARD_TRACE(...) do { if (getenv("ZENIT_WAYLAND_CLIPBOARD_TRACE")) fprintf(stderr, __VA_ARGS__); } while (0)
#define CLIPBOARD_LIMIT (16u * 1024u * 1024u)
struct ClipboardOffer {
    ZenitWaylandWindow *window;
    struct wl_data_offer *proxy;
    struct ClipboardOffer *next;
    unsigned mime_mask;
};
struct ClipboardSource {
    ZenitWaylandWindow *window;
    struct wl_data_source *proxy;
    unsigned char *bytes;
    size_t length;
    unsigned mime_mask;
};
struct ClipboardSend { int fd; unsigned char *bytes; size_t length, offset; int64_t deadline; };
struct ClipboardState {
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    struct ClipboardOffer *offers, *selection, *drag;
    struct ClipboardSource *source;
    struct ClipboardSend sends[8];
    unsigned char *received;
    size_t length, capacity;
    int receive_fd, receive_status, cache_valid, reading, cache_mime;
    uint32_t version, manager_name, serial;
    pthread_t thread;
};
static const char *clipboard_mimes[] = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "image/png" };
static int clipboard_mime_index(const char *mime) {
    for (int i = 0; i < 4; ++i) if (mime && strcmp(mime, clipboard_mimes[i]) == 0) return i;
    return -1;
}
static void clipboard_drop_offer(ZenitWaylandWindow *w, struct ClipboardOffer *offer) {
    if (!offer) return;
    struct ClipboardOffer **link = &w->clipboard->offers;
    while (*link && *link != offer) link = &(*link)->next;
    if (*link) *link = offer->next;
    request(w, offer->proxy, WL_DATA_OFFER_DESTROY, NULL, w->clipboard->version, WL_MARSHAL_FLAG_DESTROY, NULL);
    free(offer);
}
static struct ClipboardOffer *clipboard_find_offer(ZenitWaylandWindow *w, struct wl_data_offer *proxy) {
    for (struct ClipboardOffer *o = w->clipboard->offers; o; o = o->next) if (o->proxy == proxy) return o;
    return NULL;
}
static void clipboard_offer_mime(void *data, struct wl_data_offer *proxy, const char *mime) {
    (void)proxy; struct ClipboardOffer *o = data; int i = clipboard_mime_index(mime);
    if (i >= 0) o->mime_mask |= 1u << i;
}
static void clipboard_offer_action(void *data, struct wl_data_offer *proxy, uint32_t action) { (void)data; (void)proxy; (void)action; }
static const struct wl_data_offer_listener clipboard_offer_listener = {
    .offer = clipboard_offer_mime, .source_actions = clipboard_offer_action, .action = clipboard_offer_action,
};
static void clipboard_data_offer(void *data, struct wl_data_device *device, struct wl_data_offer *proxy) {
    (void)device; ZenitWaylandWindow *w = data;
    struct ClipboardOffer *o = calloc(1, sizeof(*o));
    if (!o) { request(w, proxy, WL_DATA_OFFER_DESTROY, NULL, w->clipboard->version, WL_MARSHAL_FLAG_DESTROY, NULL); return; }
    o->window = w; o->proxy = proxy; o->next = w->clipboard->offers; w->clipboard->offers = o;
    if (listen(w, proxy, &clipboard_offer_listener, o) != 0) clipboard_drop_offer(w, o);
}
static void clipboard_cancel_receive(struct ClipboardState *c, int status) {
    if (c->receive_fd >= 0) close(c->receive_fd);
    c->receive_fd = -1; c->receive_status = status;
    c->cache_valid = 0; c->length = 0;
}
static void clipboard_selection(void *data, struct wl_data_device *device, struct wl_data_offer *proxy) {
    (void)device; ZenitWaylandWindow *w = data; struct ClipboardState *c = w->clipboard;
    struct ClipboardOffer *next = clipboard_find_offer(w, proxy);
    clipboard_cancel_receive(c, -3);
    if (c->selection != next) clipboard_drop_offer(w, c->selection);
    c->selection = next;
    CLIPBOARD_TRACE("CLIPBOARD selection present=%d mimes=%u\n", next != NULL, next ? next->mime_mask : 0);
}
static void clipboard_drag_enter(void *data, struct wl_data_device *device, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *proxy) {
    (void)device; (void)surface; (void)x; (void)y; ZenitWaylandWindow *w = data;
    clipboard_drop_offer(w, w->clipboard->drag); w->clipboard->drag = clipboard_find_offer(w, proxy);
    if (proxy) { union wl_argument args[] = {{.u = serial}, {.s = NULL}}; request(w, proxy, WL_DATA_OFFER_ACCEPT, NULL, w->clipboard->version, 0, args); }
}
static void clipboard_drag_leave(void *data, struct wl_data_device *device) {
    (void)device; ZenitWaylandWindow *w = data; clipboard_drop_offer(w, w->clipboard->drag); w->clipboard->drag = NULL;
}
static void clipboard_drag_motion(void *data, struct wl_data_device *device, uint32_t time, wl_fixed_t x, wl_fixed_t y) { (void)data; (void)device; (void)time; (void)x; (void)y; }
static const struct wl_data_device_listener clipboard_device_listener = {
    .data_offer = clipboard_data_offer, .selection = clipboard_selection,
    .enter = clipboard_drag_enter, .leave = clipboard_drag_leave, .motion = clipboard_drag_motion, .drop = clipboard_drag_leave,
};
static void clipboard_drop_source(struct ClipboardSource *s) {
    if (!s) return;
    request(s->window, s->proxy, WL_DATA_SOURCE_DESTROY, NULL, s->window->clipboard->version, WL_MARSHAL_FLAG_DESTROY, NULL);
    free(s->bytes); free(s);
}
static void clipboard_source_cancelled(void *data, struct wl_data_source *proxy) {
    (void)proxy; struct ClipboardSource *s = data;
    if (s->window->clipboard->source == s) s->window->clipboard->source = NULL;
    clipboard_drop_source(s);
}
static void clipboard_source_target(void *data, struct wl_data_source *proxy, const char *mime) { (void)data; (void)proxy; (void)mime; }
static void clipboard_source_done(void *data, struct wl_data_source *proxy) { (void)data; (void)proxy; }
static void clipboard_source_action(void *data, struct wl_data_source *proxy, uint32_t action) { (void)data; (void)proxy; (void)action; }
static void clipboard_source_send(void *data, struct wl_data_source *proxy, const char *mime, int32_t fd) {
    (void)proxy; struct ClipboardSource *s = data; struct ClipboardState *c = s->window->clipboard;
    CLIPBOARD_TRACE("CLIPBOARD send bytes=%zu\n", s->length);
    int mime_index = clipboard_mime_index(mime);
    if (mime_index < 0 || !((s->mime_mask ? s->mime_mask : 7u) & (1u << mime_index))) { close(fd); return; }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return; }
    for (size_t i = 0; i < 8; ++i) if (c->sends[i].fd < 0) {
        unsigned char *bytes = malloc(s->length ? s->length : 1);
        if (!bytes) { close(fd); return; }
        memcpy(bytes, s->bytes, s->length);
        c->sends[i] = (struct ClipboardSend){.fd = fd, .bytes = bytes, .length = s->length, .deadline = keyboard_now() + 2000000000LL};
        return;
    }
    close(fd);
}
static const struct wl_data_source_listener clipboard_source_listener = {
    .target = clipboard_source_target, .send = clipboard_source_send, .cancelled = clipboard_source_cancelled,
    .dnd_drop_performed = clipboard_source_done, .dnd_finished = clipboard_source_done, .action = clipboard_source_action,
};
/* Block SIGPIPE only for this write and consume only the signal generated by
 * it. The caller's thread signal mask and preexisting pending signal survive. */
static ssize_t clipboard_write(int fd, const void *bytes, size_t size) {
    sigset_t block, old, pending; sigemptyset(&block); sigaddset(&block, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &block, &old) != 0) { errno = EIO; return -1; }
    sigpending(&pending); int already = sigismember(&pending, SIGPIPE);
    ssize_t n = write(fd, bytes, size); int saved = errno;
    if (n < 0 && saved == EPIPE && !already) { struct timespec zero = {0}; while (sigtimedwait(&block, NULL, &zero) < 0 && errno == EINTR) {} }
    pthread_sigmask(SIG_SETMASK, &old, NULL); errno = saved; return n;
}
static void clipboard_finish_send(struct ClipboardSend *s) { close(s->fd); free(s->bytes); *s = (struct ClipboardSend){.fd = -1}; }
static void clipboard_io(ZenitWaylandWindow *w) {
    struct ClipboardState *c = w->clipboard; if (!c) return;
    for (size_t i = 0; i < 8; ++i) {
        struct ClipboardSend *s = &c->sends[i]; if (s->fd < 0) continue;
        if (keyboard_now() >= s->deadline) { clipboard_finish_send(s); continue; }
        if (s->offset == s->length) { clipboard_finish_send(s); continue; }
        ssize_t n = clipboard_write(s->fd, s->bytes + s->offset, s->length - s->offset);
        if (n > 0) { s->offset += (size_t)n; if (s->offset == s->length) clipboard_finish_send(s); }
        else if (n < 0 && errno != EAGAIN && errno != EINTR) clipboard_finish_send(s);
    }
    if (c->receive_fd < 0) return;
    unsigned char block[8192];
    /* Limit per-dispatch work so an unbounded sender cannot starve UI input. */
    for (int i = 0; i < 32; ++i) {
        ssize_t n = read(c->receive_fd, block, sizeof(block));
        if (n == 0) { close(c->receive_fd); c->receive_fd = -1; c->receive_status = 0; c->cache_valid = 1; break; }
        if (n < 0) { if (errno != EAGAIN && errno != EINTR) clipboard_cancel_receive(c, -1); break; }
        if ((size_t)n > CLIPBOARD_LIMIT - c->length) { clipboard_cancel_receive(c, -2); break; }
        size_t needed = c->length + (size_t)n;
        if (needed > c->capacity) {
            size_t capacity = c->capacity ? c->capacity * 2 : 8192;
            if (capacity < needed) capacity = needed;
            if (capacity > CLIPBOARD_LIMIT) capacity = CLIPBOARD_LIMIT;
            void *bytes = realloc(c->received, capacity);
            if (!bytes) { clipboard_cancel_receive(c, -4); break; }
            c->received = bytes; c->capacity = capacity;
        }
        memcpy(c->received + c->length, block, (size_t)n); c->length = needed;
    }
}
static size_t clipboard_pollfds(ZenitWaylandWindow *w, struct pollfd *fds) {
    struct ClipboardState *c = w->clipboard; if (!c) return 0;
    size_t count = 0;
    for (size_t i = 0; i < 8; ++i) if (c->sends[i].fd >= 0) fds[count++] = (struct pollfd){.fd = c->sends[i].fd, .events = POLLOUT};
    if (c->receive_fd >= 0) fds[count++] = (struct pollfd){.fd = c->receive_fd, .events = POLLIN};
    return count;
}
static int init_clipboard(ZenitWaylandWindow *w) {
    struct ClipboardState *c = w->clipboard;
    if (!c || !c->manager || !w->seat || c->device) return 1;
    union wl_argument args[] = {{.o = NULL}, {.o = (struct wl_object *)w->seat}};
    c->device = (struct wl_data_device *)request(w, c->manager, WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE, &wl_data_device_interface, c->version, 0, args);
    return c->device && listen(w, c->device, &clipboard_device_listener, w) == 0;
}
static void destroy_clipboard_device(ZenitWaylandWindow *w) {
    struct ClipboardState *c = w->clipboard; if (!c) return;
    clipboard_cancel_receive(c, -3);
    clipboard_drop_source(c->source); c->source = NULL;
    c->selection = c->drag = NULL;
    while (c->offers) clipboard_drop_offer(w, c->offers);
    for (size_t i = 0; i < 8; ++i) if (c->sends[i].fd >= 0) clipboard_finish_send(&c->sends[i]);
    if (c->device) { if (c->version >= 2) request(w, c->device, WL_DATA_DEVICE_RELEASE, NULL, c->version, WL_MARSHAL_FLAG_DESTROY, NULL); else w->api.destroy_proxy((struct wl_proxy *)c->device); c->device = NULL; }
    c->serial = 0;
}
static void destroy_clipboard(ZenitWaylandWindow *w) {
    struct ClipboardState *c = w->clipboard; if (!c) return;
    destroy_clipboard_device(w);
    if (c->manager) w->api.destroy_proxy((struct wl_proxy *)c->manager);
    free(c->received); free(c); w->clipboard = NULL;
}
static void clipboard_focus_lost(ZenitWaylandWindow *w) {
    struct ClipboardState *c = w->clipboard; if (!c) return;
    clipboard_cancel_receive(c, -3);
    clipboard_drop_offer(w, c->selection); c->selection = NULL; c->serial = 0;
}
static void clipboard_input_serial(ZenitWaylandWindow *w, uint32_t serial) {
    if (w->clipboard) w->clipboard->serial = serial;
}
int zenit_wayland_clipboard_available(ZenitWaylandWindow *w) { int available = w && w->clipboard && w->clipboard->device && !w->closed; CLIPBOARD_TRACE("CLIPBOARD available=%d\n", available); return available; }
int zenit_wayland_clipboard_write_ready(ZenitWaylandWindow *w) {
    return zenit_wayland_clipboard_available(w) && pthread_equal(w->clipboard->thread, pthread_self()) && w->keyboard_focused && w->clipboard->serial != 0;
}
static int clipboard_set_bytes(ZenitWaylandWindow *w, const unsigned char *bytes, size_t length, unsigned mime_mask) {
    if (!zenit_wayland_clipboard_available(w)) return -3;
    struct ClipboardState *c = w->clipboard;
    if (!pthread_equal(c->thread, pthread_self())) return -7;
    CLIPBOARD_TRACE("CLIPBOARD set bytes=%zu serial=%u focused=%d\n", length, c->serial, w->keyboard_focused);
    if (!c->serial || !w->keyboard_focused) return -6;
    if ((!bytes && length) || length > CLIPBOARD_LIMIT) return -2;
    struct ClipboardSource *s = calloc(1, sizeof(*s)); if (!s) return -4;
    s->bytes = malloc(length ? length : 1); if (!s->bytes) { free(s); return -4; }
    if (length) memcpy(s->bytes, bytes, length); s->length = length; s->window = w; s->mime_mask = mime_mask;
    union wl_argument id[] = {{.o = NULL}};
    s->proxy = (struct wl_data_source *)request(w, c->manager, WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE, &wl_data_source_interface, c->version, 0, id);
    if (!s->proxy) { free(s->bytes); free(s); return -4; }
    if (listen(w, s->proxy, &clipboard_source_listener, s) != 0) { clipboard_drop_source(s); return -1; }
    for (int i = 0; i < 4; ++i) if (mime_mask & (1u << i)) { union wl_argument args[] = {{.s = clipboard_mimes[i]}}; request(w, s->proxy, WL_DATA_SOURCE_OFFER, NULL, c->version, 0, args); }
    union wl_argument args[] = {{.o = (struct wl_object *)s->proxy}, {.u = c->serial}};
    request(w, c->device, WL_DATA_DEVICE_SET_SELECTION, NULL, c->version, 0, args);
    clipboard_drop_source(c->source); c->source = s; clipboard_cancel_receive(c, -3);
    int rc = w->api.flush(w->display); return rc < 0 && errno != EAGAIN ? -1 : 0;
}
int zenit_wayland_clipboard_set_text(ZenitWaylandWindow *w, const unsigned char *bytes, size_t length) { return clipboard_set_bytes(w, bytes, length, 7u); }
int zenit_wayland_clipboard_set_png(ZenitWaylandWindow *w, const unsigned char *bytes, size_t length) {
    static const unsigned char signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (!bytes || length < sizeof(signature) || memcmp(bytes, signature, sizeof(signature))) return -1;
    return clipboard_set_bytes(w, bytes, length, 8u);
}
unsigned zenit_wayland_clipboard_probe(ZenitWaylandWindow *w) {
    if (!zenit_wayland_clipboard_available(w) || !pthread_equal(w->clipboard->thread, pthread_self())) return 0;
    if (zenit_wayland_poll(w, 0) <= 0) return 0;
    struct ClipboardState *c = w->clipboard;
    unsigned mask = c->source ? c->source->mime_mask : c->selection ? c->selection->mime_mask : 0;
    return ((mask & 7u) ? 1u : 0u) | ((mask & 8u) ? 2u : 0u);
}
static int clipboard_read_snapshot(ZenitWaylandWindow *w, unsigned requested_mask) {
    if (!zenit_wayland_clipboard_available(w)) return -3;
    struct ClipboardState *c = w->clipboard;
    if (!pthread_equal(c->thread, pthread_self())) return -7;
    if (c->reading) return -6;
    if (zenit_wayland_poll(w, 0) <= 0) return -1;
    if (c->cache_valid && (requested_mask & (1u << c->cache_mime))) return 0;
    unsigned mask = (c->source ? c->source->mime_mask : c->selection ? c->selection->mime_mask : 0) & requested_mask;
    int mime = 0; while (mime < 4 && !(mask & (1u << mime))) ++mime;
    c->cache_valid = 0; c->cache_mime = mime; c->length = 0;
    if (!mask) return 0;
    /* Our source owns a stable byte snapshot until the compositor cancels it.
     * Poll above first, so cancellation/foreign selection wins over local data. */
    if (c->source) {
        if (c->source->length > c->capacity) {
            void *bytes = realloc(c->received, c->source->length);
            if (!bytes) return -4;
            c->received = bytes; c->capacity = c->source->length;
        }
        if (c->source->length) memcpy(c->received, c->source->bytes, c->source->length);
        c->length = c->source->length; c->cache_valid = 1; return 0;
    }
    int fds[2]; if (pipe(fds) != 0) return -1;
    if (fcntl(fds[0], F_SETFL, O_NONBLOCK) < 0 || fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) { close(fds[0]); close(fds[1]); return -1; }
    c->receive_fd = fds[0]; c->receive_status = 0; c->length = 0; c->reading = 1;
    union wl_argument args[] = {{.s = clipboard_mimes[mime]}, {.h = fds[1]}};
    request(w, c->selection->proxy, WL_DATA_OFFER_RECEIVE, NULL, c->version, 0, args); close(fds[1]);
    int64_t deadline = keyboard_now() + 2000000000LL;
    while (c->receive_fd >= 0 && keyboard_now() < deadline) if (zenit_wayland_poll(w, 20) <= 0) { clipboard_cancel_receive(c, -1); break; }
    if (c->receive_fd >= 0) clipboard_cancel_receive(c, -5);
    c->reading = 0; return c->receive_status;
}
int zenit_wayland_clipboard_get_text_len(ZenitWaylandWindow *w) { int rc = clipboard_read_snapshot(w, 7u); CLIPBOARD_TRACE("CLIPBOARD read rc=%d bytes=%zu\n", rc, w && w->clipboard ? w->clipboard->length : 0); return rc < 0 ? rc : (int)w->clipboard->length; }
int zenit_wayland_clipboard_get_text(ZenitWaylandWindow *w, unsigned char *bytes, size_t capacity) {
    int rc = clipboard_read_snapshot(w, 7u); if (rc < 0) return rc;
    size_t length = w->clipboard->length; if (length > capacity || (!bytes && length)) return -2;
    if (length) memcpy(bytes, w->clipboard->received, length); return (int)length;
}
int zenit_wayland_clipboard_get_png_len(ZenitWaylandWindow *w) { int rc = clipboard_read_snapshot(w, 8u); return rc < 0 ? rc : (int)w->clipboard->length; }
int zenit_wayland_clipboard_get_png(ZenitWaylandWindow *w, unsigned char *bytes, size_t capacity) {
    int rc = clipboard_read_snapshot(w, 8u); if (rc < 0) return rc;
    size_t length = w->clipboard->length; if (length > capacity || (!bytes && length)) return -2;
    if (length) memcpy(bytes, w->clipboard->received, length); return (int)length;
}
