//! Headless pointer drag within a window.
//!
//! Design contract: docs/DRAG_INTERACTION_DESIGN.md. Summary:
//! - No Node production, no business data change, no style decision;
//! - Strict lifecycle `pending -> start -> move* -> end | cancel`, terminal exactly once;
//! - `Machine` pure state machine (threshold/axis projection/delta/exactly-once),
//!   no Node/Cx/allocator dependency;
//! - `Binding` is a Scope-managed raw-event adapter, occupies the source event slot;
//! - `Manager` per-Cx: session arbitration, capture/click suppress/cursor, cancel trigger.
//!
//! v1 covers the desktop primary mouse only; touch/pen/GestureArena see design D4.

const std = @import("std");
const core = @import("../core.zig");
const events = @import("../events.zig");

const Cx = core.Cx;
const Node = core.Node;
const Scope = core.Scope;

pub const Axis = enum(u8) {
    both,
    horizontal,
    vertical,
};

pub const Phase = enum(u8) {
    start,
    move,
    end,
    cancel,
};

pub const CancelReason = enum(u8) {
    explicit,
    escape,
    window_blur,
    pointer_cancel,
    source_detached,
    disabled,
    scope_disposed,
    native_handoff,
};

pub const Point = struct { x: f32, y: f32 };

/// Generation-safe handle (ui.NodeHandle).
pub const SourceHandle = core.NodeHandle;
pub const PointerId = u32;
pub const mouse_pointer_id: PointerId = 0;

pub const PendingDownEvent = struct {
    source: SourceHandle,
    pointer_id: PointerId,
    position_window: Point,
    button: events.MouseButton,
    modifiers: events.Modifiers,
};

pub const Event = struct {
    phase: Phase,
    source: SourceHandle,
    pointer_id: PointerId,

    /// Unclamped window logical-point coordinate.
    origin_window: Point,
    position_window: Point,

    /// position - origin, not axis-projected.
    raw_delta: Point,

    /// After axis projection, cumulative displacement. Consumer should compute result from
    /// initial model value using this.
    delta: Point,

    /// Axis projection delta since last dispatched drag event.
    step_delta: Point,

    /// Monotonic time since pointer down.
    elapsed_ns: u64,
    button: events.MouseButton,
    start_modifiers: events.Modifiers,
    modifiers: events.Modifiers,

    /// Non-null only when phase == .cancel.
    cancel_reason: ?CancelReason = null,
};

pub const StartRequest = struct {
    source: SourceHandle,
    pointer_id: PointerId,
    button: events.MouseButton,
    origin_window: Point,
    position_window: Point,
    raw_delta: Point,
    start_modifiers: events.Modifiers,
    modifiers: events.Modifiers,
};

pub const PendingDownCallback = *const fn (PendingDownEvent, *anyopaque) void;
pub const StartPredicate = *const fn (StartRequest, *anyopaque) bool;
pub const Callback = *const fn (Event, *anyopaque) void;

pub const Config = struct {
    axis: Axis = .both,
    activation_distance: f32 = 4.0,
    /// v1 accepts .left only; field reserved so future expansion doesn't reshape Config.
    button: events.MouseButton = .left,
    enabled: bool = true,

    /// null = don't override system cursor; only live during active.
    active_cursor: ?core.CursorShape = .grabbing,

    /// Called once synchronously after down claim, for immediate actions like focus/value jump.
    /// Not a drag phase; no paired callback at pending end.
    on_pending_down: ?PendingDownCallback = null,

    /// Called once crossing threshold. false = this sequence rejected.
    can_start: ?StartPredicate = null,
};

pub const AttachError = error{
    InvalidActivationDistance,
    UnsupportedButton,
    EventSlotOccupied,
    InvalidSource,
    OutOfMemory,
};

// -----------
// Machine: pure state machine
// -----------

