//! Generate the macOS capability truth matrix from CAPS + lifecycle contracts.

const std = @import("std");
const system_sdk = @import("system_sdk");

// The native window bridge references the application's accessibility router.
// This generator never creates a window, so inert exports keep the link honest
// without pulling the entire UI module into a metadata tool.
export fn zenit_a11y_set_size(_: u32, _: u64) u32 {
    return 0;
}
export fn zenit_a11y_preferences_changed() void {}
export fn zenit_ax_in_frame_service() c_int {
    return 0;
}
export fn zenit_a11y_collection_info(_: u32, _: u64, _: ?*u32, _: ?*u32, _: ?*u32) c_int {
    return 0;
}
export fn zenit_a11y_collection_row_at(_: u32, _: u64, _: u32) u64 {
    return 0xFFFF_FFFF;
}
export fn zenit_a11y_commit_scroll_to_visible(_: u32, _: u64) c_int {
    return 0;
}
export fn zenit_a11y_root_count(_: u32) c_int {
    return 0;
}
export fn zenit_a11y_root_at(_: u32, _: c_int) u64 {
    return std.math.maxInt(u32);
}
export fn zenit_a11y_children_count(_: u32, _: u64) c_int {
    return 0;
}
export fn zenit_a11y_children_at(_: u32, _: u64, _: c_int) u64 {
    return std.math.maxInt(u32);
}
export fn zenit_a11y_role(_: u32, _: u64) c_int {
    return 0;
}
export fn zenit_a11y_state(_: u32, _: u64) u32 {
    return 0;
}
export fn zenit_a11y_label(_: u32, _: u64, _: ?[*]u8, _: c_int) c_int {
    return 0;
}
export fn zenit_a11y_description(_: u32, _: u64, _: ?[*]u8, _: c_int) c_int {
    return 0;
}
export fn zenit_a11y_value(_: u32, _: u64, _: ?[*]u8, _: c_int) c_int {
    return 0;
}
export fn zenit_a11y_exists(_: u32, _: u64) c_int {
    return 0;
}
export fn zenit_a11y_numeric_value(_: u32, _: u64, _: ?*f32, _: ?*f32, _: ?*f32) c_int {
    return 0;
}
export fn zenit_a11y_frame(_: u32, _: u64, _: ?*f32, _: ?*f32, _: ?*f32, _: ?*f32) c_int {
    return 0;
}
export fn zenit_a11y_actions(_: u32, _: u64) u8 {
    return 0;
}
export fn zenit_a11y_perform_action(_: u32, _: u64, _: u8) c_int {
    return 0;
}
export fn zenit_a11y_text_selection(_: u32, _: u64, _: ?*u32, _: ?*u32, _: ?*u32) c_int {
    return 0;
}
export fn zenit_a11y_text_capabilities(_: u32, _: u64) u8 {
    return 0;
}
export fn zenit_a11y_set_text_selection(_: u32, _: u64, _: u32, _: u32) c_int {
    return 0;
}
export fn zenit_a11y_set_focus(_: u32, _: u64, _: c_int) c_int {
    return 0;
}
export fn zenit_a11y_set_text_value(_: u32, _: u64, _: ?[*]const u8, _: c_int) c_int {
    return 0;
}
export fn zenit_a11y_text_visible_range(_: u32, _: u64, _: ?*u32, _: ?*u32) c_int {
    return 0;
}
export fn zenit_a11y_text_frame(_: u32, _: u64, _: u32, _: u32, _: ?*f32, _: ?*f32, _: ?*f32, _: ?*f32) c_int {
    return 0;
}
export fn zenit_a11y_text_range_at_point(_: u32, _: u64, _: f32, _: f32, _: ?*u32, _: ?*u32) c_int {
    return 0;
}
export fn zenit_a11y_set_numeric_value(_: u32, _: u64, _: f32) c_int {
    return 0;
}
export fn zenit_a11y_numeric_capabilities(_: u32, _: u64) u8 {
    return 0;
}
export fn zenit_a11y_parent(_: u32, _: u64) u64 {
    return std.math.maxInt(u32);
}
export fn zenit_a11y_focused(_: u32) u64 {
    return std.math.maxInt(u32);
}
export fn zenit_a11y_active_descendant(_: u32, _: u64) u64 {
    return std.math.maxInt(u32);
}
export fn zenit_a11y_hit_test(_: u32, _: f32, _: f32) u64 {
    return std.math.maxInt(u32);
}
export fn zenit_a11y_orientation(_: u32, _: u64) u8 {
    return 0;
}
export fn zenit_a11y_sort_direction(_: u32, _: u64) u8 {
    return 0;
}
export fn zenit_a11y_level(_: u32, _: u64) u16 {
    return 0;
}
export fn zenit_a11y_row_index_range(_: u32, _: u64, _: ?*u32, _: ?*u32) c_int {
    return 0;
}
export fn zenit_a11y_column_index_range(_: u32, _: u64, _: ?*u32, _: ?*u32) c_int {
    return 0;
}
export fn zenit_a11y_placeholder(_: u32, _: u64, _: ?[*]u8, _: c_int) c_int {
    return 0;
}
export fn zenit_a11y_identifier(_: u32, _: u64, _: ?[*]u8, _: c_int) c_int {
    return 0;
}

