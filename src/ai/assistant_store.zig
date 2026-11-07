//! Per-owner conversation state. Session and group IDs are separate domains.
const std = @import("std");
const scope = @import("tool_scope.zig");
const cards = @import("card_stream.zig");
pub const ConversationId = @import("../host/identity.zig").ConversationId;
pub const ModelSelection = @import("provider_config.zig").ModelSelection;
pub const PermissionMode = @import("../config/config.zig").PermissionMode;
pub const Effort = @import("provider.zig").Effort;

/// Next-request overrides belong to one owner. Model IDs are owned independently
/// of saved configuration snapshots and UI callback payloads.
pub const Controls = struct {
    model: ?ModelSelection = null,
    permission: ?PermissionMode = null,
    execution_mode: ?@import("../config/config.zig").ExecutionMode = null,
    session_retention: ?@import("../config/config.zig").SessionRetention = null,
    effort: ?Effort = null,
    thinking: ?bool = null,

    /// Capture defaults once; later global edits belong to future agents.
    pub fn ensureDefaults(self: *Controls, ai: @import("../config/config.zig").Ai) void {
        if (self.permission == null) self.permission = ai.permission_mode;
        if (self.execution_mode == null) self.execution_mode = ai.execution_mode;
    }

    pub fn ensureEffort(self: *Controls, ai: @import("../config/config.zig").Ai) void {
        if (self.effort != null or self.thinking == false) return;
        self.effort = @import("provider_config.zig").lowestEffort(ai, self.model) catch null;
    }

    pub fn setModel(self: *Controls, allocator: std.mem.Allocator, key: ?ModelSelection) !void {
        var next: ?ModelSelection = null;
        if (key) |value| {
            const provider_id = try allocator.dupe(u8, value.provider_id);
            errdefer allocator.free(provider_id);
            const model_id = try allocator.dupe(u8, value.model_id);
            next = .{ .provider_id = provider_id, .model_id = model_id };
        }
        if (self.model) |previous| {
            allocator.free(previous.provider_id);
            allocator.free(previous.model_id);
        }
        self.model = next;
    }

    pub fn deinit(self: *Controls, allocator: std.mem.Allocator) void {
        if (self.model) |previous| {
            allocator.free(previous.provider_id);
            allocator.free(previous.model_id);
        }
        self.* = .{};
    }
};

