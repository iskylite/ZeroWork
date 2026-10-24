//! Text editor write-back binding to `value: Model([]const u8)` (see
//! docs/SIGNAL_API_DESIGN.md section 4.8), shared by Input (TextInputState) and Textarea
//! (TextareaState). The data source is the sole truth; the edit buffer is the user's
//! draft. Each edit exit proposes the full text to the data source, then corrects the
//! buffer by the settled value, so outside edit exit the buffer equals the data
//! source. Only exception: IME composition, whose content belongs to the IME;
//! external writes defer until composition ends. Divergence has two sources:
//!
//! - **External write** (program set the data source, effect fired): same content
//!   short-circuits; during composition only record `resync_pending`; after cancel
//!   (State.on_ime_cancelled) re-read the data source and apply; an IME composition
//!   commit is overridden by user input (the deferred external write is discarded);
//!   otherwise whole-replace, cursor to end, clear undo history, no on_change.
//! - **User edit write-back**: State.on_change proposes the current full text at edit
//!   exit; if after `commit` the data source value != buffer, the parent component
//!   (`ui.split`) rewrote/rejected the edit. Then State.reconcileUserEdit reconciles
//!   in place: reject -> selection returns to its pre-edit state, no undo entry;
//!   rewrite -> map cursor by changed region (edit_reconcile.zig), rewrite into this
//!   edit's undo unit. on_change is
//!   called only after settle, with the settled value.
//!
//! Timing: real events run in an owner batch; after `commit` valueEffect defers to the
//! end of the event entry; outside a batch it runs synchronously in `commit`. Both
//! paths are correct via the onBufferChanged exit: while `committing`, valueEffect
//! only registers dependencies and doesn't touch the buffer (else outside a batch it
//! pre-applies a whole-replace); at batch end valueEffect sees same content and
//! short-circuits.
//!
//! The edit baseline is not necessarily the data source value (external write deferred
//! during composition, or a same-batch external write not yet applied by valueEffect;
//! judged by the `synced` hash): a mismatch is treated as an external write. Reconcile
//! failure (OOM) also falls back to external-write semantics.
//!
//! State must provide: `getText() []const u8`, `imeIsComposing() bool`,
//! `applyExternalText(v) !void` (whole-replace + clear undo, no on_change),
//! `reconcileUserEdit(v, rejected) !void` (reconcile in place; outside an edit
//! transaction degrade to external write), `settleUserEdit() void` (edit exit done:
//! release temp history, rebuild checkpoint).

const std = @import("std");
const core = @import("../../core.zig");
const reactive = @import("../../reactive.zig");
const Handler = core.Handler;

pub fn TextBinding(comptime State: type) type {
    return struct {
        const Self = @This();

        state: *State,
        value: reactive.Bound([]const u8),
        on_change: ?Handler([]const u8),
        on_submit: ?Handler([]const u8) = null,
        resync_pending: bool = false,
        /// User edit proposal settling now (during onBufferChanged commit).
        committing: bool = false,
        /// Hash of value when buffer last synced from data source (null = not yet
        /// synced). When buffer truncates, != value but still synced from it (else every
        /// edit treated as baseline drift). Edit exit uses this to judge if baseline is data
        /// source value: external write not yet applied to buffer (valueEffect not run in
        /// batch yet, or deferred during composition) when hash doesn't match.
        synced: ?u64 = null,

        pub fn valueEffect(self: *Self) void {
            const v = self.value.readAs(true);
            // Outside batch commit runs sync to here: user edit write-back, let
            // onBufferChanged reconcile.
            if (self.committing) return;
            self.applyExternal(v);
        }

        fn contentHash(v: []const u8) u64 {
            return std.hash.Wyhash.hash(0, v);
        }

        /// Data source value write to buffer (Idle); deferred during composition.
        pub fn applyExternal(self: *Self, v: []const u8) void {
            if (self.state.imeIsComposing()) {
                self.resync_pending = true;
                return;
            }
            self.resync_pending = false;
            if (!std.mem.eql(u8, v, self.state.getText())) {
                self.state.applyExternalText(v) catch |err| {
                    std.log.err("[text binding] applying value failed: {}", .{err});
                    return;
                };
            }
            self.synced = contentHash(v);
        }

        /// User edit settles to buffer (edit exit / AX write).
        pub fn onBufferChanged(self: *Self, text: []const u8) void {
            const on_change = self.on_change;
            // Baseline drift: edit started when data source already rewritten but buffer
            // not yet applied (composition deferred, or same batch set data source before
            // valueEffect ran before edit). Divergence can't be blamed on parent rewrite/reject;
            // align as external write.
            const baseline_drift = self.resync_pending or self.synced != contentHash(self.value.peek());
            const landed = blk: {
                self.committing = true;
                defer self.committing = false;
                break :blk self.value.commit(text);
            };
            // `text` is buffer slice; below may rewrite buffer, thereafter use only data
            // source value.
            const source = self.value.peek();
            if (std.mem.eql(u8, source, self.state.getText())) {
                // Settle as-is (or no change): external write deferred during composition now
                // void.
                self.resync_pending = false;
                self.synced = contentHash(source);
            } else if (baseline_drift or self.state.imeIsComposing()) {
                // Baseline not data source value: align as external write (stay deferred during
                // composition).
                self.applyExternal(source);
            } else {
                // Parent rewrote/rejected this edit (reject = data source unchanged).
                self.resync_pending = false;
                if (self.state.reconcileUserEdit(source, landed == null)) |_| {
                    self.synced = contentHash(source);
                } else |err| {
                    // Reconcile fail (OOM): revert to external write semantics, ensure buffer and
                    // history coherent.
                    std.log.warn("[text binding] reconciling edit failed: {}; applying as outside write", .{err});
                    self.applyExternal(source);
                }
            }
            // This edit's outcome settled: undo granularity confined here (before on_change;
            // edits parent does to same input in callback form separate undo unit).
            self.state.settleUserEdit();
            if (landed) |v| if (on_change) |h| h.call(v);
        }

        pub fn onImeCancelled(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (!self.resync_pending) return;
            self.applyExternal(self.value.peek());
        }

        pub fn onSubmit(self: *Self, text: []const u8) void {
            if (self.on_submit) |h| h.call(text);
        }

        /// Wire binding to state's callback slots (on_change exit / composition cancel).
        pub fn install(self: *Self) void {
            self.state.on_change = core.Cx.strHandlerFrom(Self, self, Self.onBufferChanged);
            self.state.on_ime_cancelled = core.Cx.simpleHandler(Self.onImeCancelled, self);
        }

        pub fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            alloc.destroy(@as(*Self, @ptrCast(@alignCast(ptr))));
        }
    };
}
