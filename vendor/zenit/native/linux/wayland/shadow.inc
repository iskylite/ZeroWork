/* Client-side window shape and shadow for custom chrome on Wayland.
 *
 * Mutter only draws shadows for server-side decorated windows; a client that
 * hides libdecor's frame also loses its shadow. GTK draws the shadow itself in a
 * margin around the window and so do we: four wl_shm subsurfaces (top, bottom,
 * left, right strips) placed below the content surface. The margin is also the
 * resize border. Parameters are libadwaita's `window.csd` rules (libadwaita
 * 1.9, read from the Fedora 44 guest), which is what GNOME's own apps use:
 *   radius    --window-radius 15px on all four corners
 *   focused   0 0 14px 5px rgba(0,0,0,.15), 0 0 5px 2px rgba(0,0,0,.10), 0 0 0 1px rgba(0,0,0,.05)
 *   backdrop  0 0 10px 5px rgba(0,0,0,.08), 0 0 0 1px rgba(0,0,0,.05)
 *   tiled     radius 0, 0 0 0 1px (border opacity 15%), 20px margin kept
 *   maximized / fullscreen: radius 0, nothing.
 * Server-side decorations (zxdg_decoration_manager_v1 present) keep libdecor's
 * own frame and shadow, so nothing is drawn here. */
/* memfd_create is in glibc >= 2.27 but only declared under _GNU_SOURCE, which
 * would also re-version other libm symbols past what the bundled glibc stubs
 * provide; declare it directly. */
extern int memfd_create(const char *name, unsigned int flags);
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 1U
#endif
#define SHADOW_MARGIN 20 /* spread 5 + blur 14, and libadwaita's tiled 20px */
/* No libm: the Linux native sources link libc only. Abramowitz-Stegun 7.1.26
 * (|error| < 1.5e-7) is far below one alpha step. */
/* exp(-y) for y >= 0 without libm: split into m factors with exponents in
 * [-1, 0] where the Taylor series converges without cancellation. */
static double shadow_exp_neg(double y) {
    const int m = (int)y + 1; const double x = -y / m;
    double e = 1.0, term = 1.0;
    for (int i = 1; i < 30; ++i) { term *= x / i; e += term; if (term < 1e-18 && term > -1e-18) break; }
    double r = 1.0; for (int i = 0; i < m; ++i) r *= e;
    return r;
}
static double shadow_erf(double x) {
    const double sign = x < 0 ? -1.0 : 1.0, a = x < 0 ? -x : x;
    const double t = 1.0 / (1.0 + 0.3275911 * a);
    const double poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
    return sign * (1.0 - poly * (a > 6.0 ? 0.0 : shadow_exp_neg(a * a)));
}
static double shadow_max(double a, double b) { return a > b ? a : b; }
#define SHADOW_STRIPS 4

struct ShadowStrip {
    struct wl_surface *surface;
    struct wl_subsurface *subsurface;
    struct wp_viewport *viewport;
    struct wl_buffer *buffer;
    void *map;
    size_t map_size;
};
#define SHADOW_LAYERS 2
/* One centred CSS box-shadow layer: rgba(0,0,0,alpha) with blur radius (2 sigma) and spread. */
struct ShadowLayer { double alpha, blur, spread; };
struct ShadowLook { struct ShadowLayer layer[SHADOW_LAYERS]; double outline, radius; };

static int shadow_tiled(const ZenitWaylandWindow *w) {
    return (w->decor_window_state & (LIBDECOR_WINDOW_STATE_TILED_LEFT | LIBDECOR_WINDOW_STATE_TILED_RIGHT |
        LIBDECOR_WINDOW_STATE_TILED_TOP | LIBDECOR_WINDOW_STATE_TILED_BOTTOM)) != 0;
}
static int shadow_wanted(const ZenitWaylandWindow *w) {
    if (!w->subcompositor || !w->shm || !w->configured || w->closed) return 0;
    if (!w->chrome_mode || w->decoration_manager_seen) return 0;
    return (w->decor_window_state & (LIBDECOR_WINDOW_STATE_MAXIMIZED | LIBDECOR_WINDOW_STATE_FULLSCREEN)) == 0;
}
/* libadwaita rounds all four corners by --window-radius (15px) and by nothing
 * when maximized, fullscreen or tiled. The client paints these corners itself,
 * so the same radius is reported to the application through the chrome state. */
