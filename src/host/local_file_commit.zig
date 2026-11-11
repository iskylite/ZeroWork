//! Managed Local write transactions. Both Local entry points must share this
//! backend and the same authoritative request-key journal.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("local_path.zig");
const reads = @import("local_file_reads.zig");
const changes = @import("local_file_changes.zig");
const metadata = @import("local_file_metadata.zig");
const OperationId = @import("identity.zig").HostOperationId;
const Identity = @import("local_workspace.zig").Identity;
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Digest = [Sha256.digest_length]u8;
pub const Diff = changes.Diff;
pub const text_limit = 512 * 1024;
pub const Kind = enum { create, replace, edit };
pub const Edit = struct { old_text: []const u8, new_text: []const u8 };
pub const Request = struct {
    kind: Kind,
    text: []const u8 = "",
    expected_version: ?[]const u8 = null,
    edits: []const Edit = &.{},
    create_parents: bool = false,
};
const Material = struct {
    bytes: []const u8,
    state: reads.FileState,
    version: reads.Version,
    metadata_hash: Digest,
};
pub const Prepared = struct {
    target: *const path.Resolved,
    kind: Kind,
    before: ?Material,
    after: []const u8,
    diff: Diff,
    candidate_hash: Digest,
    evidence_hash: Digest,
};
pub const Recovery = struct {
    parent_identity: Identity,
    stage_name: [stage_name_len]u8,
    stage_identity: Identity,
    candidate_identity: Identity,
    // "entry" is the actual replaced item after a swap. "submitted" is
    // the immutable bytes staged before dispatch, independent of target IO.
};
pub const ParentChainEvidence = struct {
    plan: path.ParentPlan,
    /// Identity of each empty directory staged before dispatch. The named
    /// directory must match this identity before it can become a parent.
    identities: [path.max_create_parents]?Identity = @splat(null),

    pub fn validate(self: ParentChainEvidence, absolute: []const u8, device: u64) !void {
        try self.plan.validate(absolute);
        for (self.identities, 0..) |identity, index| {
            if (index < self.plan.count) {
                const id = identity orelse return error.InvalidParentCreationPlan;
                if (id.device != device or id.inode == 0) return error.InvalidParentCreationPlan;
                for (self.identities[0..index]) |earlier| {
                    if (std.meta.eql(id, earlier.?)) return error.InvalidParentCreationPlan;
                }
            } else if (identity != null) return error.InvalidParentCreationPlan;
        }
    }
};

pub const Evidence = struct {
    operation_ref: OperationId,
    target: []const u8,
    request_path: []const u8,
    base_directory: ?[]const u8,
    source: path.Source,
    workspace_revision: ?u64,
    kind: Kind,
    approved_version: ?reads.Version,
    evidence_hash: Digest,
    candidate_hash: Digest,
    candidate_version: reads.Version,
    candidate_metadata_hash: Digest,
    recovery: Recovery,
    reserved_bytes: usize,
    parent_chain: ?ParentChainEvidence = null,
    approved_diff_hash: ?Digest = null,
};
pub const Status = enum { rejected, partial, verified, committed_unverified, unknown };
pub const DiffRef = struct {
    kind: enum { approved, actual },
    digest: Digest,

    fn name(self: DiffRef) []const u8 {
        return switch (self.kind) {
            .approved => "approved-diff.json",
            .actual => "actual-diff.json",
        };
    }
};
pub const Receipt = struct {
    operation_ref: OperationId,
    status: Status = .rejected,
    side_effect_started: bool = false,
    committed: bool = false,
    verified: bool = false,
    conflict: bool = false,
    actual_before_version: ?reads.Version = null,
    submitted_after_version: ?reads.Version = null,
    recovery: ?Recovery = null,
    diff: ?Diff = null,
    diff_ref: ?DiffRef = null,
    reason: ?anyerror = null,
    journal_outcome_unknown: bool = false,
    created_parent_count: u8 = 0,
};
pub const Journal = struct {
    context: *anyopaque,
    /// Reserve recovery quota and persist the frozen evidence in the original
    /// operation record. The caller claims its request key before resolution.
    prepare: *const fn (*anyopaque, Evidence) anyerror!void,
    /// Persist dispatch intent. A crash after this point needs read-only
    /// reconciliation of this same operation, even if rename never ran.
    dispatch: *const fn (*anyopaque, OperationId) anyerror!void,
    /// Persist each successful directory publication before the next effect.
    progress: ?*const fn (*anyopaque, OperationId, u8) anyerror!void = null,
    finish: *const fn (*anyopaque, Receipt) anyerror!void,
};
pub const Gate = struct {
    context: *anyopaque,
    /// Recheck approval, live authority, cancellation and workspace
    /// dependency. A successful dispatch check is the authorization boundary.
    validate: *const fn (*anyopaque, *const Prepared) anyerror!void,
    /// Await an approval if the live mode becomes stricter after preflight.
    wait_for_approval: ?*const fn (*anyopaque) anyerror!void = null,
};
const stage_prefix = path.recovery_prefix;
const stage_suffix = path.recovery_suffix;
const stage_name_len = stage_prefix.len + 32 + stage_suffix.len;
var writes: std.Io.Mutex = .init;

fn digest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

fn validText(text: []const u8) !void {
    if (text.len > text_limit) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null)
        return error.UnsupportedTextEncoding;
}

/// The caller keeps the verified target and arena alive through approval and
/// commit. Preparing only reads the filesystem.
pub fn prepare(a: std.mem.Allocator, io: std.Io, target: *const path.Resolved, request: Request) !Prepared {
    if (comptime builtin.os.tag != .macos) return error.AtomicReplaceUnsupported;
    if (request.create_parents and request.kind != .create) return error.InvalidParentCreationPath;
    if (target.parent_plan != null and !request.create_parents) return error.ParentDirectoryNotFound;
    if (target.mode != (if (request.kind == .create) path.Mode.create else path.Mode.file)) return error.InvalidFileTarget;
    try target.revalidate(io);
    if (request.kind == .create and target.target_identity != null) return error.PathAlreadyExists;
    if (request.kind == .create and request.expected_version != null) return error.InvalidExpectedVersion;
    if (request.kind != .edit and request.edits.len != 0) return error.InvalidEdits;
    if (request.kind == .edit and request.text.len != 0) return error.InvalidEdits;

    const before = if (request.kind == .create) null else blk: {
        const expected = request.expected_version orelse return error.ExpectedVersionRequired;
        try reads.validateVersion(expected);
        const current = try snapshot(a, io, target.parent, target.basename, target.target_identity, true);
        try validText(current.bytes);
        try checkOriginal(current.state.stat);
        if (!std.mem.eql(u8, &current.version, expected)) return error.SourceChanged;
        break :blk current;
    };
    const after = if (request.kind == .edit)
        try edited(a, before.?.bytes, request.edits)
    else blk: {
        try validText(request.text);
        break :blk try a.dupe(u8, request.text);
    };
    const candidate_hash = digest(after);
    // JSON length-delimits data including literal path quotes and newlines.
    const evidence = try std.json.Stringify.valueAlloc(a, .{
        .target = target.absolute,
        .source = target.source,
        .base = target.base_directory,
        .workspace_revision = target.workspace_revision,
        .parent = target.parent_identity,
        .parent_plan = target.parent_plan,
        .kind = request.kind,
        .before = if (before) |value| value.version else null,
        .metadata = if (before) |value| value.metadata_hash else null,
        .candidate = candidate_hash,
    }, .{});
    defer a.free(evidence);
    return .{
        .target = target,
        .kind = request.kind,
        .before = before,
        .after = after,
        .diff = try changes.between(a, if (before) |value| value.bytes else "", after),
        .candidate_hash = candidate_hash,
        .evidence_hash = digest(evidence),
    };
}

