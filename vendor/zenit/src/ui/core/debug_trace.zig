/// debug_trace, DevTools render reason and event propagation tracing. Zero-cost
/// design: one null check when DevTools closed (file-scope global pointer). Data
/// in DebugTraceStore, heap-alloc on-demand, ring buffer reuse.

// === Render Reason ===

pub const RenderReason = enum(u8) {
    style_change,
    background_change,
    opacity_change,
    translate_change,
    scale_change,
    rotate_change,
    border_change,
    corner_radius_change,
    font_weight_change,
    layout_triggered,
    sizing_triggered,
    explicit,
    mount,
    transition_tick,
};

pub const RenderReasonRecord = struct {
    frame: u64,
    node_id: u32,
    reason: RenderReason,
    source: [48]u8,
    source_len: u8,

    pub fn getSource(self: *const RenderReasonRecord) []const u8 {
        return self.source[0..self.source_len];
    }
};

// === Event Trace ===

pub const EventTracePhase = enum(u8) { capture, target, bubble };

pub const EventKindTag = enum(u8) {
    mouse_down,
    mouse_up,
    click,
    double_click,
    mouse_move,
    mouse_enter,
    mouse_leave,
    scroll,
    magnify,
    drag,
    key_down,
    key_up,
    text_input,
    ime_preedit,
    ime_commit,
    focus,
    blur,
    ime_delete_surrounding,
};

pub const EventResultTag = enum(u8) { ignored, handled, stop };

pub const EventTraceRecord = struct {
    frame: u64,
    event_kind: EventKindTag,
    phase: EventTracePhase,
    target_node_id: u32,
    handler_node_id: u32,
    result: EventResultTag,
    pointer_x: f32,
    pointer_y: f32,
};

// === Store ===

const RING_SIZE = 512;

pub const DebugTraceStore = struct {
    render_records: [RING_SIZE]RenderReasonRecord = undefined,
    render_write: u32 = 0,
    render_count: u32 = 0,

    event_records: [RING_SIZE]EventTraceRecord = undefined,
    event_write: u32 = 0,
    event_count: u32 = 0,

    paused: bool = false,

    pub fn recordRender(self: *DebugTraceStore, frame: u64, node_id: u32, reason: RenderReason, comptime source: []const u8) void {
        if (self.paused) return;
        var record = RenderReasonRecord{
            .frame = frame,
            .node_id = node_id,
            .reason = reason,
            .source = undefined,
            .source_len = @intCast(@min(source.len, 48)),
        };
        const len = @min(source.len, 48);
        @memcpy(record.source[0..len], source[0..len]);
        self.render_records[self.render_write % RING_SIZE] = record;
        self.render_write +%= 1;
        if (self.render_count < RING_SIZE) self.render_count += 1;
    }

    pub fn recordEvent(
        self: *DebugTraceStore,
        frame: u64,
        event_kind: EventKindTag,
        phase: EventTracePhase,
        target_node_id: u32,
        handler_node_id: u32,
        result: EventResultTag,
        pointer_x: f32,
        pointer_y: f32,
    ) void {
        if (self.paused) return;
        self.event_records[self.event_write % RING_SIZE] = .{
            .frame = frame,
            .event_kind = event_kind,
            .phase = phase,
            .target_node_id = target_node_id,
            .handler_node_id = handler_node_id,
            .result = result,
            .pointer_x = pointer_x,
            .pointer_y = pointer_y,
        };
        self.event_write +%= 1;
        if (self.event_count < RING_SIZE) self.event_count += 1;
    }

    /// Query render records for node (recent, newest first)
    pub fn getRenderForNode(self: *const DebugTraceStore, node_id: u32, out: []RenderReasonRecord) u32 {
        var count: u32 = 0;
        if (self.render_count == 0) return 0;
        var i: u32 = 0;
        while (i < self.render_count and count < out.len) : (i += 1) {
            // Traverse newest to oldest
            const idx = (self.render_write -% 1 -% i) % RING_SIZE;
            if (self.render_records[idx].node_id == node_id) {
                out[count] = self.render_records[idx];
                count += 1;
            }
        }
        return count;
    }

    /// Get recent event records (newest first)
    pub fn getRecentEvents(self: *const DebugTraceStore, out: []EventTraceRecord) u32 {
        var count: u32 = 0;
        if (self.event_count == 0) return 0;
        var i: u32 = 0;
        while (i < self.event_count and count < out.len) : (i += 1) {
            const idx = (self.event_write -% 1 -% i) % RING_SIZE;
            out[count] = self.event_records[idx];
            count += 1;
        }
        return count;
    }

    pub fn clear(self: *DebugTraceStore) void {
        self.render_write = 0;
        self.render_count = 0;
        self.event_write = 0;
        self.event_count = 0;
    }
};

// === Global callback (zero-cost guard) ===
// file-scope variable, Node records render reason through it, no reverse ref to
// Cx

var trace_store_ptr: ?*DebugTraceStore = null;
var trace_frame: u64 = 0;

pub fn maybeRecordRender(node_id: u32, reason: RenderReason, comptime source: []const u8) void {
    const store = trace_store_ptr orelse return;
    store.recordRender(trace_frame, node_id, reason, source);
}

pub fn maybeRecordEvent(
    event_kind: EventKindTag,
    phase: EventTracePhase,
    target_node_id: u32,
    handler_node_id: u32,
    result: EventResultTag,
    pointer_x: f32,
    pointer_y: f32,
) void {
    const store = trace_store_ptr orelse return;
    store.recordEvent(trace_frame, event_kind, phase, target_node_id, handler_node_id, result, pointer_x, pointer_y);
}

pub fn setGlobalTraceTarget(store: *DebugTraceStore, frame: u64) void {
    trace_store_ptr = store;
    trace_frame = frame;
}

pub fn clearGlobalTraceTarget() void {
    trace_store_ptr = null;
}
