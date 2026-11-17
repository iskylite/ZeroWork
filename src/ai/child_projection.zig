//! One controller-owned projection for badge, sorting and stable child actions.
const std = @import("std");
const id = @import("../host/identity.zig");
const life = @import("session_lifecycle.zig");
const runtime = @import("session_runtime.zig");
const budget = @import("task_budget.zig");
pub const Group = enum { approval, attention, active, recent };
pub const Entry = struct {
    agent: id.AgentId,
    conversation: id.ConversationId,
    revision: u64,
    name: []const u8,
    /// V0.7 §2.1: host-assigned member number for display (#N label).
    seq: u32 = 0,
    summary: []const u8 = "",
    status: []const u8,
    group: Group,
    running: bool,
    active: bool = false,
    waiting_user: bool = false,
    awaiting_approval: bool = false,
    reusable: bool,
    changed_at_ms: i64 = 0,
    task: ?id.TaskId = null,
    /// V0.7 §3.8: per-child usage facts (requests and token totals).
    requests: u64 = 0,
    tokens: u64 = 0,
    /// V0.7 §12.2: "疑似卡住" (running but counters idle > stuck_minutes).
    /// Displayed as a row mark; never auto-intervened.
    stuck: bool = false,
};

/// V0.7 §10.2: Auto-upgrade decisions on the task event stream, newest
/// first. The panel renders them above the board as an explainable timeline.
pub const DecisionRow = struct {
    at_ms: i64,
    reason: []const u8,
};

pub fn decisionRows(a: std.mem.Allocator, service: *runtime.Service, parent: id.ConversationId) ![]DecisionRow {
    var rows: std.ArrayList(DecisionRow) = .empty;
    errdefer rows.deinit(a);
    for (service.task_roots.items) |root| {
        const decisions = root.decisionsSnapshot(a) catch continue;
        defer a.free(decisions);
        var owns = false;
        root.lock();
        defer root.mutex.unlock();
        for (root.facts[0..root.count]) |fact| {
            if (fact.parent == null and fact.conversation.eql(parent)) {
                owns = true;
                break;
            }
        }
        if (!owns) continue;
        for (decisions) |decision| try rows.append(a, .{ .at_ms = decision.at_ms, .reason = decision.reason });
    }
    return rows.toOwnedSlice(a);
}

/// V0.7 §14.2 Board row: a board post rendered from the G8 event stream.
pub const BoardRow = struct {
    kind: []const u8,
    origin: u32,
    category: []const u8,
    to: []const u8,
    text: []const u8,
};

pub const RoundRow = struct {
    seq: u32,
    label: []const u8,
    status: budget.Status,
    summary: []const u8,
    round: budget.BoostRound,
    previous_seq: ?u32,
};

pub const BoostView = struct {
    rows: []RoundRow,
    parent: ?budget.Fact,
};
pub fn latest(service: *runtime.Service, agent: id.AgentId) ?budget.Fact {
    var result: ?budget.Fact = null;
    for (service.store.task_facts.items) |saved| if (saved.fact.agent.eql(agent)) {
        result = saved.fact;
    };
    // Root allocations and their owned strings remain valid until Host teardown.
    for (service.task_roots.items) |root| {
        for (root.displayFacts()) |fact| if (fact.agent.eql(agent)) {
            result = fact;
        };
    }
    return result;
}
pub fn unresolved(service: *runtime.Service, agent: id.AgentId) bool {
    for (service.store.task_facts.items) |saved| if (saved.fact.agent.eql(agent) and (saved.fact.status == .outcome_unknown or saved.fact.status == .interrupted)) return true;
    for (service.task_roots.items) |root| {
        for (root.displayFacts()) |fact| if (fact.agent.eql(agent) and (fact.status == .outcome_unknown or fact.status == .interrupted)) return true;
    }
    return false;
}
pub fn entry(service: *runtime.Service, record: *life.Record) Entry {
    const info = record.child.?.info;
    const prefs = life.Store.childPreferences(record);
    const fact = latest(service, info.agent);
    const runner = service.runnerFor(info.agent);
    const executing = if (runner) |value| value.thread != null and value.state.load(.acquire) == .running else false;
    const state: budget.Status = if (fact) |value| value.status else .succeeded;
    const active = executing and state == .running;
    const needs_verification = unresolved(service, info.agent);
    const group: Group = if (needs_verification) .attention else switch (state) {
        .human_wait, .failed, .outcome_unknown, .interrupted => .attention,
        .running, .queued_dependency, .waiting_model, .waiting_children, .settling => .active,
        else => .recent,
    };
    return .{ .agent = info.agent, .conversation = record.id, .revision = record.child_settings_revision, .name = prefs.name, .seq = if (fact) |value| value.seq else 0, .summary = if (fact) |value| value.summary else "", .status = if (record.ending != null) "收尾中" else if (needs_verification and budget.terminal(state)) "待核验" else if (fact == null) "空闲" else switch (state) {
        .human_wait => "等待用户",
        .failed => "失败",
        .outcome_unknown => "结果未知",
        .interrupted => "已中断",
        .running => if (active) "运行中" else "排队中",
        .queued_dependency => "等待依赖",
        .waiting_model => "等待模型",
        .waiting_children => "等待依赖",
        .settling => "收尾中",
        .succeeded => "已完成",
        .cancelled => "已停止",
    }, .group = group, .running = active, .active = fact != null and !budget.terminal(state), .waiting_user = state == .human_wait, .reusable = prefs.reusable, .changed_at_ms = if (fact) |value| value.changed_at_ms else 0, .task = if (fact) |value| value.task else null, .requests = if (fact) |value| value.counters.requests else 0, .tokens = if (fact) |value| value.counters.input_tokens + value.counters.output_tokens else 0 };
}
pub fn less(_: void, left: Entry, right: Entry) bool {
    if (left.group != right.group) return @backingInt(left.group) < @backingInt(right.group);
    if (left.changed_at_ms != right.changed_at_ms) return left.changed_at_ms > right.changed_at_ms;
    return std.mem.order(u8, &left.agent.bytes, &right.agent.bytes) == .lt;
}
pub fn query(a: std.mem.Allocator, service: *runtime.Service, parent: id.ConversationId) ![]Entry {
    return queryStuck(a, service, parent, &.{});
}

