/// WrapMap: universal soft wrap mapping.
///
/// Maintains buffer line -> display line mapping. Each display line has fixed line height; wrap
/// changes how many display lines a buffer line occupies.
///
/// Generic parameter Doc: any doc type providing read-only API:
///   lineCount() -> usize
///   totalLength() -> usize
///   getLineStart(line) -> usize
///   getLineLength(line) -> usize
///   getTextBuf(start, len, buf) -> ![]const u8
///   getTextAlloc(alloc, start, len) -> ![]const u8
///
/// A Fenwick tree accelerates prefix sums.
/// - applyEdit with unchanged line count: O(K*logN) incremental update (vs O(N) rebuildPrefixSums)
/// - bufferLineToDisplayLine: O(logN)
/// - displayLineInfo: O(logN)
const std = @import("std");
const Allocator = std.mem.Allocator;
const FenwickTree = @import("fenwick_tree.zig").FenwickTree;
const prepared_wrap_line = @import("prepared_wrap_line.zig");
const PreparedWrapLine = prepared_wrap_line.PreparedWrapLine;
const grapheme = @import("grapheme.zig");
const i18n = @import("i18n");

fn saturatingU32(value: usize) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn displayLineDelta(old: u32, new: u32) i32 {
    const delta = @as(i64, new) - @as(i64, old);
    return @intCast(std.math.clamp(delta, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Get first codepoint of a grapheme cluster slice (line break rules only look at cluster-initial
/// codepoint, matches render side text_layout.decodeUtf8).
fn firstCodepoint(cluster: []const u8) u21 {
    if (cluster.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(cluster[0]) catch return 0xFFFD;
    if (len > cluster.len) return 0xFFFD;
    return std.unicode.utf8Decode(cluster[0..len]) catch 0xFFFD;
}

/// Text width measure function (signature matches UIContext.measure_fn).
pub const MeasureFn = *const fn ([*]const u8, usize, f32, u16, bool) f32;
pub const MeasureCtxFn = *const fn (*anyopaque, [*]const u8, usize, f32, u16, bool) f32;

/// Wrap info for single buffer line.
pub const WrapEntry = struct {
    /// Wrap break byte offset list (relative to line start). N breaks -> N+1 display lines.
    breaks: []u32 = &.{},
    /// Breaks allocated by WrapMap (need free).
    owned: bool = false,
    /// Width-independent preprocessing segment cache; avoid full-text rescan when width changes.
    prepared: ?*PreparedWrapLine = null,
    /// Line breaks are interpolated placeholder (wrap not precisely computed, rewrap next frame).
    is_interpolated: bool = false,
};

/// Edit / rewrap dirty-zone patch. Downstream (DisplaySnapshot /
/// HighlightSnapshot) consume patch decide invalidation.
pub const WrapPatch = struct {
    /// Affected buffer_line range (half-open).
    dirty_start_line: u32,
    dirty_end_line: u32,
    /// display_line count change (+ / -).
    display_delta: i32,
    /// WrapMap revision (snapshot version, monotone increment).
    revision: u64,
    /// This patch from wrap width / toggle change (affects whole doc).
    is_global: bool = false,
};

/// Display line information (from displayLineInfo return).
pub const DisplayLineInfo = struct {
    /// Corresponding buffer line number.
    buffer_line: usize,
    /// Wrap index in that buffer line (0 = first line).
    wrap_index: usize,
    /// This display line's segment start/end index. Current wrap path equals
    /// single wrap segment; for upper-layer long-line display reuse.
    segment_start_index: usize = 0,
    segment_end_index: usize = 1,
    /// This display line start byte offset within buffer line.
    byte_start: usize,
    /// This display line end byte offset within buffer line.
    byte_end: usize,
};

/// Display coordinates (buffer coordinate conversion result).
pub const DisplayPoint = struct {
    display_line: u32,
    display_col: usize, // Byte offset relative to display line start.
};

pub const BufferLineRange = struct {
    start: usize,
    end: usize,
};

pub const DisplayLineRange = struct {
    start: usize,
    end: usize,
};

/// WrapMap, generic soft wrap mapping. Doc: any type providing lineCount/
/// getLineStart/getLineLength/getTextBuf/getTextAlloc/totalLength. Infers the
/// snapshot payload type from Doc type.
/// Lead (first) byte of the **character** preceding position i (skipping UTF-8 continuation
/// bytes). The wrap word-break "CJK/emoji
/// after breakable" rule must see the previous char's lead byte; text[i-1] on a multibyte char
/// gives a continuation byte (<0xE0), the rule never fires, and the break point retreats
/// before punctuation ("punct followed by Latin word"): punct is pushed to the next line head,
/// misaligning with render fold (selection rect/cursor misaligned for the whole segment).
fn prevCharLead(text: []const u8, i: usize) u8 {
    var j = i;
    while (j > 0) {
        j -= 1;
        if ((text[j] & 0xC0) != 0x80) return text[j];
    }
    return 0;
}

fn SnapshotType(comptime Doc: type) type {
    // snapshot(self: *const Doc, alloc: Allocator) !SomeSnapshot
    const SnapshotFn = @TypeOf(Doc.snapshot);
    const ret = @typeInfo(SnapshotFn).@"fn".return_type.?;
    // strip error union
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

pub fn WrapMap(comptime Doc: type) type {
    // Doc must provide snapshot API to support background rewrap.
    const has_snapshot = @hasDecl(Doc, "snapshot");

    return struct {
        const Self = @This();
        pub const SupportsAsync = has_snapshot;

        allocator: Allocator,
        io: std.Io,
        enabled: bool = false,
        wrap_width: f32 = 0,

        /// Each buffer line's wrap breaks.
        line_wraps: std.ArrayListUnmanaged(WrapEntry) = .empty,

        /// Fenwick Tree: each buffer line's display line count as value. prefixSum(i)
        /// = front i+1 buffer lines' display line total.
        fenwick: ?FenwickTree = null,

        total_display_lines: u32 = 0,
        measure_fn: ?MeasureFn = null,
        /// Context-aware measurement for per-window font systems. Preferred
        /// over `measure_fn` when both are present.
        measure_ctx_fn: ?MeasureCtxFn = null,
        measure_ctx: ?*anyopaque = null,
        font_size: f32 = 14,
        font_weight: u16 = 400,
        /// Monospace single-char width (ASCII), used quick wrap calc.
        char_width: f32 = 0,
        /// Enable exact wrap (per-char true measure, high precision but slower).
        precise_wrap: bool = false,
        /// Tab expand size (default 4).
        tab_size: usize = 4,

        // ── Interpolation / Patch state ──.
        /// Snapshot version: increment each patch (apply edit / rewrap / width
        /// change).
        revision: u64 = 0,
        /// Pending patch (UI thread every frame takePendingPatch).
        pending_patch: ?WrapPatch = null,
        /// Has interpolated lines -> next frame need exact rewrap.
        has_interpolated_lines: bool = false,
        /// Structural allocation failed: use a coherent 1:1 mapping until retry.
        needs_rebuild: bool = false,

        // ── Background rewrap state (only active when Doc provides snapshot) ──.
        bg_thread: if (has_snapshot) ?std.Thread else void = if (has_snapshot) null else {},
        bg_done: if (has_snapshot) std.atomic.Value(bool) else void = if (has_snapshot) std.atomic.Value(bool).init(false) else {},
        /// Background thread return (buffer_line, breaks) result list.
        bg_result: if (has_snapshot) std.ArrayListUnmanaged(BgRewrapResult) else void = if (has_snapshot) .empty else {},
        /// Parameter snapshot when spawn task.
        bg_doc_snapshot: if (has_snapshot) ?SnapshotType(Doc) else void = if (has_snapshot) null else {},
        bg_wrap_width: f32 = 0,
        bg_wrap_columns: usize = 0,
        bg_tab_size: usize = 0,
        bg_char_width: f32 = 0,
        /// Doc edit_version at launch (stale check).
        bg_doc_version: u64 = 0,
        /// WrapMap revision at launch (stale check).
        bg_base_revision: u64 = 0,

        pub const BgRewrapResult = struct {
            buffer_line: u32,
            breaks: []u32, // owned by WrapMap.allocator
        };

        pub fn init(allocator: Allocator, io: std.Io) Self {
            var self = Self{ .allocator = allocator, .io = io };
            if (has_snapshot) {
                self.bg_done = std.atomic.Value(bool).init(false);
            }
            return self;
        }

        fn hasPreciseMeasure(self: *const Self) bool {
            return self.measure_ctx_fn != null or self.measure_fn != null;
        }

        pub fn deinit(self: *Self) void {
            if (has_snapshot) {
                if (self.bg_thread) |t| t.join();
                for (self.bg_result.items) |*r| {
                    if (r.breaks.len > 0) self.allocator.free(r.breaks);
                }
                self.bg_result.deinit(self.allocator);
                if (self.bg_doc_snapshot) |*s| s.deinit();
            }
            for (self.line_wraps.items) |*entry| {
                self.freeWrapEntry(entry);
            }
            self.line_wraps.deinit(self.allocator);
            if (self.fenwick) |*ft| ft.deinit();
        }

        // ── Patch API ──

        /// Pull and clear pending patch.
        pub fn takePendingPatch(self: *Self) ?WrapPatch {
            const p = self.pending_patch;
            self.pending_patch = null;
            return p;
        }

        /// Merge/emit patch.
        fn emitPatch(self: *Self, dirty_start: u32, dirty_end: u32, display_delta: i32, is_global: bool) void {
            self.revision +%= 1;
            if (self.pending_patch) |*p| {
                // Merge multiple patches: range union + cumulate delta.
                p.dirty_start_line = @min(p.dirty_start_line, dirty_start);
                p.dirty_end_line = @max(p.dirty_end_line, dirty_end);
                p.display_delta +|= display_delta;
                p.revision = self.revision;
                p.is_global = p.is_global or is_global;
            } else {
                self.pending_patch = .{
                    .dirty_start_line = dirty_start,
                    .dirty_end_line = dirty_end,
                    .display_delta = display_delta,
                    .revision = self.revision,
                    .is_global = is_global,
                };
            }
        }

        /// Set wrap width. **No longer sync full recompute**: only update width
        /// param + mark all lines interpolated + emit global patch. Caller
        /// (editor_before_render) responsible next frame call `rewrapInterpolated
        /// (budget_us)` exact converge, or `startBackgroundRewrap()` to background.
        pub fn setWrapWidth(self: *Self, width: f32, doc: *const Doc) void {
            if (@abs(self.wrap_width - width) < 1.0) return;
            self.wrap_width = width;
            if (!self.enabled) return;
            self.markAllInterpolated();
            self.emitPatch(0, @intCast(doc.lineCount()), 0, true);
        }

        /// Enable/disable wrap. **No longer sync full recompute**: enable init
        /// entries (each line breaks=&.{} + interpolated=true), disable clear. Exact
        /// wrap calc defer to `rewrapInterpolated`.
        pub fn setEnabled(self: *Self, enabled: bool, doc: *const Doc) void {
            if (self.enabled == enabled and !self.needs_rebuild) return;
            const old_total = self.total_display_lines;
            self.enabled = enabled;
            self.clearAll(doc.lineCount());
            if (enabled) {
                self.line_wraps.ensureTotalCapacity(self.allocator, doc.lineCount()) catch {
                    self.needs_rebuild = true;
                    self.has_interpolated_lines = doc.lineCount() > 0;
                    self.emitPatch(0, saturatingU32(doc.lineCount()), displayLineDelta(old_total, self.total_display_lines), true);
                    return;
                };
                for (0..doc.lineCount()) |_| self.line_wraps.appendAssumeCapacity(.{ .is_interpolated = true });
                self.rebuildFenwickFromWraps();
                self.has_interpolated_lines = doc.lineCount() > 0;
            }
            self.emitPatch(0, saturatingU32(doc.lineCount()), displayLineDelta(old_total, self.total_display_lines), true);
        }

        /// Mark all lines interpolated (when wrap width changes).
        fn markAllInterpolated(self: *Self) void {
            for (self.line_wraps.items) |*entry| entry.is_interpolated = true;
            self.has_interpolated_lines = self.needs_rebuild or self.line_wraps.items.len > 0;
        }

        /// Full recompute all lines.
        pub fn rebuildAll(self: *Self, doc: *const Doc) void {
            // Publish a global patch and invalidate older background results.
            const old_total = self.total_display_lines;
            defer self.emitPatch(0, saturatingU32(doc.lineCount()), displayLineDelta(old_total, self.total_display_lines), true);
            if (!self.enabled) {
                self.clearAll(doc.lineCount());
                return;
            }
            var next: std.ArrayListUnmanaged(WrapEntry) = .empty;
            next.ensureTotalCapacity(self.allocator, doc.lineCount()) catch {
                self.clearAll(doc.lineCount());
                self.needs_rebuild = true;
                self.has_interpolated_lines = doc.lineCount() > 0;
                return;
            };
            var pending = false;
            for (0..doc.lineCount()) |idx| {
                const entry = self.wrapSingleLine(doc, idx);
                next.appendAssumeCapacity(entry);
                pending = pending or entry.is_interpolated;
            }
            for (self.line_wraps.items) |*entry| self.freeWrapEntry(entry);
            self.line_wraps.deinit(self.allocator);
            self.line_wraps = next;
            self.needs_rebuild = false;
            self.has_interpolated_lines = pending;
            self.rebuildFenwickFromWraps();
        }

        /// Rebuild Fenwick Tree from display_counts.
        fn rebuildFenwick(self: *Self, display_counts: []const u32) void {
            if (self.fenwick) |*ft| ft.deinit();
            self.fenwick = FenwickTree.buildFrom(self.allocator, display_counts) catch null;
            if (self.fenwick) |ft| {
                self.total_display_lines = ft.total();
            } else {
                // Fallback: cumulate.
                var total: u32 = 0;
                for (display_counts) |c| total +|= c;
                self.total_display_lines = total;
            }
        }

        /// Clear wrap (restore 1:1 when disabled).
        fn clearAll(self: *Self, line_count: usize) void {
            for (self.line_wraps.items) |*entry| self.freeWrapEntry(entry);
            self.line_wraps.clearRetainingCapacity();
            if (self.fenwick) |*ft| ft.deinit();
            self.fenwick = null;
            self.total_display_lines = saturatingU32(line_count);
            self.needs_rebuild = false;
            self.has_interpolated_lines = false;
        }

        /// Incremental edit: **only interpolate, don't compute exact wrap**. All
        /// affected lines are marked `is_interpolated=true`, breaks keep old values (coords
        /// usable, wrap positions might be stale). Exact wrap finishes next frame in
        /// `rewrapInterpolated(budget_us)`; lines exceeding budget go to `startBackgroundRewrap`.
        /// Complexity: O(K) line count change + O(N) fenwick rebuild (only when count
        /// changes). No count change: O(K) fenwick set (K = affected lines), zero wrap
        /// calc.
        pub fn applyEdit(self: *Self, doc: *const Doc, start_line: usize, old_line_count: usize, new_line_count: usize) void {
            if (!self.enabled) {
                // When wrap disabled maintain 1:1 mapping, only incremental adjust
                // line_wraps array and fenwick.
                self.applyEditDisabled(doc.lineCount(), start_line, old_line_count, new_line_count);
                return;
            }

            const old_total = self.total_display_lines;
            const new_doc_lines = doc.lineCount();
            const expected_old_lines: ?usize = blk: {
                if (new_line_count > new_doc_lines) break :blk null;
                break :blk std.math.add(usize, new_doc_lines - new_line_count, old_line_count) catch null;
            };
            const valid_edit = if (expected_old_lines) |old_lines|
                self.line_wraps.items.len == old_lines and
                    start_line <= old_lines and old_line_count <= old_lines - start_line and
                    start_line <= new_doc_lines and new_line_count <= new_doc_lines - start_line
            else
                false;
            if (!valid_edit) {
                self.rebuildAll(doc);
                return;
            }

            if (old_line_count == new_line_count) {
                // Line count unchanged: only mark affected interpolated; if no wrap
                // change then display_delta = 0.
                const total_lines = doc.lineCount();
                const end = @min(start_line + new_line_count, total_lines);
                for (@min(start_line, end)..end) |i| {
                    if (i < self.line_wraps.items.len) {
                        self.markInterpolated(i);
                    }
                }
            } else if (new_line_count > old_line_count) {
                // Line count increase: insert empty entry + mark whole edit segment
                // interpolated.
                const added = new_line_count - old_line_count;
                const insert_at = start_line + old_line_count;
                self.line_wraps.ensureTotalCapacity(self.allocator, new_doc_lines) catch {
                    self.clearAll(new_doc_lines);
                    self.needs_rebuild = true;
                    self.has_interpolated_lines = new_doc_lines > 0;
                    self.emitPatch(0, saturatingU32(new_doc_lines), displayLineDelta(old_total, self.total_display_lines), true);
                    return;
                };
                for (0..added) |j| {
                    self.line_wraps.insert(self.allocator, insert_at + j, .{
                        .is_interpolated = true,
                    }) catch {
                        // OOM: fallback rebuild (rare).
                        self.rebuildAll(doc);
                        return;
                    };
                }
                // All old lines within edit segment also interpolated.
                const old_end = @min(start_line + old_line_count, self.line_wraps.items.len);
                for (start_line..old_end) |i| {
                    self.markInterpolated(i);
                }

                // Fenwick needs resize.
                self.rebuildFenwickFromWraps();
            } else {
                // Line count decrease.
                const removed = old_line_count - new_line_count;
                const remove_start = start_line + new_line_count;
                const remove_end = @min(remove_start + removed, self.line_wraps.items.len);
                for (remove_start..remove_end) |i| {
                    self.freeWrapEntry(&self.line_wraps.items[i]);
                }
                var k: usize = 0;
                while (k < removed and remove_start < self.line_wraps.items.len) : (k += 1) {
                    _ = self.line_wraps.orderedRemove(remove_start);
                }

                // Remaining edit segment lines mark interpolated.
                const end = @min(start_line + new_line_count, self.line_wraps.items.len);
                for (@min(start_line, end)..end) |i| {
                    self.markInterpolated(i);
                }

                self.rebuildFenwickFromWraps();
            }

            self.has_interpolated_lines = true;
            const new_total = self.total_display_lines;
            const display_delta = displayLineDelta(old_total, new_total);
            self.emitPatch(
                @intCast(start_line),
                @intCast(start_line + new_line_count),
                display_delta,
                false,
            );
        }

        /// Mark entry interpolated (keep old breaks as coord placeholder).
        fn markInterpolated(self: *Self, line_idx: usize) void {
            if (line_idx >= self.line_wraps.items.len) return;
            const entry = &self.line_wraps.items[line_idx];
            entry.is_interpolated = true;
            self.has_interpolated_lines = true;
            // Defuse the stale `prepared` cache (a latent trap): it is a segment snapshot of the
            // **pre-edit** text and content_hash is never compared anywhere in the repo.
            // Production components set precise_wrap=true, which bypasses the fast path, so it
            // never bit; any new consumer that forgets the flag would have rewrapInterpolated
            // recompute breaks from the old segments (cursor/selection misaligned). The line is
            // already marked interpolated, so the snapshot is necessarily stale: free it directly
            // and the fast path falls back to re-reading the document.
            if (entry.prepared) |prepared| {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                entry.prepared = null;
            }
        }

        /// Tally interpolated line count (scheduler decides).
        pub fn interpolatedLineCount(self: *const Self) usize {
            if (self.needs_rebuild) return self.total_display_lines;
            if (!self.has_interpolated_lines) return 0;
            var count: usize = 0;
            for (self.line_wraps.items) |entry| {
                if (entry.is_interpolated) count += 1;
            }
            return count;
        }

        pub const RewrapResult = struct {
            /// This rewrap exact-compute line count.
            lines_rewrapped: usize,
            /// Still interpolated line count (budget exhausted leave next frame or
            /// background).
            lines_remaining: usize,
        };

        /// Exact wrap calc for interpolated lines, budget control. `budget_us =
        /// null` means unlimited (sync converge all interpolated lines). Return
        /// process/remain tally; if display line count changed emit patch.
        fn retryRebuild(self: *Self, doc: *const Doc) ?RewrapResult {
            if (!self.needs_rebuild) return null;
            self.rebuildAll(doc);
            return .{ .lines_rewrapped = if (self.needs_rebuild) 0 else doc.lineCount(), .lines_remaining = self.interpolatedLineCount() };
        }

        pub fn rewrapInterpolated(self: *Self, doc: *const Doc, budget_us: ?u64) RewrapResult {
            if (self.retryRebuild(doc)) |result| return result;
            if (!self.has_interpolated_lines) return .{ .lines_rewrapped = 0, .lines_remaining = 0 };
            if (!self.enabled) {
                // Wrap disabled no need rewrap, just clear interpolated mark.
                for (self.line_wraps.items) |*e| e.is_interpolated = false;
                self.has_interpolated_lines = false;
                return .{ .lines_rewrapped = 0, .lines_remaining = 0 };
            }

            var timer: ?@import("zenit_time").Timer = if (budget_us != null) @import("zenit_time").Timer.start(self.io) catch null else null;
            var processed: usize = 0;
            var min_dirty: u32 = std.math.maxInt(u32);
            var max_dirty: u32 = 0;
            var delta: i32 = 0;

            const wrap_columns = self.wrapWidthColumns();
            for (self.line_wraps.items, 0..) |*entry, i| {
                if (!entry.is_interpolated) continue;
                if (budget_us) |budget| {
                    if (timer) |*t| {
                        if (t.read() / 1000 >= budget) break;
                    }
                }

                const old_display_count: i32 = @intCast(entry.breaks.len + 1);

                // Fast path: if already has prepared, directly resplit by column count,
                // no need redoc.
                if (!(self.precise_wrap and self.hasPreciseMeasure())) {
                    if (entry.prepared) |prepared| {
                        if (entry.owned and entry.breaks.len > 0) {
                            self.allocator.free(entry.breaks);
                        }
                        entry.breaks = prepared.breaksForColumns(self.allocator, wrap_columns, self.tab_size) catch {
                            // Failure fallback to wrapSingleLine.
                            entry.breaks = &.{};
                            entry.owned = false;
                            // Don't first set entry.prepared = null, freeWrapEntry relies
                            // `if (entry.prepared)` free PreparedWrapLine (has segments heap
                            // array),
                            // early clear pointer = whole leak (it internally null).
                            self.freeWrapEntry(entry);
                            entry.* = self.wrapSingleLine(doc, i);
                            const ndc: i32 = @intCast(entry.breaks.len + 1);
                            delta += ndc - old_display_count;
                            if (self.fenwick) |*ft| {
                                if (i < ft.n) ft.set(i, @intCast(ndc));
                            }
                            min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                            max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                            processed += 1;
                            continue;
                        };
                        entry.owned = entry.breaks.len > 0;
                        entry.is_interpolated = false;
                        const ndc: i32 = @intCast(entry.breaks.len + 1);
                        delta += ndc - old_display_count;
                        if (self.fenwick) |*ft| {
                            if (i < ft.n) ft.set(i, @intCast(ndc));
                        }
                        min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                        max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                        processed += 1;
                        continue;
                    }
                }

                // Slow path: no prepared, or precise_wrap mode -> redoc.
                self.freeWrapEntry(entry);
                entry.* = self.wrapSingleLine(doc, i);
                const new_display_count: i32 = @intCast(entry.breaks.len + 1);
                delta += new_display_count - old_display_count;

                if (self.fenwick) |*ft| {
                    if (i < ft.n) ft.set(i, @intCast(new_display_count));
                }

                min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                processed += 1;
            }

            // Refresh total.
            self.refreshTotal();

            // Check any interpolated remain.
            var remaining: usize = 0;
            for (self.line_wraps.items) |entry| {
                if (entry.is_interpolated) remaining += 1;
            }
            self.has_interpolated_lines = remaining > 0;

            if (processed > 0 and (delta != 0 or max_dirty > min_dirty)) {
                self.emitPatch(min_dirty, max_dirty, delta, false);
            }
            return .{ .lines_rewrapped = processed, .lines_remaining = remaining };
        }

        /// Convenient API: sync converge all interpolated (unlimited budget).
        pub fn rewrapInterpolatedAll(self: *Self, doc: *const Doc) RewrapResult {
            return self.rewrapInterpolated(doc, null);
        }

        /// Sync converge only [start_line, end_line) interpolated (unlimited
        /// budget). For edit path: exact rewrap few edit lines immediately, avoid VL
        /// adjustLineCount jitter; outside-range interpolated still leave maintainWrapMap.
        pub fn rewrapInterpolatedRange(self: *Self, doc: *const Doc, start_line: usize, end_line_exclusive: usize) RewrapResult {
            if (self.retryRebuild(doc)) |result| return result;
            if (!self.has_interpolated_lines or !self.enabled) {
                return .{ .lines_rewrapped = 0, .lines_remaining = 0 };
            }
            var processed: usize = 0;
            var min_dirty: u32 = std.math.maxInt(u32);
            var max_dirty: u32 = 0;
            var delta: i32 = 0;
            const wrap_columns = self.wrapWidthColumns();
            const end = @min(end_line_exclusive, self.line_wraps.items.len);
            for (@min(start_line, end)..end) |i| {
                const entry = &self.line_wraps.items[i];
                if (!entry.is_interpolated) continue;
                const old_display_count: i32 = @intCast(entry.breaks.len + 1);
                // Fast+slow path (same rewrapInterpolated).
                if (!(self.precise_wrap and self.hasPreciseMeasure())) {
                    if (entry.prepared) |prepared| {
                        if (entry.owned and entry.breaks.len > 0) {
                            self.allocator.free(entry.breaks);
                        }
                        entry.breaks = prepared.breaksForColumns(self.allocator, wrap_columns, self.tab_size) catch {
                            entry.breaks = &.{};
                            entry.owned = false;
                            // Don't first set entry.prepared = null, freeWrapEntry relies
                            // `if (entry.prepared)` free PreparedWrapLine (has segments heap
                            // array),
                            // early clear pointer = whole leak (it internally null).
                            self.freeWrapEntry(entry);
                            entry.* = self.wrapSingleLine(doc, i);
                            const ndc: i32 = @intCast(entry.breaks.len + 1);
                            delta += ndc - old_display_count;
                            if (self.fenwick) |*ft| {
                                if (i < ft.n) ft.set(i, @intCast(ndc));
                            }
                            min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                            max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                            processed += 1;
                            continue;
                        };
                        entry.owned = entry.breaks.len > 0;
                        entry.is_interpolated = false;
                        const ndc: i32 = @intCast(entry.breaks.len + 1);
                        delta += ndc - old_display_count;
                        if (self.fenwick) |*ft| {
                            if (i < ft.n) ft.set(i, @intCast(ndc));
                        }
                        min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                        max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                        processed += 1;
                        continue;
                    }
                }
                self.freeWrapEntry(entry);
                entry.* = self.wrapSingleLine(doc, i);
                const ndc: i32 = @intCast(entry.breaks.len + 1);
                delta += ndc - old_display_count;
                if (self.fenwick) |*ft| {
                    if (i < ft.n) ft.set(i, @intCast(ndc));
                }
                min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                processed += 1;
            }
            self.refreshTotal();
            // Check global remaining.
            var remaining: usize = 0;
            for (self.line_wraps.items) |e| if (e.is_interpolated) {
                remaining += 1;
            };
            self.has_interpolated_lines = remaining > 0;
            if (processed > 0) {
                self.emitPatch(min_dirty, max_dirty, delta, false);
            }
            return .{ .lines_rewrapped = processed, .lines_remaining = remaining };
        }

        // ============================================================================
        // Background rewrap task (enabled only when Doc supports snapshot)
        // ============================================================================

        pub const BgPollResult = union(enum) {
            /// Background still running.
            none,
            /// Background done and applied.
            applied: RewrapApplyStats,
            /// Background done but doc edit version changed -> result discard.
            stale,
            /// Background failed (OOM / snapshot fail etc.).
            failed,
        };

        pub const RewrapApplyStats = struct {
            lines_applied: usize,
            display_delta: i32,
        };

        // ────────────────────────────────────────────────────────
        // Background Rewrap
        // ────────────────────────────────────────────────────────

        /// Spawn background rewrap: - snapshot current doc - collect current
        /// interpolated line list - spawn worker thread, exact rewrap per line -
        /// complete UI thread `pollBackgroundRewrap` pulls apply. Only callable when
        /// `has_snapshot=true`; skip if task already running. `doc_version` by caller
        /// provide (usually state.edit_count), used stale judge.
        pub fn startBackgroundRewrap(self: *Self, doc: *Doc, doc_version: u64) void {
            if (!has_snapshot) return;
            if (self.bg_thread != null) return;
            if (!self.enabled or !self.has_interpolated_lines or self.needs_rebuild) return;

            // Snapshot doc (needs *Doc: snapshot internal holds mutex vs UI thread
            // mutation exclusive).
            var snap = doc.snapshot(self.allocator) catch return;
            errdefer snap.deinit();
            self.bg_doc_snapshot = snap;
            self.bg_wrap_width = self.wrap_width;
            self.bg_tab_size = self.tab_size;
            self.bg_char_width = self.char_width;
            self.bg_wrap_columns = self.wrapWidthColumns();
            self.bg_doc_version = doc_version;
            self.bg_base_revision = self.revision;
            self.bg_done.store(false, .release);

            // Clear last residue result.
            for (self.bg_result.items) |*r| {
                if (r.breaks.len > 0) self.allocator.free(r.breaks);
            }
            // The worker publishes a new owned list, replacing bg_result.
            // Release the previous backing allocation before that transfer.
            self.bg_result.clearAndFree(self.allocator);

            self.bg_thread = std.Thread.spawn(.{}, bgRewrapThread, .{self}) catch {
                self.bg_doc_snapshot.?.deinit();
                self.bg_doc_snapshot = null;
                return;
            };
        }

        fn bgRewrapThread(self: *Self) void {
            if (!has_snapshot) return;
            defer self.bg_done.store(true, .release);

            const snap = &self.bg_doc_snapshot.?;
            const line_count = snap.lineCount();

            var work_buf: std.ArrayListUnmanaged(BgRewrapResult) = .empty;
            defer {
                for (work_buf.items) |*r| {
                    if (r.breaks.len > 0) self.allocator.free(r.breaks);
                }
                work_buf.deinit(self.allocator);
            }
            work_buf.ensureTotalCapacity(self.allocator, line_count) catch return;

            if (snap.totalLength() == 0) {
                self.bg_result = work_buf;
                work_buf = .empty;
                return;
            }

            var i: usize = 0;
            while (i < line_count) : (i += 1) {
                const line_start = snap.getLineStart(i);
                const line_len = snap.getLineLength(i);
                if (line_len == 0) {
                    work_buf.append(self.allocator, .{ .buffer_line = @intCast(i), .breaks = &.{} }) catch return;
                } else {
                    var stack_buf: [8192]u8 = undefined;
                    var line_storage: ?[]u8 = null;
                    defer if (line_storage) |storage| self.allocator.free(storage);

                    const line_text_full = if (line_len <= stack_buf.len)
                        snap.getTextBuf(line_start, line_len, &stack_buf) catch return
                    else blk: {
                        const heap = self.allocator.alloc(u8, line_len) catch return;
                        line_storage = heap;
                        break :blk snap.getTextBuf(line_start, line_len, heap) catch return;
                    };
                    var content_end = line_text_full.len;
                    while (content_end > 0 and (line_text_full[content_end - 1] == '\n' or line_text_full[content_end - 1] == '\r')) {
                        content_end -= 1;
                    }
                    const line_text = line_text_full[0..content_end];
                    if (line_text.len == 0) {
                        work_buf.append(self.allocator, .{ .buffer_line = @intCast(i), .breaks = &.{} }) catch return;
                        continue;
                    }
                    const breaks = self.bgComputeBreaks(line_text) catch continue;
                    work_buf.append(self.allocator, .{
                        .buffer_line = @intCast(i),
                        .breaks = breaks,
                    }) catch {
                        if (breaks.len > 0) self.allocator.free(breaks);
                        return;
                    };
                }
            }

            self.bg_result = work_buf;
            work_buf = .empty;
        }

        /// Background thread wrap calc (independent self's wrap_width / char_width
        /// etc., uses launch snapshot params bg_*).
        fn bgComputeBreaks(self: *Self, text: []const u8) ![]u32 {
            if (!has_snapshot) return &.{};
            var breaks_list: std.ArrayListUnmanaged(u32) = .empty;
            errdefer breaks_list.deinit(self.allocator);

            const cw = if (self.bg_char_width > 0) self.bg_char_width else @as(f32, 8.0);
            const ts = if (self.bg_tab_size == 0) 4 else self.bg_tab_size;
            const wrap_w = self.bg_wrap_width;

            var seg_start: usize = 0;
            var last_word_boundary: usize = 0;
            var accumulated_w: f32 = 0;
            var col: usize = 0;
            var i: usize = 0;
            var grapheme_cursor = grapheme.BoundaryCursor.init(text);
            while (i < text.len) {
                const byte = text[i];
                // Advance by grapheme cluster (1e2bee4 fixed computeWraps/Precise,
                // this brother forgotten then): by codepoint splits ZWJ emoji/combining.
                const next_i = grapheme_cursor.next(i);
                if (i > seg_start) {
                    if (byte == ' ' or byte == '\t') {
                        last_word_boundary = next_i;
                    } else if (byte >= 0xE0) {
                        last_word_boundary = i;
                    } else if (i > 0 and prevCharLead(text, i) >= 0xE0) {
                        last_word_boundary = i;
                    }
                }
                const char_w: f32 = if (byte == '\t') blk: {
                    const spaces = ts - (col % ts);
                    col += spaces;
                    break :blk @as(f32, @floatFromInt(spaces)) * cw;
                } else if (byte < 0x80) blk: {
                    col += 1;
                    break :blk cw;
                } else blk: {
                    col += 2;
                    break :blk cw * 2.0;
                };
                accumulated_w += char_w;
                if (accumulated_w > wrap_w and i > seg_start) {
                    const break_at: usize = if (last_word_boundary > seg_start) last_word_boundary else i;
                    try breaks_list.append(self.allocator, @intCast(break_at));
                    seg_start = break_at;
                    last_word_boundary = seg_start;
                    accumulated_w = 0;
                    col = 0;
                    i = break_at;
                    continue;
                }
                i = next_i;
            }
            return breaks_list.toOwnedSlice(self.allocator);
        }

        /// Poll background result every frame. `current_doc_version` stale judge
        /// (compare launch startBackgroundRewrap's doc_version).
        pub fn pollBackgroundRewrap(self: *Self, current_doc_version: u64) BgPollResult {
            if (!has_snapshot) return .none;
            if (self.bg_thread == null) return .none;
            if (!self.bg_done.load(.acquire)) return .none;

            if (self.bg_thread) |t| t.join();
            self.bg_thread = null;

            defer {
                if (self.bg_doc_snapshot) |*s| s.deinit();
                self.bg_doc_snapshot = null;
            }

            // Stale: doc version changed -> discard result (edit changed line map,
            // force apply misaligns).
            if (current_doc_version != self.bg_doc_version or self.bg_base_revision != self.revision or !self.enabled or self.needs_rebuild) {
                for (self.bg_result.items) |*r| {
                    if (r.breaks.len > 0) self.allocator.free(r.breaks);
                }
                self.bg_result.clearRetainingCapacity();
                return .stale;
            }

            // Apply: each result swap breaks + fenwick update.
            var delta: i32 = 0;
            var min_dirty: u32 = std.math.maxInt(u32);
            var max_dirty: u32 = 0;
            var applied: usize = 0;
            for (self.bg_result.items) |result| {
                const i: usize = result.buffer_line;
                if (i >= self.line_wraps.items.len) {
                    if (result.breaks.len > 0) self.allocator.free(result.breaks);
                    continue;
                }
                const entry = &self.line_wraps.items[i];
                const old_display_count: i32 = @intCast(entry.breaks.len + 1);

                // Swap: free old breaks, install new breaks.
                if (entry.owned and entry.breaks.len > 0) {
                    self.allocator.free(entry.breaks);
                }
                entry.breaks = result.breaks;
                entry.owned = result.breaks.len > 0;
                entry.is_interpolated = false;
                // Keep prepared (for next wrap width change fast-path).

                const new_display_count: i32 = @intCast(entry.breaks.len + 1);
                delta += new_display_count - old_display_count;
                if (self.fenwick) |*ft| {
                    if (i < ft.n) ft.set(i, @intCast(new_display_count));
                }
                min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                applied += 1;
            }
            self.bg_result.clearRetainingCapacity();

            self.refreshTotal();

            // Check any interpolated remain (lines new-edit after snapshot).
            var remaining: usize = 0;
            for (self.line_wraps.items) |entry| {
                if (entry.is_interpolated) remaining += 1;
            }
            self.has_interpolated_lines = remaining > 0;

            if (applied > 0) {
                self.emitPatch(min_dirty, max_dirty, delta, false);
            }
            return .{ .applied = .{ .lines_applied = applied, .display_delta = delta } };
        }

        pub fn hasBackgroundRewrap(self: *const Self) bool {
            if (!has_snapshot) return false;
            return self.bg_thread != null;
        }

        /// Rebuild fenwick from line_wraps (when line count changed).
        fn refreshTotal(self: *Self) void {
            if (self.fenwick) |ft| {
                self.total_display_lines = ft.total();
            } else {
                var total: u32 = 0;
                for (self.line_wraps.items) |entry| total +|= saturatingU32(entry.breaks.len + 1);
                self.total_display_lines = total;
            }
        }

        fn rebuildFenwickFromWraps(self: *Self) void {
            // Drop stale indexes even if allocating replacement counts fails.
            if (self.fenwick) |*ft| ft.deinit();
            self.fenwick = null;
            const n = self.line_wraps.items.len;
            const display_counts = self.allocator.alloc(u32, n) catch {
                self.refreshTotal();
                return;
            };
            defer self.allocator.free(display_counts);
            for (self.line_wraps.items, 0..) |entry, i| display_counts[i] = saturatingU32(entry.breaks.len + 1);
            self.rebuildFenwick(display_counts);
        }

        /// Disabled wrapping is an allocation-free identity mapping.
        fn applyEditDisabled(self: *Self, total_lines: usize, _: usize, _: usize, _: usize) void {
            self.clearAll(total_lines);
        }

        /// Wrap calc single line.
        fn wrapSingleLine(self: *Self, doc: *const Doc, line: usize) WrapEntry {
            if (self.wrap_width <= 0) return .{};

            const line_start = doc.getLineStart(line);
            const line_len = doc.getLineLength(line);
            if (line_len == 0) return .{};
            if (!(self.precise_wrap and self.hasPreciseMeasure()) and line_len > 8192) {
                return self.prepareAndComputeWrapsChunked(doc, line_start, line_len);
            }

            var stack_buf: [8192]u8 = undefined;
            var line_text: []const u8 = "";
            var heap = false;

            if (line_len <= stack_buf.len) {
                line_text = doc.getTextBuf(line_start, line_len, &stack_buf) catch return .{ .is_interpolated = true };
            } else {
                line_text = doc.getTextAlloc(self.allocator, line_start, line_len) catch return .{ .is_interpolated = true };
                heap = true;
            }
            defer if (heap) self.allocator.free(line_text);

            var text_len = line_text.len;
            while (text_len > 0 and (line_text[text_len - 1] == '\n' or line_text[text_len - 1] == '\r')) text_len -= 1;
            if (text_len == 0) return .{};
            const text = line_text[0..text_len];

            return self.prepareAndComputeWraps(text);
        }

        fn prepareAndComputeWrapsChunked(self: *Self, doc: *const Doc, line_start: usize, line_len: usize) WrapEntry {
            const FeedCtx = struct {
                doc: *const Doc,
                line_start: usize,
            };

            var ctx = FeedCtx{ .doc = doc, .line_start = line_start };
            const prepared = prepared_wrap_line.prepareLineChunked(
                self.allocator,
                struct {
                    fn feed(ptr: *anyopaque, offset: usize, buf: []u8) anyerror![]const u8 {
                        const typed: *FeedCtx = @ptrCast(@alignCast(ptr));
                        return typed.doc.getTextBuf(typed.line_start + offset, buf.len, buf);
                    }
                }.feed,
                &ctx,
                line_len,
                4096,
            ) catch return .{ .is_interpolated = true };
            errdefer {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
            }

            const breaks = prepared.breaksForColumns(self.allocator, self.wrapWidthColumns(), self.tab_size) catch {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                return .{ .is_interpolated = true };
            };
            return .{
                .breaks = breaks,
                .owned = breaks.len > 0,
                .prepared = prepared,
            };
        }

        fn prepareAndComputeWraps(self: *Self, text: []const u8) WrapEntry {
            if (self.precise_wrap and self.hasPreciseMeasure()) {
                return self.computeWraps(text);
            }

            const prepared = prepared_wrap_line.prepareLine(self.allocator, text) catch return self.computeWraps(text);
            // Note: this fn return type non-!T, errdefer never triggers (once had
            // errdefer dead code gave "covered" false image). Failure path must explicit
            // cleanup, contrast prepareAndComputeWrapsChunked correct write.
            const breaks = prepared.breaksForColumns(self.allocator, self.wrapWidthColumns(), self.tab_size) catch {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                return self.computeWraps(text);
            };
            return .{
                .breaks = breaks,
                .owned = breaks.len > 0,
                .prepared = prepared,
            };
        }

        fn wrapWidthColumns(self: *const Self) usize {
            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            return @max(1, @as(usize, @intFromFloat(@floor(self.wrap_width / @max(cw, 0.5)))));
        }

        /// Wrap break calc core algorithm.
        fn computeWraps(self: *Self, text: []const u8) WrapEntry {
            if (self.precise_wrap and self.hasPreciseMeasure()) {
                return self.computeWrapsPrecise(text);
            }

            var breaks_stack: [256]u32 = undefined;
            var stack_count: usize = 0;
            var breaks_heap: std.ArrayListUnmanaged(u32) = .empty;
            var use_heap = false;
            defer if (use_heap) breaks_heap.deinit(self.allocator);

            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            const ts = if (self.tab_size == 0) 4 else self.tab_size;

            var seg_start: usize = 0;
            var last_word_boundary: usize = 0;
            var accumulated_w: f32 = 0;
            var col: usize = 0; // Current column (for tab stop calc).
            var i: usize = 0;
            var grapheme_cursor = grapheme.BoundaryCursor.init(text);

            while (i < text.len) {
                const byte = text[i];
                // Same computeWrapsPrecise: advance by grapheme cluster, break not inside
                // cluster (estimate path same downstream as display line segment start).
                const next_i = grapheme_cursor.next(i);

                if (i > seg_start) {
                    if (byte == ' ' or byte == '\t') {
                        last_word_boundary = next_i;
                    } else if (byte >= 0xE0) {
                        last_word_boundary = i;
                    } else if (i > 0 and prevCharLead(text, i) >= 0xE0) {
                        last_word_boundary = i;
                    }
                }

                const char_w: f32 = if (byte == '\t') blk: {
                    const spaces = ts - (col % ts);
                    col += spaces;
                    break :blk @as(f32, @floatFromInt(spaces)) * cw;
                } else if (byte < 0x80) blk: {
                    col += 1;
                    break :blk cw;
                } else blk: {
                    col += 2;
                    break :blk cw * 2.0;
                };
                accumulated_w += char_w;

                if (accumulated_w > self.wrap_width and i > seg_start) {
                    var break_at: usize = undefined;
                    if (last_word_boundary > seg_start) {
                        break_at = last_word_boundary;
                    } else {
                        break_at = i;
                    }

                    if (!use_heap and stack_count < breaks_stack.len) {
                        breaks_stack[stack_count] = @intCast(break_at);
                        stack_count += 1;
                    } else {
                        if (!use_heap) {
                            breaks_heap.ensureTotalCapacity(self.allocator, breaks_stack.len * 2) catch return .{ .is_interpolated = true };
                            for (breaks_stack[0..stack_count]) |bp| {
                                breaks_heap.appendAssumeCapacity(bp);
                            }
                            use_heap = true;
                        }
                        breaks_heap.append(self.allocator, @intCast(break_at)) catch return .{ .is_interpolated = true };
                    }

                    seg_start = break_at;
                    last_word_boundary = seg_start;
                    accumulated_w = 0;
                    col = 0;
                    i = break_at;
                    continue;
                }

                i = next_i;
            }

            const break_count = if (use_heap) breaks_heap.items.len else stack_count;
            if (break_count == 0) return .{};

            const breaks = self.allocator.alloc(u32, break_count) catch return .{ .is_interpolated = true };
            if (use_heap) {
                @memcpy(breaks, breaks_heap.items[0..break_count]);
            } else {
                @memcpy(breaks, breaks_stack[0..break_count]);
            }
            return .{ .breaks = breaks, .owned = true };
        }

        /// Exact wrap: per-char true measure width (for high-precision UI text
        /// box).
        fn computeWrapsPrecise(self: *Self, text: []const u8) WrapEntry {
            var breaks_stack: [256]u32 = undefined;
            var stack_count: usize = 0;
            var breaks_heap: std.ArrayListUnmanaged(u32) = .empty;
            var use_heap = false;
            defer if (use_heap) breaks_heap.deinit(self.allocator);

            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            const ts = if (self.tab_size == 0) 4 else self.tab_size;

            var seg_start: usize = 0;
            var last_word_boundary: usize = 0;
            var accumulated_w: f32 = 0;
            var col: usize = 0;
            var i: usize = 0;
            var grapheme_cursor = grapheme.BoundaryCursor.init(text);

            while (i < text.len) {
                const byte = text[i];
                // Advance unit must be an extended grapheme cluster, not a codepoint: ZWJ sequence
                // (family emoji = 8 codepoints / 1 glyph), skin tone, VS16, combining
                // diacritics are all multi-codepoint single glyphs. By codepoint, a single glyph's
                // advance is split and accumulated over several segments, and
                // break/last_word_boundary can
                // land inside a cluster. Display line segment start then isn't a glyph boundary, so
                // cursor x and selection rect misalign: emoji caret left, selection half-glyph.
                // Whole-cluster measure keeps advance same-origin with shaping.
                const next_i = grapheme_cursor.next(i);

                const char_w: f32 = if (byte == '\t') blk: {
                    const spaces = ts - (col % ts);
                    col += spaces;
                    break :blk @as(f32, @floatFromInt(spaces)) * cw;
                } else blk: {
                    if (byte >= 0xE0) {
                        col += 2;
                    } else {
                        col += 1;
                    }
                    const measured = self.measureText(text[i..next_i]);
                    if (measured > 0) break :blk measured;
                    break :blk if (byte >= 0xE0) cw * 2.0 else cw;
                };
                accumulated_w += char_w;

                if (accumulated_w > self.wrap_width and i > seg_start) {
                    const break_at: usize = if (last_word_boundary > seg_start) last_word_boundary else i;

                    if (!use_heap and stack_count < breaks_stack.len) {
                        breaks_stack[stack_count] = @intCast(break_at);
                        stack_count += 1;
                    } else {
                        if (!use_heap) {
                            breaks_heap.ensureTotalCapacity(self.allocator, breaks_stack.len * 2) catch return .{ .is_interpolated = true };
                            for (breaks_stack[0..stack_count]) |bp| {
                                breaks_heap.appendAssumeCapacity(bp);
                            }
                            use_heap = true;
                        }
                        breaks_heap.append(self.allocator, @intCast(break_at)) catch return .{ .is_interpolated = true };
                    }

                    seg_start = break_at;
                    last_word_boundary = seg_start;
                    accumulated_w = 0;
                    col = 0;
                    i = break_at;
                    continue;
                }

                // Break rules and render side text_layout.findLineBreak exact same-origin:
                // breakable after CJK; other positions per UAX #14 pair table (i18n.linebreak).
                // Record must after overflow judge, current cluster overflow, break only before.
                // Old lead-byte heuristic treated emoji CJK (both sides breakable), render
                // classify emoji AL (AL×AL not break): same overflow two sides select different
                // break, WrapMap segment and render line thereafter misaligned, selection/cursor
                // whole-segment offset.
                if (i > seg_start) {
                    const cp = firstCodepoint(text[i..next_i]);
                    if (i18n.linebreak.isCJK(cp)) {
                        last_word_boundary = next_i;
                    } else if (next_i < text.len) {
                        const next_cp = firstCodepoint(text[next_i..@min(next_i + 4, text.len)]);
                        if (i18n.linebreak.canBreakBetween(i18n.linebreak.classify(cp), i18n.linebreak.classify(next_cp))) {
                            last_word_boundary = next_i;
                        }
                    }
                }

                i = next_i;
            }

            const break_count = if (use_heap) breaks_heap.items.len else stack_count;
            if (break_count == 0) return .{};

            const breaks = self.allocator.alloc(u32, break_count) catch return .{ .is_interpolated = true };
            if (use_heap) {
                @memcpy(breaks, breaks_heap.items[0..break_count]);
            } else {
                @memcpy(breaks, breaks_stack[0..break_count]);
            }
            return .{ .breaks = breaks, .owned = true };
        }

        /// Measure text width.
        fn measureText(self: *const Self, text: []const u8) f32 {
            if (text.len == 0) return 0;
            if (self.measure_ctx_fn) |mfn| {
                if (self.measure_ctx) |ctx| {
                    return mfn(ctx, text.ptr, text.len, self.font_size, self.font_weight, false);
                }
            }
            if (self.measure_fn) |mfn| {
                return mfn(text.ptr, text.len, self.font_size, self.font_weight, false);
            }
            // Monospace fallback (char_width estimate, only test env without GPU).
            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            var w: f32 = 0;
            var i: usize = 0;
            while (i < text.len) {
                const b = text[i];
                const cl: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
                w += if (b >= 0xE0) cw * 2.0 else cw;
                i += @min(cl, text.len - i);
            }
            return w;
        }

        /// buffer line -> that line first display line number (Fenwick O(logN)).
        pub fn bufferLineToDisplayLine(self: *const Self, buf_line: usize) u32 {
            if (!self.enabled or self.needs_rebuild) return saturatingU32(buf_line);
            if (self.fenwick) |ft| {
                if (buf_line == 0) return 0;
                if (buf_line > ft.n) return self.total_display_lines;
                return ft.prefixSum(buf_line - 1);
            }
            var total: u32 = 0;
            for (self.line_wraps.items[0..@min(buf_line, self.line_wraps.items.len)]) |entry| total +|= saturatingU32(entry.breaks.len + 1);
            return total;
        }

        /// buffer coords -> display coords.
        pub fn bufferToDisplay(self: *const Self, buf_line: usize, byte_col: usize) DisplayPoint {
            if (!self.enabled or self.needs_rebuild) return .{ .display_line = saturatingU32(buf_line), .display_col = byte_col };

            if (buf_line >= self.line_wraps.items.len) {
                return .{ .display_line = self.total_display_lines, .display_col = 0 };
            }

            const base = self.bufferLineToDisplayLine(buf_line);
            const wrap_idx = self.wrapIndexForBufferByte(buf_line, byte_col);
            const seg_start: usize = if (wrap_idx == 0) 0 else self.line_wraps.items[buf_line].breaks[wrap_idx - 1];
            return .{
                .display_line = base + @as(u32, @intCast(wrap_idx)),
                .display_col = byte_col - seg_start,
            };
        }

        pub fn wrapIndexForBufferByte(self: *const Self, buf_line: usize, byte_col: usize) usize {
            if (!self.enabled or buf_line >= self.line_wraps.items.len) return 0;
            const breaks = self.line_wraps.items[buf_line].breaks;
            var wrap_idx: usize = 0;
            for (breaks) |bp| {
                if (byte_col < bp) break;
                wrap_idx += 1;
            }
            return wrap_idx;
        }

        pub fn displayLineForBufferByte(self: *const Self, buf_line: usize, byte_col: usize) u32 {
            if (!self.enabled or self.needs_rebuild) return saturatingU32(buf_line);
            if (buf_line >= self.line_wraps.items.len) return self.total_display_lines;
            return self.bufferLineToDisplayLine(buf_line) + @as(u32, @intCast(self.wrapIndexForBufferByte(buf_line, byte_col)));
        }

        /// display line -> buffer line + wrap segment info (Fenwick O(logN)).
        ///
        /// `line_wraps` after incremental edit interpolation window may temporary
        /// keep old breaks, must clamp current doc line-len. Passing `doc` required
        /// param ensures all callers get directly-sliceable range, not depend consumer
        /// remember per-place defend stale breaks.
        pub fn displayLineInfo(self: *const Self, display_line: u32, doc: *const Doc) DisplayLineInfo {
            if (!self.enabled or self.line_wraps.items.len == 0) {
                const buffer_line: usize = display_line;
                const line_len = if (buffer_line < doc.lineCount()) doc.getLineLength(buffer_line) else 0;
                return .{
                    .buffer_line = buffer_line,
                    .wrap_index = 0,
                    .segment_start_index = 0,
                    .segment_end_index = 1,
                    .byte_start = 0,
                    .byte_end = line_len,
                };
            }

            const dl = self.clampDisplayLine(display_line);
            const buf_line = self.findBufferLineForClamped(dl);

            const base_dl = self.bufferLineToDisplayLine(buf_line);
            const wrap_index_raw: usize = @intCast(dl - base_dl);

            if (buf_line >= self.line_wraps.items.len) {
                return .{
                    .buffer_line = buf_line,
                    .wrap_index = 0,
                    .segment_start_index = 0,
                    .segment_end_index = 1,
                    .byte_start = 0,
                    .byte_end = 0,
                };
            }

            const entry = self.line_wraps.items[buf_line];
            // wrap_index valid range [0, breaks.len], breaks.len is last segment (to
            // line end).
            const wrap_index = @min(wrap_index_raw, entry.breaks.len);
            const line_len = if (buf_line < doc.lineCount()) doc.getLineLength(buf_line) else 0;
            const stale_start: usize = if (wrap_index == 0) 0 else entry.breaks[wrap_index - 1];
            const stale_end: usize = if (wrap_index < entry.breaks.len) entry.breaks[wrap_index] else line_len;
            const byte_start = @min(stale_start, line_len);
            const byte_end = @max(byte_start, @min(stale_end, line_len));

            return .{
                .buffer_line = buf_line,
                .wrap_index = wrap_index,
                .segment_start_index = wrap_index,
                .segment_end_index = wrap_index + 1,
                .byte_start = byte_start,
                .byte_end = byte_end,
            };
        }

        pub fn bufferLineForDisplayLine(self: *const Self, display_line: u32) usize {
            if (!self.enabled or self.needs_rebuild) return display_line;
            if (self.line_wraps.items.len == 0) return 0;
            return self.findBufferLineForClamped(self.clampDisplayLine(display_line));
        }

        /// Total display line count.
        pub fn displayLineCount(self: *const Self) u32 {
            if (!self.enabled) return 0;
            return self.total_display_lines;
        }

        /// Get buffer line display count.
        pub fn displayLinesForBuffer(self: *const Self, buf_line: usize) u32 {
            if (!self.enabled or buf_line >= self.line_wraps.items.len) return 1;
            return @intCast(self.line_wraps.items[buf_line].breaks.len + 1);
        }

        pub fn displayRangeForBufferLine(self: *const Self, buf_line: usize) DisplayLineRange {
            const start: usize = @intCast(self.bufferLineToDisplayLine(buf_line));
            return .{
                .start = start,
                .end = start + self.displayLinesForBuffer(buf_line),
            };
        }

        pub fn bufferRangeForDisplayRange(self: *const Self, display_start: usize, display_end: usize) BufferLineRange {
            if (!self.enabled or self.line_wraps.items.len == 0 or display_end <= display_start) {
                return .{ .start = display_start, .end = display_end };
            }
            const clamped_start = @min(display_start, @as(usize, self.total_display_lines -| 1));
            const clamped_end_exclusive = @min(display_end, @as(usize, self.total_display_lines));
            if (clamped_end_exclusive <= clamped_start) {
                const start_buf = self.bufferLineForDisplayLine(@intCast(clamped_start));
                return .{ .start = start_buf, .end = start_buf };
            }
            const start_buf = self.bufferLineForDisplayLine(@intCast(clamped_start));
            const end_buf = self.bufferLineForDisplayLine(@intCast(clamped_end_exclusive - 1)) + 1;
            return .{ .start = start_buf, .end = end_buf };
        }

        /// Get buffer line wrap breaks slice.
        pub fn breaksForBuffer(self: *const Self, buf_line: usize) []const u32 {
            if (!self.enabled or buf_line >= self.line_wraps.items.len) return &.{};
            return self.line_wraps.items[buf_line].breaks;
        }

        fn freeWrapEntry(self: *Self, entry: *WrapEntry) void {
            if (entry.owned and entry.breaks.len > 0) {
                self.allocator.free(entry.breaks);
            }
            entry.breaks = &.{};
            entry.owned = false;
            if (entry.prepared) |prepared| {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                entry.prepared = null;
            }
        }

        fn clampDisplayLine(self: *const Self, display_line: u32) u32 {
            if (self.total_display_lines == 0) return 0;
            return @min(display_line, self.total_display_lines - 1);
        }

        fn findBufferLineForClamped(self: *const Self, dl: u32) usize {
            return if (self.fenwick) |ft| blk: {
                if (dl == 0) break :blk 0;
                const target = dl + 1;
                const idx = ft.find(target);
                if (idx == 0) break :blk 0;
                const prev_sum = ft.prefixSum(idx - 1);
                if (dl < prev_sum) break :blk idx - 1;
                break :blk idx;
            } else blk: {
                var acc: u32 = 0;
                for (self.line_wraps.items, 0..) |entry, i| {
                    acc +|= saturatingU32(entry.breaks.len + 1);
                    if (acc > dl) break :blk i;
                }
                break :blk self.line_wraps.items.len -| 1;
            };
        }
    };
}

const testing = std.testing;

const MockDoc = struct {
    text: []const u8,
    starts: []const usize,
    buf_reads: *usize,
    alloc_reads: *usize,

    fn lineCount(self: *const MockDoc) usize {
        return self.starts.len;
    }

    fn totalLength(self: *const MockDoc) usize {
        return self.text.len;
    }

    fn getLineStart(self: *const MockDoc, line: usize) usize {
        return self.starts[@min(line, self.starts.len - 1)];
    }

    fn getLineLength(self: *const MockDoc, line: usize) usize {
        const start = self.getLineStart(line);
        const next = if (line + 1 < self.starts.len) self.starts[line + 1] else self.text.len;
        return next - start;
    }

    fn getTextBuf(self: *const MockDoc, start: usize, len: usize, buf: []u8) ![]const u8 {
        self.buf_reads.* += 1;
        const end = @min(start + len, self.text.len);
        const slice = self.text[start..end];
        if (slice.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..slice.len], slice);
        return buf[0..slice.len];
    }

    fn getTextAlloc(self: *const MockDoc, allocator: Allocator, start: usize, len: usize) ![]const u8 {
        self.alloc_reads.* += 1;
        const end = @min(start + len, self.text.len);
        return allocator.dupe(u8, self.text[start..end]);
    }
};

test "WrapMap reuses prepared lines on wrap width change" {
    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const text = "alpha beta gamma\nshort line\n";
    const starts = [_]usize{ 0, 17 };
    const doc = MockDoc{
        .text = text,
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };

    var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 1;
    wm.tab_size = 4;
    wm.setWrapWidth(6, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(usize, 2), buf_reads);
    try testing.expectEqual(@as(usize, 0), alloc_reads);
    try testing.expect(wm.displayLinesForBuffer(0) > 1);

    wm.setWrapWidth(10, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(usize, 2), buf_reads);
    try testing.expectEqual(@as(usize, 0), alloc_reads);
    try testing.expect(wm.displayLinesForBuffer(0) < 3);

    const display_range = wm.displayRangeForBufferLine(0);
    try testing.expectEqual(@as(usize, 0), display_range.start);
    try testing.expectEqual(@as(usize, @intCast(wm.displayLinesForBuffer(0))), display_range.end);
}

test "WrapMap applyEdit rebuilds on inconsistent edit ranges" {
    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const doc = MockDoc{
        .text = "one line",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 1;
    wm.setWrapWidth(4, &doc);
    wm.setEnabled(true, &doc);

    wm.applyEdit(&doc, 999, 1, 1);
    try testing.expectEqual(doc.lineCount(), wm.line_wraps.items.len);
    try testing.expect(wm.takePendingPatch().?.is_global);
}

test "WrapMap chunked long line avoids heap line allocation during rewrap" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..12000) |_| {
        try text.append(testing.allocator, 'x');
    }

    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const doc = MockDoc{
        .text = text.items,
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };

    var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 1;
    wm.tab_size = 4;
    wm.setWrapWidth(120, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expect(buf_reads > 0);
    try testing.expectEqual(@as(usize, 0), alloc_reads);
    try testing.expect(wm.displayLinesForBuffer(0) > 1);
}

test "WrapMap context measurement stays isolated across windows" {
    const MeasureState = struct {
        advance: f32,

        fn withContext(raw: *anyopaque, _: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return @as(f32, @floatFromInt(len)) * self.advance;
        }

        fn legacy(_: [*]const u8, _: usize, _: f32, _: u16, _: bool) f32 {
            return 0;
        }
    };

    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const doc = MockDoc{
        .text = "abcd",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    var narrow_font = MeasureState{ .advance = 1 };
    var wide_font = MeasureState{ .advance = 3 };

    var narrow = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer narrow.deinit();
    narrow.precise_wrap = true;
    narrow.measure_fn = MeasureState.legacy;
    narrow.measure_ctx_fn = MeasureState.withContext;
    narrow.measure_ctx = &narrow_font;
    narrow.setWrapWidth(5, &doc);
    narrow.setEnabled(true, &doc);
    _ = narrow.rewrapInterpolatedAll(&doc);

    var wide = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wide.deinit();
    wide.precise_wrap = true;
    wide.measure_fn = MeasureState.legacy;
    wide.measure_ctx_fn = MeasureState.withContext;
    wide.measure_ctx = &wide_font;
    wide.setWrapWidth(5, &doc);
    wide.setEnabled(true, &doc);
    _ = wide.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(u32, 1), narrow.displayLinesForBuffer(0));
    try testing.expect(wide.displayLinesForBuffer(0) > narrow.displayLinesForBuffer(0));
}

// Soft wrap breaks must land on extended grapheme cluster boundaries. Root cause being
// locked: wrap loops advancing by UTF-8 codepoint (lead byte gives 1/2/3/4 bytes). ZWJ
// sequence (family emoji = 8 codepoints / 1 glyph), skin tone, VS16, combining
// diacritics are multi-codepoint single glyphs; by codepoint, glyph advance is split
// across segments and break/last_word_boundary fall inside a cluster. Downstream takes display
// line byte_start as display-segment start for shaping/caret, so a start in the middle of a
// glyph misaligns caret x and selection rect for the whole segment: emoji caret left,
// selection half-glyph. Break unit = grapheme cluster; this test locks that invariant
// (ZWJ/skin tone examples assert byte_start is not inside a cluster).
test "soft wrap 断点落在 grapheme cluster 边界（emoji/ZWJ/肤色/组合）" {
    const M = struct {
        fn ctx(_: *anyopaque, ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            _ = ptr;
            return @as(f32, @floatFromInt(len)) * 2.0;
        }
    };
    const cases = [_][]const u8{
        "aaaa\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}aaaa", // ZWJ family.
        "aaaa\u{2764}\u{FE0F}aaaa", // BMP + VS16
        "aaaae\u{0301}aaaa", // Combining diacritic.
        "aaaa\u{1F44B}\u{1F3FB}aaaa", // Skin tone modifier.
        "aaaa\u{1F60A}aaaa", // Single-codepoint SMP emoji.
        "aaaa\u{4E2D}\u{6587}aaaa", // CJK fullwidth
    };
    var dummy: u8 = 0;
    for (cases) |txt| {
        const starts = [_]usize{0};
        var br: usize = 0;
        var ar: usize = 0;
        const doc = MockDoc{ .text = txt, .starts = &starts, .buf_reads = &br, .alloc_reads = &ar };
        var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
        defer wm.deinit();
        wm.precise_wrap = true;
        wm.measure_ctx_fn = M.ctx;
        wm.measure_ctx = @ptrCast(&dummy);
        wm.setWrapWidth(20, &doc);
        wm.setEnabled(true, &doc);
        _ = wm.rewrapInterpolatedAll(&doc);
        const n = wm.displayLinesForBuffer(0);
        try testing.expect(n >= 1);
        var d: u32 = 0;
        while (d < n) : (d += 1) {
            const info = wm.displayLineInfo(d, &doc);
            const bs = @min(info.byte_start, txt.len);
            try testing.expect(@import("text_coordinates.zig").isGraphemeBoundary(txt, bs));
        }
    }
}

// Precise wrap break rule must match render side text_layout.findLineBreak (UAX #14 pair table +
// isCJK).
//
// Regression root: old impl used lead-byte heuristic (any char >= 0xE0 breakable before/after),
// treated emoji as CJK; render side i18n.linebreak.classify categorizes emoji as AL (AL x AL no
// break). Text 'asfd🎩like_missing_fds🍰oddassdfasdf' overflows at 🍰: render backed to 'missing' line
// (line1 = 'fds🍰...'), WrapMap broke at 🍰 (line1 = '🍰...'), edit cursor/selection based on WrapMap
// lines misaligned from render since first wrap.
test "precise wrap 断点规则与渲染端一致：emoji 前不断行" {
    const M = struct {
        fn ctx(_: *anyopaque, ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            _ = ptr;
            // Simulate realistic measurements: Latin ~7px, CJK 16px, emoji 21px (by byte length).
            return switch (len) {
                1 => 7.0,
                3 => 16.0,
                4 => 21.0,
                else => @as(f32, @floatFromInt(len)) * 7.0,
            };
        }
    };
    //                0...4  8..11 14  17..20 23..27 30
    const txt = "asfd\u{1F3A9}一样的欠fds\u{1F370}奥asdfasdf";
    const starts = [_]usize{0};
    var br: usize = 0;
    var ar: usize = 0;
    const doc = MockDoc{ .text = txt, .starts = &starts, .buf_reads = &br, .alloc_reads = &ar };
    var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.precise_wrap = true;
    wm.measure_ctx_fn = M.ctx;
    var dummy: u8 = 0;
    wm.measure_ctx = @ptrCast(&dummy);
    // txt = 4 ASCII + hat emoji + 4 CJK chars + 'fds' + cake emoji + ...:
    // 4*7+21+4*16+3*7 = 134 <= 140; +cake emoji (21) = 155 > 140. Render: the cake emoji (AL) is
    // non-breakable before -> falls back to after the 4th CJK char (byte 20). Old impl broke at
    // the cake emoji (byte 23).
    wm.setWrapWidth(140, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(usize, 2), wm.displayLinesForBuffer(0));
    const line1 = wm.displayLineInfo(1, &doc);
    try testing.expectEqual(@as(usize, 20), line1.byte_start);
    try testing.expectEqualStrings("fds\u{1F370}奥asdfasdf", txt[line1.byte_start..]);
}

test "displayLineInfo clamps interpolated stale breaks to current line length" {
    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const long_doc = MockDoc{
        .text = "abcdefghijklmnop",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.setWrapWidth(16, &long_doc);
    wm.setEnabled(true, &long_doc);
    _ = wm.rewrapInterpolatedAll(&long_doc);
    try testing.expect(wm.displayLinesForBuffer(0) > 1);

    // Same-line edit preserves old breaks as interpolation placeholders until
    // the maintenance pass. The public query must still be slice-safe now.
    const short_doc = MockDoc{
        .text = "x",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    wm.applyEdit(&short_doc, 0, 1, 1);
    const stale_last: u32 = wm.displayLinesForBuffer(0) - 1;
    const info = wm.displayLineInfo(stale_last, &short_doc);
    try testing.expect(info.byte_start <= short_doc.text.len);
    try testing.expect(info.byte_end <= short_doc.text.len);
    try testing.expect(info.byte_start <= info.byte_end);
}

test "WrapMap missing Fenwick retains wrapped coordinate prefixes" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const doc: MockDoc = .{ .text = "abcdefgh\nijklmnop", .starts = &.{ 0, 9 }, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    var wm = WrapMap(MockDoc).init(testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.wrap_width = 16;
    wm.setEnabled(true, &doc);
    wm.rebuildAll(&doc);
    const expected = wm.bufferLineToDisplayLine(1);
    try testing.expect(expected > 1);
    if (wm.fenwick) |*ft| ft.deinit();
    wm.fenwick = null;
    try testing.expectEqual(expected, wm.bufferLineToDisplayLine(1));
    const info = wm.displayLineInfo(expected, &doc);
    try testing.expectEqual(@as(usize, 1), info.buffer_line);
    try testing.expectEqual(@as(usize, 0), info.byte_start);
}

test "WrapMap failed rebuild keeps current document coordinates usable and retries" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const old: MockDoc = .{ .text = "abcdefgh", .starts = &.{0}, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    const current: MockDoc = .{ .text = "abcdefgh\nijklmnop", .starts = &.{ 0, 9 }, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var wm = WrapMap(MockDoc).init(failing.allocator(), @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.wrap_width = 16;
    wm.setEnabled(true, &old);
    wm.rebuildAll(&old);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    wm.rebuildAll(&current);
    try testing.expectEqual(@as(u32, 2), wm.total_display_lines);
    try testing.expectEqual(@as(u32, 1), wm.bufferToDisplay(1, 3).display_line);
    try testing.expectEqual(@as(usize, 3), wm.bufferToDisplay(1, 3).display_col);
    try testing.expectEqual(@as(usize, 1), wm.bufferLineForDisplayLine(1));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = wm.rewrapInterpolatedAll(&current);
    try testing.expect(wm.total_display_lines > 2);
    try testing.expectEqual(current.lineCount(), wm.line_wraps.items.len);
}

fn expectCoherentWrapMapping(wm: *const WrapMap(MockDoc), doc: *const MockDoc) !void {
    if (!wm.enabled or wm.needs_rebuild) {
        try testing.expectEqual(saturatingU32(doc.lineCount()), wm.total_display_lines);
        try testing.expect(wm.fenwick == null);
        for (0..doc.lineCount()) |line| {
            const point = wm.bufferToDisplay(line, 1);
            try testing.expectEqual(saturatingU32(line), point.display_line);
            try testing.expectEqual(@as(usize, 1), point.display_col);
            try testing.expectEqual(line, wm.bufferLineForDisplayLine(saturatingU32(line)));
        }
        return;
    }
    try testing.expectEqual(doc.lineCount(), wm.line_wraps.items.len);
    var display: u32 = 0;
    for (wm.line_wraps.items, 0..) |entry, line| {
        try testing.expectEqual(display, wm.bufferLineToDisplayLine(line));
        for (0..entry.breaks.len + 1) |segment| {
            const info = wm.displayLineInfo(display, doc);
            try testing.expectEqual(line, info.buffer_line);
            try testing.expectEqual(segment, info.wrap_index);
            try testing.expect(info.byte_start <= info.byte_end);
            try testing.expect(info.byte_end <= doc.getLineLength(line));
            try testing.expectEqual(line, wm.bufferLineForDisplayLine(display));
            display += 1;
        }
    }
    try testing.expectEqual(display, wm.total_display_lines);
    if (wm.fenwick) |ft| {
        try testing.expectEqual(doc.lineCount(), ft.n);
        try testing.expectEqual(display, ft.total());
    }
}

test "WrapMap rebuild enable and growth allocation failures keep coherent mappings and recover" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const old: MockDoc = .{ .text = "abcdefgh", .starts = &.{0}, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    const current: MockDoc = .{ .text = "abcdefghijklmnop\nabcdefghijklmnop\nabcdefghijklmnop", .starts = &.{ 0, 17, 34 }, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    for (0..4) |operation| {
        var completed = false;
        for (0..150) |failure| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var wm = WrapMap(MockDoc).init(failing.allocator(), @import("std").testing.io);
            defer wm.deinit();
            wm.char_width = 8;
            wm.wrap_width = 16;
            wm.setEnabled(true, &old);
            wm.rebuildAll(&old);
            if (operation == 1 or operation == 3) wm.setEnabled(false, &old);
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            switch (operation) {
                0 => wm.rebuildAll(&current),
                1 => wm.setEnabled(true, &current),
                2, 3 => wm.applyEdit(&current, 0, 1, 3),
                else => unreachable,
            }
            const induced = failing.has_induced_failure;
            try expectCoherentWrapMapping(&wm, &current);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (operation != 3) {
                _ = wm.rewrapInterpolatedAll(&current);
                _ = wm.rewrapInterpolatedAll(&current);
                try testing.expect(!wm.has_interpolated_lines);
                try testing.expect(!wm.needs_rebuild);
                try expectCoherentWrapMapping(&wm, &current);
                try testing.expectEqual(@as(u32, 24), wm.total_display_lines);
            }
            if (!induced) {
                completed = true;
                break;
            }
        }
        try testing.expect(completed);
    }
}

test "WrapMap line wrap allocation failure stays pending through whole and range refresh" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const text = (@as([("abcdefgh").len * (1200)]u8, @bitCast(@as([1200][("abcdefgh").len]u8, @splat(("abcdefgh").*)))) ++ "");
    const doc: MockDoc = .{ .text = text, .starts = &.{0}, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    for ([_]bool{ false, true }) |range| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var wm = WrapMap(MockDoc).init(failing.allocator(), @import("std").testing.io);
        defer wm.deinit();
        wm.char_width = 8;
        wm.wrap_width = 160;
        wm.setEnabled(true, &doc);
        wm.rebuildAll(&doc);
        wm.setWrapWidth(80, &doc);
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        const failed = if (range) wm.rewrapInterpolatedRange(&doc, 0, 1) else wm.rewrapInterpolatedAll(&doc);
        try testing.expectEqual(@as(usize, 1), failed.lines_remaining);
        try testing.expect(wm.has_interpolated_lines);
        try expectCoherentWrapMapping(&wm, &doc);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        const retried = if (range) wm.rewrapInterpolatedRange(&doc, 0, 1) else wm.rewrapInterpolatedAll(&doc);
        try testing.expectEqual(@as(usize, 0), retried.lines_remaining);
        try testing.expectEqual(@as(u32, 960), wm.total_display_lines);
        try expectCoherentWrapMapping(&wm, &doc);
    }
}

test "WrapMap background publication rejects obsolete mapping epochs" {
    const AsyncDoc = struct {
        const Snapshot = struct {
            pub fn deinit(_: *@This()) void {}
        };
        pub fn snapshot(_: *@This(), _: Allocator) !Snapshot {
            return .{};
        }
    };
    for (0..4) |mutation| {
        var wm = WrapMap(AsyncDoc).init(testing.allocator, @import("std").testing.io);
        defer wm.deinit();
        wm.enabled = true;
        try wm.line_wraps.append(testing.allocator, .{ .is_interpolated = true });
        wm.has_interpolated_lines = true;
        wm.total_display_lines = 1;
        const breaks = try testing.allocator.dupe(u32, &.{ 2, 4 });
        try wm.bg_result.append(testing.allocator, .{ .buffer_line = 0, .breaks = breaks });
        wm.bg_thread = try std.Thread.spawn(.{}, struct {
            fn run() void {}
        }.run, .{});
        wm.bg_done.store(true, .release);
        switch (mutation) {
            0 => {},
            1 => wm.revision += 1,
            2 => wm.enabled = false,
            3 => wm.needs_rebuild = true,
            else => unreachable,
        }
        const result = wm.pollBackgroundRewrap(0);
        if (mutation == 0) {
            try testing.expect(result == .applied);
            try testing.expectEqual(@as(u32, 3), wm.total_display_lines);
            try testing.expectEqual(@as(u32, 3), wm.bufferLineToDisplayLine(1));
        } else {
            try testing.expect(result == .stale);
            try testing.expectEqual(@as(u32, 1), wm.total_display_lines);
            try testing.expect(wm.line_wraps.items[0].is_interpolated);
            try testing.expectEqual(@as(usize, 0), wm.line_wraps.items[0].breaks.len);
        }
    }
}