static float shadow_corner_radius(const ZenitWaylandWindow *w) {
    if (!w->chrome_mode || w->decoration_manager_seen) return 0;
    if (w->decor_window_state & (LIBDECOR_WINDOW_STATE_MAXIMIZED | LIBDECOR_WINDOW_STATE_FULLSCREEN)) return 0;
    return shadow_tiled(w) ? 0 : 15;
}
/* sqrt without libm (the native sources link libc only): Newton iterations. */
static double shadow_sqrt(double v) {
    if (v <= 0) return 0;
    double r = v > 1 ? v : 1;
    for (int i = 0; i < 30; ++i) r = 0.5 * (r + v / r);
    return r;
}
/* Whether (x, y) lies in a corner square of a rounded width x height box. */
static int shadow_in_corner(double width, double height, double radius, double x, double y) {
    return radius > 0 && (x < radius || x > width - radius) && (y < radius || y > height - radius);
}
/* Signed distance to a width x height rectangle at the origin whose corners
 * are rounded by `radius` (negative inside). */
static double shadow_sdf(double width, double height, double radius, double x, double y) {
    if (shadow_in_corner(width, height, radius, x, y)) {
        const double cx = x < radius ? radius : width - radius, cy = y < radius ? radius : height - radius;
        return shadow_sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) - radius;
    }
    const double dx = shadow_max(-x, x - width), dy = shadow_max(-y, y - height);
    return dx > 0 && dy > 0 ? shadow_sqrt(dx * dx + dy * dy) : shadow_max(dx, dy);
}
/* Fraction of a pixel of half-width h (logical) centred at signed distance d
 * that lies in the band [lo, hi] of distances. */
static double shadow_band(double d, double h, double lo, double hi) {
    const double c = (d + h < hi ? d + h : hi) - (d - h > lo ? d - h : lo);
    return c > 0 ? c / (2 * h) : 0;
}
static struct ShadowLook shadow_look(const ZenitWaylandWindow *w) {
    const int active = (w->decor_window_state & LIBDECOR_WINDOW_STATE_ACTIVE) != 0;
    struct ShadowLook look = { .outline = .05, .radius = shadow_corner_radius(w) };
    if (shadow_tiled(w)) { look.outline = .15; return look; }
    if (active) {
        look.layer[0] = (struct ShadowLayer){ .15, 14, 5 };
        look.layer[1] = (struct ShadowLayer){ .10, 5, 2 };
    } else {
        look.layer[0] = (struct ShadowLayer){ .08, 10, 5 };
    }
    return look;
}
/* Gaussian-blurred box coverage (CSS box-shadow: blur radius b = 2 sigma). */
static double shadow_axis(double lo, double hi, double v, double sigma) {
    if (sigma <= 0) return v >= lo && v < hi ? 1.0 : 0.0;
    const double k = 1.0 / (sigma * 1.4142135623730951);
    return 0.5 * (shadow_erf((hi - v) * k) - shadow_erf((lo - v) * k));
}
/* Away from the corners a blurred box is separable: alpha * fx(x) * fy(y).
 * Callers tabulate fx per column and fy per row (per layer) so a strip costs
 * O(width + height) erf evaluations instead of O(width * height) on every
 * interactive resize step. */