pub const Message = struct {
    user: bool,
    turn: ?@import("conversation_turn.zig").Turn = null,
    text: []u8,
    wire_text: ?[]u8 = null,
    attachments: ?@import("local_text_attachments.zig").Bundle = null,
    images: ?@import("image_attachments.zig").Bundle = null,

    pub fn clone(self: *const Message, allocator: std.mem.Allocator) !Message {
        const text = try allocator.dupe(u8, self.text);
        errdefer allocator.free(text);
        const wire = if (self.wire_text) |value| try allocator.dupe(u8, value) else null;
        errdefer if (wire) |value| allocator.free(value);
        var attachments = if (self.attachments) |bundle| try bundle.retain() else null;
        errdefer if (attachments) |*bundle| bundle.deinit();
        var images = if (self.images) |bundle| try bundle.retain() else null;
        errdefer if (images) |*bundle| bundle.deinit();
        return .{ .user = self.user, .turn = if (self.turn) |*turn| try turn.clone(allocator) else null, .text = text, .wire_text = wire, .attachments = attachments, .images = images };
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.turn) |*turn| turn.deinit(allocator);
        allocator.free(self.text);
        if (self.wire_text) |wire| allocator.free(wire);
        if (self.attachments) |*bundle| bundle.deinit();
        if (self.images) |*bundle| bundle.deinit();
    }
};
pub const Phase = enum { idle, running, approval, done, failed, stopped };
pub const State = struct {
    title: @import("conversation_title.zig").Title = .{},
    phase: Phase = .idle,
    id: u64 = 0,
    conversation_id: ConversationId = .{},
    initial_owner: ?scope.Owner = null,
    binding_revision: u64 = 1,
    selected: bool = true,
    listed: bool = true,
    child_agent: ?@import("../host/identity.zig").AgentId = null,
    closed: bool = false,
    /// Ended entries remain in history, but are never automatically reopened
    /// when a terminal becomes independently visible again.
    ended: bool = false,
    historical_environment: bool = false,
    tool_results: ?@import("tool_results.zig").Store = null,
    owner: scope.Owner,
    history: std.ArrayList(Message) = .empty,
    wire_history: @import("wire_history.zig").History = .{},
    stream: cards.Stream,
    current_turn: @import("conversation_turn.zig").Turn = .{},
    last_user_text: ?[]u8 = null,
    last_user_wire: ?[]u8 = null,
    last_user_attachments: ?@import("local_text_attachments.zig").Bundle = null,
    last_user_images: ?@import("image_attachments.zig").Bundle = null,
    draft: ?[]u8 = null,
    model: @import("float_model.zig").Model = .{},
    controls: Controls = .{},
    /// A nonempty fallback also records that this conversation has already
    /// attempted its one automatic title request.
    pub fn beginTitle(self: *State, question: []const u8) bool {
        if (self.title.text() != null) return false;
        return self.title.set(question);
    }
    pub fn titleText(self: *const State, history: []const Message, last_user: ?[]const u8, scratch: *@import("conversation_title.zig").Title) ?[]const u8 {
        if (self.title.text()) |value| return value;
        for (history) |message| {
            if (message.user and scratch.set(message.text)) return scratch.text();
        }
        if (last_user) |value| if (scratch.set(value)) return scratch.text();
        return null;
    }
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.current_turn.deinit(allocator);
        for (self.history.items) |*message| message.deinit(allocator);
        self.history.deinit(allocator);
        self.wire_history.deinit();
        self.stream.deinit();
        if (self.tool_results) |*results| results.deinit();
        if (self.last_user_text) |text| allocator.free(text);
        if (self.last_user_wire) |text| allocator.free(text);
        if (self.last_user_attachments) |*bundle| bundle.deinit();
        if (self.last_user_images) |*bundle| bundle.deinit();
        if (self.draft) |text| allocator.free(text);
        self.controls.deinit(allocator);
    }
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    authority: ?*@import("session_runtime.zig").Service = null,
    states: std.ArrayList(State) = .empty,
    next_id: u64 = 1,
    attachment_ids: std.ArrayList(u64) = .empty,
    image_ids: std.ArrayList(u64) = .empty,
    /// Kept separately because the host moves/replaces State when switching
    /// presented owners. A picker ticket never points into the State array.
    attachment_drafts: std.ArrayList(*@import("local_text_attachments.zig").Draft) = .empty,
    image_drafts: std.ArrayList(*@import("image_attachments.zig").Draft) = .empty,
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Store) void {
        for (self.states.items) |*state| state.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.attachment_ids.deinit(self.allocator);
        self.image_ids.deinit(self.allocator);
        for (self.attachment_drafts.items) |draft| {
            draft.deinit();
            self.allocator.destroy(draft);
        }
        self.attachment_drafts.deinit(self.allocator);
        for (self.image_drafts.items) |draft| {
            draft.deinit();
            self.allocator.destroy(draft);
        }
        self.image_drafts.deinit(self.allocator);
    }
    pub fn find(self: *Store, id: u64) ?*State {
        for (self.states.items) |*state| if (state.id == id) return state;
        return null;
    }
    pub fn findConversation(self: *Store, id: ConversationId) ?*State {
        if (!id.valid()) return null;
        for (self.states.items) |*state| if (state.conversation_id.eql(id)) return state;
        return null;
    }
    /// The selected conversation's data is moved into the visible host.
    /// Background completion must resolve the request's original identity.
    pub fn wireHistoryFor(self: *Store, id: u64, displayed_id: ?u64, displayed: *@import("wire_history.zig").History) ?*@import("wire_history.zig").History {
        const state = self.find(id) orelse return null;
        if (displayed_id) |current| if (current == id) return displayed;
        return &state.wire_history;
    }
    pub fn select(self: *Store, id: u64) bool {
        const chosen = self.find(id) orelse return false;
        if (chosen.closed or chosen.ended or chosen.child_agent != null) return false;
        const owner = chosen.owner;
        for (self.states.items) |*state| {
            if (state.child_agent == null and state.owner.eql(owner)) state.selected = state.id == id;
        }
        return true;
    }
    pub fn create(self: *Store, owner: scope.Owner) !*State {
        const id = self.next_id;
        if (id == 0) return error.ConversationIdentityExhausted;
        try self.states.append(self.allocator, .{ .id = id, .conversation_id = ConversationId.generate(), .initial_owner = owner, .owner = owner, .stream = cards.Stream.init(self.allocator) });
        self.next_id = if (id == std.math.maxInt(u64)) 0 else id + 1;
        _ = self.select(id);
        return self.find(id).?;
    }
    pub fn createChildPresentation(self: *Store, record: *const @import("session_lifecycle.zig").Record, owner: scope.Owner) !*State {
        const info = (record.child orelse return error.ChildNotFound).info;
        if (self.findConversation(record.id)) |state| return state;
        const id = self.next_id;
        if (id == 0) return error.ConversationIdentityExhausted;
        try self.states.append(self.allocator, .{ .id = id, .conversation_id = record.id, .initial_owner = record.initial_origin, .owner = owner, .child_agent = info.agent, .selected = false, .listed = false, .ended = record.binding == null, .binding_revision = record.revision, .stream = cards.Stream.init(self.allocator) });
        self.next_id = if (id == std.math.maxInt(u64)) 0 else id + 1;
        return self.find(id).?;
    }
    pub fn get(self: *Store, owner: scope.Owner) !*State {
        // Presentation selection cannot replace a conversation still held by
        // this attachment. Reconcile a stale welcome against the live authority
        // before choosing which history to display; only End releases a binding.
        if (self.authority) |service| for (service.store.agents.items) |agent| {
            if (agent.role != .attached or agent.closing or !agent.owner.eql(owner)) continue;
            const id = agent.current orelse continue;
            const record = service.store.find(id) orelse continue;
            const binding = record.binding orelse continue;
            if (record.needs_recovery or !binding.agent.eql(agent.id) or !binding.owner.eql(owner)) continue;
            const state = self.findConversation(id) orelse continue;
            if (state.closed) continue;
            state.owner = owner;
            state.ended = false;
            state.binding_revision = record.revision;
            _ = self.select(state.id);
            return state;
        };
        if (self.active(owner)) |state| return state;
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            const state = &self.states.items[index];
            if (state.child_agent == null and state.owner.eql(owner) and !state.closed and !state.ended) {
                _ = self.select(state.id);
                return &self.states.items[index];
            }
        }
        const state = try self.create(owner);
        state.listed = false;
        return state;
    }
    pub fn active(self: *Store, owner: scope.Owner) ?*State {
        for (self.states.items) |*state| if (state.child_agent == null and state.owner.eql(owner) and state.selected and !state.closed and !state.ended) return state;
        return null;
    }
    pub fn endActivity(self: *Store, id: u64, revision: u64) !void {
        const state = self.find(id) orelse return error.ConversationNotFound;
        if (state.closed or state.ended or !state.selected or state.binding_revision != revision) return error.BindingChanged;
        var next = try @import("../host/identity.zig").advance(revision);
        if (self.authority) |service| if (service.store.find(state.conversation_id)) |record| {
            if (record.binding != null) {
                const ticket = try service.store.fence(record.id);
                const operation = if (record.ending) |ending| ending.operation else @import("../host/identity.zig").HostOperationId.generate();
                try service.endConversation(ticket, operation);
                if (record.binding != null) return error.ResourceCleanupPending;
            }
            next = record.revision;
        };
        state.binding_revision = next;
        state.selected = false;
        state.ended = true;
        state.listed = true;
        state.phase = .stopped;
        state.model.visible = false;
    }
    pub const Handoff = struct { id: ConversationId, runtime_id: u64, from: scope.Owner, to: scope.Owner, revision: u64, next_revision: u64 };
    /// Reserve/validate before a controller publishes the group. This plan has
    /// no borrowed State pointer and commits without allocation or cloning data.
    pub fn prepareHandoff(self: *Store, id: ConversationId, from: scope.Owner, revision: u64, group_id: u64) !Handoff {
        const state = self.findConversation(id) orelse return error.ConversationNotFound;
        if (state.child_agent != null or state.closed or state.ended or !state.owner.eql(from) or state.binding_revision != revision) return error.BindingChanged;
        if (from != .session or group_id == 0) return error.InvalidBindingHandoff;
        if (self.authority) |service| if (service.store.hasBoundChildren(id)) return error.ChildSettlementRequired;
        for (self.states.items) |other| if (other.child_agent == null and !other.closed and other.owner.eql(.{ .group = group_id })) return error.BindingConflict;
        return .{ .id = id, .runtime_id = state.id, .from = from, .to = .{ .group = group_id }, .revision = revision, .next_revision = try @import("../host/identity.zig").advance(revision) };
    }
    pub fn commitHandoff(self: *Store, plan: Handoff) !void {
        const state = self.findConversation(plan.id) orelse return error.ConversationNotFound;
        if (state.child_agent != null or state.id != plan.runtime_id or state.closed or state.ended or !state.owner.eql(plan.from) or state.binding_revision != plan.revision) return error.BindingChanged;
        if (plan.from != .session or plan.to != .group or plan.to.group == 0 or plan.next_revision != try @import("../host/identity.zig").advance(plan.revision)) return error.InvalidBindingHandoff;
        for (self.states.items) |other| if (other.child_agent == null and !other.closed and other.owner.eql(plan.to)) return error.BindingConflict;
        if (self.authority) |service| if (service.store.find(plan.id)) |record| {
            const ticket = try service.store.fence(record.id);
            if (ticket.binding != plan.revision) return error.BindingChanged;
            const committed = try service.handoff(ticket, plan.to);
            if (committed.binding != plan.next_revision) return error.BindingChanged;
        };
        if (state.initial_owner == null) state.initial_owner = plan.from;
        state.owner = plan.to;
        state.binding_revision = plan.next_revision;
        state.selected = true;
        if (self.attachmentDraftFor(state.id)) |draft| draft.owner = plan.to;
        if (self.imageDraftFor(state.id)) |draft| draft.owner = plan.to;
    }
    pub fn attachmentDraftForTicket(self: *Store, ticket: @import("local_text_attachments.zig").Ticket) ?*@import("local_text_attachments.zig").Draft {
        if (ticket.conversation_id) |id| {
            const state = self.findConversation(id) orelse return null;
            if (state.closed or state.ended) return null;
            return self.attachmentDraftFor(state.id);
        }
        return null;
    }
    pub fn imageDraftForTicket(self: *Store, ticket: @import("image_attachments.zig").Ticket) ?*@import("image_attachments.zig").Draft {
        if (ticket.conversation_id) |id| {
            const state = self.findConversation(id) orelse return null;
            if (state.closed or state.ended) return null;
            return self.imageDraftFor(state.id);
        }
        return null;
    }
    pub fn remove(self: *Store, id: u64) void {
        if (self.authority) |service| if (self.find(id)) |state| if (service.store.find(state.conversation_id)) |record| {
            if (record.binding != null or record.ending != null) return;
            service.store.remove(record.id) catch return;
        };
        var i: usize = self.attachment_ids.items.len;
        while (i > 0) {
            i -= 1;
            if (self.attachment_ids.items[i] == id) {
                const draft = self.attachment_drafts.items[i];
                draft.deinit();
                self.allocator.destroy(draft);
                _ = self.attachment_ids.orderedRemove(i);
                _ = self.attachment_drafts.orderedRemove(i);
            }
        }
        i = self.image_ids.items.len;
        while (i > 0) {
            i -= 1;
            if (self.image_ids.items[i] == id) {
                const draft = self.image_drafts.items[i];
                draft.deinit();
                self.allocator.destroy(draft);
                _ = self.image_ids.orderedRemove(i);
                _ = self.image_drafts.orderedRemove(i);
            }
        }
        for (self.states.items, 0..) |*state, index| if (state.id == id) {
            state.deinit(self.allocator);
            _ = self.states.orderedRemove(index);
            return;
        };
    }
    pub fn imageDraftFor(self: *Store, id: u64) ?*@import("image_attachments.zig").Draft {
        for (self.image_ids.items, self.image_drafts.items) |conversation, draft| if (conversation == id) return draft;
        return null;
    }
    pub fn attachmentDraftFor(self: *Store, id: u64) ?*@import("local_text_attachments.zig").Draft {
        for (self.attachment_ids.items, self.attachment_drafts.items) |conversation, draft| if (conversation == id) return draft;
        return null;
    }
    pub fn imageDraft(self: *Store, owner: scope.Owner) !*@import("image_attachments.zig").Draft {
        return self.imageDraftForState((try self.get(owner)).id);
    }
    pub fn imageDraftForState(self: *Store, id: u64) !*@import("image_attachments.zig").Draft {
        const owner = (self.find(id) orelse return error.ConversationNotFound).owner;
        for (self.image_drafts.items, self.image_ids.items) |draft, conversation| if (conversation == id) return draft;
        try self.image_ids.ensureUnusedCapacity(self.allocator, 1);
        const Draft = @import("image_attachments.zig").Draft;
        var initial = try Draft.init(self.allocator, owner);
        initial.conversation_id = self.find(id).?.conversation_id;
        errdefer initial.deinit();
        const draft = try self.allocator.create(Draft);
        errdefer self.allocator.destroy(draft);
        draft.* = initial;
        try self.image_drafts.append(self.allocator, draft);
        self.image_ids.appendAssumeCapacity(id);
        return draft;
    }
    pub fn attachmentDraft(self: *Store, owner: scope.Owner) !*@import("local_text_attachments.zig").Draft {
        return self.attachmentDraftForState((try self.get(owner)).id);
    }
    pub fn attachmentDraftForState(self: *Store, id: u64) !*@import("local_text_attachments.zig").Draft {
        const owner = (self.find(id) orelse return error.ConversationNotFound).owner;
        for (self.attachment_drafts.items, self.attachment_ids.items) |draft, conversation| if (conversation == id) return draft;
        try self.attachment_ids.ensureUnusedCapacity(self.allocator, 1);
        const Draft = @import("local_text_attachments.zig").Draft;
        var initial = try Draft.init(self.allocator, owner);
        initial.conversation_id = self.find(id).?.conversation_id;
        errdefer initial.deinit();
        const draft = try self.allocator.create(Draft);
        errdefer self.allocator.destroy(draft);
        draft.* = initial;
        try self.attachment_drafts.append(self.allocator, draft);
        self.attachment_ids.appendAssumeCapacity(id);
        return draft;
    }
};