fn edited(a: std.mem.Allocator, before: []const u8, edits: []const Edit) ![]const u8 {
    if (edits.len == 0 or edits.len > 128) return error.InvalidEdits;
    const Match = struct {
        start: usize,
        end: usize,
        text: []const u8,

        fn less(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.start < rhs.start;
        }
    };
    var matches: [128]Match = undefined;
    var removed: usize = 0;
    var added: usize = 0;
    for (edits, 0..) |edit, i| {
        if (edit.old_text.len == 0) return error.EmptyMatch;
        try validText(edit.old_text);
        try validText(edit.new_text);
        const start = std.mem.indexOf(u8, before, edit.old_text) orelse return error.MatchNotFound;
        if (std.mem.indexOfPos(u8, before, start + 1, edit.old_text) != null) return error.AmbiguousMatch;
        const end = start + edit.old_text.len;
        matches[i] = .{ .start = start, .end = end, .text = edit.new_text };
        removed += edit.old_text.len;
        added += edit.new_text.len;
    }
    const ordered = matches[0..edits.len];
    std.mem.sort(Match, ordered, {}, Match.less);
    var previous: usize = 0;
    for (ordered) |match| {
        if (match.start < previous) return error.OverlappingEdits;
        previous = match.end;
    }
    const total = before.len - removed + added;
    if (total > text_limit) return error.FileTooLarge;
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    var start: usize = 0;
    for (ordered) |match| {
        try writer.writer.writeAll(before[start..match.start]);
        try writer.writer.writeAll(match.text);
        start = match.end;
    }
    try writer.writer.writeAll(before[start..]);
    const after = try writer.toOwnedSlice();
    errdefer a.free(after);
    try validText(after);
    return after;
}

fn checkOriginal(stat: std.Io.File.Stat) !void {
    if (stat.nlink != 1) return error.HardlinkUnsupported;
    if (@backingInt(stat.permissions) & 0o7000 != 0) return error.SpecialPermissionsUnsupported;
}

fn entryStat(dir: std.Io.Dir, name: [:0]const u8) !std.c.Stat {
    var st: std.c.Stat = undefined;
    const rc = std.c.fstatat(dir.handle, name.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW);
    return switch (std.c.errno(rc)) {
        .SUCCESS => st,
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        else => error.FileStatFailed,
    };
}

fn openEntry(dir: std.Io.Dir, name: [:0]const u8, expected: ?Identity, writable: bool) !std.Io.File {
    const named = try entryStat(dir, name);
    if (named.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
    const before = Identity.fromStat(named);
    if (expected) |id| if (!std.meta.eql(before, id)) return error.SourceChanged;
    const fd = while (true) {
        const result = std.c.openat(dir.handle, name.ptr, .{
            .ACCMODE = if (writable) .RDWR else .RDONLY,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
            .NOCTTY = true,
        });
        switch (std.c.errno(result)) {
            .SUCCESS => break result,
            .INTR => continue,
            .NOENT, .LOOP => return error.SourceChanged,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.FileOpenFailed,
        }
    };
    errdefer _ = std.c.close(fd);
    var held: std.c.Stat = undefined;
    if (std.c.fstat(fd, &held) != 0 or held.mode & std.c.S.IFMT != std.c.S.IFREG or
        !std.meta.eql(before, Identity.fromStat(held))) return error.SourceChanged;
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

fn snapshot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, base: []const u8, expected: ?Identity, writable: bool) !Material {
    const name = try a.dupeSentinel(u8, base, 0);
    defer a.free(name);
    const file = try openEntry(dir, name, expected, writable);
    defer file.close(io);
    const before = try reads.fileState(file, io);
    const metadata_hash = try metadata.fingerprint(a, file);
    if (before.stat.size > text_limit) return error.FileTooLarge;
    const bytes = try a.alloc(u8, @intCast(before.stat.size));
    errdefer a.free(bytes);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = try file.readPositional(io, &.{bytes[used..]}, used);
        if (n == 0) return error.SourceChanged;
        used += n;
    }
    const after = try reads.fileState(file, io);
    const named = try entryStat(dir, name);
    const named_stat = std.Io.Threaded.statFromPosix(&named);
    if (!before.unchanged(after) or !std.meta.eql(after.identity, Identity.fromStat(named)) or
        named_stat.kind != .file or named_stat.size != after.stat.size or
        named_stat.mtime.nanoseconds != after.stat.mtime.nanoseconds or
        named_stat.ctime.nanoseconds != after.stat.ctime.nanoseconds) return error.SourceChanged;
    return .{ .bytes = bytes, .state = after, .version = reads.version(after, bytes), .metadata_hash = metadata_hash };
}

fn checkCurrent(a: std.mem.Allocator, io: std.Io, proposal: *const Prepared) !void {
    const target = proposal.target;
    try target.revalidate(io);
    if (proposal.before) |before| {
        const current = try snapshot(a, io, target.parent, target.basename, target.target_identity, true);
        defer a.free(current.bytes);
        try checkOriginal(current.state.stat);
        if (!std.mem.eql(u8, &current.version, &before.version) or
            !std.mem.eql(u8, &current.metadata_hash, &before.metadata_hash)) return error.SourceChanged;
    }
}

pub fn stageName(operation: OperationId) [stage_name_len]u8 {
    return stage_prefix.* ++ std.fmt.bytesToHex(operation.bytes, .lower) ++ stage_suffix.*;
}

pub fn syncDir(dir: std.Io.Dir) !void {
    while (true) {
        const rc = std.c.fsync(dir.handle);
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.RecoverySyncFailed,
        }
    }
}

fn renameEntry(from: std.Io.Dir, name: [:0]const u8, to: std.Io.Dir, new_name: [:0]const u8, kind: Kind) !void {
    const rc = std.c.renameatx_np(from.handle, name.ptr, to.handle, new_name.ptr, if (kind == .create) .{ .EXCL = true } else .{ .SWAP = true });
    return switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .EXIST, .NOTEMPTY => error.PathAlreadyExists,
        .NOENT, .NOTDIR, .ISDIR, .LOOP => error.SourceChanged,
        .XDEV, .OPNOTSUPP, .NOSYS, .INVAL => if (kind == .create) error.AtomicCreateUnsupported else error.AtomicReplaceUnsupported,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        // Filesystem/network errors may leave the syscall outcome uncertain.
        else => error.CommitOutcomeUnknown,
    };
}

fn writeFile(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = @fromBackingInt(0o600) });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
    try file.sync(io);
}

const Rename = *const fn (std.Io.Dir, [:0]const u8, std.Io.Dir, [:0]const u8, Kind) anyerror!void;
const TestHooks = struct {
    rename: Rename = renameEntry,
    after_last_check: ?*const fn (*anyopaque, std.Io, *const Prepared) anyerror!void = null,
    context: ?*anyopaque = null,
};

fn probe(io: std.Io, stage: std.Io.Dir, kind: Kind, rename: Rename) !void {
    try writeFile(io, stage, "probe-source", "from");
    defer stage.deleteFile(io, "probe-source") catch {};
    defer stage.deleteFile(io, "probe-destination") catch {};
    if (kind != .create) try writeFile(io, stage, "probe-destination", "to");
    try rename(stage, "probe-source", stage, "probe-destination", kind);
}

fn retainAndFinish(journal: Journal, receipt: Receipt) Receipt {
    journal.finish(journal.context, receipt) catch |err| {
        var uncertain = receipt;
        uncertain.status = .unknown;
        uncertain.journal_outcome_unknown = true;
        uncertain.reason = receipt.reason orelse err;
        return uncertain;
    };
    return receipt;
}

fn rejected(journal: Journal, receipt: Receipt, err: anyerror) Receipt {
    var result = receipt;
    if (result.created_parent_count != 0 and result.status == .rejected) result.status = .partial;
    result.reason = err;
    return retainAndFinish(journal, result);
}

fn stagedParentName(index: usize) [9:0]u8 {
    var name = "parent-00".*;
    name[7] = @intCast('0' + index / 10);
    name[8] = @intCast('0' + index % 10);
    return name;
}