static double shadow_axis_x(const struct ShadowLayer *l, double width, double x) {
    return l->alpha > 0 ? shadow_axis(-l->spread, width + l->spread, x, l->blur / 2.0) : 0;
}
static double shadow_axis_y(const struct ShadowLayer *l, double height, double y) {
    return l->alpha > 0 ? l->alpha * shadow_axis(-l->spread, height + l->spread, y, l->blur / 2.0) : 0;
}
/* fx, fy: this pixel's column and row factors, one per layer.
 * h: half a buffer pixel in logical units, for antialiasing the window shape. */
static unsigned char shadow_alpha(const struct ShadowLook *look, double width, double height, double x, double y,
    const double *fx, const double *fy, double h) {
    double a = 0;
    for (int i = 0; i < SHADOW_LAYERS; ++i) {
        const struct ShadowLayer *l = &look->layer[i];
        if (l->alpha <= 0) continue;
        double layer = fx[i] * fy[i];
        /* Near a rounded corner the blurred shape is the rounded box itself, not
         * the separable rectangle (that would leave a dark square under the
         * transparent corner): Gaussian falloff of its signed distance. */
        const double s = l->spread, rs = look->radius > 0 ? look->radius + s : 0;
        if (shadow_in_corner(width + 2 * s, height + 2 * s, rs, x + s, y + s)) {
            const double d = shadow_sdf(width + 2 * s, height + 2 * s, rs, x + s, y + s);
            layer = l->alpha * 0.5 * (1.0 - shadow_erf(d / (l->blur / 2.0 * 1.4142135623730951)));
        }
        a = 1.0 - (1.0 - a) * (1.0 - layer);
    }
    /* As CSS box-shadow, nothing under the window shape itself, antialiased
     * along the rounded corners the content clears to transparent. */
    const double d = shadow_sdf(width, height, look->radius, x, y);
    a *= shadow_band(d, h, 0, 1e9);
    /* 1px outline just outside the window shape. */
    const double outline = look->outline * shadow_band(d, h, 0, 1);
    a = 1.0 - (1.0 - a) * (1.0 - outline);
    if (a < 0) a = 0; if (a > 1) a = 1;
    return (unsigned char)(a * 255.0 + 0.5);
}
static void shadow_release_buffer(ZenitWaylandWindow *w, struct ShadowStrip *strip) {
    if (strip->buffer) { destroy_request(w, strip->buffer, 1); strip->buffer = NULL; }
    if (strip->map) { munmap(strip->map, strip->map_size); strip->map = NULL; strip->map_size = 0; }
}
static void shadow_destroy(ZenitWaylandWindow *w) {
    for (int i = 0; i < SHADOW_STRIPS; ++i) {
        struct ShadowStrip *strip = &w->shadow[i];
        shadow_release_buffer(w, strip);
        if (strip->viewport) { destroy_request(w, strip->viewport, 1); strip->viewport = NULL; }
        if (strip->subsurface) { destroy_request(w, strip->subsurface, 1); strip->subsurface = NULL; }
        if (strip->surface) { destroy_request(w, strip->surface, w->compositor_version); strip->surface = NULL; }
    }
    w->shadow_shown = 0;
    w->edge_active = 0; /* no leave event follows a destroyed surface */
}
static int shadow_create_strips(ZenitWaylandWindow *w) {
    union wl_argument new_id[] = { { .o = NULL } };
    for (int i = 0; i < SHADOW_STRIPS; ++i) {
        struct ShadowStrip *strip = &w->shadow[i];
        if (strip->surface) continue;
        strip->surface = (struct wl_surface *)request(w, w->compositor, WL_COMPOSITOR_CREATE_SURFACE, &wl_surface_interface, w->compositor_version, 0, new_id);
        if (!strip->surface) return 0;
        union wl_argument sub[] = { { .o = NULL }, { .o = (struct wl_object *)strip->surface }, { .o = (struct wl_object *)w->surface } };
        strip->subsurface = (struct wl_subsurface *)request(w, w->subcompositor, WL_SUBCOMPOSITOR_GET_SUBSURFACE, &wl_subsurface_interface, 1, 0, sub);
        if (!strip->subsurface) return 0;
        union wl_argument below[] = { { .o = (struct wl_object *)w->surface } };
        request(w, strip->subsurface, WL_SUBSURFACE_PLACE_BELOW, NULL, 1, 0, below);
        /* Shadows update on their own commits; they never wait for a content frame. */
        request(w, strip->subsurface, WL_SUBSURFACE_SET_DESYNC, NULL, 1, 0, NULL);
        if (w->viewporter && w->fractional) {
            union wl_argument vp[] = { { .o = NULL }, { .o = (struct wl_object *)strip->surface } };
            strip->viewport = (struct wp_viewport *)request(w, w->viewporter, WP_VIEWPORTER_GET_VIEWPORT, &wp_viewport_interface, 1, 0, vp);
            /* Fractional scaling requires buffer_scale 1; never fall back to it. */
            if (!strip->viewport) return 0;
        }
    }
    return 1;
}
/* Rows at each end of the content area that the top and bottom strips also
 * cover: they lie below the content surface, so their shadow and outline show
 * only through the transparent rounded corners. Uses the painted look so hit
 * coordinates match the buffers. */