test "conversation selection follows the live binding instead of a stale single-connection welcome" {
    const a = std.testing.allocator;
    var service = @import("session_runtime.zig").Service.init(a);
    defer service.deinit();
    var store = Store.init(a);
    defer store.deinit();
    store.authority = &service;
    const owner: scope.Owner = .{ .session = 1 };
    const agent = try service.store.attach(owner);
    const ticket = try service.store.create(agent.id);
    const original = try store.create(owner);
    const original_id = original.id;
    original.conversation_id = ticket.conversation;
    // Model a stale presentation flag and a newly selected empty welcome.
    original.ended = true;
    const welcome_id = (try store.create(owner)).id;
    const selected = try store.get(owner);
    try std.testing.expectEqual(original_id, selected.id);
    try std.testing.expect(selected.selected and !selected.ended);
    try std.testing.expect(!store.find(welcome_id).?.selected);
    try std.testing.expectEqual(ticket.binding, selected.binding_revision);
    try std.testing.expect((try service.store.fence(ticket.conversation)).eql(ticket));
    const operation = @import("../host/identity.zig").HostOperationId.generate();
    _ = try service.store.beginEnd(ticket, operation);
    try service.store.commitEnd(ticket, operation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
    selected.ended = true;
    selected.selected = false;
    try std.testing.expectEqual(welcome_id, (try store.get(owner)).id);
}

test "conversation title stays fixed after followups and uses the first question as fallback" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const state = try store.create(.{ .session = 1 });
    try std.testing.expect(state.beginTitle("帮我排查 nginx 启动失败"));
    try std.testing.expect(!state.beginTitle("继续"));
    try std.testing.expectEqualStrings("帮我排查 nginx 启动失败", state.title.text().?);
    var scratch: @import("conversation_title.zig").Title = .{};
    const history = [_]Message{
        .{ .user = false, .text = @constCast("assistant") },
        .{ .user = true, .text = @constCast("第一条实际问题") },
        .{ .user = true, .text = @constCast("好的") },
    };
    const untitled = try store.create(.{ .session = 1 });
    try std.testing.expectEqualStrings("第一条实际问题", untitled.titleText(&history, "继续", &scratch).?);
    try std.testing.expect(untitled.titleText(&.{}, null, &scratch) == null);
}