/// V0.7 §12.2: the caller passes the stuck member set from the shared host.
pub fn queryStuck(a: std.mem.Allocator, service: *runtime.Service, parent: id.ConversationId, stuck: []const id.AgentId) ![]Entry {
    var rows: std.ArrayList(Entry) = .empty;
    errdefer rows.deinit(a);
    for (service.store.records.items) |record| if (record.child) |owned| if (owned.info.owning_parent_conversation.eql(parent)) {
        var row = entry(service, record);
        for (stuck) |agent| if (agent.eql(row.agent)) {
            row.stuck = true;
            if (row.status.len != 0 and std.mem.indexOf(u8, row.status, "疑似卡住") == null) row.status = "疑似卡住";
        };
        try rows.append(a, row);
    };
    std.mem.sort(Entry, rows.items, {}, less);
    return rows.toOwnedSlice(a);
}

/// V0.7 §14.2/G8: the parent root's board posts as UI rows. Posts stay on the
/// board for reading even after model delivery consumed them (§11.2); this
/// projection is read-only and never mutates the delivery watermark.
pub fn boardRows(a: std.mem.Allocator, service: *runtime.Service, parent: id.ConversationId) ![]BoardRow {
    var rows: std.ArrayList(BoardRow) = .empty;
    errdefer rows.deinit(a);
    for (service.task_roots.items) |root| {
        root.lock();
        defer root.mutex.unlock();
        // The parent root is the one holding the parent fact for this
        // conversation's delegated children.
        var owns = false;
        for (root.facts[0..root.count]) |fact| {
            if (fact.parent == null and fact.conversation.eql(parent)) {
                owns = true;
                break;
            }
        }
        if (!owns) continue;
        for (root.board_posts.items) |post| {
            const target: []const u8 = switch (post.to) {
                .parent => "协调者",
                .member => "成员",
                .all => "全体",
            };
            try rows.append(a, .{ .kind = post.kind, .origin = post.origin, .category = @tagName(post.category), .to = target, .text = post.text });
        }
    }
    return rows.toOwnedSlice(a);
}

pub fn boostView(a: std.mem.Allocator, service: *runtime.Service, conversation: id.ConversationId) !BoostView {
    var parent: ?budget.Fact = null;
    var live: ?*budget.Root = null;
    for (service.store.task_facts.items) |saved| {
        const fact = saved.fact;
        if (fact.parent == null and fact.boost_limit != null and fact.conversation.eql(conversation) and (parent == null or fact.created_at_ms >= parent.?.created_at_ms)) parent = fact;
    }
    for (service.task_roots.items) |root| {
        const facts = root.displayFacts();
        if (facts.len == 0) continue;
        const fact = facts[0];
        if (fact.parent == null and fact.boost_limit != null and fact.conversation.eql(conversation) and (parent == null or fact.created_at_ms >= parent.?.created_at_ms)) {
            parent = fact;
            live = root;
        }
    }

    var rows: std.ArrayList(RoundRow) = .empty;
    errdefer rows.deinit(a);
    if (parent) |run| {
        var facts: std.ArrayList(budget.Fact) = .empty;
        defer facts.deinit(a);
        if (live) |root| {
            try facts.appendSlice(a, root.displayFacts());
        } else {
            for (service.store.task_facts.items) |saved| {
                if (saved.fact.root.eql(run.root)) try facts.append(a, saved.fact);
            }
        }
        for (facts.items) |fact| {
            const round = fact.boost_round orelse continue;
            const previous_seq: ?u32 = if (round.previous) |task| for (facts.items) |prior| {
                if (prior.task.eql(task)) break prior.seq;
            } else null else null;
            try rows.append(a, .{ .seq = fact.seq, .label = fact.label, .status = fact.status, .summary = fact.summary, .round = round, .previous_seq = previous_seq });
        }
    }
    std.mem.sort(RoundRow, rows.items, {}, struct {
        fn less(_: void, left: RoundRow, right: RoundRow) bool {
            return if (left.round.number == right.round.number) left.seq < right.seq else left.round.number < right.round.number;
        }
    }.less);
    return .{ .rows = try rows.toOwnedSlice(a), .parent = parent };
}