/// Pure state machine: input down/move/up/cancel (time caller-computed elapsed_ns),
/// output zero to two transitions. No Node/Cx/allocator; independent unit-testable.
pub const Machine = struct {
    axis: Axis = .both,
    activation_distance: f32 = 4.0,

    state: State = .idle,
    origin: Point = .{ .x = 0, .y = 0 },
    /// Latest observed position (cancel event coordinate).
    last_pos: Point = .{ .x = 0, .y = 0 },
    last_elapsed_ns: u64 = 0,
    /// Latest dispatched position + axis delta (step_delta base).
    last_dispatched_pos: Point = .{ .x = 0, .y = 0 },
    last_dispatched_delta: Point = .{ .x = 0, .y = 0 },

    pub const State = enum { idle, pending, active, rejected };

    pub const Transition = struct {
        kind: Phase,
        position: Point,
        raw_delta: Point,
        delta: Point,
        step_delta: Point,
        elapsed_ns: u64,
    };

    pub const Output = struct {
        buf: [2]Transition = undefined,
        len: u8 = 0,

        fn push(self: *Output, t: Transition) void {
            std.debug.assert(self.len < 2);
            self.buf[self.len] = t;
            self.len += 1;
        }

        pub fn slice(self: *const Output) []const Transition {
            return self.buf[0..self.len];
        }
    };

    fn project(self: *const Machine, raw: Point) Point {
        return switch (self.axis) {
            .both => raw,
            .horizontal => .{ .x = raw.x, .y = 0 },
            .vertical => .{ .x = 0, .y = raw.y },
        };
    }

    fn projectedDistance(self: *const Machine, raw: Point) f32 {
        return switch (self.axis) {
            .both => @sqrt(raw.x * raw.x + raw.y * raw.y),
            .horizontal => @abs(raw.x),
            .vertical => @abs(raw.y),
        };
    }

    fn makeTransition(self: *Machine, kind: Phase, pos: Point, elapsed_ns: u64) Transition {
        const raw = Point{ .x = pos.x - self.origin.x, .y = pos.y - self.origin.y };
        const delta = self.project(raw);
        const step = Point{
            .x = delta.x - self.last_dispatched_delta.x,
            .y = delta.y - self.last_dispatched_delta.y,
        };
        self.last_dispatched_pos = pos;
        self.last_dispatched_delta = delta;
        return .{
            .kind = kind,
            .position = pos,
            .raw_delta = raw,
            .delta = delta,
            .step_delta = step,
            .elapsed_ns = elapsed_ns,
        };
    }

    pub fn feedDown(self: *Machine, pos: Point) Output {
        std.debug.assert(self.state == .idle);
        var out = Output{};
        self.origin = pos;
        self.last_pos = pos;
        self.last_elapsed_ns = 0;
        // start has step_delta == delta; down instant activates both to zero.
        self.last_dispatched_pos = pos;
        self.last_dispatched_delta = .{ .x = 0, .y = 0 };
        self.state = .pending;
        if (self.activation_distance == 0) {
            self.state = .active;
            out.push(self.makeTransition(.start, pos, 0));
        }
        return out;
    }

    pub fn feedMove(self: *Machine, pos: Point, elapsed_ns: u64) Output {
        var out = Output{};
        self.last_pos = pos;
        self.last_elapsed_ns = elapsed_ns;
        switch (self.state) {
            .idle, .rejected => {},
            .pending => {
                const raw = Point{ .x = pos.x - self.origin.x, .y = pos.y - self.origin.y };
                if (self.projectedDistance(raw) >= self.activation_distance) {
                    self.state = .active;
                    out.push(self.makeTransition(.start, pos, elapsed_ns));
                }
            },
            .active => {
                // No redundant move for same coordinate.
                if (pos.x != self.last_dispatched_pos.x or pos.y != self.last_dispatched_pos.y) {
                    out.push(self.makeTransition(.move, pos, elapsed_ns));
                }
            },
        }
        return out;
    }

    pub fn feedUp(self: *Machine, pos: Point, elapsed_ns: u64) Output {
        var out = Output{};
        self.last_pos = pos;
        self.last_elapsed_ns = elapsed_ns;
        switch (self.state) {
            .idle => {},
            .rejected => self.state = .idle,
            .pending => {
                // No move after down, but up past threshold: emit start then end.
                // If consumer rejects on start, binding discards following end.
                const raw = Point{ .x = pos.x - self.origin.x, .y = pos.y - self.origin.y };
                if (self.projectedDistance(raw) >= self.activation_distance) {
                    self.state = .active;
                    out.push(self.makeTransition(.start, pos, elapsed_ns));
                    out.push(self.makeTransition(.end, pos, elapsed_ns));
                }
                self.state = .idle;
            },
            .active => {
                // end uses mouse-up final position, even if same as last move.
                out.push(self.makeTransition(.end, pos, elapsed_ns));
                self.state = .idle;
            },
        }
        return out;
    }

    /// Any cancel trigger. active emits one cancel (position = latest observed);
    /// pending/rejected silent back to idle.
    pub fn feedCancel(self: *Machine) Output {
        var out = Output{};
        switch (self.state) {
            .idle => {},
            .pending, .rejected => self.state = .idle,
            .active => {
                out.push(self.makeTransition(.cancel, self.last_pos, self.last_elapsed_ns));
                self.state = .idle;
            },
        }
        return out;
    }

    /// binding calls when can_start returns false: discard just-emitted start, this
    /// pointer sequence asks predicate no more, emits no drag callback. Machine already
    /// back to idle on up-crosses threshold; stay idle.
    pub fn reject(self: *Machine) void {
        std.debug.assert(self.state != .pending);
        if (self.state == .active) self.state = .rejected;
    }

    pub fn reset(self: *Machine) void {
        self.state = .idle;
    }
};