test "same numeric session and group IDs retain separate conversations" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const session = try store.get(.{ .session = 7 });
    _ = try session.stream.append(.{ .text = "session answer" });
    const group = try store.get(.{ .group = 7 });
    try std.testing.expectEqual(@as(usize, 0), group.stream.count());
    _ = try group.stream.append(.{ .text = "group answer" });
    try std.testing.expectEqualStrings("session answer", (try store.get(.{ .session = 7 })).stream.cards.items[0].text);
}

test "stable conversation identity isolates equal UI counters across windows and restart" {
    var first = Store.init(std.testing.allocator);
    defer first.deinit();
    var second = Store.init(std.testing.allocator);
    defer second.deinit();
    const first_state = try first.create(.{ .session = 7 });
    const id = first_state.conversation_id;
    const other = try second.create(.{ .session = 7 });
    try std.testing.expectEqual(first_state.id, other.id);
    try std.testing.expect(id.valid() and other.conversation_id.valid());
    try std.testing.expect(!id.eql(other.conversation_id));
    try std.testing.expect(first.findConversation(other.conversation_id) == null);
    try std.testing.expect(second.findConversation(id) == null);
    const ui_id = first_state.id;
    _ = try first.create(.{ .session = 7 });
    try std.testing.expect(first.select(ui_id));
    try std.testing.expect(first.findConversation(id).?.conversation_id.eql(id));
    first.remove(ui_id);
    try std.testing.expect(first.findConversation(id) == null);
    var restarted = Store.init(std.testing.allocator);
    defer restarted.deinit();
    const fresh = try restarted.create(.{ .session = 7 });
    try std.testing.expectEqual(ui_id, fresh.id);
    try std.testing.expect(!fresh.conversation_id.eql(id));
    restarted.next_id = std.math.maxInt(u64);
    _ = try restarted.create(.{ .session = 7 });
    try std.testing.expectError(error.ConversationIdentityExhausted, restarted.create(.{ .session = 7 }));
}

