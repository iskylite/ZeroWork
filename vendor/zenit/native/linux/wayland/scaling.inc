/* Fractional-scale-v1 uses 120ths and requires buffer_scale=1 plus a viewport
 * destination in logical units. Without both globals, retain wl_output's
 * integer scale. Toplevel physical dimensions round halfway away from zero. */
static uint32_t scaled_dimension(const ZenitWaylandWindow *w, uint32_t logical) {
    if (!w->fractional) return logical * (uint32_t)w->scale;
    return (uint32_t)(((uint64_t)logical * w->preferred_scale + 60) / 120);
}
static void fractional_preferred_scale(void *data, struct wp_fractional_scale_v1 *fractional, uint32_t scale) {
    (void)fractional; ZenitWaylandWindow *w = data;
    if (!scale || scale > 1920) {
        fprintf(stderr, "Unsupported Wayland preferred scale: %u/120\n", scale);
        w->closed = 1; return;
    }
    w->preferred_scale = scale;
    if (w->pointer_focused) (void)apply_cursor(w);
    shadow_sync(w);
}
static const struct wp_fractional_scale_v1_listener fractional_listener = {
    .preferred_scale = fractional_preferred_scale,
};
static int init_fractional_scaling(ZenitWaylandWindow *w) {
    if (!w->viewporter || !w->fractional_manager) return 1;
    union wl_argument args[] = { { .o = NULL }, { .o = (struct wl_object *)w->surface } };
    w->viewport = (struct wp_viewport *)request(w, w->viewporter, WP_VIEWPORTER_GET_VIEWPORT,
        &wp_viewport_interface, 1, 0, args);
    w->fractional = (struct wp_fractional_scale_v1 *)request(w, w->fractional_manager,
        WP_FRACTIONAL_SCALE_MANAGER_V1_GET_FRACTIONAL_SCALE, &wp_fractional_scale_v1_interface, 1, 0, args);
    if (!w->viewport || !w->fractional || listen(w, w->fractional, &fractional_listener, w) != 0) return 0;
    w->preferred_scale = 120;
    /* No destination yet: zenit_wayland_before_present sends it with the
     * first buffer, so no commit ever pairs a destination with another size. */
    return 1;
}