// Manager: central arbitrator, one per Cx

pub const Manager = struct {
    session: ?Session = null,
    /// Incremented per claim. On reentry, use it to reverify session identity,
    /// avoid "old session's following handler writing to new session".
    generation: u32 = 0,

    pending_terminals: [max_pending_terminals]PendingTerminal = undefined,
    pending_terminal_len: u8 = 0,

    pub const SessionPhase = enum { pending, active, rejected };

    pub const Session = struct {
        binding: *Binding,
        source: SourceHandle,
        pointer_id: PointerId,
        button: events.MouseButton,
        start_modifiers: events.Modifiers,
        phase: SessionPhase = .pending,
        captured: bool = false,
        cursor_token: ?core.CursorToken = null,
        /// start callback dispatch started. phase goes active step 1, start callback not until
        /// step 5; between (setPointerCapture triggers old holder's on_capture_lost, source dies),
        /// cancel: from consumer view drag never started, must silent (s11.1).
        start_delivered: bool = false,
    };

    fn isCurrent(self: *const Manager, binding: *const Binding, generation: u32) bool {
        const s = self.session orelse return false;
        return s.binding == binding and self.generation == generation;
    }

    /// Escape priority consumer: any session (pending/rejected/active) cancels + consumed.
    pub fn handleEscape(self: *Manager, cx: *Cx) bool {
        if (self.session == null) return false;
        self.cancel(cx, .escape);
        return true;
    }

    /// Unified cancel entry. An active session emits one main callback(.cancel); pending/rejected
    /// clean up silently. Both suppress this pointer sequence's click. Idempotent.
    ///
    /// Order contract (terminal path same as `Binding.finishSession`):
    /// 1. Commit manager state, finish all Binding work **before any user code**
    ///    (machine wrap-up, terminal event + callback/context snapshot queued);
    /// 2. Release cursor / capture, hover resync: runs user code synchronously (on_capture_lost,
    ///    mouse_enter/leave), which may dispose the scope owning Binding;
    /// 3. Deliver queued terminal callbacks.
    /// After step 2 there is no more Binding dereference. Terminal callbacks are delivered in
    /// queue order, exactly once, before the context is destroyed: if Binding is destroyed in
    /// step 2, destroyResource delivers first (s11.3) and step 3 finds the queue empty.
    /// Delivery may also happen early via nesting: step 2 user code ending another session (or
    /// destroying another Binding) flushes the whole queue, so this terminal is delivered before
    /// this session's capture release / hover resync finishes.
    pub fn cancel(self: *Manager, cx: *Cx, reason: CancelReason) void {
        const session = self.session orelse return;
        // Commit early (commit-before-callback): reentry cancel/dispose sees empty session, idem
        // no-op.
        self.session = null;
        const binding = session.binding;

        // Canceled pointer sequence not valid click; later mouse-up idem cleanup (cleared next left
        // down).
        cx.dispatcher.cancelClickSynthesisForActivePointer();

        // Main callback only on start dispatched: machine may cross threshold but start callback
        // not yet to consumer (can_start/on_pending_down reentry canceled, or steps 1~5 canceled)
        // —from user view drag never started, must silent.
        if (session.phase == .active and session.start_delivered) {
            binding.start_modifiers_snapshot = session.start_modifiers;
            const out = binding.machine.feedCancel();
            for (out.slice()) |t| {
                std.debug.assert(t.kind == .cancel);
                // Queue doesn't run user code; binding still safe to read.
                self.queueTerminal(binding.terminalFor(t, reason));
            }
        }
        binding.machine.reset();

        // ---- Below runs user code, no more binding dereference ----
        if (session.cursor_token) |token| cx.releaseCursor(token);
        if (session.captured) {
            if (cx.dispatcher.releasePointerCaptureFor(session.source)) {
                cx.resyncPointerAfterCaptureRelease(cx.mouse_x, cx.mouse_y, null);
            }
        }
        self.flushTerminals();
    }

    /// Queued but not-yet-delivered terminal callbacks (end / cancel). Snapshot callback +
    /// event, no Binding dereference on deliver.
    pub const PendingTerminal = struct {
        /// Identity-compare only (destroyResource delivers first), no deref on deliver.
        binding: *const Binding,
        event: Event,
        callback: Callback,
        context: *anyopaque,
    };

    /// Terminal cleanup step 2 user code may nest trigger another session's terminal,
    /// so FIFO not single-slot. Queue doesn't run user code; deliver all via `flushTerminals`
    /// by queue order, exactly once.
    const max_pending_terminals = 8;

    fn queueTerminal(self: *Manager, p: PendingTerminal) void {
        if (self.pending_terminal_len == max_pending_terminals) {
            // 8-level nesting terminal cleanup to get here (each level new + end session in prior's
            // capture/hover callback)—runaway reentry.
            @panic("drag: 嵌套的终止回调超过上限（终止清理中的用户代码反复启动并终止拖拽）");
        }
        self.pending_terminals[self.pending_terminal_len] = p;
        self.pending_terminal_len += 1;
    }

    fn flushTerminals(self: *Manager) void {
        while (self.pending_terminal_len > 0) {
            const p = self.pending_terminals[0];
            // Dequeue before callback: reentry terminal path sees updated queue.
            std.mem.copyForwards(PendingTerminal, self.pending_terminals[0 .. self.pending_terminal_len - 1], self.pending_terminals[1..self.pending_terminal_len]);
            self.pending_terminal_len -= 1;
            p.callback(p.event, p.context);
        }
    }

    fn hasPendingTerminalFor(self: *const Manager, binding: *const Binding) bool {
        for (self.pending_terminals[0..self.pending_terminal_len]) |p| {
            if (p.binding == binding) return true;
        }
        return false;
    }

    /// Node lifecycle: source's subtree detached/destroyed -> cancel session.
    /// Identity stable-id only, no deref of stale pointer.
    pub fn handleSubtreeInvalidation(self: *Manager, cx: *Cx, subtree_root: *Node) void {
        const session = self.session orelse return;
        if (isNodeInSubtree(subtree_root, session.source.id)) {
            self.cancel(cx, .source_detached);
        }
    }
};