test "conversation handoff preserves history controls drafts and pending tickets without cloning" {
    const a = std.testing.allocator;
    const attachments = @import("local_text_attachments.zig");
    var store = Store.init(a);
    defer store.deinit();
    const owner: scope.Owner = .{ .session = 7 };
    const state = try store.create(owner);
    const id = state.conversation_id;
    const runtime_id = state.id;
    state.draft = try a.dupe(u8, "未发送的草稿");
    state.controls.permission = .auto;
    try state.history.append(a, .{ .user = true, .text = try a.dupe(u8, "原会话历史") });
    const files = try store.attachmentDraft(owner);
    const file_ticket = try files.begin();
    const images = try store.imageDraft(owner);
    const image_ticket = try images.begin("/captured.png", .{});
    const plan = try store.prepareHandoff(id, owner, 1, 9);
    try store.commitHandoff(plan);
    const moved = store.findConversation(id).?;
    try std.testing.expectEqual(runtime_id, moved.id);
    try std.testing.expectEqual(@as(u64, 9), moved.owner.group);
    try std.testing.expect(moved.initial_owner.?.eql(owner));
    try std.testing.expectEqualStrings("未发送的草稿", moved.draft.?);
    try std.testing.expectEqualStrings("原会话历史", moved.history.items[0].text);
    try std.testing.expectEqual(PermissionMode.auto, moved.controls.permission.?);
    try std.testing.expectEqual(files, store.attachmentDraftForTicket(file_ticket).?);
    var content = try attachments.ContentRef.create(a, "/captured.txt", "late reader content", 0);
    defer content.release();
    _ = try store.attachmentDraftForTicket(file_ticket).?.complete(file_ticket, &content);
    try std.testing.expect(store.imageDraftForTicket(image_ticket).?.fail(image_ticket, error.Cancelled));
    try std.testing.expectEqualStrings("late reader content", files.items.items[0].reference.content().?.bytes);
    const standalone = try store.get(owner);
    try std.testing.expect(!standalone.conversation_id.eql(id));
    const other_files = try store.attachmentDraft(owner);
    const other_ticket = try other_files.begin();
    try std.testing.expect(!other_files.contains(file_ticket));
    try std.testing.expect(!file_ticket.eql(other_ticket));
    try std.testing.expectEqual(@as(usize, 0), other_files.items.items.len);
    var historical = try files.freeze();
    defer historical.deinit();
    try std.testing.expectError(error.StaleAttachmentBundle, other_files.restore(&historical));
    try other_files.restoreHistory(&historical);
    try std.testing.expectEqualStrings("late reader content", other_files.items.items[0].reference.content().?.bytes);
    try std.testing.expect(other_files.conversation_id.?.eql(standalone.conversation_id));
    try std.testing.expect(!other_files.contains(file_ticket) and !other_files.contains(other_ticket));
    try std.testing.expect(store.find(runtime_id).?.owner == .group);
    try std.testing.expectError(error.BindingChanged, store.commitHandoff(plan));
    try std.testing.expectError(error.InvalidBindingHandoff, store.prepareHandoff(id, .{ .group = 9 }, 2, 10));
    // Deleted conversations cannot be recreated by an old picker/reader ticket.
    store.remove(runtime_id);
    try std.testing.expect(store.attachmentDraftForTicket(file_ticket) == null);
    try std.testing.expect(store.imageDraftForTicket(image_ticket) == null);
}