fn checkNamedDirectory(dir: std.Io.Dir, name: [:0]const u8, identity: Identity) !void {
    const current = try entryStat(dir, name);
    if (current.mode & std.c.S.IFMT != std.c.S.IFDIR or
        !std.meta.eql(Identity.fromStat(current), identity)) return error.SourceChanged;
}

fn prepareParents(io: std.Io, stage: std.Io.Dir, target: *const path.Resolved) !?ParentChainEvidence {
    const plan = target.parent_plan orelse return null;
    var chain: ParentChainEvidence = .{ .plan = plan };
    for (0..plan.count) |index| {
        const name = stagedParentName(index);
        try stage.createDir(io, &name, @fromBackingInt(0o755));
        const dir = try stage.openDir(io, &name, .{ .follow_symlinks = false });
        defer dir.close(io);
        chain.identities[index] = try Identity.of(dir);
        try checkNamedDirectory(stage, &name, chain.identities[index].?);
        try syncDir(dir);
    }
    try chain.validate(target.absolute, target.parent_identity.device);
    return chain;
}

const OpenedParent = struct {
    dir: std.Io.Dir,
    owned: bool = false,

    fn close(self: OpenedParent, io: std.Io) void {
        if (self.owned) self.dir.close(io);
    }
};

/// Never follow links for a newly published component. Capture the directory
/// handle before passing it to the next rename, and check its exact identity.
fn openPublishedParent(io: std.Io, ancestor: std.Io.Dir, absolute: []const u8, chain: ?ParentChainEvidence, count: u8, matched: *u8) !OpenedParent {
    var result: OpenedParent = .{ .dir = ancestor };
    errdefer result.close(io);
    const planned = chain orelse return result;
    for (0..count) |index| {
        const part = planned.plan.component(absolute, index);
        var name: [std.Io.Dir.max_name_bytes:0]u8 = undefined;
        @memcpy(name[0..part.len], part);
        name[part.len] = 0;
        try checkNamedDirectory(result.dir, name[0..part.len :0], planned.identities[index].?);
        const next = try result.dir.openDir(io, part, .{ .follow_symlinks = false });
        result.close(io);
        result = .{ .dir = next, .owned = true };
        if (!std.meta.eql(try Identity.of(next), planned.identities[index].?)) return error.SourceChanged;
        matched.* += 1;
    }
    return result;
}

fn publishParent(io: std.Io, target: *const path.Resolved, chain: ParentChainEvidence, stage: std.Io.Dir, receipt: *Receipt, rename: Rename) !void {
    const index = receipt.created_parent_count;
    const staged_name = stagedParentName(index);
    try target.revalidateParent(io);
    var matched: u8 = 0;
    const parent = try openPublishedParent(io, target.parent, target.absolute, chain, index, &matched);
    defer parent.close(io);
    const part = chain.plan.component(target.absolute, index);
    var name: [std.Io.Dir.max_name_bytes:0]u8 = undefined;
    @memcpy(name[0..part.len], part);
    name[part.len] = 0;
    const staged_dir = try stage.openDir(io, &staged_name, .{ .follow_symlinks = false, .iterate = true });
    defer staged_dir.close(io);
    if (!std.meta.eql(try Identity.of(staged_dir), chain.identities[index].?)) return error.SourceChanged;
    var entries = staged_dir.iterate();
    if (try entries.next(io) != null) return error.RecoveryMaterialChanged;
    try checkNamedDirectory(stage, &staged_name, chain.identities[index].?);
    try rename(stage, &staged_name, parent.dir, name[0..part.len :0], .create);
    receipt.created_parent_count += 1;
    receipt.side_effect_started = true;
    try syncDir(stage);
    try syncDir(parent.dir);
}

/// Returns false when the lock was dropped. The caller must recheck the
/// staging and destination before trying the final gate again.
fn validateOrWait(io: std.Io, gate: Gate, proposal: *const Prepared, locked: *bool) !bool {
    gate.validate(gate.context, proposal) catch |err| {
        if (err != error.ToolApprovalRequired) return err;
        const wait = gate.wait_for_approval orelse return err;
        writes.unlock(io);
        locked.* = false;
        try wait(gate.context);
        try writes.lock(io);
        locked.* = true;
        return false;
    };
    return true;
}

/// Preserve staging from the moment a journal callback may reference it.
/// Pre-dispatch errors leave the destination untouched. No path is written
/// again after the syscall, even when verification fails.
pub fn commit(a: std.mem.Allocator, io: std.Io, proposal: *const Prepared, operation: OperationId, journal: Journal, gate: Gate) !Receipt {
    return commitImpl(a, io, proposal, operation, journal, gate, .{});
}