static int shadow_strip_corner(const ZenitWaylandWindow *w) {
    const int r = (int)(w->shadow_look->radius + 0.999);
    return 2 * r < (int)w->height ? r : 0;
}
/* Strip origins in content coordinates, matching shadow_sync's layout:
 * top (-m, -m, W+2m, m+c), bottom (-m, H-c, W+2m, m+c), left (-m, c, m, H-2c),
 * right (W, c, m, H-2c). */
static void shadow_strip_origin(const ZenitWaylandWindow *w, int strip, float *x, float *y) {
    const float m = SHADOW_MARGIN, c = (float)shadow_strip_corner(w);
    switch (strip) {
    case 0: *x = -m; *y = -m; break;
    case 1: *x = -m; *y = (float)w->height - c; break;
    case 2: *x = -m; *y = c; break;
    default: *x = (float)w->width; *y = c; break;
    }
}
/* GTK 4's resize border: RESIZE_HANDLE_SIZE outside the window, larger corners. */
#define SHADOW_RESIZE_BORDER 12
#define SHADOW_RESIZE_CORNER 24
/* Input region of a strip, applied on its next commit: the band of the margin
 * within SHADOW_RESIZE_BORDER of the window is the resize border; farther out,
 * and everywhere for a tiled window (its neighbours own that space), presses
 * reach whatever is below. */