test "owner controls own callback model strings and keep session and group overrides separate" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var provider_id = [_]u8{ 'l', 'a', 'b' };
    var model_id = [_]u8{ 'o', 'p', 's' };
    const first = try store.get(.{ .session = 7 });
    try first.controls.setModel(store.allocator, .{ .provider_id = &provider_id, .model_id = &model_id });
    first.controls.permission = .auto;
    first.controls.effort = .high;
    @memset(&provider_id, 'x');
    @memset(&model_id, 'x');
    const grouped = try store.get(.{ .group = 7 });
    try std.testing.expect(grouped.controls.model == null and grouped.controls.permission == null and grouped.controls.effort == null);
    try grouped.controls.setModel(store.allocator, .{ .provider_id = "local", .model_id = "quiet" });
    grouped.controls.permission = .confirm;
    grouped.controls.effort = .low;
    _ = try store.get(.{ .session = 8 });
    const restored = &(try store.get(.{ .session = 7 })).controls;
    try std.testing.expectEqualStrings("lab", restored.model.?.provider_id);
    try std.testing.expectEqualStrings("ops", restored.model.?.model_id);
    try std.testing.expectEqual(PermissionMode.auto, restored.permission.?);
    try std.testing.expectEqual(Effort.high, restored.effort.?);
    const group_restored = &(try store.get(.{ .group = 7 })).controls;
    try std.testing.expectEqualStrings("quiet", group_restored.model.?.model_id);
    try std.testing.expectEqual(PermissionMode.confirm, group_restored.permission.?);
    try std.testing.expectEqual(Effort.low, group_restored.effort.?);
}