fn commitImpl(a: std.mem.Allocator, io: std.Io, proposal: *const Prepared, operation: OperationId, journal: Journal, gate: Gate, hooks: TestHooks) !Receipt {
    if (comptime builtin.os.tag != .macos) return error.AtomicReplaceUnsupported;
    if (!operation.valid()) return error.InvalidIdentity;
    const target = proposal.target;
    if (target.parent_plan != null and journal.progress == null) return error.ParentProgressUnavailable;
    const name = try a.dupeSentinel(u8, target.basename, 0);
    defer a.free(name);
    try writes.lock(io);
    var locked = true;
    defer if (locked) writes.unlock(io);
    while (!try validateOrWait(io, gate, proposal, &locked)) {}
    try checkCurrent(a, io, proposal);

    const stage_name = stageName(operation);
    try target.parent.createDir(io, &stage_name, @fromBackingInt(0o700));
    const stage = try target.parent.openDir(io, &stage_name, .{ .follow_symlinks = false });
    defer stage.close(io);
    const stage_identity = try Identity.of(stage);
    var native: std.c.Stat = undefined;
    if (std.c.fstat(stage.handle, &native) != 0 or native.uid != std.c.geteuid() or
        native.mode & 0o777 != 0o700 or stage_identity.device != target.parent_identity.device) return error.InvalidRecoveryDirectory;
    var keep = false;
    defer if (!keep) {
        // Only remove names in the held staging directory. Never recursively
        // remove a directory that may have been moved into its place.
        stage.deleteFile(io, "submitted") catch {};
        stage.deleteFile(io, "entry") catch {};
        stage.deleteFile(io, "approved-diff.json") catch {};
        if (target.parent_plan) |plan| {
            for (0..plan.count) |index| stage.deleteDir(io, &stagedParentName(index)) catch {};
        }
        if (checkStage(target.parent, &stage_name, stage_identity)) |_|
            target.parent.deleteDir(io, &stage_name) catch {}
        else |_| {}
    };
    try metadata.requirePrivateDirectory(stage);
    try probe(io, stage, proposal.kind, hooks.rename);

    const staged = try stage.createFile(io, "entry", .{ .exclusive = true, .permissions = @fromBackingInt(0o600) });
    defer staged.close(io);
    if (proposal.before) |before| {
        const original = try openEntry(target.parent, name, target.target_identity, true);
        defer original.close(io);
        if (!std.mem.eql(u8, &(try metadata.fingerprint(a, original)), &before.metadata_hash)) return error.SourceChanged;
        if (std.c.fcopyfile(original.handle, staged.handle, null, .{ .ACL = true, .STAT = true, .XATTR = true }) != 0)
            return error.MetadataPreservationFailed;
    }
    try staged.writePositionalAll(io, proposal.after, 0);
    try staged.setLength(io, proposal.after.len);
    try staged.sync(io);
    const candidate = try snapshot(a, io, stage, "entry", null, false);
    defer a.free(candidate.bytes);
    if (!std.mem.eql(u8, candidate.bytes, proposal.after)) return error.VerificationFailed;
    if (proposal.before) |before| {
        if (!std.mem.eql(u8, &candidate.metadata_hash, &before.metadata_hash)) return error.MetadataPreservationFailed;
    }
    try writeFile(io, stage, "submitted", proposal.after);
    const diff_bytes = try std.json.Stringify.valueAlloc(a, proposal.diff, .{});
    defer a.free(diff_bytes);
    try writeFile(io, stage, "approved-diff.json", diff_bytes);
    const parent_chain = try prepareParents(io, stage, target);
    try syncDir(stage);
    try syncDir(target.parent);

    const recovery: Recovery = .{
        .parent_identity = target.parent_identity,
        .stage_name = stage_name,
        .stage_identity = stage_identity,
        .candidate_identity = candidate.state.identity,
    };
    const evidence: Evidence = .{
        .operation_ref = operation,
        .target = target.absolute,
        .request_path = target.requested,
        .base_directory = target.base_directory,
        .source = target.source,
        .workspace_revision = target.workspace_revision,
        .kind = proposal.kind,
        .approved_version = if (proposal.before) |before| before.version else null,
        .evidence_hash = proposal.evidence_hash,
        .candidate_hash = proposal.candidate_hash,
        .candidate_version = candidate.version,
        .candidate_metadata_hash = candidate.metadata_hash,
        .recovery = recovery,
        .parent_chain = parent_chain,
        .approved_diff_hash = digest(diff_bytes),
        .reserved_bytes = proposal.after.len + diff_bytes.len +
            @max(proposal.after.len, if (proposal.before) |before| before.bytes.len else 0) +
            (if (proposal.before != null) @as(usize, changes.max_encoded_bytes) else 0) +
            (if (parent_chain) |chain| @as(usize, chain.plan.count) * 4096 else 0),
    };
    var receipt: Receipt = .{ .operation_ref = operation, .recovery = recovery };
    keep = true;
    journal.prepare(journal.context, evidence) catch |err| {
        if (err == error.RecoveryQuotaExceeded) {
            keep = false;
            receipt.recovery = null;
            receipt.reason = err;
            return receipt;
        }
        receipt.status = .unknown;
        receipt.journal_outcome_unknown = true;
        receipt.reason = err;
        return receipt;
    };
    journal.dispatch(journal.context, operation) catch |err| {
        return rejected(journal, receipt, err);
    };
    while (true) {
        checkStage(target.parent, &stage_name, stage_identity) catch |err| return rejected(journal, receipt, err);
        const current_staged = snapshot(a, io, stage, "entry", recovery.candidate_identity, false) catch |err|
            return rejected(journal, receipt, err);
        defer a.free(current_staged.bytes);
        if (!std.mem.eql(u8, &current_staged.version, &candidate.version) or
            !std.mem.eql(u8, &current_staged.metadata_hash, &candidate.metadata_hash))
            return rejected(journal, receipt, error.SourceChanged);
        checkCurrent(a, io, proposal) catch |err| return rejected(journal, receipt, err);
        const approved = validateOrWait(io, gate, proposal, &locked) catch |err| return rejected(journal, receipt, err);
        if (approved) break;
    }
    if (hooks.after_last_check) |run| run(hooks.context.?, io, proposal) catch |err| return rejected(journal, receipt, err);

    if (parent_chain) |chain| {
        for (0..chain.plan.count) |_| {
            checkStage(target.parent, &stage_name, stage_identity) catch |err| return rejected(journal, receipt, err);
            publishParent(io, target, chain, stage, &receipt, hooks.rename) catch |err| {
                if (err == error.CommitOutcomeUnknown) {
                    receipt.side_effect_started = true;
                    receipt.status = .unknown;
                }
                return rejected(journal, receipt, err);
            };
            journal.progress.?(journal.context, operation, receipt.created_parent_count) catch |err|
                return rejected(journal, receipt, err);
        }
        // The last progress append can block. Recheck the names and anchor
        // before allowing the final exclusive file rename.
        target.revalidateParent(io) catch |err| return rejected(journal, receipt, err);
        checkStage(target.parent, &stage_name, stage_identity) catch |err| return rejected(journal, receipt, err);
        const final_candidate = snapshot(a, io, stage, "entry", recovery.candidate_identity, false) catch |err|
            return rejected(journal, receipt, err);
        defer a.free(final_candidate.bytes);
        if (!std.mem.eql(u8, &final_candidate.version, &candidate.version) or
            !std.mem.eql(u8, &final_candidate.metadata_hash, &candidate.metadata_hash))
            return rejected(journal, receipt, error.SourceChanged);
    }
    var matched: u8 = 0;
    const destination = openPublishedParent(io, target.parent, target.absolute, parent_chain, receipt.created_parent_count, &matched) catch |err|
        return rejected(journal, receipt, err);
    defer destination.close(io);
    hooks.rename(stage, "entry", destination.dir, name, proposal.kind) catch |err| {
        if (err == error.CommitOutcomeUnknown) {
            receipt.side_effect_started = true;
            receipt.status = .unknown;
            receipt.reason = err;
            return retainAndFinish(journal, receipt);
        }
        return rejected(journal, receipt, err);
    };
    receipt.side_effect_started = true;
    receipt.committed = true;
    receipt.status = .committed_unverified;
    // The submitted version describes our candidate, independent of anything
    // an external editor does after the syscall.
    receipt.submitted_after_version = candidate.version;
    verifyCommit(a, io, stage, proposal, candidate, parent_chain, destination.dir, &receipt) catch |err| {
        receipt.reason = err;
        if (receipt.diff) |actual_diff| {
            receipt.diff_ref = persistConflictDiff(a, io, stage, actual_diff) catch null;
            // The original item and submitted bytes still support inspection.
            if (receipt.diff_ref == null) receipt.diff = null;
        }
        return retainAndFinish(journal, receipt);
    };
    receipt.status = .verified;
    receipt.verified = true;
    receipt.diff = proposal.diff;
    receipt.diff_ref = .{ .kind = .approved, .digest = evidence.approved_diff_hash.? };
    return retainAndFinish(journal, receipt);
}

fn checkStage(parent: std.Io.Dir, stage_name: []const u8, expected: Identity) !void {
    var name: [stage_name_len:0]u8 = undefined;
    name[stage_name_len] = 0;
    @memcpy(name[0..stage_name_len], stage_name);
    const named = try entryStat(parent, &name);
    if (named.mode & std.c.S.IFMT != std.c.S.IFDIR or !std.meta.eql(Identity.fromStat(named), expected))
        return error.RecoveryDirectoryChanged;
}

fn verifyCommit(a: std.mem.Allocator, io: std.Io, stage: std.Io.Dir, proposal: *const Prepared, candidate: Material, parent_chain: ?ParentChainEvidence, destination: std.Io.Dir, receipt: *Receipt) !void {
    const target = proposal.target;
    try syncDir(stage);
    try syncDir(destination);
    if (proposal.before) |before| {
        const different_inode = if (entryStat(stage, "entry")) |named|
            !std.meta.eql(Identity.fromStat(named), before.state.identity)
        else |_|
            false;
        const displaced = snapshot(a, io, stage, "entry", null, false) catch |err| {
            receipt.conflict = different_inode or knownIdentityConflict(err);
            return err;
        };
        defer a.free(displaced.bytes);
        receipt.actual_before_version = displaced.version;
        if (!std.mem.eql(u8, &displaced.version, &before.version) or
            !std.mem.eql(u8, &displaced.metadata_hash, &before.metadata_hash))
        {
            receipt.conflict = true;
            if (validText(displaced.bytes)) |_| {
                receipt.diff = try conflictDiff(a, displaced.bytes, proposal.after);
            } else |_| {}
            return error.ConcurrentModification;
        }
    }
    receipt.diff = proposal.diff;
    target.revalidateParent(io) catch |err| {
        receipt.conflict = knownIdentityConflict(err);
        return err;
    };
    var matched: u8 = 0;
    const parent = openPublishedParent(io, target.parent, target.absolute, parent_chain, receipt.created_parent_count, &matched) catch |err| {
        receipt.conflict = knownIdentityConflict(err);
        return err;
    };
    defer parent.close(io);
    const current = snapshot(a, io, parent.dir, target.basename, candidate.state.identity, false) catch |err| {
        receipt.conflict = knownIdentityConflict(err);
        return err;
    };
    defer a.free(current.bytes);
    if (!std.mem.eql(u8, &current.version, &candidate.version) or
        !std.mem.eql(u8, &current.metadata_hash, &candidate.metadata_hash))
    {
        receipt.conflict = true;
        return error.ConcurrentModification;
    }
}

