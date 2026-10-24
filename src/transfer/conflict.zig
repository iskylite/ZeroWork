//! V0.1.4 conflict decisions for one frozen Intent. Memory only: the caller owns
//! real stat/exclusive-create/verified-replace IO and returns its exact receipt.
//! No decision here creates a Job, changes Manager state, or proves IO cleanup.
//! Returned slices borrow this Model until its next mutation; an asynchronous
//! consumer must copy a Check/Execution before enqueueing it on an IO owner.
const std = @import("std");
const identity = @import("../host/identity.zig");
const transfer = @import("manager.zig");
const local = @import("../local/fs_service.zig");
const remote = @import("../proto/ssh/sftp_readonly.zig");

pub const Endpoint = union(enum) {
    local_fs: local.EndpointRef,
    sftp: remote.EndpointRef,

    pub fn eql(a: Endpoint, b: Endpoint) bool {
        return std.meta.eql(a, b);
    }
};
pub const Metadata = struct {
    kind: enum { file, directory, symlink, other, unknown },
    size: ?u64 = null,
    modified_at: ?u64 = null,
};
/// A host-owned observed target version, not an invented remote inode. Reuse a
/// revision only while the same path's observed version is unchanged.
pub const TargetVersion = struct { revision: u64, metadata: Metadata };
pub const Observation = union(enum) { absent, present: TargetVersion };
pub const EntrySeed = struct {
    job: transfer.JobId,
    attempt: u32,
    source_path: []const u8,
    source_metadata: Metadata,
    target_path: []const u8,
};
pub const Intent = struct {
    id: u64,
    original_owner: identity.SessionHandle,
    resource_owner: identity.ResourceOwner,
    direction: transfer.Direction,
    source_endpoint: Endpoint,
    target_endpoint: Endpoint,
    entries: []const EntrySeed,
};
pub const Key = struct {
    intent_id: u64,
    owner: identity.ResourceOwner,
    original_owner: identity.SessionHandle,
    entry: u32,
    job: transfer.JobId,
    attempt: u32,
    revision: u64,
};
pub const Choice = enum { skip, save_as, keep_both, overwrite };
pub const Selection = struct { choice: ?Choice = null, rename: []const u8 = "", apply_to_remaining: bool = false };
pub const Phase = enum { unseen, waiting, checking, confirming, executing, deferred, completed };
pub const Issue = enum { target_changed, name_exists, invalid_name, io_failed };
pub const Prompt = struct {
    key: Key,
    direction: transfer.Direction,
    source_endpoint: Endpoint,
    target_endpoint: Endpoint,
    source_path: []const u8,
    source_metadata: Metadata,
    target_path: []const u8,
    target: Observation,
    selection: Selection,
    suggested_path: ?[]const u8,
    phase: Phase,
    issue: ?Issue,
};
pub const Check = struct {
    key: Key,
    id: u64,
    kind: enum { target_revalidate, candidate_stat },
    endpoint: Endpoint,
    path: []const u8,
};
pub const ConfirmationTicket = struct { intent_id: u64, owner: identity.ResourceOwner, id: u64 };
pub const OverwriteTarget = struct { key: Key, path: []const u8, version: TargetVersion };
pub const Confirmation = struct {
    ticket: ConfirmationTicket,
    original_owner: identity.SessionHandle,
    direction: transfer.Direction,
    endpoint: Endpoint,
    targets: []const OverwriteTarget,
};
pub const ExecutionTicket = struct { key: Key, id: u64 };
pub const Execution = struct {
    ticket: ExecutionTicket,
    direction: transfer.Direction,
    source_endpoint: Endpoint,
    target_endpoint: Endpoint,
    source_path: []const u8,
    target_path: []const u8,
    choice: Choice,
    /// Exclusive create must reject an existing destination. Verified replace
    /// must enforce this version again at the executor's real commit boundary;
    /// it must not delete the existing final file before data/close/verification.
    action: union(enum) { exclusive_create, replace_verified: TargetVersion },
};
pub const Completion = struct { key: Key, kind: enum { skipped, created, replaced }, actual_target_path: []const u8 };
pub const Next = union(enum) {
    waiting: Prompt,
    target_revalidate: Check,
    candidate_stat: Check,
    overwrite_confirmation: Confirmation,
    execute: Execution,
    completed: Completion,
    pause: Key,
};
pub const Receipt = union(enum) {
    created: []const u8,
    replaced,
    name_exists,
    target_changed: Observation,
    failed,
};