fn isNodeInSubtree(root: *Node, node_id: u32) bool {
    if (root.id == node_id) return true;
    for (root.children.items) |child| {
        if (isNodeInSubtree(child, node_id)) return true;
    }
    return false;
}

// Binding: raw-event adapter managed by Scope

pub const Binding = struct {
    cx: *Cx,
    /// Only deref within source's own event handler (handler on source;
    /// event arrival proves node alive); cross-frame hold via source_handle.
    source_node: *Node,
    /// Written after registry round-trip validation on claim.
    source_handle: SourceHandle = .{ .id = 0, .generation = 0 },
    config: Config,
    callback: Callback,
    context: *anyopaque,
    machine: Machine,
    enabled: bool,
    /// down instant, elapsed_ns base.
    down_instant: ?@import("zenit_time").Instant = null,
    /// Latest input modifiers (move without realtime degraded to latest-known).
    cur_modifiers: events.Modifiers = .{},
    /// down instant snapshot for terminal dispatch (session cleared after still usable).
    start_modifiers_snapshot: events.Modifiers = .{},

    /// Register drag on source. Binding is scope-managed, caller doesn't free;
    /// failure is transactional, no half-registered state.
    ///
    /// Lifecycle contract (docs/DRAG_INTERACTION_DESIGN.md s11.3): attach after the callback
    /// context is created; reverse cleanup guarantees the cancel callback runs before the context
    /// is destroyed.
    pub fn attach(
        scope: *Scope,
        cx: *Cx,
        source: *Node,
        config: Config,
        callback: Callback,
        context: *anyopaque,
    ) AttachError!*Binding {
        if (std.math.isNan(config.activation_distance) or
            std.math.isInf(config.activation_distance) or
            config.activation_distance < 0)
        {
            return AttachError.InvalidActivationDistance;
        }
        if (config.button != .left) return AttachError.UnsupportedButton;
        const ev = &source.behavior.events;
        if (ev.on_event != null or ev.on_event_capture != null or
            ev.on_scroll != null or ev.event_context != null)
        {
            return AttachError.EventSlotOccupied;
        }
        // If source already registered, its id must resolve back; resolve to other node means
        // stale handle (e.g., id reuse untracked). Unregistered new node ok; claim round-trip
        // validates.
        const source_handle: SourceHandle = blk: {
            const h = cx.node_registry.handleFor(source);
            if (cx.node_registry.resolve(h, null)) |resolved| {
                if (resolved != source) return AttachError.InvalidSource;
            }
            // Establish a generation before the first event. This lets scope
            // cleanup distinguish a live, not-yet-registered source from a node
            // that was already freed, without dereferencing a stale pointer.
            const generation = cx.node_registry.trackGeneration(source) catch return AttachError.OutOfMemory;
            break :blk .{ .id = source.id, .generation = generation };
        };

        const binding = cx.allocator.create(Binding) catch return AttachError.OutOfMemory;
        errdefer cx.allocator.destroy(binding);
        binding.* = .{
            .cx = cx,
            .source_node = source,
            .source_handle = source_handle,
            .config = config,
            .callback = callback,
            .context = context,
            .machine = .{
                .axis = config.axis,
                .activation_distance = config.activation_distance,
            },
            .enabled = config.enabled,
        };
        scope.registerResource(binding, destroyResource) catch return AttachError.OutOfMemory;

        // All failables done before occupying event slot.
        ev.on_event = sourceEventHandler;
        ev.event_context = binding;
        return binding;
    }

    fn destroyResource(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const binding: *Binding = @ptrCast(@alignCast(ptr));
        const cx = binding.cx;
        // This binding's terminal callback queued but not delivered (terminal cleanup's user code
        // unloaded it): context still there (reverse cleanup), deliver first, outer cleanup finds
        // queue empty.
        if (cx.drag_manager.hasPendingTerminalFor(binding)) cx.drag_manager.flushTerminals();
        // scope deinit: if session owns this binding, cancel callback before context dies (context
        // registered first, reverse cleanup after; constructible from order).
        if (cx.drag_manager.session) |s| {
            if (s.binding == binding) cx.drag_manager.cancel(cx, .scope_disposed);
        }
        // Detach event slot: only touch if source still lives same identity. Node may die before
        // scope (or never registered), skip, same exposure as existing component scope-owned
        // event_context.
        const live_source = cx.node_registry.resolve(binding.source_handle, null) orelse
            if (cx.node_registry.isCurrentIdentity(binding.source_handle, binding.source_node)) binding.source_node else null;
        if (live_source) |node| {
            if (node == binding.source_node) {
                node.behavior.events.on_event = null;
                node.behavior.events.event_context = null;
            }
        }
        allocator.destroy(binding);
    }

    pub fn setEnabled(self: *Binding, enabled: bool) void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        if (!enabled) {
            if (self.cx.drag_manager.session) |s| {
                if (s.binding == self) self.cx.drag_manager.cancel(self.cx, .disabled);
            }
        }
    }

    pub fn cancel(self: *Binding, reason: CancelReason) void {
        if (self.cx.drag_manager.session) |s| {
            if (s.binding == self) self.cx.drag_manager.cancel(self.cx, reason);
        }
    }

    pub fn isPending(self: *const Binding) bool {
        const s = self.cx.drag_manager.session orelse return false;
        return s.binding == self and s.phase == .pending;
    }

    pub fn isDragging(self: *const Binding) bool {
        const s = self.cx.drag_manager.session orelse return false;
        return s.binding == self and s.phase == .active;
    }

    // -- internal --

    fn elapsedNs(self: *const Binding) u64 {
        const down = self.down_instant orelse return 0;
        const now = @import("zenit_time").Instant.now(self.cx.io) catch return 0;
        // No underflow when clock same or backward.
        if (now.order(down) == .lt) return 0;
        return now.since(down);
    }

    fn buildEvent(self: *const Binding, t: Machine.Transition, session: Manager.Session, reason: ?CancelReason) Event {
        return .{
            .phase = t.kind,
            .source = session.source,
            .pointer_id = session.pointer_id,
            .origin_window = self.machine.origin,
            .position_window = t.position,
            .raw_delta = t.raw_delta,
            .delta = t.delta,
            .step_delta = t.step_delta,
            .elapsed_ns = t.elapsed_ns,
            .button = session.button,
            .start_modifiers = session.start_modifiers,
            .modifiers = self.cur_modifiers,
            .cancel_reason = reason,
        };
    }

    /// Dispatch one transition to consumer. Session committed (commit-before-callback) before;
    /// here only copy event + callback, no deref self-outside proof of life.
    fn dispatchTransition(self: *Binding, t: Machine.Transition, reason: ?CancelReason) void {
        // Note: terminal (end/cancel) call with manager.session cleared;
        // buildEvent-needed session info passed caller snapshot.
        const s = self.cx.drag_manager.session orelse blk: {
            // Terminal path: session cleared, buildEvent uses binding cache.
            break :blk Manager.Session{
                .binding = self,
                .source = self.source_handle,
                .pointer_id = mouse_pointer_id,
                .button = self.config.button,
                .start_modifiers = self.start_modifiers_snapshot,
            };
        };
        const event = self.buildEvent(t, s, reason);
        const cb = self.callback;
        const ctx = self.context;
        cb(event, ctx);
    }

    /// Activation sequence (s8.2): mark active -> suppress click -> capture -> cursor -> start
    /// callback. false = activation aborted (source stale or reentry cleared session).
    fn activate(self: *Binding, t: Machine.Transition, generation: u32) bool {
        const cx = self.cx;
        const manager = &cx.drag_manager;

        // can_start: asked once synchronously when the threshold is crossed; if rejected, the
        // sequence is silently voided and click is suppressed.
        if (self.config.can_start) |predicate| {
            const s = manager.session.?;
            const request = StartRequest{
                .source = s.source,
                .pointer_id = s.pointer_id,
                .button = s.button,
                .origin_window = self.machine.origin,
                .position_window = t.position,
                .raw_delta = t.raw_delta,
                .start_modifiers = s.start_modifiers,
                .modifiers = self.cur_modifiers,
            };
            const ctx = self.context;
            const allowed = predicate(request, ctx);
            // Predicate reentrant: reverify session.
            if (!manager.isCurrent(self, generation)) return false;
            if (!allowed) {
                self.machine.reject();
                manager.session.?.phase = .rejected;
                cx.dispatcher.cancelClickSynthesisForActivePointer();
                return false;
            }
        }

        // 1. manager mark session active.
        manager.session.?.phase = .active;
        // 2. Suppress this pointer sequence click.
        cx.dispatcher.cancelClickSynthesisForActivePointer();
        // 3. Set pointer capture (source must resolve else detach cleanup).
        const source = cx.node_registry.resolve(manager.session.?.source, null) orelse {
            manager.cancel(cx, .source_detached);
            return false;
        };
        const source_handle = manager.session.?.source;
        cx.setPointerCapture(source);
        // setPointerCapture releases old capture first, triggers on_capture_lost (user code),
        // may cancel session or destroy binding: only identity-compare, no self deref.
        // setPointerCapture may grant capture to source even if session gone; match-release to
        // clean,
        // else capture on node without session until next left-up auto-clears.
        if (!manager.isCurrent(self, generation)) {
            if (cx.dispatcher.releasePointerCaptureFor(source_handle)) {
                cx.resyncPointerAfterCaptureRelease(cx.mouse_x, cx.mouse_y, null);
            }
            return false;
        }
        manager.session.?.captured = true;
        // 4. Set optional active cursor.
        if (self.config.active_cursor) |shape| {
            // Failing to acquire a cursor lease only means "drag doesn't change cursor"; drag
            // proceeds
            // (cursor_token stays null; finishSession/cancel handle null). Must not panic:
            // acquireCursor error.NoPointerCapture is a recoverable protocol state triggered by a
            // **legal app callback**: setPointerCapture first releases, triggering on_capture_lost;
            // if
            // the app moves capture elsewhere (a reasonable response), the outer setPointerCapture
            // fails
            // early and the lease cannot be acquired. The library must not kill the host over legal
            // app usage.
            manager.session.?.cursor_token = cx.acquireCursor(source, shape) catch |err| switch (err) {
                error.OutOfMemory => @panic("OOM: drag cursor lease"),
                error.NoPointerCapture => null,
            };
        }
        // 5. Emit start callback. Mark "dispatched" first: cancel in start callback gets cancel.
        manager.session.?.start_delivered = true;
        self.dispatchTransition(t, null);
        return manager.isCurrent(self, generation);
    }

    /// Terminal cleanup + end callback. Session is snapshotted to the binding cache before clear.
    /// Same principle as `Manager.cancel` (commit-before-callback): finish Binding work + snapshot,
    /// then release capture (triggers on_capture_lost user code); no self deref afterwards.
    /// Unlike cancel, no hover resync here (natural mouse-up resyncs in handleMouseUpEx after
    /// dispatch), so the end callback runs before hover resync.
    fn finishSession(self: *Binding, t: Machine.Transition) void {
        const cx = self.cx;
        const manager = &cx.drag_manager;
        const session = manager.session.?;
        self.start_modifiers_snapshot = session.start_modifiers;
        manager.session = null;
        // Snapshot before reset (same order as cancel), buildEvent reads machine.origin.
        manager.queueTerminal(self.terminalFor(t, null));
        self.machine.reset();

        // ---- Below runs user code, no more self deref ----
        if (session.cursor_token) |token| cx.releaseCursor(token);
        if (session.captured) {
            // Natural mouse-up dispatcher auto-clears capture; here match-release,
            // idem coexist (up path equally safe). hover resync from handleMouseUpEx
            // had_pointer_capture.
            _ = cx.dispatcher.releasePointerCaptureFor(session.source);
        }
        manager.flushTerminals();
    }

    /// Terminal event (end / cancel) snapshot: manager.session cleared; session info from binding
    /// cache.
    fn terminalFor(self: *Binding, t: Machine.Transition, reason: ?CancelReason) Manager.PendingTerminal {
        const s = Manager.Session{
            .binding = self,
            .source = self.source_handle,
            .pointer_id = mouse_pointer_id,
            .button = self.config.button,
            .start_modifiers = self.start_modifiers_snapshot,
        };
        return .{
            .binding = self,
            .event = self.buildEvent(t, s, reason),
            .callback = self.callback,
            .context = self.context,
        };
    }

    fn processOutput(self: *Binding, out: Machine.Output, generation: u32) void {
        const manager = &self.cx.drag_manager;
        for (out.slice()) |t| {
            if (!manager.isCurrent(self, generation)) return;
            switch (t.kind) {
                .start => {
                    // Activation failure (reject / source stale / reentry cleared): discard
                    // remaining (e.g.
                    // up-crosses-threshold end).
                    if (!self.activate(t, generation)) return;
                },
                .move => self.dispatchTransition(t, null),
                .end => self.finishSession(t),
                .cancel => unreachable, // cancel only via Manager.cancel dispatch
            }
        }
    }

    fn sourceEventHandler(event: core.Event, raw_ctx: ?*anyopaque) core.EventResult {
        const binding: *Binding = @ptrCast(@alignCast(raw_ctx orelse return .ignored));
        const cx = binding.cx;
        const manager = &cx.drag_manager;

        switch (event) {
            .mouse_down => |e| {
                if (!binding.enabled) return .ignored;
                if (e.button != binding.config.button) return .ignored;
                // Per-Cx at most one session; new non-sequence down doesn't preempt.
                if (manager.session != null) return .ignored;
                if (binding.machine.state != .idle) return .ignored;

                // Stable handle round-trip: can't claim if unresolvable.
                const handle = cx.node_registry.handleFor(binding.source_node);
                const resolved = cx.node_registry.resolve(handle, null) orelse return .ignored;
                if (resolved != binding.source_node) return .ignored;
                binding.source_handle = handle;

                manager.generation +%= 1;
                const generation = manager.generation;
                manager.session = .{
                    .binding = binding,
                    .source = handle,
                    .pointer_id = mouse_pointer_id,
                    .button = e.button,
                    .start_modifiers = e.modifiers,
                };
                binding.start_modifiers_snapshot = e.modifiers;
                binding.cur_modifiers = e.modifiers;
                binding.down_instant = @import("zenit_time").Instant.now(binding.cx.io) catch null;

                const out = binding.machine.feedDown(.{ .x = e.x, .y = e.y });

                // Order fixed: commit pending ownership -> on_pending_down -> reverify generation
                // -> (activation_distance==0) activation.
                if (binding.config.on_pending_down) |pending_cb| {
                    const pending_event = PendingDownEvent{
                        .source = handle,
                        .pointer_id = mouse_pointer_id,
                        .position_window = .{ .x = e.x, .y = e.y },
                        .button = e.button,
                        .modifiers = e.modifiers,
                    };
                    const ctx = binding.context;
                    pending_cb(pending_event, ctx);
                    if (!manager.isCurrent(binding, generation)) return .stop;
                }

                binding.processOutput(out, generation);
                return .stop;
            },
            .mouse_move => |e| {
                if (!manager.isCurrent(binding, manager.generation)) return .ignored;
                if (manager.session.?.binding != binding) return .ignored;
                binding.cur_modifiers = e.modifiers;
                const out = binding.machine.feedMove(.{ .x = e.x, .y = e.y }, binding.elapsedNs());
                binding.processOutput(out, manager.generation);
                return .stop;
            },
            .mouse_up => |e| {
                const s = manager.session orelse return .ignored;
                if (s.binding != binding) return .ignored;
                if (e.button != s.button) return .ignored;
                binding.cur_modifiers = e.modifiers;
                const generation = manager.generation;
                const out = binding.machine.feedUp(.{ .x = e.x, .y = e.y }, binding.elapsedNs());
                if (out.len == 0) {
                    // pending not cross threshold (click stays valid) or rejected wrap-up:
                    // silent clear. rejected click suppress already set.
                    manager.session = null;
                    binding.machine.reset();
                    return .stop;
                }
                binding.processOutput(out, generation);
                // up crosses threshold but can_start rejected: sequence ends with up, session
                // can't carry (finishSession already cleared). end normally delivered when
                // finishSession.
                if (manager.isCurrent(binding, generation)) {
                    manager.session = null;
                    binding.machine.reset();
                }
                return .stop;
            },
            else => return .ignored,
        }
    }
};