fn knownIdentityConflict(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.FileTooLarge, error.NotRegularFile, error.SourceChanged, error.DirectoryChanged => true,
        else => false,
    };
}

fn conflictDiff(a: std.mem.Allocator, before: []const u8, after: []const u8) !Diff {
    var diff = try changes.between(a, before, after);
    const lines = try a.dupe(changes.Line, diff.lines);
    a.free(diff.lines);
    errdefer a.free(lines);
    var copied: usize = 0;
    errdefer for (lines[0..copied]) |line| {
        if (line.kind == .remove) a.free(line.text);
    };
    for (lines) |*line| {
        if (line.kind == .remove) line.text = try a.dupe(u8, line.text);
        copied += 1;
    }
    diff.lines = lines;
    return diff;
}

fn persistConflictDiff(a: std.mem.Allocator, io: std.Io, stage: std.Io.Dir, diff: Diff) !DiffRef {
    const encoded = try std.json.Stringify.valueAlloc(a, diff, .{});
    defer a.free(encoded);
    try writeFile(io, stage, "actual-diff.json", encoded);
    try syncDir(stage);
    return .{ .kind = .actual, .digest = digest(encoded) };
}

pub const Observation = struct {
    target_version: ?reads.Version = null,
    candidate_matches: bool = false,
    candidate_payload_preserved: bool = false,
    staged_entry_version: ?reads.Version = null,
    staged_entry_is_candidate: bool = false,
    target_error: ?anyerror = null,
    staged_entry_error: ?anyerror = null,
    candidate_payload_error: ?anyerror = null,
    matching_parent_count: u8 = 0,
};

/// Reconcile the original operation by observation only. Matching bytes or
/// identities describe the observed files and do not update the commit fact.
pub fn observe(a: std.mem.Allocator, io: std.Io, evidence: Evidence) !Observation {
    if (comptime builtin.os.tag != .macos) return error.AtomicReplaceUnsupported;
    const anchor = try openRecoveryAnchor(io, evidence);
    defer anchor.close(io);
    var observed: Observation = .{};
    const count = if (evidence.parent_chain) |chain| chain.plan.count else 0;
    if (openPublishedParent(io, anchor, evidence.target, evidence.parent_chain, count, &observed.matching_parent_count)) |parent| {
        defer parent.close(io);
        if (snapshot(a, io, parent.dir, std.fs.path.basename(evidence.target), null, false)) |current| {
            defer a.free(current.bytes);
            observed.target_version = current.version;
            observed.candidate_matches = std.meta.eql(current.state.identity, evidence.recovery.candidate_identity) and
                std.mem.eql(u8, &current.version, &evidence.candidate_version) and
                std.mem.eql(u8, &current.metadata_hash, &evidence.candidate_metadata_hash);
        } else |err| observed.target_error = err;
    } else |err| observed.target_error = err;
    const stage = openRecoveryStage(io, anchor, evidence.recovery) catch |err| {
        observed.staged_entry_error = err;
        observed.candidate_payload_error = err;
        return observed;
    };
    defer stage.close(io);
    if (snapshot(a, io, stage, "entry", null, false)) |entry| {
        defer a.free(entry.bytes);
        observed.staged_entry_version = entry.version;
        observed.staged_entry_is_candidate = std.meta.eql(entry.state.identity, evidence.recovery.candidate_identity);
    } else |err| observed.staged_entry_error = err;
    if (snapshot(a, io, stage, "submitted", null, false)) |payload| {
        defer a.free(payload.bytes);
        observed.candidate_payload_preserved = std.mem.eql(u8, &digest(payload.bytes), &evidence.candidate_hash);
    } else |err| observed.candidate_payload_error = err;
    return observed;
}

fn openRecoveryAnchor(io: std.Io, evidence: Evidence) !std.Io.Dir {
    if (!std.mem.eql(u8, &stageName(evidence.operation_ref), &evidence.recovery.stage_name)) return error.InvalidRecoveryReference;
    const dir_name = if (evidence.parent_chain) |chain| block: {
        try chain.validate(evidence.target, evidence.recovery.parent_identity.device);
        break :block chain.plan.prefix(evidence.target);
    } else std.fs.path.dirname(evidence.target) orelse return error.InvalidRecoveryReference;
    const parent = try std.Io.Dir.openDirAbsolute(io, dir_name, .{ .follow_symlinks = false });
    errdefer parent.close(io);
    if (!std.meta.eql(try Identity.of(parent), evidence.recovery.parent_identity)) return error.SourceChanged;
    return parent;
}

fn openRecoveryStage(io: std.Io, parent: std.Io.Dir, recovery: Recovery) !std.Io.Dir {
    const stage = parent.openDir(io, &recovery.stage_name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.ChangeContentExpired,
        else => return err,
    };
    errdefer stage.close(io);
    if (!std.meta.eql(try Identity.of(stage), recovery.stage_identity)) return error.RecoveryDirectoryChanged;
    return stage;
}

fn openRecovery(io: std.Io, evidence: Evidence) !struct { parent: std.Io.Dir, stage: std.Io.Dir } {
    const parent = try openRecoveryAnchor(io, evidence);
    errdefer parent.close(io);
    return .{ .parent = parent, .stage = try openRecoveryStage(io, parent, evidence.recovery) };
}

pub fn readDiff(a: std.mem.Allocator, io: std.Io, evidence: Evidence, ref: DiffRef) !std.json.Parsed(Diff) {
    const dirs = try openRecovery(io, evidence);
    defer dirs.parent.close(io);
    defer dirs.stage.close(io);
    const file = snapshot(a, io, dirs.stage, ref.name(), null, false) catch |err| switch (err) {
        error.FileNotFound => return error.ChangeContentExpired,
        else => return err,
    };
    defer a.free(file.bytes);
    if (!std.mem.eql(u8, &digest(file.bytes), &ref.digest)) return error.RecoveryMaterialChanged;
    return std.json.parseFromSlice(Diff, a, file.bytes, .{ .allocate = .alloc_always });
}

/// Remove the recovery materials of a verified commit after history release.
pub fn expireRecovery(io: std.Io, evidence: Evidence) !void {
    return expireRecoveryLayout(io, evidence, .verified);
}

/// The journal has durably recorded rejection before any destination effect.
/// The candidate and any planned parent directories are still staged.
pub fn expireRejectedRecovery(io: std.Io, evidence: Evidence) !void {
    return expireRecoveryLayout(io, evidence, .rejected);
}