const Entry = struct {
    seed: EntrySeed,
    revision: u64 = 0,
    target: Observation = .absent,
    phase: Phase = .unseen,
    choice: ?Choice = null,
    rename: ?[]u8 = null,
    apply_remaining: bool = false,
    policy: ?Choice = null,
    approval: ?TargetVersion = null,
    candidate: ?[]u8 = null,
    ordinal: u16 = 1,
    check: ?Check = null,
    execution: ?Execution = null,
    completion: ?Completion = null,
    issue: ?Issue = null,
};
const PendingConfirmation = struct { value: Confirmation, targets: []OverwriteTarget, entry: usize, apply_remaining: bool };

pub const Model = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    intent: Intent,
    entries: []Entry,
    next_id: u64 = 1,
    confirmation: ?PendingConfirmation = null,

    /// Deep-copies all paths. Entries are the complete, immutable Intent plan;
    /// there is deliberately no append API for later Intents or new sources.
    pub fn init(allocator: std.mem.Allocator, intent: Intent) !Model {
        if (intent.id == 0 or @backingInt(intent.original_owner.session_id) == 0 or intent.original_owner.generation == 0) return error.InvalidIdentity;
        switch (intent.resource_owner) {
            .session => |owner| if (!owner.eql(intent.original_owner)) return error.OwnerMismatch,
            .retained_transfer => |retained_id| if (@backingInt(retained_id) == 0) return error.InvalidIdentity,
        }
        try validEndpoint(intent.source_endpoint, intent);
        try validEndpoint(intent.target_endpoint, intent);
        if (intent.direction == .upload and (intent.source_endpoint != .local_fs or intent.target_endpoint != .sftp)) return error.DirectionMismatch;
        if (intent.direction == .download and (intent.source_endpoint != .sftp or intent.target_endpoint != .local_fs)) return error.DirectionMismatch;
        if (intent.entries.len == 0 or intent.entries.len > 4096) return error.EntryLimit;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const seeds = try a.dupe(EntrySeed, intent.entries);
        const entries = try a.alloc(Entry, seeds.len);
        for (seeds, entries, 0..) |*seed, *entry, i| {
            if (seed.job == 0 or seed.attempt == 0) return error.InvalidIdentity;
            try validPath(seed.source_path);
            try validPath(seed.target_path);
            for (seeds[0..i]) |old| if (old.job == seed.job and old.attempt == seed.attempt and std.mem.eql(u8, old.source_path, seed.source_path)) return error.DuplicateEntry;
            seed.source_path = try a.dupe(u8, seed.source_path);
            seed.target_path = try a.dupe(u8, seed.target_path);
            entry.* = .{ .seed = seed.* };
        }
        var frozen = intent;
        frozen.entries = seeds;
        return .{ .allocator = allocator, .arena = arena, .intent = frozen, .entries = entries };
    }

    pub fn deinit(self: *Model) void {
        self.clearConfirmation();
        for (self.entries) |*entry| {
            if (entry.rename) |name| self.allocator.free(name);
            if (entry.candidate) |path| self.allocator.free(path);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    /// Only a real host stat result offers a conflict. New entries start with
    /// no selection unless this exact Intent's earlier explicit policy covers it.
    pub fn offer(self: *Model, index: usize, version: TargetVersion) !Prompt {
        if (index >= self.entries.len) return error.UnknownEntry;
        try validObservation(.{ .present = version });
        const entry = &self.entries[index];
        if (entry.phase == .executing) return error.ExecutionPending;
        if (entry.phase == .completed) return error.AlreadyResolved;
        if (entry.revision != 0 and observationEql(entry.target, .{ .present = version })) return self.prompt(index);
        if (entry.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        self.clearConfirmation();
        self.clearCandidate(entry);
        const first = entry.revision == 0;
        entry.revision += 1;
        entry.target = .{ .present = version };
        entry.phase = .waiting;
        entry.choice = if (first) entry.policy else null;
        entry.approval = null;
        entry.check = null;
        entry.issue = if (first) null else .target_changed;
        return self.prompt(index);
    }

    pub fn snapshot(self: *const Model, index: usize) !Prompt {
        if (index >= self.entries.len or self.entries[index].revision == 0) return error.UnknownEntry;
        return self.prompt(index);
    }

    /// Keeps even invalid rename input for correction. Validation happens before
    /// a Check/Execution can be emitted; a filename never changes the source.
    pub fn select(self: *Model, key: Key, selection: Selection) !void {
        const entry = try self.find(key);
        if (entry.phase == .executing) return error.ExecutionPending;
        if (entry.phase == .completed) return error.AlreadyResolved;
        if (self.confirmation != null) return error.ConfirmationPending;
        if (selection.rename.len > 4096) return error.InvalidName;
        const name = if (selection.rename.len > 0) try self.allocator.dupe(u8, selection.rename) else null;
        if (entry.rename) |old| self.allocator.free(old);
        entry.rename = name;
        entry.choice = selection.choice;
        entry.apply_remaining = selection.apply_to_remaining;
        entry.approval = null;
        entry.check = null;
        entry.issue = null;
        entry.phase = .waiting;
        self.clearCandidate(entry);
    }

    pub fn next(self: *Model, key: Key) !Next {
        const entry = try self.find(key);
        if (entry.phase == .executing) return error.ExecutionPending;
        if (entry.phase == .completed) return .{ .completed = entry.completion.? };
        if (entry.phase == .deferred) return .{ .pause = key };
        if (self.confirmation) |pending| {
            if (pending.entry == key.entry) return .{ .overwrite_confirmation = pending.value };
            return error.ConfirmationPending;
        }
        const choice = entry.choice orelse return error.NoSelection;
        if (choice == .save_as) validateName(if (entry.rename) |name| name else "") catch |err| {
            entry.issue = .invalid_name;
            return err;
        };
        if (entry.check) |check| return switch (check.kind) {
            .target_revalidate => .{ .target_revalidate = check },
            .candidate_stat => .{ .candidate_stat = check },
        };
        return .{ .target_revalidate = try self.checkFor(key.entry, .target_revalidate, entry.seed.target_path) };
    }

    /// A Check is exact-key, endpoint and raw-path scoped. Late responses cannot
    /// approve a newer prompt, attempt, binding, or another candidate name.
    pub fn observe(self: *Model, check: Check, actual: Observation) !Next {
        const entry = try self.find(check.key);
        const pending = entry.check orelse return error.StaleCheck;
        if (!checkEql(pending, check)) return error.StaleCheck;
        try validObservation(actual);
        entry.check = null;
        if (check.kind == .target_revalidate) {
            if (!observationEql(entry.target, actual)) return self.changed(check.key.entry, actual);
            const choice = entry.choice orelse return error.NoSelection;
            switch (choice) {
                .skip => {
                    self.applyPolicy(check.key.entry, choice);
                    entry.phase = .completed;
                    entry.completion = .{ .key = check.key, .kind = .skipped, .actual_target_path = entry.seed.target_path };
                    return .{ .completed = entry.completion.? };
                },
                .save_as, .keep_both => return self.candidateCheck(check.key.entry),
                .overwrite => {
                    if (actual != .present or actual.present.metadata.kind != .file) return error.UnsupportedOverwrite;
                    if (entry.approval) |approved| if (std.meta.eql(approved, actual.present)) return self.execute(check.key.entry, .{ .replace_verified = approved });
                    return self.confirmationFor(check.key.entry);
                },
            }
        }
        if (actual == .absent) return self.execute(check.key.entry, .exclusive_create);
        if (entry.choice == .keep_both) {
            try advanceOrdinal(entry);
            return self.candidateCheck(check.key.entry);
        }
        entry.phase = .waiting;
        entry.issue = .name_exists;
        return .{ .waiting = self.prompt(check.key.entry) };
    }

    /// Explicit second approval. The whole frozen set is validated before any
    /// approval is installed. Future/unseen targets get strategy only, no grant.
    pub fn confirmOverwrite(self: *Model, ticket: ConfirmationTicket) !void {
        const pending = self.confirmation orelse return error.StaleConfirmation;
        if (!std.meta.eql(ticket, pending.value.ticket)) return error.StaleConfirmation;
        for (pending.targets) |target| {
            const entry = try self.find(target.key);
            if (entry.phase == .executing or entry.phase == .completed or !observationEql(entry.target, .{ .present = target.version })) return error.StaleConfirmation;
        }
        for (pending.targets) |target| {
            const entry = &self.entries[target.key.entry];
            entry.choice = .overwrite;
            entry.approval = target.version;
            entry.phase = .waiting;
        }
        if (pending.apply_remaining) self.installPolicy(pending.entry, .overwrite);
        self.clearConfirmation();
    }

    pub fn returnToChoice(self: *Model, ticket: ConfirmationTicket) !Prompt {
        const pending = self.confirmation orelse return error.StaleConfirmation;
        if (!std.meta.eql(ticket, pending.value.ticket)) return error.StaleConfirmation;
        const index = pending.entry;
        self.entries[index].phase = .waiting;
        self.clearConfirmation();
        return self.prompt(index);
    }

    /// No transfer cancellation/delete is inferred from postponing a choice.
    pub fn deferConflict(self: *Model, key: Key) !Next {
        const entry = try self.find(key);
        if (entry.phase == .executing or entry.phase == .completed) return error.InvalidState;
        self.clearConfirmation();
        entry.check = null;
        entry.approval = null;
        entry.phase = .deferred;
        return .{ .pause = key };
    }

    /// The executor returns this exact ticket only after its actual operation.
    /// A name race cannot become overwrite; keep-both retries an exclusive name.
    pub fn finish(self: *Model, ticket: ExecutionTicket, receipt: Receipt) !Next {
        const entry = try self.find(ticket.key);
        const execution = entry.execution orelse return error.StaleExecution;
        if (entry.phase != .executing or !std.meta.eql(ticket, execution.ticket)) return error.StaleExecution;
        switch (receipt) {
            .created => |path| {
                if (execution.action != .exclusive_create or !std.mem.eql(u8, path, execution.target_path)) return error.ResultTargetMismatch;
                entry.completion = .{ .key = ticket.key, .kind = .created, .actual_target_path = execution.target_path };
            },
            .replaced => {
                if (execution.action != .replace_verified) return error.ResultTargetMismatch;
                entry.completion = .{ .key = ticket.key, .kind = .replaced, .actual_target_path = execution.target_path };
            },
            .name_exists => {
                if (execution.action != .exclusive_create) return error.ResultTargetMismatch;
                entry.execution = null;
                entry.phase = .waiting;
                if (entry.choice == .keep_both) {
                    try advanceOrdinal(entry);
                    return self.candidateCheck(ticket.key.entry);
                }
                entry.issue = .name_exists;
                return .{ .waiting = self.prompt(ticket.key.entry) };
            },
            .target_changed => |actual| {
                try validObservation(actual);
                entry.execution = null;
                return self.changed(ticket.key.entry, actual);
            },
            .failed => {
                entry.execution = null;
                entry.phase = .waiting;
                entry.issue = .io_failed;
                return .{ .waiting = self.prompt(ticket.key.entry) };
            },
        }
        entry.phase = .completed;
        entry.execution = null;
        return .{ .completed = entry.completion.? };
    }

    /// The engine calls this only before offering an entry, after real source
    /// fingerprinting. No existing decision or approval is silently retargeted.
    pub fn setUnseenSourceMetadata(self: *Model, index: usize, metadata: Metadata) !void {
        if (index >= self.entries.len) return error.UnknownEntry;
        if (self.entries[index].phase == .unseen) self.entries[index].seed.source_metadata = metadata;
    }

    /// An engine handoff may preserve this same frozen Intent's remaining
    /// strategy; it never preserves an overwrite grant or a save-as literal.
    pub fn inheritRemainingPolicy(self: *Model, choice: Choice) void {
        for (self.entries) |*entry| if (entry.phase == .unseen) {
            entry.policy = choice;
        };
    }
    pub fn remainingPolicy(self: *const Model) ?Choice {
        for (self.entries) |entry| if (entry.policy) |policy| return policy;
        return null;
    }
    pub fn finishUncontested(self: *Model, index: usize) !void {
        if (index >= self.entries.len) return error.UnknownEntry;
        const entry = &self.entries[index];
        if (entry.phase != .unseen) return error.InvalidState;
        entry.phase = .completed;
        entry.completion = .{ .key = self.keyFor(index), .kind = .created, .actual_target_path = entry.seed.target_path };
    }

    pub fn skippedCount(self: *const Model) usize {
        var count: usize = 0;
        for (self.entries) |entry| if (entry.completion) |done| if (done.kind == .skipped) {
            count += 1;
        };
        return count;
    }

    fn keyFor(self: *const Model, index: usize) Key {
        const entry = self.entries[index];
        return .{ .intent_id = self.intent.id, .owner = self.intent.resource_owner, .original_owner = self.intent.original_owner, .entry = @intCast(index), .job = entry.seed.job, .attempt = entry.seed.attempt, .revision = entry.revision };
    }
    fn find(self: *Model, key: Key) !*Entry {
        if (key.entry >= self.entries.len or !std.meta.eql(self.keyFor(key.entry), key) or key.revision == 0) return error.StaleConflict;
        return &self.entries[key.entry];
    }
    fn prompt(self: *const Model, index: usize) Prompt {
        const entry = self.entries[index];
        return .{ .key = self.keyFor(index), .direction = self.intent.direction, .source_endpoint = self.intent.source_endpoint, .target_endpoint = self.intent.target_endpoint, .source_path = entry.seed.source_path, .source_metadata = entry.seed.source_metadata, .target_path = entry.seed.target_path, .target = entry.target, .selection = .{ .choice = entry.choice, .rename = if (entry.rename) |name| name else "", .apply_to_remaining = entry.apply_remaining }, .suggested_path = entry.candidate, .phase = entry.phase, .issue = entry.issue };
    }
    fn id(self: *Model) !u64 {
        if (self.next_id == 0 or self.next_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        const result = self.next_id;
        self.next_id += 1;
        return result;
    }
    fn clearCandidate(self: *Model, entry: *Entry) void {
        if (entry.candidate) |path| self.allocator.free(path);
        entry.candidate = null;
        entry.ordinal = 1;
    }
    fn clearConfirmation(self: *Model) void {
        if (self.confirmation) |pending| {
            if (self.entries[pending.entry].phase == .confirming) self.entries[pending.entry].phase = .waiting;
            self.allocator.free(pending.targets);
        }
        self.confirmation = null;
    }
    fn checkFor(self: *Model, index: usize, kind: @FieldType(Check, "kind"), path: []const u8) !Check {
        const check: Check = .{ .key = self.keyFor(index), .id = try self.id(), .kind = kind, .endpoint = self.intent.target_endpoint, .path = path };
        self.entries[index].check = check;
        self.entries[index].phase = .checking;
        return check;
    }
    fn candidateCheck(self: *Model, index: usize) !Next {
        const entry = &self.entries[index];
        const check_id = try self.id();
        const name = if (entry.choice == .save_as) try self.allocator.dupe(u8, entry.rename.?) else try keepBothName(self.allocator, std.fs.path.basename(entry.seed.target_path), entry.ordinal);
        defer self.allocator.free(name);
        const path = try std.fs.path.join(self.allocator, &.{ std.fs.path.dirname(entry.seed.target_path).?, name });
        errdefer self.allocator.free(path);
        try validPath(path);
        if (entry.candidate) |old| self.allocator.free(old);
        entry.candidate = path;
        const check: Check = .{ .key = self.keyFor(index), .id = check_id, .kind = .candidate_stat, .endpoint = self.intent.target_endpoint, .path = path };
        entry.check = check;
        entry.phase = .checking;
        return .{ .candidate_stat = check };
    }
    fn execute(self: *Model, index: usize, action: @FieldType(Execution, "action")) !Next {
        const entry = &self.entries[index];
        const execution: Execution = .{ .ticket = .{ .key = self.keyFor(index), .id = try self.id() }, .direction = self.intent.direction, .source_endpoint = self.intent.source_endpoint, .target_endpoint = self.intent.target_endpoint, .source_path = entry.seed.source_path, .target_path = if (action == .exclusive_create) entry.candidate.? else entry.seed.target_path, .choice = entry.choice.?, .action = action };
        self.applyPolicy(index, entry.choice.?);
        entry.approval = null;
        entry.execution = execution;
        entry.phase = .executing;
        return .{ .execute = execution };
    }
    fn changed(self: *Model, index: usize, actual: Observation) !Next {
        const entry = &self.entries[index];
        if (entry.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        self.clearConfirmation();
        self.clearCandidate(entry);
        entry.revision += 1;
        entry.target = actual;
        entry.choice = null;
        entry.approval = null;
        entry.check = null;
        entry.phase = .waiting;
        entry.issue = .target_changed;
        return .{ .waiting = self.prompt(index) };
    }
    fn applyPolicy(self: *Model, index: usize, choice: Choice) void {
        if (self.entries[index].apply_remaining) self.installPolicy(index, choice);
    }
    fn installPolicy(self: *Model, index: usize, choice: Choice) void {
        for (self.entries, 0..) |*entry, i| {
            if (i == index or entry.phase == .completed or entry.phase == .executing) continue;
            entry.policy = choice;
            if (entry.phase == .waiting) {
                entry.choice = choice;
                if (choice == .save_as) {
                    if (entry.rename) |name| self.allocator.free(name);
                    entry.rename = null;
                }
            }
        }
    }
    fn confirmationFor(self: *Model, index: usize) !Next {
        const batch = self.entries[index].apply_remaining;
        var count: usize = 1;
        if (batch) for (self.entries, 0..) |entry, i| {
            if (i != index and entry.phase == .waiting and entry.target == .present and entry.target.present.metadata.kind == .file) count += 1;
        };
        const targets = try self.allocator.alloc(OverwriteTarget, count);
        errdefer self.allocator.free(targets);
        targets[0] = .{ .key = self.keyFor(index), .path = self.entries[index].seed.target_path, .version = self.entries[index].target.present };
        var at: usize = 1;
        if (batch) for (self.entries, 0..) |entry, i| {
            if (i == index or entry.phase != .waiting or entry.target != .present or entry.target.present.metadata.kind != .file) continue;
            targets[at] = .{ .key = self.keyFor(i), .path = entry.seed.target_path, .version = entry.target.present };
            at += 1;
        };
        const confirmation: Confirmation = .{ .ticket = .{ .intent_id = self.intent.id, .owner = self.intent.resource_owner, .id = try self.id() }, .original_owner = self.intent.original_owner, .direction = self.intent.direction, .endpoint = self.intent.target_endpoint, .targets = targets };
        self.confirmation = .{ .value = confirmation, .targets = targets, .entry = index, .apply_remaining = batch };
        self.entries[index].phase = .confirming;
        return .{ .overwrite_confirmation = confirmation };
    }
};

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
}
pub fn keepBothName(allocator: std.mem.Allocator, name: []const u8, ordinal: u16) ![]u8 {
    if (ordinal == 0 or ordinal > 9999) return error.CandidateLimit;
    const extension = if (name.len > 7 and std.ascii.eqlIgnoreCase(name[name.len - 7 ..], ".tar.gz")) name[name.len - 7 ..] else std.fs.path.extension(name);
    const result = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ name[0 .. name.len - extension.len], ordinal, extension });
    errdefer allocator.free(result);
    if (result.len > 255) return error.InvalidName;
    return result;
}
fn advanceOrdinal(entry: *Entry) !void {
    if (entry.ordinal == 9999) return error.CandidateLimit;
    entry.ordinal += 1;
}
fn validPath(path: []const u8) !void {
    if (path.len < 2 or path.len > 4096 or path[0] != '/' or path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}
fn validObservation(value: Observation) !void {
    if (value == .present and value.present.revision == 0) return error.InvalidTargetVersion;
}
fn observationEql(a: Observation, b: Observation) bool {
    return std.meta.eql(a, b);
}
fn checkEql(a: Check, b: Check) bool {
    return std.meta.eql(a.key, b.key) and a.id == b.id and a.kind == b.kind and a.endpoint.eql(b.endpoint) and std.mem.eql(u8, a.path, b.path);
}
fn validEndpoint(endpoint: Endpoint, intent: Intent) !void {
    switch (endpoint) {
        .local_fs => |value| {
            if (value.binding_id == 0 or value.binding_generation == 0) return error.InvalidBinding;
            if (value.resource_owner) |owner| if (!owner.eql(intent.resource_owner)) return error.OwnerMismatch;
        },
        .sftp => |value| {
            if (value.binding_id == 0 or value.binding_generation == 0) return error.InvalidBinding;
            if (!value.resource_owner.eql(intent.resource_owner)) return error.OwnerMismatch;
            if (value.origin_session) |owner| if (!owner.eql(intent.original_owner)) return error.OwnerMismatch;
        },
    }
}