static int shadow_set_input_region(ZenitWaylandWindow *w, int index, int resizable) {
    struct ShadowStrip *strip = &w->shadow[index];
    union wl_argument new_id[] = { { .o = NULL } };
    struct wl_region *region = (struct wl_region *)request(w, w->compositor, WL_COMPOSITOR_CREATE_REGION, &wl_region_interface, w->compositor_version, 0, new_id);
    /* Without a region the strip would take pointer input on its whole area. */
    if (!region) return 0;
    if (resizable) {
        const int m = SHADOW_MARGIN, b = SHADOW_RESIZE_BORDER, W = (int)w->width, H = (int)w->height, c = shadow_strip_corner(w);
        /* Rectangles in strip-local coordinates. */
        int rects[3][4]; int n = 0;
        switch (index) {
        case 0: /* above the window, plus the side bands beside the top corners */
            rects[n][0] = m - b; rects[n][1] = m - b; rects[n][2] = W + 2 * b; rects[n][3] = b; ++n;
            if (c) { rects[n][0] = m - b; rects[n][1] = m; rects[n][2] = b; rects[n][3] = c; ++n;
                     rects[n][0] = m + W; rects[n][1] = m; rects[n][2] = b; rects[n][3] = c; ++n; }
            break;
        case 1: /* below the window, plus the side bands beside the bottom corners */
            rects[n][0] = m - b; rects[n][1] = c; rects[n][2] = W + 2 * b; rects[n][3] = b; ++n;
            if (c) { rects[n][0] = m - b; rects[n][1] = 0; rects[n][2] = b; rects[n][3] = c; ++n;
                     rects[n][0] = m + W; rects[n][1] = 0; rects[n][2] = b; rects[n][3] = c; ++n; }
            break;
        case 2: rects[n][0] = m - b; rects[n][1] = 0; rects[n][2] = b; rects[n][3] = H - 2 * c; ++n; break;
        default: rects[n][0] = 0; rects[n][1] = 0; rects[n][2] = b; rects[n][3] = H - 2 * c; ++n; break;
        }
        for (int i = 0; i < n; ++i) {
            union wl_argument add[] = { { .i = rects[i][0] }, { .i = rects[i][1] }, { .i = rects[i][2] }, { .i = rects[i][3] } };
            request(w, region, WL_REGION_ADD, NULL, 1, 0, add);
        }
    }
    union wl_argument input[] = { { .o = (struct wl_object *)region } };
    request(w, strip->surface, WL_SURFACE_SET_INPUT_REGION, NULL, w->compositor_version, 0, input);
    destroy_request(w, region, 1);
    return 1;
}
/* libdecor edge for content coordinates in the margin, 0 when none. */
static int shadow_edge_at(const ZenitWaylandWindow *w, float x, float y) {
    if (!w->chrome_mode || shadow_tiled(w) || (w->decor_window_state & (LIBDECOR_WINDOW_STATE_MAXIMIZED | LIBDECOR_WINDOW_STATE_FULLSCREEN))) return 0;
    const float W = (float)w->width, H = (float)w->height, c = SHADOW_RESIZE_CORNER;
    const int left = x < c, right = x > W - c, top = y < c, bottom = y > H - c;
    if (y < 0) return left ? LIBDECOR_RESIZE_EDGE_TOP_LEFT : right ? LIBDECOR_RESIZE_EDGE_TOP_RIGHT : LIBDECOR_RESIZE_EDGE_TOP;
    if (y >= H) return left ? LIBDECOR_RESIZE_EDGE_BOTTOM_LEFT : right ? LIBDECOR_RESIZE_EDGE_BOTTOM_RIGHT : LIBDECOR_RESIZE_EDGE_BOTTOM;
    if (x < 0) return top ? LIBDECOR_RESIZE_EDGE_TOP_LEFT : bottom ? LIBDECOR_RESIZE_EDGE_BOTTOM_LEFT : LIBDECOR_RESIZE_EDGE_LEFT;
    if (x >= W) return top ? LIBDECOR_RESIZE_EDGE_TOP_RIGHT : bottom ? LIBDECOR_RESIZE_EDGE_BOTTOM_RIGHT : LIBDECOR_RESIZE_EDGE_RIGHT;
    return 0;
}
/* cursor.inc shape index for an edge: ew 9, ns 10, nwse 11, nesw 12, default 0. */
static uint32_t shadow_edge_cursor(int edge) {
    switch (edge) {
    case LIBDECOR_RESIZE_EDGE_TOP: case LIBDECOR_RESIZE_EDGE_BOTTOM: return 10;
    case LIBDECOR_RESIZE_EDGE_LEFT: case LIBDECOR_RESIZE_EDGE_RIGHT: return 9;
    case LIBDECOR_RESIZE_EDGE_TOP_LEFT: case LIBDECOR_RESIZE_EDGE_BOTTOM_RIGHT: return 11;
    case LIBDECOR_RESIZE_EDGE_TOP_RIGHT: case LIBDECOR_RESIZE_EDGE_BOTTOM_LEFT: return 12;
    default: return 0;
    }
}
static void shadow_edge_update_cursor(ZenitWaylandWindow *w) {
    const uint32_t shape = shadow_edge_cursor(shadow_edge_at(w, w->edge_x, w->edge_y));
    if (shape == w->edge_cursor || !w->pointer) return;
    if (!w->cursor_device) init_cursor_device(w);
    if (apply_cursor_shape(w, shape)) w->edge_cursor = shape;
}
static int shadow_pointer_enter(ZenitWaylandWindow *w, struct wl_surface *surface, uint32_t serial, float x, float y) {
    if (!w->shadow || !surface) return 0;
    for (int i = 0; i < SHADOW_STRIPS; ++i) {
        if (w->shadow[i].surface != surface) continue;
        float ox, oy; shadow_strip_origin(w, i, &ox, &oy);
        w->edge_active = 1; w->edge_strip = i; w->edge_x = ox + x; w->edge_y = oy + y;
        w->pointer_enter_serial = serial; w->edge_cursor = UINT32_MAX;
        shadow_edge_update_cursor(w);
        return 1;
    }
    return 0;
}
static int shadow_pointer_leave(ZenitWaylandWindow *w, struct wl_surface *surface) {
    if (!w->edge_active || !w->shadow || w->shadow[w->edge_strip].surface != surface) return 0;
    w->edge_active = 0;
    return 1;
}
static int shadow_pointer_motion(ZenitWaylandWindow *w, float x, float y) {
    if (!w->edge_active) return 0;
    float ox, oy; shadow_strip_origin(w, w->edge_strip, &ox, &oy);
    w->edge_x = ox + x; w->edge_y = oy + y;
    shadow_edge_update_cursor(w);
    return 1;
}
static int shadow_pointer_button(ZenitWaylandWindow *w, uint32_t serial, uint32_t button, uint32_t state) {
    if (!w->edge_active) return 0;
    if (button != 272 || state != WL_POINTER_BUTTON_STATE_PRESSED) return 1;
    const int edge = shadow_edge_at(w, w->edge_x, w->edge_y);
    if (edge && w->seat && w->decor_frame && w->decor_api.resize &&
        (!w->decor_api.has_capability || w->decor_api.has_capability(w->decor_frame, LIBDECOR_ACTION_RESIZE)))
        w->decor_api.resize(w->decor_frame, w->seat, serial, (enum libdecor_resize_edge)edge);
    return 1;
}
static void shadow_hide(ZenitWaylandWindow *w) {
    if (!w->shadow_shown) return;
    for (int i = 0; i < SHADOW_STRIPS; ++i) {
        struct ShadowStrip *strip = &w->shadow[i];
        if (!strip->surface) continue;
        union wl_argument detach[] = { { .o = NULL }, { .i = 0 }, { .i = 0 } };
        request(w, strip->surface, WL_SURFACE_ATTACH, NULL, w->compositor_version, 0, detach);
        request(w, strip->surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
        shadow_release_buffer(w, strip);
    }
    w->shadow_shown = 0;
    w->edge_active = 0;
}
/* Allocate, paint and commit one strip. Logical rect (x, y, lw, lh) is relative
 * to the content surface origin; buffer pixels follow the content scale. */
static int shadow_paint_strip(ZenitWaylandWindow *w, struct ShadowStrip *strip, const struct ShadowLook *look,
    int x, int y, uint32_t lw, uint32_t lh) {
    const uint32_t pw = scaled_dimension(w, lw), ph = scaled_dimension(w, lh);
    const double scale = (double)scaled_dimension(w, 1000) / 1000.0;
    if (!pw || !ph || pw > 32768 || ph > 32768) return 0;
    const size_t stride = (size_t)pw * 4, size = stride * ph;
    int fd = memfd_create("zenit-shadow", MFD_CLOEXEC);
    if (fd < 0) return 0;
    if (ftruncate(fd, (off_t)size) != 0) { close(fd); return 0; }
    /* Layer-interleaved tables: fx[px * SHADOW_LAYERS + layer], likewise fy. */
    double *fx = malloc(sizeof(double) * SHADOW_LAYERS * ((size_t)pw + ph));
    if (!fx) { close(fd); return 0; }
    double *fy = fx + (size_t)SHADOW_LAYERS * pw;
    for (uint32_t px = 0; px < pw; ++px)
        for (int i = 0; i < SHADOW_LAYERS; ++i) fx[(size_t)px * SHADOW_LAYERS + i] = shadow_axis_x(&look->layer[i], w->width, x + ((double)px + 0.5) / scale);
    for (uint32_t py = 0; py < ph; ++py)
        for (int i = 0; i < SHADOW_LAYERS; ++i) fy[(size_t)py * SHADOW_LAYERS + i] = shadow_axis_y(&look->layer[i], w->height, y + ((double)py + 0.5) / scale);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { free(fx); close(fd); return 0; }
    for (uint32_t py = 0; py < ph; ++py) {
        const double ly = y + ((double)py + 0.5) / scale;
        for (uint32_t px = 0; px < pw; ++px) {
            const double lx = x + ((double)px + 0.5) / scale;
            pixels[(size_t)py * pw + px] = (uint32_t)shadow_alpha(look, w->width, w->height, lx, ly,
                &fx[(size_t)px * SHADOW_LAYERS], &fy[(size_t)py * SHADOW_LAYERS], 0.5 / scale) << 24; /* premultiplied black */
        }
    }
    free(fx);
    union wl_argument pool_args[] = { { .o = NULL }, { .h = fd }, { .i = (int32_t)size } };
    struct wl_shm_pool *pool = (struct wl_shm_pool *)request(w, w->shm, WL_SHM_CREATE_POOL, &wl_shm_pool_interface, 1, 0, pool_args);
    close(fd);
    if (!pool) { munmap(pixels, size); return 0; }
    union wl_argument buffer_args[] = { { .o = NULL }, { .i = 0 }, { .i = (int32_t)pw }, { .i = (int32_t)ph }, { .i = (int32_t)stride }, { .u = WL_SHM_FORMAT_ARGB8888 } };
    struct wl_buffer *buffer = (struct wl_buffer *)request(w, pool, WL_SHM_POOL_CREATE_BUFFER, &wl_buffer_interface, 1, 0, buffer_args);
    /* wl_shm_pool.destroy is opcode 1 (opcode 0 is create_buffer); the generic
     * destroy helper assumes opcode 0. */
    request(w, pool, WL_SHM_POOL_DESTROY, NULL, 1, WL_MARSHAL_FLAG_DESTROY, NULL);
    if (!buffer) { munmap(pixels, size); return 0; }
    /* The previous buffer stays the surface's content until this commit; it is
     * released only afterwards. */
    struct ShadowStrip previous = *strip;
    strip->buffer = buffer; strip->map = pixels; strip->map_size = size;
    union wl_argument position[] = { { .i = x }, { .i = y } };
    request(w, strip->subsurface, WL_SUBSURFACE_SET_POSITION, NULL, 1, 0, position);
    if (strip->viewport) {
        union wl_argument destination[] = { { .i = (int32_t)lw }, { .i = (int32_t)lh } };
        request(w, strip->viewport, WP_VIEWPORT_SET_DESTINATION, NULL, 1, 0, destination);
    } else if (w->compositor_version >= 3) {
        union wl_argument buffer_scale[] = { { .i = w->scale } };
        request(w, strip->surface, WL_SURFACE_SET_BUFFER_SCALE, NULL, w->compositor_version, 0, buffer_scale);
    }
    if (!shadow_set_input_region(w, (int)(strip - w->shadow), !shadow_tiled(w))) { shadow_release_buffer(w, strip); *strip = previous; return 0; }
    union wl_argument attach[] = { { .o = (struct wl_object *)buffer }, { .i = 0 }, { .i = 0 } };
    request(w, strip->surface, WL_SURFACE_ATTACH, NULL, w->compositor_version, 0, attach);
    union wl_argument damage[] = { { .i = 0 }, { .i = 0 }, { .i = INT32_MAX }, { .i = INT32_MAX } };
    request(w, strip->surface, WL_SURFACE_DAMAGE, NULL, w->compositor_version, 0, damage);
    request(w, strip->surface, WL_SURFACE_COMMIT, NULL, w->compositor_version, 0, NULL);
    shadow_release_buffer(w, &previous);
    return 1;
}
/* Bring the shadow in line with the current size, state and scale. Cheap when
 * nothing changed; called after configure, resize, chrome and scale updates. */
/* Custom chrome owns the content surface's opaque region: everything except the
 * client-painted (transparent) top corners. libdecor may have published a full
 * rectangle for its own frame; this request wins on the next content commit. */
static void shadow_update_opaque_region(ZenitWaylandWindow *w) {
    if (!w->chrome_mode || !w->compositor || !w->surface || w->compositor_version < 1) return;
    const int r = (int)shadow_corner_radius(w), W = (int)w->width, H = (int)w->height;
    union wl_argument new_id[] = { { .o = NULL } };
    struct wl_region *region = (struct wl_region *)request(w, w->compositor, WL_COMPOSITOR_CREATE_REGION, &wl_region_interface, w->compositor_version, 0, new_id);
    if (!region) return;
    /* The middle band, then the top and bottom bands between the corners. */
    union wl_argument middle[] = { { .i = 0 }, { .i = r }, { .i = W }, { .i = H > 2 * r ? H - 2 * r : 0 } };
    request(w, region, WL_REGION_ADD, NULL, 1, 0, middle);
    if (r > 0 && W > 2 * r && H > 2 * r) {
        union wl_argument top[] = { { .i = r }, { .i = 0 }, { .i = W - 2 * r }, { .i = r } };
        request(w, region, WL_REGION_ADD, NULL, 1, 0, top);
        union wl_argument bottom[] = { { .i = r }, { .i = H - r }, { .i = W - 2 * r }, { .i = r } };
        request(w, region, WL_REGION_ADD, NULL, 1, 0, bottom);
    }
    union wl_argument opaque[] = { { .o = (struct wl_object *)region } };
    request(w, w->surface, WL_SURFACE_SET_OPAQUE_REGION, NULL, w->compositor_version, 0, opaque);
    destroy_request(w, region, 1);
}
static void shadow_sync(ZenitWaylandWindow *w) {
    shadow_update_opaque_region(w);
    if (!shadow_wanted(w)) { shadow_hide(w); return; }
    const struct ShadowLook look = shadow_look(w);
    const uint32_t pixel_scale = scaled_dimension(w, 1000);
    if (w->shadow_shown && w->shadow_width == w->width && w->shadow_height == w->height &&
        w->shadow_pixel_scale == pixel_scale && memcmp(w->shadow_look, &look, sizeof(look)) == 0) return;
    if (!shadow_create_strips(w)) { shadow_destroy(w); return; }
    const int m = SHADOW_MARGIN, W = (int)w->width, H = (int)w->height;
    *w->shadow_look = look; /* shadow_strip_corner reads the look being painted */
    const int c = shadow_strip_corner(w);
    const int ok = shadow_paint_strip(w, &w->shadow[0], &look, -m, -m, w->width + 2 * m, (uint32_t)(m + c)) &&
        shadow_paint_strip(w, &w->shadow[1], &look, -m, H - c, w->width + 2 * m, (uint32_t)(m + c)) &&
        shadow_paint_strip(w, &w->shadow[2], &look, -m, c, m, (uint32_t)(H - 2 * c)) &&
        shadow_paint_strip(w, &w->shadow[3], &look, W, c, m, (uint32_t)(H - 2 * c));
    if (!ok) { shadow_destroy(w); return; }
    w->shadow_shown = 1; w->shadow_width = w->width; w->shadow_height = w->height;
    w->shadow_pixel_scale = pixel_scale; *w->shadow_look = look;
}