fn expireRecoveryLayout(io: std.Io, evidence: Evidence, layout: enum { verified, rejected }) !void {
    const dirs = openRecovery(io, evidence) catch |err| switch (err) {
        error.ChangeContentExpired => return,
        else => return err,
    };
    defer dirs.parent.close(io);
    defer dirs.stage.close(io);
    var native: std.c.Stat = undefined;
    if (std.c.fstat(dirs.stage.handle, &native) != 0 or native.uid != std.c.geteuid() or
        native.mode & 0o777 != 0o700) return error.InvalidRecoveryDirectory;
    try metadata.requirePrivateDirectory(dirs.stage);
    const names: []const [:0]const u8 = if (layout == .verified and evidence.kind == .create)
        &.{ "approved-diff.json", "submitted" }
    else
        &.{ "approved-diff.json", "submitted", "entry" };
    const staged_parents = if (layout == .rejected) evidence.parent_chain else null;
    var iterator = dirs.stage.iterate();
    entries: while (try iterator.next(io)) |entry| {
        if (entry.kind == .file) {
            for (names) |name| if (std.mem.eql(u8, entry.name, name)) continue :entries;
        } else if (entry.kind == .directory) {
            if (staged_parents) |chain| for (0..chain.plan.count) |index| {
                const name = stagedParentName(index);
                if (!std.mem.eql(u8, entry.name, &name)) continue;
                const dir = try dirs.stage.openDir(io, &name, .{ .follow_symlinks = false, .iterate = true });
                defer dir.close(io);
                if (!std.meta.eql(try Identity.of(dir), chain.identities[index].?)) return error.RecoveryMaterialChanged;
                var contents = dir.iterate();
                if (try contents.next(io) != null) return error.RecoveryMaterialChanged;
                continue :entries;
            };
        }
        return error.RecoveryMaterialChanged;
    }
    var checked: [3]?Identity = @splat(null);
    const a = std.heap.page_allocator;
    for (names, 0..) |name, index| {
        const material = snapshot(a, io, dirs.stage, name, null, false) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer a.free(material.bytes);
        if (material.state.stat.nlink != 1) return error.RecoveryMaterialChanged;
        if (std.mem.eql(u8, name, "submitted")) {
            if (!std.mem.eql(u8, &digest(material.bytes), &evidence.candidate_hash)) return error.RecoveryMaterialChanged;
        } else if (std.mem.eql(u8, name, "entry")) {
            const version = switch (layout) {
                .rejected => evidence.candidate_version,
                .verified => evidence.approved_version orelse return error.InvalidRecoveryReference,
            };
            if ((layout == .rejected and !std.meta.eql(material.state.identity, evidence.recovery.candidate_identity)) or
                !std.mem.eql(u8, &material.version, &version) or
                !std.mem.eql(u8, &material.metadata_hash, &evidence.candidate_metadata_hash))
                return error.RecoveryMaterialChanged;
        } else if (evidence.approved_diff_hash) |expected| {
            if (!std.mem.eql(u8, &digest(material.bytes), &expected)) return error.RecoveryMaterialChanged;
        } else if (layout == .rejected) return error.InvalidRecoveryReference;
        checked[index] = material.state.identity;
    }
    try checkStage(dirs.parent, &evidence.recovery.stage_name, evidence.recovery.stage_identity);
    for (names, checked[0..names.len]) |name, identity| {
        const id = identity orelse continue;
        const entry = entryStat(dirs.stage, name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (entry.mode & std.c.S.IFMT != std.c.S.IFREG or entry.nlink != 1 or
            !std.meta.eql(Identity.fromStat(entry), id))
            return error.RecoveryMaterialChanged;
        dirs.stage.deleteFile(io, name) catch |err| if (err != error.FileNotFound) return err;
    }
    if (staged_parents) |chain| {
        for (0..chain.plan.count) |index| {
            const name = stagedParentName(index);
            checkNamedDirectory(dirs.stage, &name, chain.identities[index].?) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            dirs.stage.deleteDir(io, &name) catch |err| if (err != error.FileNotFound) return err;
        }
    }
    try syncDir(dirs.stage);
    try checkStage(dirs.parent, &evidence.recovery.stage_name, evidence.recovery.stage_identity);
    try dirs.parent.deleteDir(io, &evidence.recovery.stage_name);
    try syncDir(dirs.parent);
}

const Fixture = struct {
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    evidence: ?Evidence = null,
    dispatches: u32 = 0,
    validations: u32 = 0,
    durable_parent_count: u8 = 0,
    receipt: ?Receipt = null,
    deny_at_dispatch: bool = false,
    require_approval_at_dispatch: bool = false,
    approval_waits: u8 = 0,
    edit_while_waiting: bool = false,
    fail_finish: bool = false,

    fn journal(self: *Fixture) Journal {
        return .{
            .context = self,
            .prepare = persistPrepare,
            .dispatch = persistDispatch,
            .progress = persistParent,
            .finish = persistFinish,
        };
    }

    fn gate(self: *Fixture) Gate {
        return .{ .context = self, .validate = validate, .wait_for_approval = waitForApproval };
    }

    fn persistPrepare(raw: *anyopaque, evidence: Evidence) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(self.evidence == null);
        const encoded = try std.json.Stringify.valueAlloc(self.a, evidence, .{});
        defer self.a.free(encoded);
        try writeFile(self.io, self.dir, "prepared.json", encoded);
        try syncDir(self.dir);
        self.evidence = evidence;
    }

    fn persistDispatch(raw: *anyopaque, operation: OperationId) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(operation.eql(self.evidence.?.operation_ref));
        try writeFile(self.io, self.dir, "dispatch", &operation.bytes);
        try syncDir(self.dir);
        self.dispatches += 1;
    }

    fn persistParent(raw: *anyopaque, operation: OperationId, count: u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(operation.eql(self.evidence.?.operation_ref));
        try std.testing.expectEqual(@as(u32, 1), self.dispatches);
        try std.testing.expectEqual(self.durable_parent_count + 1, count);
        const name = [_]u8{ 'p', 'a', 'r', 'e', 'n', 't', '-', '0' + count };
        try writeFile(self.io, self.dir, &name, &.{count});
        try syncDir(self.dir);
        self.durable_parent_count = count;
    }

    fn persistFinish(raw: *anyopaque, receipt: Receipt) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(receipt.operation_ref.eql(self.evidence.?.operation_ref));
        if (self.fail_finish) return error.DiskWriteFailed;
        try writeFile(self.io, self.dir, "terminal", @tagName(receipt.status));
        try syncDir(self.dir);
        self.receipt = receipt;
    }

    fn validate(raw: *anyopaque, _: *const Prepared) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.validations += 1;
        if (self.deny_at_dispatch and self.dispatches != 0) return error.WorkspaceChanged;
        if (self.require_approval_at_dispatch and self.dispatches != 0 and self.approval_waits == 0)
            return error.ToolApprovalRequired;
    }

    fn waitForApproval(raw: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(writes.tryLock());
        writes.unlock(self.io);
        self.approval_waits += 1;
        if (self.edit_while_waiting) {
            try writeFile(self.io, self.dir, "external-edit", "changed during approval");
            try self.dir.rename("external-edit", self.dir, "target", self.io);
        }
    }

    fn swapExternal(raw: *anyopaque, io: std.Io, proposal: *const Prepared) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(@as(u32, 1), self.dispatches);
        try writeFile(io, proposal.target.parent, "external", "external\n");
        try proposal.target.parent.rename("external", proposal.target.parent, proposal.target.basename, io);
    }

    fn swapExternalSymlink(_: *anyopaque, io: std.Io, proposal: *const Prepared) !void {
        const parent = proposal.target.parent;
        try writeFile(io, parent, "unrelated", "keep this");
        try parent.symLink(io, "unrelated", "outside-link", .{});
        try parent.rename("outside-link", parent, proposal.target.basename, io);
    }

    fn createExternal(raw: *anyopaque, io: std.Io, proposal: *const Prepared) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(@as(u32, 1), self.dispatches);
        try writeFile(io, proposal.target.parent, proposal.target.basename, "winner");
    }

    fn createCompetingParent(from: std.Io.Dir, name: [:0]const u8, to: std.Io.Dir, new_name: [:0]const u8, kind: Kind) !void {
        if (std.mem.eql(u8, name, "parent-01")) {
            try to.createDir(std.testing.io, new_name, @fromBackingInt(0o755));
            const competing = try to.openDir(std.testing.io, new_name, .{});
            defer competing.close(std.testing.io);
            try writeFile(std.testing.io, competing, "external", "external");
        }
        return renameEntry(from, name, to, new_name, kind);
    }

    fn createCompetingNestedFile(from: std.Io.Dir, name: [:0]const u8, to: std.Io.Dir, new_name: [:0]const u8, kind: Kind) !void {
        if (std.mem.eql(u8, name, "entry")) try writeFile(std.testing.io, to, new_name, "winner");
        return renameEntry(from, name, to, new_name, kind);
    }

    fn unsupported(_: std.Io.Dir, _: [:0]const u8, _: std.Io.Dir, _: [:0]const u8, _: Kind) !void {
        return error.AtomicReplaceUnsupported;
    }
};