// Machine unit tests (S18.1)

const testing = std.testing;

fn expectPoint(expected_x: f32, expected_y: f32, p: Point) !void {
    try testing.expectEqual(expected_x, p.x);
    try testing.expectEqual(expected_y, p.y);
}

test "Machine: down/up 未越阈值零 transition" {
    var m = Machine{ .activation_distance = 4 };
    try testing.expectEqual(@as(u8, 0), m.feedDown(.{ .x = 10, .y = 10 }).len);
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 12, .y = 11 }, 100).len);
    try testing.expectEqual(@as(u8, 0), m.feedUp(.{ .x = 12, .y = 11 }, 200).len);
    try testing.expectEqual(Machine.State.idle, m.state);
}

test "Machine: 阈值边界 — 小于不激活、等于激活" {
    var m = Machine{ .axis = .horizontal, .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 3.99, .y = 100 }, 1).len);
    const out = m.feedMove(.{ .x = -4, .y = 0 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.start, out.buf[0].kind);
    try expectPoint(-4, 0, out.buf[0].delta);
}

test "Machine: vertical 轴投影只看 dy" {
    var m = Machine{ .axis = .vertical, .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    // Large dx doesn't activate
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 100, .y = 3 }, 1).len);
    const out = m.feedMove(.{ .x = 100, .y = 5 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try expectPoint(0, 5, out.buf[0].delta);
    try expectPoint(100, 5, out.buf[0].raw_delta);
}

test "Machine: both 用欧氏距离" {
    var m = Machine{ .axis = .both, .activation_distance = 5 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 3, .y = 3 }, 1).len); // sqrt(18) < 5
    const out = m.feedMove(.{ .x = 3, .y = 4 }, 2); // 5 == 5
    try testing.expectEqual(@as(u8, 1), out.len);
}