test "owner controls initialize lowest effort and inherit it across models and providers" {
    const allocator = std.testing.allocator;
    var models = [_]@import("../config/config.zig").AiModel{
        .{ .id = "first", .context_window = 8192, .reasoning = true, .efforts = .{ false, true, true, false, false, false, false } },
        .{ .id = "second", .context_window = 8192, .reasoning = true, .efforts = .{ true, false, true, false, false, false, false } },
        .{ .id = "quiet", .context_window = 8192, .reasoning = false, .efforts = @splat(false) },
    };
    var providers = [_]@import("../config/config.zig").AiProvider{
        .{ .name = "one", .enabled = true, .model_count = models.len, .models = &models },
        .{ .name = "two", .enabled = true, .model_count = models.len, .models = &models },
    };
    const ai: @import("../config/config.zig").Ai = .{ .default_provider = "one", .provider_count = providers.len, .providers = &providers };
    var controls: Controls = .{};
    defer controls.deinit(allocator);
    controls.ensureEffort(ai);
    try std.testing.expectEqual(Effort.medium, controls.effort.?);
    try controls.setModel(allocator, .{ .provider_id = "two", .model_id = "second" });
    controls.ensureEffort(ai);
    try std.testing.expectEqual(Effort.medium, controls.effort.?);
    try std.testing.expectError(error.UnsupportedEffort, @import("provider_config.zig").validateEffort(ai, controls.model, controls.effort.?));
    controls.effort = .high;
    try controls.setModel(allocator, .{ .provider_id = "one", .model_id = "quiet" });
    controls.ensureEffort(ai);
    try std.testing.expectEqual(Effort.high, controls.effort.?);
    try controls.setModel(allocator, .{ .provider_id = "two", .model_id = "second" });
    controls.ensureEffort(ai);
    try std.testing.expectEqual(Effort.high, controls.effort.?);
    controls.effort = null;
    controls.ensureEffort(ai);
    try std.testing.expectEqual(Effort.low, controls.effort.?);
    controls.effort = null;
    controls.thinking = false;
    controls.ensureEffort(ai);
    try std.testing.expect(controls.effort == null);
    controls.thinking = null;
    models[1].efforts = @splat(false);
    controls.ensureEffort(ai);
    try std.testing.expect(controls.effort == null);
    models[1].efforts[5] = true;
    controls.ensureEffort(ai);
    try std.testing.expectEqual(Effort.none, controls.effort.?);
}