fn fixtureTarget(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, mode: path.Mode) !path.Resolved {
    const cwd = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    return path.resolve(a, io, .{ .path = "target", .base_directory = cwd }, mode);
}

fn assertFile(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    const text = try dir.readFileAlloc(io, name, a, .limited(1024));
    defer a.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn readVersion(a: std.mem.Allocator, io: std.Io, target: *const path.Resolved) !reads.Version {
    var cancel: @import("../ai/provider.zig").CancelToken = .{};
    const page = try reads.readText(a, io, target, .{}, &cancel);
    return page.version;
}

test "managed local write verifies swapped contents and retains the replaced descriptor" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try writeFile(io, tmp.dir, "target", "\xef\xbb\xbfport=80\r\n");
    const original = try tmp.dir.openFile(io, "target", .{ .mode = .read_write });
    defer original.close(io);
    const Xattr = struct {
        extern "c" fn fsetxattr(c_int, [*:0]const u8, [*]const u8, usize, u32, c_int) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), Xattr.fsetxattr(original.handle, "com.zerowork.fixture", "attribute", 9, 0, 0));
    try original.setPermissions(io, @fromBackingInt(0o640));
    const target = try fixtureTarget(a, io, tmp.dir, .file);
    defer target.deinit(a, io);
    const version = try readVersion(a, io, &target);
    const plan = try prepare(a, io, &target, .{
        .kind = .edit,
        .expected_version = &version,
        .edits = &.{.{ .old_text = "80", .new_text = "90" }},
    });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commit(a, io, &plan, OperationId.generate(), f.journal(), f.gate());
    try std.testing.expectEqual(Status.verified, receipt.status);
    try std.testing.expect(receipt.side_effect_started and receipt.committed and receipt.verified);
    try std.testing.expectEqual(@as(?reads.Version, version), receipt.actual_before_version);
    try std.testing.expectEqual(@as(?usize, 1), receipt.diff.?.added);
    try std.testing.expectEqual(@as(?usize, 1), receipt.diff.?.removed);
    try std.testing.expectEqual(@as(u32, 2), f.validations);
    try assertFile(a, io, tmp.dir, "target", "\xef\xbb\xbfport=90\r\n");
    const after_target = try fixtureTarget(a, io, tmp.dir, .file);
    defer after_target.deinit(a, io);
    try std.testing.expectEqual(receipt.submitted_after_version.?, try readVersion(a, io, &after_target));
    const stage = try tmp.dir.openDir(io, &receipt.recovery.?.stage_name, .{});
    defer stage.close(io);
    try assertFile(a, io, stage, "entry", "\xef\xbb\xbfport=80\r\n");
    // External editors may retain a writable fd to the old inode.
    try original.writePositionalAll(io, "late", 0);
    try std.testing.expectError(error.RecoveryMaterialChanged, expireRecovery(io, f.evidence.?));
    try assertFile(a, io, stage, "entry", "lateort=80\r\n");
    try assertFile(a, io, tmp.dir, "target", "\xef\xbb\xbfport=90\r\n");
}

test "managed local write retains the actual external save after the last version check" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try writeFile(io, tmp.dir, "target", "original\n");
    const target = try fixtureTarget(a, io, tmp.dir, .file);
    defer target.deinit(a, io);
    const version = try readVersion(a, io, &target);
    const plan = try prepare(a, io, &target, .{ .kind = .replace, .expected_version = &version, .text = "approved\n" });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commitImpl(a, io, &plan, OperationId.generate(), f.journal(), f.gate(), .{ .after_last_check = Fixture.swapExternal, .context = &f });
    try std.testing.expectEqual(Status.committed_unverified, receipt.status);
    try std.testing.expect(receipt.committed and !receipt.verified and receipt.conflict);
    try std.testing.expectEqual(@as(?anyerror, error.ConcurrentModification), receipt.reason);
    try std.testing.expect(!std.mem.eql(u8, &receipt.actual_before_version.?, &version));
    try std.testing.expectEqualStrings("external\n", receipt.diff.?.lines[0].text);
    const stage = try tmp.dir.openDir(io, &receipt.recovery.?.stage_name, .{});
    defer stage.close(io);
    try assertFile(a, io, stage, "entry", "external\n");
    try assertFile(a, io, stage, "submitted", "approved\n");
    try assertFile(a, io, tmp.dir, "target", "approved\n");
    const projected = try stage.readFileAlloc(io, "actual-diff.json", a, .limited(1024));
    try std.testing.expect(std.mem.indexOf(u8, projected, "external") != null);
}

test "managed local write preserves a raced symlink without following it" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try writeFile(io, tmp.dir, "target", "original");
    const target = try fixtureTarget(a, io, tmp.dir, .file);
    defer target.deinit(a, io);
    const version = try readVersion(a, io, &target);
    const plan = try prepare(a, io, &target, .{ .kind = .replace, .expected_version = &version, .text = "candidate" });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commitImpl(a, io, &plan, OperationId.generate(), f.journal(), f.gate(), .{ .after_last_check = Fixture.swapExternalSymlink, .context = &f });
    try std.testing.expect(receipt.committed and !receipt.verified and receipt.conflict);
    try std.testing.expect(receipt.actual_before_version == null and receipt.diff == null);
    const stage = try tmp.dir.openDir(io, &receipt.recovery.?.stage_name, .{});
    defer stage.close(io);
    const entry = try stage.statFile(io, "entry", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, entry.kind);
    try assertFile(a, io, tmp.dir, "unrelated", "keep this");
    try assertFile(a, io, tmp.dir, "target", "candidate");
}

test "managed local write excludes a competing create at the syscall" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const target = try fixtureTarget(a, io, tmp.dir, .create);
    defer target.deinit(a, io);
    const plan = try prepare(a, io, &target, .{ .kind = .create, .text = "candidate" });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commitImpl(a, io, &plan, OperationId.generate(), f.journal(), f.gate(), .{ .after_last_check = Fixture.createExternal, .context = &f });
    try std.testing.expectEqual(Status.rejected, receipt.status);
    try std.testing.expectEqual(@as(?anyerror, error.PathAlreadyExists), receipt.reason);
    try std.testing.expect(!receipt.side_effect_started and !receipt.committed);
    try assertFile(a, io, tmp.dir, "target", "winner");
}

test "managed local write refuses unsupported atomic replacement before dispatch" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try writeFile(io, tmp.dir, "target", "original");
    const target = try fixtureTarget(a, io, tmp.dir, .file);
    defer target.deinit(a, io);
    const version = try readVersion(a, io, &target);
    const plan = try prepare(a, io, &target, .{ .kind = .replace, .expected_version = &version, .text = "candidate" });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const operation = OperationId.generate();
    try std.testing.expectError(error.AtomicReplaceUnsupported, commitImpl(a, io, &plan, operation, f.journal(), f.gate(), .{ .rename = Fixture.unsupported }));
    try std.testing.expect(f.evidence == null);
    try std.testing.expectEqual(@as(u32, 0), f.dispatches);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, &stageName(operation), .{}));
    try assertFile(a, io, tmp.dir, "target", "original");
}

test "managed local write rechecks authorization at dispatch and observes without replay" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const target = try fixtureTarget(a, io, tmp.dir, .create);
    defer target.deinit(a, io);
    const plan = try prepare(a, io, &target, .{ .kind = .create, .text = "candidate" });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir, .deny_at_dispatch = true };
    const receipt = try commit(a, io, &plan, OperationId.generate(), f.journal(), f.gate());
    try std.testing.expectEqual(Status.rejected, receipt.status);
    try std.testing.expectEqual(@as(?anyerror, error.WorkspaceChanged), receipt.reason);
    try std.testing.expect(!receipt.side_effect_started);
    const observed = try observe(a, io, f.evidence.?);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), observed.target_error);
    try std.testing.expect(!observed.candidate_matches);
    try std.testing.expect(observed.candidate_payload_preserved and observed.staged_entry_is_candidate);
}

