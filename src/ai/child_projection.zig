//! One controller-owned projection for badge, sorting and stable child actions.
const std = @import("std");
const id = @import("../host/identity.zig");
const life = @import("session_lifecycle.zig");
const runtime = @import("session_runtime.zig");
const budget = @import("task_budget.zig");
pub const Group = enum { attention, active, recent };
pub const Entry = struct {
    agent: id.AgentId,
    conversation: id.ConversationId,
    revision: u64,
    name: []const u8,
    summary: []const u8 = "",
    status: []const u8,
    group: Group,
    running: bool,
    reusable: bool,
    changed_at_ms: i64 = 0,
    task: ?id.TaskId = null,
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
        .running, .waiting_model, .waiting_children, .settling => .active,
        else => .recent,
    };
    return .{ .agent = info.agent, .conversation = record.id, .revision = record.child_settings_revision, .name = prefs.name, .summary = if (fact) |value| value.summary else "", .status = if (record.ending != null) "收尾中" else if (needs_verification and budget.terminal(state)) "待核验" else if (fact == null) "空闲" else switch (state) {
        .human_wait => "等待用户",
        .failed => "失败",
        .outcome_unknown => "结果未知",
        .interrupted => "已中断",
        .running => if (active) "运行中" else "排队中",
        .waiting_model => "等待模型",
        .waiting_children => "等待依赖",
        .settling => "收尾中",
        .succeeded => "已完成",
        .cancelled => "已停止",
    }, .group = group, .running = active, .reusable = prefs.reusable, .changed_at_ms = if (fact) |value| value.changed_at_ms else 0, .task = if (fact) |value| value.task else null };
}
pub fn less(_: void, left: Entry, right: Entry) bool {
    if (left.group != right.group) return @backingInt(left.group) < @backingInt(right.group);
    if (left.changed_at_ms != right.changed_at_ms) return left.changed_at_ms > right.changed_at_ms;
    return std.mem.order(u8, &left.agent.bytes, &right.agent.bytes) == .lt;
}
pub fn query(a: std.mem.Allocator, service: *runtime.Service, parent: id.ConversationId) ![]Entry {
    var rows: std.ArrayList(Entry) = .empty;
    errdefer rows.deinit(a);
    for (service.store.records.items) |record| if (record.child) |owned| if (owned.info.owning_parent_conversation.eql(parent)) {
        try rows.append(a, entry(service, record));
    };
    std.mem.sort(Entry, rows.items, {}, less);
    return rows.toOwnedSlice(a);
}