test "Machine: activation_distance=0 在 down 当场 start 且 delta 为零" {
    var m = Machine{ .activation_distance = 0 };
    const out = m.feedDown(.{ .x = 7, .y = 9 });
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.start, out.buf[0].kind);
    try expectPoint(0, 0, out.buf[0].delta);
    try expectPoint(0, 0, out.buf[0].step_delta);
    try testing.expectEqual(Machine.State.active, m.state);
}

test "Machine: start 只发一次，start.step_delta == delta，move 的 total/step 正确" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 10, .y = 10 });
    const start_out = m.feedMove(.{ .x = 20, .y = 10 }, 1);
    try testing.expectEqual(@as(u8, 1), start_out.len);
    try expectPoint(10, 0, start_out.buf[0].delta);
    try expectPoint(10, 0, start_out.buf[0].step_delta);

    const move_out = m.feedMove(.{ .x = 25, .y = 13 }, 2);
    try testing.expectEqual(@as(u8, 1), move_out.len);
    try testing.expectEqual(Phase.move, move_out.buf[0].kind);
    try expectPoint(15, 3, move_out.buf[0].delta);
    try expectPoint(5, 3, move_out.buf[0].step_delta);
}

test "Machine: 相同坐标不发冗余 move" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 5, .y = 5 }, 1);
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 5, .y = 5 }, 2).len);
}