test "managed local write preserves evidence when the final journal write fails" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const target = try fixtureTarget(a, io, tmp.dir, .create);
    defer target.deinit(a, io);
    const plan = try prepare(a, io, &target, .{ .kind = .create, .text = "candidate" });
    var f: Fixture = .{ .a = a, .io = io, .dir = tmp.dir, .fail_finish = true };
    const receipt = try commit(a, io, &plan, OperationId.generate(), f.journal(), f.gate());
    try std.testing.expectEqual(Status.unknown, receipt.status);
    try std.testing.expect(receipt.committed and receipt.journal_outcome_unknown);
    try assertFile(a, io, tmp.dir, "target", "candidate");
    const source = try tmp.dir.readFileAlloc(io, "prepared.json", a, .limited(4096));
    const parsed = try std.json.parseFromSlice(Evidence, a, source, .{});
    defer parsed.deinit();
    const observed = try observe(a, io, parsed.value);
    try std.testing.expect(observed.candidate_matches and observed.candidate_payload_preserved);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), observed.staged_entry_error);
    try std.testing.expect(f.receipt == null);
}

fn fixtureNestedTarget(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !path.Resolved {
    const cwd = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    return path.resolve(a, io, .{ .path = name, .base_directory = cwd, .create_parents = true }, .create);
}

test "managed local write publishes the approved directory chain and recovers from its existing anchor" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "other/subdir");
    try tmp.dir.symLink(io, "other/subdir", "alias", .{ .is_directory = true });
    const target = try fixtureNestedTarget(a, io, tmp.dir, "alias/../one/./two/target");
    defer target.deinit(a, io);
    const anchor = try tmp.dir.realPathFileAlloc(io, "other", a);
    var names: [path.max_create_parents][]const u8 = undefined;
    const parents = target.plannedParents(&names);
    try std.testing.expectEqual(@as(usize, 2), parents.len);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/one", .{anchor}), parents[0]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/one/two", .{anchor}), parents[1]);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "other/one", .{}));
    const proposal = try prepare(a, io, &target, .{ .kind = .create, .text = "created", .create_parents = true });
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "other/one", .{}));

    var fixture: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commit(a, io, &proposal, OperationId.generate(), fixture.journal(), fixture.gate());
    try std.testing.expectEqual(Status.verified, receipt.status);
    try std.testing.expect(receipt.committed and receipt.side_effect_started);
    try std.testing.expectEqual(@as(u8, 2), receipt.created_parent_count);
    try std.testing.expectEqual(receipt.created_parent_count, fixture.durable_parent_count);
    try assertFile(a, io, tmp.dir, "other/one/two/target", "created");
    const evidence = fixture.evidence.?;
    const observed = try observe(a, io, evidence);
    try std.testing.expectEqual(@as(u8, 2), observed.matching_parent_count);
    try std.testing.expect(observed.candidate_matches and observed.candidate_payload_preserved);
    const projected = try readDiff(a, io, evidence, receipt.diff_ref.?);
    defer projected.deinit();
    try std.testing.expectEqualStrings("created", projected.value.lines[0].text);

    try expireRecovery(io, evidence);
    try expireRecovery(io, evidence);
    try std.testing.expectError(error.ChangeContentExpired, readDiff(a, io, evidence, receipt.diff_ref.?));
    const expired = try observe(a, io, evidence);
    try std.testing.expect(expired.candidate_matches);
    try std.testing.expectEqual(@as(?anyerror, error.ChangeContentExpired), expired.candidate_payload_error);
    try assertFile(a, io, tmp.dir, "other/one/two/target", "created");
}

test "managed local write retains the first published parent when a concurrent directory wins the second" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const target = try fixtureNestedTarget(a, io, tmp.dir, "one/two/target");
    defer target.deinit(a, io);
    const proposal = try prepare(a, io, &target, .{ .kind = .create, .text = "candidate", .create_parents = true });
    var fixture: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commitImpl(a, io, &proposal, OperationId.generate(), fixture.journal(), fixture.gate(), .{ .rename = Fixture.createCompetingParent });
    try std.testing.expectEqual(Status.partial, receipt.status);
    try std.testing.expect(receipt.side_effect_started and !receipt.committed and !receipt.verified);
    try std.testing.expectEqual(@as(?anyerror, error.PathAlreadyExists), receipt.reason);
    try std.testing.expectEqual(@as(u8, 1), receipt.created_parent_count);
    try std.testing.expectEqual(receipt.created_parent_count, fixture.durable_parent_count);
    try assertFile(a, io, tmp.dir, "one/two/external", "external");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "one/two/target", .{}));
    const observed = try observe(a, io, fixture.evidence.?);
    try std.testing.expectEqual(@as(u8, 1), observed.matching_parent_count);
    try std.testing.expectEqual(@as(?anyerror, error.SourceChanged), observed.target_error);
    try std.testing.expect(observed.candidate_payload_preserved and observed.staged_entry_is_candidate);
}

test "managed local write reports every created parent when the final file loses an exclusive create race" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const target = try fixtureNestedTarget(a, io, tmp.dir, "one/two/target");
    defer target.deinit(a, io);
    const proposal = try prepare(a, io, &target, .{ .kind = .create, .text = "candidate", .create_parents = true });
    var fixture: Fixture = .{ .a = a, .io = io, .dir = tmp.dir };
    const receipt = try commitImpl(a, io, &proposal, OperationId.generate(), fixture.journal(), fixture.gate(), .{ .rename = Fixture.createCompetingNestedFile });
    try std.testing.expectEqual(Status.partial, receipt.status);
    try std.testing.expectEqual(@as(?anyerror, error.PathAlreadyExists), receipt.reason);
    try std.testing.expectEqual(@as(u8, 2), receipt.created_parent_count);
    try std.testing.expectEqual(receipt.created_parent_count, fixture.durable_parent_count);
    try std.testing.expect(!receipt.committed);
    try assertFile(a, io, tmp.dir, "one/two/target", "winner");
    const observed = try observe(a, io, fixture.evidence.?);
    try std.testing.expectEqual(@as(u8, 2), observed.matching_parent_count);
    try std.testing.expect(!observed.candidate_matches and observed.candidate_payload_preserved);
}

test "managed local write releases its mutex and rechecks target when automatic approval tightens during staging" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    for ([_]bool{ false, true }) |edit_while_waiting| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        try writeFile(io, tmp.dir, "target", "original");
        const target = try fixtureTarget(a, io, tmp.dir, .file);
        defer target.deinit(a, io);
        const version = try readVersion(a, io, &target);
        const proposal = try prepare(a, io, &target, .{ .kind = .replace, .text = "candidate", .expected_version = &version });
        var fixture: Fixture = .{
            .a = a,
            .io = io,
            .dir = tmp.dir,
            .require_approval_at_dispatch = true,
            .edit_while_waiting = edit_while_waiting,
        };
        const receipt = try commit(a, io, &proposal, OperationId.generate(), fixture.journal(), fixture.gate());
        try std.testing.expectEqual(@as(u32, 1), fixture.dispatches);
        try std.testing.expectEqual(@as(u8, 1), fixture.approval_waits);
        if (edit_while_waiting) {
            try std.testing.expectEqual(Status.rejected, receipt.status);
            try std.testing.expectEqual(@as(?anyerror, error.SourceChanged), receipt.reason);
            try std.testing.expect(!receipt.side_effect_started);
            try assertFile(a, io, tmp.dir, "target", "changed during approval");
        } else {
            try std.testing.expectEqual(Status.verified, receipt.status);
            try std.testing.expect(receipt.committed);
            try assertFile(a, io, tmp.dir, "target", "candidate");
        }
    }
}