// Inert exports parallel to the text input bridge. window_bridge.m externs these six symbols,
// real implementation is in src/ui/a11y/macos_bridge.zig, but this tool only generates
// capability matrix metadata and shouldn't pull in the entire UI module. It never creates
// windows, so these are never called. Each new text input capability needs a companion stub
// here, else `zig build capability-matrix` fails to link.
export fn zenit_text_input_copy(_: u32, _: u64, _: ?[*]u8, _: c_int) c_int {
    return -1;
}
export fn zenit_text_input_selection(_: u32, _: ?*u32, _: ?*u32, _: ?*u32) c_int {
    return -1;
}
export fn zenit_text_input_frame(_: u32, _: u32, _: u32, _: ?*f32, _: ?*f32, _: ?*f32, _: ?*f32) c_int {
    return -1;
}
export fn zenit_text_input_range_at_point(_: u32, _: f32, _: f32, _: ?*u32, _: ?*u32) c_int {
    return -1;
}
export fn zenit_text_input_utf16_for_utf8(_: u32, _: u64) u64 {
    return 0;
}
export fn zenit_text_input_utf8_for_utf16(_: u32, _: u64) u64 {
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const caps_mod = system_sdk.capabilities;
    const macos = system_sdk.backends.macos.MacOSBackend;
    try caps_mod.validateAdvertised(macos.CAPS, macos.vtable);

    var out_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll(
        "# macOS Capability Truth Matrix\n\n" ++
            "Generated by `zig build capability-matrix`; do not hand-edit support values.\n\n" ++
            "| Capability | Supported | Implementation | Owner | Execution | Candidate | Acceptance | Lifetime |\n" ++
            "|---|---|---|---|---|---|---|---|\n",
    );
    inline for (@import("zenit_reflection").fields(caps_mod.Capability)) |field| {
        const capability: caps_mod.Capability = @fromBackingInt(@intCast(field.value));
        const contract = caps_mod.contractFor(capability);
        const supported = macos.CAPS.has(capability);
        const implemented = caps_mod.implementationPresent(capability, macos.vtable);
        try out.print("| `{s}` | {s} | {s} | `{s}` | `{s}` | {s} | `{s}` | {s} |\n", .{
            @tagName(capability),
            if (supported) "yes" else "no",
            if (implemented) "callable" else "absent",
            @tagName(contract.owner),
            @tagName(contract.execution),
            if (contract.candidate_required) "required" else "optional",
            @tagName(contract.acceptance),
            contract.lifetime,
        });
    }
    try out.flush();
}