test "Machine: up 坐标与最后 move 不同，end 反映最终位置" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 5, .y = 0 }, 1);
    const out = m.feedUp(.{ .x = 9, .y = 2 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.end, out.buf[0].kind);
    try expectPoint(9, 2, out.buf[0].delta);
    try expectPoint(4, 2, out.buf[0].step_delta);
}

test "Machine: up 与最后 move 相同坐标仍发 end" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 5, .y = 0 }, 1);
    const out = m.feedUp(.{ .x = 5, .y = 0 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.end, out.buf[0].kind);
}

test "Machine: 无 move 但 up 跨阈值，顺序为 start/end" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    const out = m.feedUp(.{ .x = 10, .y = 0 }, 1);
    try testing.expectEqual(@as(u8, 2), out.len);
    try testing.expectEqual(Phase.start, out.buf[0].kind);
    try testing.expectEqual(Phase.end, out.buf[1].kind);
    try expectPoint(10, 0, out.buf[0].delta);
    try expectPoint(0, 0, out.buf[1].step_delta);
    try testing.expectEqual(Machine.State.idle, m.state);
}

test "Machine: active cancel 恰好一次，坐标用最近观察位置" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 8, .y = 6 }, 5);
    const out = m.feedCancel();
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.cancel, out.buf[0].kind);
    try expectPoint(8, 6, out.buf[0].position);
    try testing.expectEqual(@as(u64, 5), out.buf[0].elapsed_ns);
    // Idempotent: cancel again no output
    try testing.expectEqual(@as(u8, 0), m.feedCancel().len);
}

test "Machine: pending/rejected cancel 静默" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u8, 0), m.feedCancel().len);
    try testing.expectEqual(Machine.State.idle, m.state);

    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 10, .y = 0 }, 1); // start
    m.reject();
    try testing.expectEqual(@as(u8, 0), m.feedCancel().len);
    try testing.expectEqual(Machine.State.idle, m.state);
}

test "Machine: rejected 后 move/up 均无输出" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 10, .y = 0 }, 1);
    m.reject();
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 50, .y = 50 }, 2).len);
    try testing.expectEqual(@as(u8, 0), m.feedUp(.{ .x = 50, .y = 50 }, 3).len);
    try testing.expectEqual(Machine.State.idle, m.state);
}
