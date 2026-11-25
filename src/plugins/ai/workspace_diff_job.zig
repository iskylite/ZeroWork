//! A bounded, detached projection of already-displayed operation receipts.
//! No UI/main-loop actor owns the journal or waits for slow volumes.
const std = @import("std");
const preview = @import("../../host/workspace_preview.zig");
const diff = @import("../../ai/workspace_turn_diff.zig");
const host = @import("../../ai/host_tools.zig");
const facts = @import("../../ai/tool_results.zig");
const ProcessJournal = @import("../../ai/lifecycle_runtime.zig").ProcessJournal;

const worker_limit = 4;
const receipt_limit = 8;
var workers: std.atomic.Value(u8) = .init(0);

fn reserve() bool {
    var active = workers.load(.monotonic);
    while (active < worker_limit) {
        active = workers.cmpxchgWeak(active, active + 1, .acq_rel, .monotonic) orelse return true;
    }
    return false;
}

pub fn eligible(record: *const facts.Record, authority: host.Context, turn: u64) bool {
    const fact = record.host orelse return false;
    if (record.turn_id != turn or !record.owner.eql(authority.binding) or
        !fact.receipt.conversation_id.eql(authority.conversation_id) or !fact.receipt.task_id.eql(authority.task_id) or
        fact.receipt.binding_revision != authority.binding_revision or fact.content.len > 48 * 1024 or record.call_id.len > 512) return false;
    var name_buffer: [64]u8 = undefined;
    const name = @import("../../ai/plugin_tools.zig").decodeName(&name_buffer, record.name) catch record.name;
    return std.mem.eql(u8, name, "host.local_write_text") or std.mem.eql(u8, name, "host.local_edit_text");
}

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    current: diff.Current,
    selection: diff.Selection,
    records: std.ArrayList(facts.Record) = .empty,
    refs: std.atomic.Value(u8) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    canceled: std.atomic.Value(bool) = .init(false),
    result: anyerror!diff.Result = error.Pending,
    matched_index: ?usize = null,

    pub fn start(current: diff.Current, selection: diff.Selection, current_records: []const *facts.Record) !*Job {
        if (!reserve()) return error.DiffBusy;
        errdefer _ = workers.fetchSub(1, .acq_rel);
        const a = std.heap.c_allocator;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .arena = .init(a), .current = current, .selection = selection };
        errdefer job.arena.deinit();
        const storage = job.arena.allocator();
        job.current.source.workspace = try current.source.workspace.clone(storage);
        job.current.source.data_root = try storage.dupe(u8, current.source.data_root);
        job.selection.relative = try storage.dupe(u8, selection.relative);
        var n = current_records.len;
        while (n > 0 and job.records.items.len < receipt_limit) {
            n -= 1;
            const record = current_records[n];
            if (!eligible(record, current.authority, current.turn_id)) continue;
            var fact = record.host.?;
            fact.content = try storage.dupe(u8, fact.content);
            fact.fetch = null;
            try job.records.append(storage, .{
                .arena = .init(storage),
                .owner = record.owner,
                .turn_id = record.turn_id,
                .conversation_id = record.conversation_id,
                .call_id = try storage.dupe(u8, record.call_id),
                .name = try storage.dupe(u8, record.name),
                .arguments = "",
                .command = "",
                .arguments_hash = @splat(0),
                .targets = &.{},
                .host = fact,
                .dispatched = record.dispatched,
            });
        }
        if (job.records.items.len == 0) return error.NoVisibleDiffReceipt;
        (try std.Thread.spawn(.{}, run, .{job})).detach();
        return job;
    }
    fn run(job: *Job) void {
        job.result = job.read();
        _ = workers.fetchSub(1, .acq_rel);
        job.done.store(true, .release);
        job.release();
    }
    fn read(job: *Job) !diff.Result {
        if (job.canceled.load(.acquire)) return error.Canceled;
        const store = try ProcessJournal.acquire(.{ .data_root = job.current.source.data_root });
        defer store.release();
        const a = job.arena.allocator();
        // Revalidate the selected path against the authorized root and
        // descriptor, before any content is made available to the UI.
        var runtime = std.Io.Threaded.init(std.heap.c_allocator, .{});
        defer runtime.deinit();
        for (job.records.items, 0..) |*record, index| {
            if (job.canceled.load(.acquire)) return error.Canceled;
            const result = try diff.project(a, job.current, job.selection, record, store);
            if (result == .not_applicable) continue;
            if (result == .change) {
                var live = try preview.capture(a, runtime.io(), job.current.source, .read, job.selection.relative);
                defer live.release();
                if (live != .text or !std.meta.eql(live.text.file, @as(?@TypeOf(job.selection.file), job.selection.file))) return error.WorkspaceChanged;
            }
            job.matched_index = index;
            return result;
        }
        return .not_applicable;
    }
    pub fn cancel(job: *Job) void {
        job.canceled.store(true, .release);
    }
    pub fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        job.arena.deinit();
        std.heap.c_allocator.destroy(job);
    }
};