test "owner controls model replacement keeps prior state on allocation failure and supports reset" {
    const allocator = std.testing.allocator;
    var controls: Controls = .{ .permission = .auto, .effort = .medium };
    defer controls.deinit(allocator);
    try controls.setModel(allocator, .{ .provider_id = "lab", .model_id = "old" });
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, controls.setModel(failing.allocator(), .{ .provider_id = "other", .model_id = "new" }));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expect(controls.model.?.eql(.{ .provider_id = "lab", .model_id = "old" }));
    // Reusing the current borrowed key must copy before freeing its strings.
    try controls.setModel(allocator, controls.model);
    try std.testing.expectEqualStrings("old", controls.model.?.model_id);
    try controls.setModel(allocator, null);
    try std.testing.expect(controls.model == null);
    try std.testing.expectEqual(PermissionMode.auto, controls.permission.?);
    try std.testing.expectEqual(Effort.medium, controls.effort.?);
}

test "multiple AI conversations remain isolated within one tab and close by identity" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first = try store.get(.{ .session = 1 });
    const id = first.id;
    _ = try first.stream.append(.{ .text = "first answer" });
    const second_id = (try store.create(.{ .session = 1 })).id;
    try std.testing.expect(second_id != id);
    try std.testing.expectEqual(@as(usize, 0), (try store.get(.{ .session = 1 })).stream.count());
    try std.testing.expect(store.select(id));
    try std.testing.expectEqualStrings("first answer", (try store.get(.{ .session = 1 })).stream.cards.items[0].text);
    store.remove(second_id);
    try std.testing.expect(store.find(second_id) == null);
    try std.testing.expectEqual(id, (try store.get(.{ .session = 1 })).id);
}

test "implicit conversation stays out of list and deletion restores a surviving conversation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const initial = (try store.get(.{ .session = 1 })).id;
    try std.testing.expect(!store.find(initial).?.listed);
    const second = (try store.create(.{ .session = 1 })).id;
    store.find(second).?.closed = true;
    store.find(second).?.selected = false;
    try std.testing.expectEqual(initial, (try store.get(.{ .session = 1 })).id);
    store.remove(second);
    try std.testing.expectEqual(@as(usize, 1), store.states.items.len);
}

test "wire history conversation identity isolates background completion and fresh sessions" {
    const WireHistory = @import("wire_history.zig").History;
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    const first_id = (try store.create(.{ .session = 7 })).id;
    var displayed = try WireHistory.copy(a, &.{.{ .content = "first conversation" }}, "answer");
    defer displayed.deinit();
    // Model the real host's move when another conversation becomes visible.
    store.find(first_id).?.wire_history = displayed;
    displayed = .{};
    const next_id = (try store.create(.{ .session = 7 })).id;
    try std.testing.expectEqual(@as(usize, 0), store.wireHistoryFor(next_id, next_id, &displayed).?.messages.len);
    const background = store.wireHistoryFor(first_id, next_id, &displayed).?;
    try std.testing.expect(background != &displayed);
    background.deinit();
    background.* = try WireHistory.copy(a, &.{.{ .content = "original request result" }}, "background final answer");
    try std.testing.expectEqual(@as(usize, 0), displayed.messages.len);
    try std.testing.expectEqualStrings("background final answer", store.find(first_id).?.wire_history.messages[1].content);
    try std.testing.expect(store.select(first_id));
    displayed = store.find(first_id).?.wire_history;
    store.find(first_id).?.wire_history = .{};
    try std.testing.expectEqualStrings("original request result", store.wireHistoryFor(first_id, first_id, &displayed).?.messages[0].content);
    const group_id = (try store.create(.{ .group = 7 })).id;
    try std.testing.expectEqual(@as(usize, 0), store.wireHistoryFor(group_id, first_id, &displayed).?.messages.len);
    store.remove(next_id);
    try std.testing.expect(store.wireHistoryFor(next_id, first_id, &displayed) == null);
}
