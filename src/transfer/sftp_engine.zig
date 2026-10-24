//! SFTP TransferEngine 适配层。
//!
//! 把 `src/proto/ssh/session.zig` 的 SFTP 能力包装成 `src/transfer/manager.zig`
//! 定义的 `TransferEngine` 契约（open / pause / cancel / poll + ctx 转译）。
//!
//! 线程模型：每个引擎只有一个 IO owner，所有冻结的 Session/SFTP 调用
//! 都由该线程执行。多个 Job 各自保存句柄、offset 和稳定 buffer；每轮最多
//! 32 KiB、一次远端 read/write，完整 blocking API 返回后才换 Job。
//! open() 只深拷贝输入/绑定并入队，不在调用线程执行文件或网络 IO。
//! owner 自有 std.Io.Threaded；进度通过原子字段发布给 poll/Manager。
//! 当前适配要求专用 blocking Session，不在同一 SFTP 上下文的 EAGAIN 中
//! 切换 handle；非阻塞多上下文管线仍须由后续 Session 调度能力提供。
//!
//! 路径语义：源路径保留相对目录或绝对路径；目标目录只拼接源 basename，
//! rename 在上传和下载均优先。仅本地路径展开 ~ 和 ~/；远端路径不读取本机 HOME。
//! 下载只写本 Job 排他创建的随机临时文件，成功后以 renamePreserve 落位。
//!
//! 已知简化（诚实降级，待 c.zig 透出远端绑定后升级）：
//!  - md5_check：SFTP-only有界完整双边MD5；不一致只修复末逻辑块一次后完整复验；
//!  - cancel：只删除本 Job 排他创建且 inode 仍匹配的本地临时文件；远端部分保留；
//!  - pause/resume：内存checkpoint精确交接原Job，完整SHA256与prefix复验后续写；
//!    校验暂停保原临时文件，恢复重做完整校验；跨进程持久恢复仍未实现；
//!  - speed_bps：按任务总耗时均值估算（无 500ms 滑动窗口）；
//!  - 引擎任务列表不做 GC，随 detachSession/deinit 统一 join owner + 释放。
const std = @import("std");
const manager = @import("manager.zig");
const conflict = @import("conflict.zig");
pub const conflict_types = @import("conflict_types.zig");
const ssh_session = @import("../proto/ssh/session.zig");
const exec_api = @import("../ai/execbridge.zig");
const OperationKey = @import("../host/operation.zig").OperationKey;
const transfer_window = @import("../proto/ssh/transfer_window.zig");
const window_policy = @import("window_policy.zig");
const PacingBudget = @import("../proto/ssh/transfer_pacer.zig").Budget;
const monotonicNs = @import("../platform/realtime.zig").monotonicNs;

pub const JobSpec = manager.JobSpec;
pub const EngineProgress = manager.EngineProgress;
pub const EngineJobId = manager.EngineJobId;

/// Fair IO turn limit, independent of the frozen logical chunk size.
pub const chunk_bytes: u32 = 32 * 1024;
/// Previous fixed capacity, retained for compatibility tests; jobs use their own policy.
pub const window_capacity: u16 = 64;
const metadata_budget_ns: u64 = 30 * std.time.ns_per_s;

/// The metadata boundary runs on the unique IO owner, never on open/poll.
pub const RemoteMetadata = struct {
    context: ?*anyopaque = null,
    size: *const fn (?*anyopaque, *ssh_session.Session, [:0]const u8) anyerror!u64 = remoteSize,
    stat: *const fn (?*anyopaque, *ssh_session.Session, [:0]const u8) anyerror!ssh_session.SftpAttributes = remoteStat,

    target_stat: *const fn (?*anyopaque, *ssh_session.Session, [:0]const u8) anyerror!ssh_session.SftpAttributes = targetStat,

    fn targetStat(_: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpAttributes {
        try session.sftpInit();
        return session.sftpStat(path, false);
    }

    fn remoteStat(_: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpAttributes {
        try session.sftpInit();
        return session.sftpStat(path, true);
    }

    fn remoteSize(_: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !u64 {
        return session.sftpSize(path);
    }
};

/// All file operations use this frozen adapter on the same owner thread. It
/// also permits a controlled service to exercise the production scheduler.
pub const ReadPurpose = enum { fingerprint, prefix, transfer, checksum, repair };
pub const RemoteFiles = struct {
    context: ?*anyopaque = null,
    open_read: *const fn (?*anyopaque, *ssh_session.Session, [:0]const u8, ReadPurpose) anyerror!ssh_session.SftpHandle = openRead,
    stat_handle: *const fn (?*anyopaque, *ssh_session.Session, *ssh_session.SftpHandle) anyerror!ssh_session.SftpAttributes = handleStat,
    open_write: *const fn (?*anyopaque, *ssh_session.Session, [:0]const u8, u64, bool) anyerror!ssh_session.SftpHandle = openWrite,
    create_exclusive: *const fn (?*anyopaque, *ssh_session.Session, [:0]const u8) anyerror!ssh_session.SftpHandle = createExclusive,
    truncate: *const fn (?*anyopaque, *ssh_session.Session, *ssh_session.SftpHandle) anyerror!void = truncateHandle,
    read: *const fn (?*anyopaque, *ssh_session.SftpHandle, []u8) anyerror!usize = nativeRead,
    write: *const fn (?*anyopaque, *ssh_session.SftpHandle, []const u8) anyerror!usize = nativeWrite,
    close: *const fn (?*anyopaque, *ssh_session.SftpHandle) ssh_session.SftpCloseResult = nativeClose,
    release: *const fn (?*anyopaque, *ssh_session.Session) ssh_session.ReleaseReceipt = nativeRelease,

    fn openRead(_: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8, _: ReadPurpose) !ssh_session.SftpHandle {
        try session.sftpInit();
        // Existing readonly adapter preserves real not-found/permission errors.
        return (try session.sftpOpenReadonly(path, false)).file;
    }
    fn handleStat(_: ?*anyopaque, session: *ssh_session.Session, handle: *ssh_session.SftpHandle) !ssh_session.SftpAttributes {
        var readonly: ssh_session.SftpReadonlyHandle = .{ .file = handle.*, .session = session };
        return readonly.stat();
    }
    fn openWrite(_: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8, offset: u64, preserve: bool) !ssh_session.SftpHandle {
        return if (offset == 0 and !preserve) session.sftpOpenWrite(path) else session.sftpOpenAppend(path, offset);
    }
    fn createExclusive(_: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpHandle {
        return session.sftpOpenExclusive(path);
    }
    fn truncateHandle(_: ?*anyopaque, session: *ssh_session.Session, handle: *ssh_session.SftpHandle) !void {
        return session.sftpTruncate(handle, 0);
    }
    fn nativeRead(_: ?*anyopaque, handle: *ssh_session.SftpHandle, bytes: []u8) !usize {
        return handle.read(bytes);
    }
    fn nativeWrite(_: ?*anyopaque, handle: *ssh_session.SftpHandle, bytes: []const u8) !usize {
        return handle.write(bytes);
    }
    fn nativeClose(_: ?*anyopaque, handle: *ssh_session.SftpHandle) ssh_session.SftpCloseResult {
        return handle.closeReceipt();
    }
    fn nativeRelease(_: ?*anyopaque, session: *ssh_session.Session) ssh_session.ReleaseReceipt {
        const receipt = session.closeSftpReceipt();
        // closeSftpReceipt drives shutdown nonblocking. A subsequent accepted
        // transfer on this still-live dedicated Session must restore its mode.
        if (receipt == .released and session.state == .active and session.handle != null) session.setBlocking();
        return receipt;
    }
};

/// Zig 0.17 移除了 std.Thread.Mutex，std.atomic.Mutex 只有 tryLock 语义；
/// 控制面临界区极短（列表操作、原子发布），worker 热路径不进锁，
/// 这里用自旋锁实现阻塞语义。
const SpinMutex = struct {
    state: std.atomic.Value(bool) = .init(false), // false=unlocked, true=locked

    pub fn lock(self: *SpinMutex) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
};

/// EngineState 的原子槽位镜像（0.17 的 Value(T) 要求枚举显式指定 tag 类型，
/// manager.EngineState 是自动编号，故以 u8 存储并在边界转换）。
const state_running: u8 = @backingInt(manager.EngineState.running);
const state_succeeded: u8 = @backingInt(manager.EngineState.succeeded);
const state_failed: u8 = @backingInt(manager.EngineState.failed);
const state_paused: u8 = @backingInt(manager.EngineState.paused);
const state_cancelled: u8 = @backingInt(manager.EngineState.cancelled);

fn engineStateOf(raw: u8) manager.EngineState {
    return @fromBackingInt(@intCast(raw));
}

/// Job 内跨线程读写失败类别的最小锁槽位。
const FailureSlot = struct {
    mutex: SpinMutex = .{},
    value: ?manager.Failure = null,

    fn set(self: *FailureSlot, failure: manager.Failure) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value = failure;
    }

    fn get(self: *FailureSlot) ?manager.Failure {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.value;
    }
};

const VerificationSlot = struct {
    mutex: SpinMutex = .{},
    value: ?manager.Verification = null,
    revision: u64 = 0,
    const Snapshot = struct { value: ?manager.Verification, revision: u64 };
    fn get(self: *VerificationSlot) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .value = self.value, .revision = self.revision };
    }
    fn set(self: *VerificationSlot, value: manager.Verification) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.meta.eql(self.value, @as(?manager.Verification, value))) return;
        self.value = value;
        self.revision +|= 1;
    }
    fn clear(self: *VerificationSlot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.value == null) return;
        self.value = null;
        self.revision +|= 1;
    }
};

/// 引擎自有的 spec 持有副本：open() 后调用方可立即释放输入切片。
const OwnedSpec = struct {
    session_id: u64,
    transfer_binding: ?manager.ServiceHandle,
    conflict_context: ?conflict_types.Context,
    direction: manager.Direction,
    sources: [][]u8,
    remote_dir: []u8,
    local_dir: []u8,
    rename: ?[]u8,
    resume_transfer: bool,
    md5_check: bool,
    notify_complete: bool = true,
    chunk_kb: u16 = 64,
    window_chunks: u8 = 16,
    pacing_kbps: u32 = 0,

    fn clone(allocator: std.mem.Allocator, spec: JobSpec) !OwnedSpec {
        const sources = try allocator.alloc([]u8, spec.sources.len);
        var initialized: usize = 0;
        errdefer {
            for (sources[0..initialized]) |source| allocator.free(source);
            allocator.free(sources);
        }
        for (spec.sources, 0..) |source, i| {
            sources[i] = try allocator.dupe(u8, source);
            initialized += 1;
        }
        const remote_dir = try allocator.dupe(u8, spec.remote_dir);
        errdefer allocator.free(remote_dir);
        const local_dir = try allocator.dupe(u8, spec.local_dir);
        errdefer allocator.free(local_dir);
        const rename = if (spec.rename) |value| try allocator.dupe(u8, value) else null;
        return .{
            .session_id = spec.session_id,
            .transfer_binding = spec.transfer_binding,
            .conflict_context = spec.conflict_context,
            .direction = spec.direction,
            .sources = sources,
            .remote_dir = remote_dir,
            .local_dir = local_dir,
            .rename = rename,
            .resume_transfer = spec.resume_transfer,
            .md5_check = spec.md5_check,
            .notify_complete = spec.notify_complete,
            .chunk_kb = spec.chunk_kb,
            .window_chunks = spec.window_chunks,
            .pacing_kbps = spec.pacing_kbps,
        };
    }

    fn deinit(self: *OwnedSpec, allocator: std.mem.Allocator) void {
        for (self.sources) |source| allocator.free(source);
        allocator.free(self.sources);
        allocator.free(self.remote_dir);
        allocator.free(self.local_dir);
        if (self.rename) |value| allocator.free(value);
        self.* = undefined;
    }

    fn view(self: OwnedSpec) JobSpec {
        return .{
            .session_id = self.session_id,
            .transfer_binding = self.transfer_binding,
            .conflict_context = self.conflict_context,
            .direction = self.direction,
            .sources = self.sources,
            .remote_dir = self.remote_dir,
            .local_dir = self.local_dir,
            .rename = self.rename,
            .resume_transfer = self.resume_transfer,
            .md5_check = self.md5_check,
            .notify_complete = self.notify_complete,
            .chunk_kb = self.chunk_kb,
            .window_chunks = self.window_chunks,
            .pacing_kbps = self.pacing_kbps,
        };
    }
};

/// One accepted Job, at a stable address until engine teardown.
const Job = struct {
    id: EngineJobId,
    spec: OwnedSpec,
    started_ms: u64 = 0,
    // Frozen at acceptance; a later attachSession must not retarget this job.
    session: ?*ssh_session.Session = null,
    exec_service: ?exec_api.ExecBridge = null,
    exec_key: ?OperationKey = null,
    remote_metadata: RemoteMetadata = .{},
    remote_files: RemoteFiles = .{},
    runtime: Runtime = .{},
    checkpoint: ?Runtime = null,
    handed_off: bool = false,

    // —— IO owner 写、poll 读的原子进度（done 单调不减且 ≤ total，Manager 契约）——
    state: std.atomic.Value(u8) = .init(state_running),
    retryable: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    total_ready: std.atomic.Value(bool) = .init(false),
    speed: std.atomic.Value(u64) = .init(0),
    failure: FailureSlot = .{},
    verification: VerificationSlot = .{},
    conflicts: ConflictSlot = .{},
    conflict_waiting: std.atomic.Value(bool) = .init(false),
    conflict_revision: std.atomic.Value(u64) = .init(0),
    skipped_files: std.atomic.Value(u32) = .init(0),
    skipped_bytes: std.atomic.Value(u64) = .init(0),

    // —— 控制面 ——
    pause_flag: std.atomic.Value(bool) = .init(false),
    cancel_flag: std.atomic.Value(bool) = .init(false),
    // Retained by this exact accepted ID, including after a paused receipt.
    owned_temp: ?OwnedTemp = null,
    terminal: std.atomic.Value(bool) = .init(false),
    // A terminal event precedes scoped cleanup; only this flag releases the
    // worker's borrowed Session/Exec lifetime.
    worker_done: std.atomic.Value(bool) = .init(false),
    release_unknown: std.atomic.Value(bool) = .init(false),

    // —— 仅在引擎锁下访问的发布簿记 ——
    emitted: bool = false,
    emitted_done: u64 = 0,
    reported_state: ?manager.EngineState = null,
    reported_cleanup: ?manager.JobCleanup = null,
    reported_verification: u64 = 0,
    emitted_verification: u64 = 0,
    emitted_conflict: u64 = 0,
    emitted_skipped: u64 = 0,
};

/// Only the IO owner reads or mutates this continuation. Its buffer remains at
/// the same address for a whole native call and for any partial transfer.
const OwnedTemp = struct {
    path: []u8,
    inode: ?std.Io.File.INode = null,
    created: bool = false,
};

const FileStamp = struct {
    kind: ssh_session.SftpKind,
    size: u64,
    mtime_ns: ?i128,
    inode: ?std.Io.File.INode = null,

    fn local(value: std.Io.File.Stat) !FileStamp {
        if (value.kind != .file) return error.SourceChanged;
        return .{ .kind = .file, .size = value.size, .mtime_ns = value.mtime.toNanoseconds(), .inode = value.inode };
    }
    fn remote(value: ssh_session.SftpAttributes) !FileStamp {
        if (value.kind != .file or value.size == null) return error.SourceChanged;
        return .{ .kind = value.kind, .size = value.size.?, .mtime_ns = if (value.modified_at) |v| @as(i128, v) * std.time.ns_per_s else null };
    }
    fn same(a: FileStamp, b: FileStamp) bool {
        return a.kind == b.kind and a.size == b.size and a.mtime_ns == b.mtime_ns and a.inode == b.inode;
    }
};
const Fingerprint = struct { stamp: FileStamp, sha256: [32]u8 };

const Runtime = struct {
    const Phase = enum {
        metadata,
        prepare,
        source_open,
        source_scan,
        source_close,
        target_stat,
        target_retry_close,
        conflict_step,
        prefix_open,
        prefix_scan,
        prefix_close,
        open_remote,
        open_local,
        skip_remote,
        transfer,
        close_remote,
        finalize_file,
        checksum_open,
        checksum_local,
        checksum_remote,
        checksum_close,
        checksum_compare,
        repair_open,
        publish_file,
        cleanup,
        cleanup_unknown,
        done,
    };
    const Outcome = union(enum) { succeeded, paused, cancelled, failed: struct { failure: manager.Failure, retryable: bool } };
    phase: Phase = .metadata,
    outcome: Outcome = .succeeded,
    metadata_started: i128 = 0,
    metadata_index: usize = 0,
    metadata_sum: u64 = 0,
    source_sizes: ?[]u64 = null,
    source_index: usize = 0,
    conflict_next_phase: Phase = .open_remote,
    base: u64 = 0,
    file: File = .{},
    checksum: std.crypto.hash.Md5 = .init(.{}),
    checksum_sha: std.crypto.hash.sha2.Sha256 = .init(.{}),
    checksum_offset: u64 = 0,
    local_md5: ?[16]u8 = null,
    remote_md5: ?[16]u8 = null,
    checksum_local_stamp: ?FileStamp = null,
    checksum_remote_stamp: ?FileStamp = null,
    verification_pending: bool = false,
    repair_count: u8 = 0,
    repair_start: ?u64 = null,
    repair_end: ?u64 = null,
    repairing: bool = false,
    // A consumed failed close cannot be retried through its freed pointer.
    // The whole context must acknowledge release before detachIfIdle succeeds.
    unknown_close: bool = false,
    unknown_release_attempted: bool = false,
    unknown_temp: bool = false,
    resume_validation: bool = false,
    resume_failure: ?manager.Failure = null,
    scan_hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    scan_offset: u64 = 0,
    scan_stamp: ?FileStamp = null,
    prefix_length: u64 = 0,
    compare_buffer: [chunk_bytes]u8 = undefined,

    const File = struct {
        local_path: ?[]u8 = null,
        part_path: ?[]u8 = null,
        remote_path: ?[:0]u8 = null,
        local: ?std.Io.File = null,
        remote: ?ssh_session.SftpHandle = null,
        size: u64 = 0,
        offset: u64 = 0,
        resume_offset: u64 = 0,
        skipped: u64 = 0,
        window: ?transfer_window.Window = null,
        chunk: ?transfer_window.Chunk = null,
        chunk_done: usize = 0,
        buffered: bool = false,
        buffer_len: usize = 0,
        buffer_done: usize = 0,
        fingerprint: ?Fingerprint = null,
        initial_stamp: ?FileStamp = null,
        target_stamp: ?FileStamp = null,
        original_target_path: ?[]u8 = null,
        last_checked_target: ?TargetStamp = null,
        observed_target: ?TargetStamp = null,
        target_revision: u64 = 0,
        approved_target: ?TargetStamp = null,
        target_action: enum { exclusive_create, replace_verified } = .exclusive_create,
        execution: ?conflict.ExecutionTicket = null,
        target_capture_needed: bool = false,
        upload_opened: bool = false,
        restoring: bool = false,
        final_published: bool = false,
        buffer: [chunk_bytes]u8 = undefined,
    };
};

const TargetStamp = struct {
    kind: @FieldType(conflict.Metadata, "kind"),
    size: ?u64,
    mtime_ns: ?i128,
    inode: ?std.Io.File.INode = null,

    fn local(value: std.Io.File.Stat) TargetStamp {
        return .{ .kind = switch (value.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        }, .size = value.size, .mtime_ns = value.mtime.toNanoseconds(), .inode = value.inode };
    }
    fn remote(value: ssh_session.SftpAttributes) TargetStamp {
        return .{ .kind = switch (value.kind) {
            .file => .file,
            .directory => .directory,
            .symlink => .symlink,
            else => .unknown,
        }, .size = value.size, .mtime_ns = if (value.modified_at) |n| @as(i128, n) * std.time.ns_per_s else null };
    }
    fn metadata(self: TargetStamp) conflict.Metadata {
        return .{ .kind = self.kind, .size = self.size, .modified_at = if (self.mtime_ns) |n| @intCast(@max(0, @divFloor(n, std.time.ns_per_s))) else null };
    }
};

const ConflictSlot = struct {
    mutex: SpinMutex = .{},
    model: ?*conflict.Model = null,
    entry_base: usize = 0,
    policy: ?conflict.Choice = null,
    next: ?conflict.Next = null,
    snapshot: ?conflict_types.Snapshot = null,
    key: ?conflict.Key = null,
    input: ?conflict_types.Request = null,

    fn clearInput(self: *ConflictSlot) void {
        if (self.input) |request| if (request == .select) std.heap.c_allocator.free(request.select.selection.rename);
        self.input = null;
    }
    fn deinit(self: *ConflictSlot) void {
        self.clearInput();
        if (self.model) |model| {
            model.deinit();
            std.heap.c_allocator.destroy(model);
        }
        self.model = null;
    }
};

/// Detached, value-only diagnostics. Slices borrow this checkpoint until a
/// successful import/cancel. No native Session or driver context is retained.
pub const CheckpointInfo = struct {
    spec: JobSpec,
    original_engine_job: EngineJobId,
    source_index: usize,
    done_bytes: u64,
    total_bytes: u64,
    skipped_files: u32,
    skipped_bytes: u64,
    temp_path: ?[]const u8,
    verification: ?manager.Verification,
};

const CheckpointPayload = struct {
    // All allocations are independent of the old engine/runtime allocator.
    spec: OwnedSpec,
    original_engine_job: EngineJobId,
    continuation: Runtime,
    temp: ?OwnedTemp,
    done_bytes: u64,
    total_bytes: u64,
    total_ready: bool,
    skipped_files: u32,
    skipped_bytes: u64,
    verification: ?manager.Verification,
    remaining_policy: ?conflict.Choice,
};

/// Unique owned continuation. Move this value exactly once and clear the old
/// optional slot. An unconsumed checkpoint cannot be silently deinitialized.
/// It contains no borrowed Session*, ExecBridge or remote adapter callback ctx.
pub const OwnedCheckpoint = struct {
    _payload: ?CheckpointPayload = null,

    pub fn describe(self: *const OwnedCheckpoint) ?CheckpointInfo {
        const p = if (self._payload) |*payload| payload else return null;
        return .{ .spec = p.spec.view(), .original_engine_job = p.original_engine_job, .source_index = p.continuation.source_index, .done_bytes = p.done_bytes, .total_bytes = p.total_bytes, .skipped_files = p.skipped_files, .skipped_bytes = p.skipped_bytes, .temp_path = if (p.temp) |temp| if (temp.created) temp.path else null else null, .verification = p.verification };
    }

    /// Explicit local IO: call only on a background owner, never a UI safeTick.
    /// Upload remnants are preserved. A changed/unknown local artifact keeps
    /// this exact checkpoint owned and deinit Busy, rather than unlinking it.
    pub fn cancel(self: *OwnedCheckpoint, io: std.Io) manager.JobCleanup {
        const p = if (self._payload) |*payload| payload else return .released;
        if (p.temp) |temp| if (temp.created) {
            const stat = std.Io.Dir.cwd().statFile(io, temp.path, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.FileNotFound) {
                    self.releaseStorage();
                    return .released;
                }
                return .unknown;
            };
            if (temp.inode == null or stat.kind != .file or stat.inode != temp.inode.?) return .unknown;
            std.Io.Dir.cwd().deleteFile(io, temp.path) catch |err| {
                if (err != error.FileNotFound) return .unknown;
            };
        };
        self.releaseStorage();
        return .released;
    }

    pub fn deinit(self: *OwnedCheckpoint) error{Busy}!void {
        if (self._payload != null) return error.Busy;
    }

    fn releaseStorage(self: *OwnedCheckpoint) void {
        if (self._payload) |*p| {
            const file = &p.continuation.file;
            std.debug.assert(file.local == null and file.remote == null);
            const allocator = std.heap.c_allocator;
            if (file.local_path) |path| allocator.free(path);
            if (file.part_path) |path| allocator.free(path);
            if (file.remote_path) |path| allocator.free(path);
            if (file.original_target_path) |path| allocator.free(path);
            if (p.continuation.source_sizes) |sizes| allocator.free(sizes);
            if (p.temp) |temp| allocator.free(temp.path);
            p.spec.deinit(allocator);
        }
        self._payload = null;
    }
};

/// 单文件执行结果；worker 据此聚合为整个任务的终态。
const FileOutcome = union(enum) {
    completed: u64,
    cancelled,
    failed: struct { failure: manager.Failure, retryable: bool },
};

const DownloadPaths = struct {
    final: []u8,
    part: []u8,
};

/// 墙钟毫秒（0.17 std.time 移除了 milliTimestamp；实现与
/// src/ui/terminal_view.zig 的 wallClockMs 同源）。
fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    const ms: i64 = @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    return @intCast(@max(0, ms));
}

/// 错误粗分类（契约第 6 条）：SFTP 读写失败 → .io；本地路径类错误按名映射；
/// 其余一律 .connection。
fn classifyError(err: anyerror) manager.Failure {
    return switch (err) {
        error.SftpReadFailed, error.SftpWriteFailed => .io,
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .connection,
    };
}

fn failed(failure: manager.Failure, retryable: bool) FileOutcome {
    std.log.warn("sftp_engine: file op failed failure={s} retryable={}", .{ @tagName(failure), retryable });
    return .{ .failed = .{ .failure = failure, .retryable = retryable } };
}

/// open 阶段的 JobSpec 校验，错误集与 manager.Manager.enqueue 语义一致。
fn validateSpec(spec: JobSpec) !void {
    try window_policy.validateWindowPolicy(spec.chunk_kb, spec.window_chunks, 1);
    if (spec.conflict_context) |context| {
        if (context.intent_id == 0 or context.job == 0 or context.attempt == 0) return error.InvalidConflictContext;
        if (spec.session_id != 0 and spec.session_id != @backingInt(context.original_owner.session_id)) return error.OwnerMismatch;
        if (spec.transfer_binding) |binding| {
            if (!binding.resource_owner.eql(context.resource_owner)) return error.OwnerMismatch;
            if (binding.origin_session) |origin| if (!origin.eql(context.original_owner)) return error.OwnerMismatch;
        }
    }
    if (spec.sources.len == 0) return error.NoSources;
    for (spec.sources) |source| if (source.len == 0) return error.EmptySource;
    if (spec.direction == .upload and spec.remote_dir.len == 0) return error.MissingRemoteDirectory;
    if (spec.direction == .download and spec.local_dir.len == 0) return error.MissingLocalDirectory;
    if (spec.rename) |rename| {
        if (rename.len == 0 or spec.sources.len != 1 or
            std.mem.indexOfScalar(u8, rename, '/') != null or
            std.mem.eql(u8, rename, ".") or std.mem.eql(u8, rename, "..") or
            std.mem.indexOfScalar(u8, rename, 0) != null) return error.InvalidRename;
    }
}

fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (parts, 0..) |part, i| {
        if (part.len == 0) continue;
        try buf.appendSlice(allocator, part);
        if (i + 1 < parts.len and part[part.len - 1] != '/') try buf.append(allocator, '/');
    }
    return buf.toOwnedSlice(allocator);
}

/// 拼接并以 0 结尾（SFTP API 要求 [:0]const u8）。
fn joinPathZ(allocator: std.mem.Allocator, parts: []const []const u8) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (parts, 0..) |part, i| {
        if (part.len == 0) continue;
        try buf.appendSlice(allocator, part);
        if (i + 1 < parts.len and part[part.len - 1] != '/') try buf.append(allocator, '/');
    }
    try buf.append(allocator, 0);
    const owned = try buf.toOwnedSlice(allocator);
    return owned[0 .. owned.len - 1 :0];
}

fn expandLocalHomeWith(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/"))
        return allocator.dupe(u8, path);
    const base = home orelse return error.HomeUnavailable;
    if (base.len == 0 or base[0] != '/') return error.HomeUnavailable;
    if (path.len == 1) return allocator.dupe(u8, base);
    return joinPath(allocator, &.{ base, path[2..] });
}

fn expandLocalHome(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/")) return allocator.dupe(u8, path);
    const home = try @import("../platform/account.zig").home(allocator);
    defer allocator.free(home);
    return expandLocalHomeWith(allocator, path, home);
}

fn uploadLocalPath(allocator: std.mem.Allocator, spec: JobSpec, source: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(source) or std.mem.eql(u8, source, "~") or std.mem.startsWith(u8, source, "~/"))
        return expandLocalHome(allocator, source);
    const directory = try expandLocalHome(allocator, spec.local_dir);
    defer allocator.free(directory);
    return joinPath(allocator, &.{ directory, source });
}

fn uploadRemotePath(allocator: std.mem.Allocator, spec: JobSpec, source: []const u8) ![:0]u8 {
    return joinPathZ(allocator, &.{ spec.remote_dir, spec.rename orelse std.fs.path.basename(source) });
}

fn downloadRemotePath(allocator: std.mem.Allocator, spec: JobSpec, source: []const u8) ![:0]u8 {
    if (std.fs.path.isAbsolute(source)) return allocator.dupeSentinel(u8, source, 0);
    return joinPathZ(allocator, &.{ spec.remote_dir, source });
}

fn downloadLocalPaths(allocator: std.mem.Allocator, spec: JobSpec, source: []const u8, temp_id: []const u8) !DownloadPaths {
    const directory = try expandLocalHome(allocator, spec.local_dir);
    defer allocator.free(directory);
    const final = try joinPath(allocator, &.{ directory, spec.rename orelse std.fs.path.basename(source) });
    errdefer allocator.free(final);
    const part = try std.fmt.allocPrint(allocator, "{s}.zerowork-{s}.part", .{ final, temp_id });
    return .{ .final = final, .part = part };
}

/// 发布一次进度。done 以 total 封顶，保证单调且不越界（Manager 会把
/// done>total 或回退判为 protocol 故障）。
fn updateProgress(job: *Job, done_bytes: u64) void {
    const total = job.total.load(.acquire);
    const clamped = @min(done_bytes -| job.skipped_bytes.load(.acquire), total);
    job.done.store(clamped, .release);
    const elapsed = nowMs() -| job.started_ms;
    // 简化：总耗时均值（未做 500ms 滑动窗口）。
    const speed: u64 = if (elapsed > 0) clamped *| 1000 / elapsed else 0;
    job.speed.store(speed, .release);
}

const Md5Hex = [32]u8;

fn md5File(allocator: std.mem.Allocator, path: []const u8) !Md5Hex {
    var io_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var hash = std.crypto.hash.Md5.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buf}, offset);
        if (n == 0) break;
        hash.update(buf[0..n]);
        offset += n;
    }
    var digest: [16]u8 = undefined;
    hash.final(&digest);
    var out: Md5Hex = undefined;
    _ = std.fmt.bufPrint(&out, "{s}", .{std.fmt.bytesToHex(digest, .lower)}) catch unreachable;
    _ = allocator;
    return out;
}

fn shellQuote(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (path) |byte| {
        if (byte == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn parseMd5(output: []const u8) !Md5Hex {
    var token = std.mem.tokenizeAny(u8, output, " \t\r\n");
    const text = token.next() orelse return error.InvalidRemoteChecksum;
    if (text.len != 32) return error.InvalidRemoteChecksum;
    var out: Md5Hex = undefined;
    for (text, 0..) |byte, i| {
        if (!std.ascii.isHex(byte)) return error.InvalidRemoteChecksum;
        out[i] = std.ascii.toLower(byte);
    }
    return out;
}

fn lastBlockOffset(size: u64, logical_chunk_bytes: u32) u64 {
    return if (size == 0) 0 else (size - 1) / logical_chunk_bytes * logical_chunk_bytes;
}

fn checksumEqual(a: Md5Hex, b: Md5Hex) bool {
    var different: u8 = 0;
    for (a, 0..) |byte, i| different |= byte ^ b[i];
    return different == 0;
}

fn finishFailed(job: *Job, failure: manager.Failure, retryable: bool) void {
    std.log.warn("sftp_engine: job failed failure={s} retryable={}", .{ @tagName(failure), retryable });
    job.failure.set(failure);
    job.retryable.store(retryable, .release);
    job.speed.store(0, .release);
    job.state.store(state_failed, .release);
    job.terminal.store(true, .release);
}

fn finishSucceeded(job: *Job) void {
    job.done.store(job.total.load(.acquire) -| job.skipped_bytes.load(.acquire), .release);
    job.speed.store(0, .release);
    job.state.store(state_succeeded, .release);
    job.terminal.store(true, .release);
}

/// Stop state is independent of the actual scoped-cleanup receipt.
fn finishCancelled(job: *Job) void {
    job.retryable.store(false, .release);
    job.speed.store(0, .release);
    job.state.store(state_cancelled, .release);
    job.terminal.store(true, .release);
}

fn finishPaused(job: *Job) void {
    job.retryable.store(false, .release);
    job.speed.store(0, .release);
    job.state.store(state_paused, .release);
    job.terminal.store(true, .release);
}

pub const SftpEngine = struct {
    allocator: std.mem.Allocator,
    /// attachSession 注入；detachSession 后为 null（指向调用方拥有的 Session）。
    session: ?*ssh_session.Session = null,
    // Opaque adapter carrier only: no native handle, channel, or socket is borrowed.
    service_token: ssh_session.Session = .{},
    /// Inject the existing IO-owner service, never create another native Exec
    /// driver in a transfer thread. V0.1.4 supplies its real authorization key.
    exec_service: ?exec_api.ExecBridge = null,
    exec_key: ?OperationKey = null,
    remote_metadata: RemoteMetadata = .{},
    remote_files: RemoteFiles = .{},
    owner_thread: ?std.Thread = null,
    owner_done: std.atomic.Value(bool) = .init(true),
    stopping: bool = false,
    transport_failed: bool = false,
    io_cursor: usize = 0,
    // One budget per sole IO owner/Session, shared by all accepted jobs.
    pacing: PacingBudget = .{},
    mutex: SpinMutex = .{},
    next_id: EngineJobId = 1,
    jobs: std.ArrayList(*Job) = .empty,
    poll_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*SftpEngine {
        const self = try allocator.create(SftpEngine);
        self.* = .{ .allocator = allocator };
        return self;
    }

    /// Cancel accepted work and join the unique IO owner before freeing inputs.
    pub fn deinit(self: *SftpEngine) void {
        self.detachSession();
        for (self.jobs.items) |job| {
            discardCheckpoint(job);
            job.conflicts.deinit();
            clearTempRecord(job);
            job.spec.deinit(self.allocator);
            self.allocator.destroy(job);
        }
        self.jobs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Caller grants exclusive access to this dedicated Session until detach.
    /// A terminal/other service must never drive this same native binding.
    pub fn attachSession(self: *SftpEngine, session: *ssh_session.Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session = session;
        self.transport_failed = false;
        self.exec_service = null;
        self.exec_key = null;
    }

    /// A byte-service mailbox can keep all native Session access on another
    /// existing IO owner. Its callbacks are the only remote authority here.
    pub fn attachRemoteService(self: *SftpEngine, metadata: RemoteMetadata, files: RemoteFiles) void {
        self.attachSession(&self.service_token);
        self.remote_metadata = metadata;
        self.remote_files = files;
    }

    /// Cancellation request only; joining or native release is never performed
    /// by the caller. Existing accepted IDs remain the release authorities.
    pub fn cancelAll(self: *SftpEngine) void {
        self.mutex.lock();
        const count = self.jobs.items.len;
        self.mutex.unlock();
        for (0..count) |index| {
            self.mutex.lock();
            const id = self.jobs.items[index].id;
            self.mutex.unlock();
            self.cancel(id);
        }
    }

    pub fn attachExecService(self: *SftpEngine, service: exec_api.ExecBridge, key: OperationKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.exec_service = service;
        self.exec_key = key;
    }

    /// Memory-only fault gate. The sole IO owner still settles its current
    /// call and closes its own handles; a transport observation is no release.
    pub fn transportFailed(self: *SftpEngine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.transport_failed = true;
        for (self.jobs.items) |job| if (!job.handed_off and !job.terminal.load(.acquire) and !job.cancel_flag.load(.acquire)) {
            job.pause_flag.store(true, .release);
        };
    }

    pub fn faultJobCount(self: *SftpEngine) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.jobs.items) |job| if (!job.handed_off and (!job.worker_done.load(.acquire) or engineStateOf(job.state.load(.acquire)) == .paused)) {
            count += 1;
        };
        return count;
    }

    /// Exportability deliberately survives loss of transport authority.
    pub fn canExportPaused(self: *SftpEngine, id: EngineJobId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.handed_off or job.cancel_flag.load(.acquire) or !job.worker_done.load(.acquire) or job.release_unknown.load(.acquire) or engineStateOf(job.state.load(.acquire)) != .paused) return false;
            const saved = job.checkpoint orelse return false;
            return saved.file.local == null and saved.file.remote == null and !saved.unknown_close and !saved.unknown_temp and !saved.file.final_published;
        };
        return false;
    }

    /// Explicit shutdown/cancel only, never the fault-observation path.
    pub fn cancelFaulted(self: *SftpEngine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.transport_failed) return;
        var paused = false;
        for (self.jobs.items) |job| if (!job.handed_off) {
            job.cancel_flag.store(true, .release);
            paused = paused or engineStateOf(job.state.load(.acquire)) == .paused;
        };
        if (paused and self.owner_done.load(.acquire)) {
            if (self.owner_thread) |thread| thread.join();
            self.owner_thread = null;
            self.owner_done.store(false, .release);
            self.owner_thread = std.Thread.spawn(.{}, ownerRun, .{self}) catch {
                self.owner_done.store(true, .release);
                for (self.jobs.items) |job| if (!job.handed_off and engineStateOf(job.state.load(.acquire)) == .paused) {
                    job.worker_done.store(false, .release);
                    job.release_unknown.store(true, .release);
                    finishCancelled(job);
                };
                return;
            };
        }
    }

    /// False leaves bindings, cancellation flags and the sole owner handle
    /// untouched, including a native close whose release is still unknown.
    pub fn detachIfIdle(self: *SftpEngine) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (!job.worker_done.load(.acquire)) return false;
        if (!self.owner_done.load(.acquire)) return false;
        if (self.owner_thread) |thread| {
            thread.join(); // owner_done: no file/network operation remains
            self.owner_thread = null;
        }
        self.clearBindings();
        return true;
    }

    /// Explicit teardown stops accepting new work, cancels the captured jobs,
    /// and joins the unique owner. Unknown remote cleanup remains unknown;
    /// this path hands the Session back to its owner for final Session release.
    pub fn detachSession(self: *SftpEngine) void {
        self.mutex.lock();
        self.stopping = true;
        self.session = null;
        self.exec_service = null;
        self.exec_key = null;
        for (self.jobs.items) |job| job.cancel_flag.store(true, .release);
        const thread = self.owner_thread;
        self.owner_thread = null;
        self.mutex.unlock();
        if (thread) |live| live.join();
        self.mutex.lock();
        for (self.jobs.items) |job| if (job.runtime.phase == .cleanup_unknown) discardRuntime(job);
        self.clearBindings();
        self.stopping = false;
        self.mutex.unlock();
    }

    fn clearBindings(self: *SftpEngine) void {
        for (self.jobs.items) |job| {
            job.session = null;
            job.exec_service = null;
            job.exec_key = null;
        }
        self.session = null;
        self.exec_service = null;
        self.exec_key = null;
    }

    /// 返回可交给 Manager 的引擎 vtable（ctx 转译由顶层小函数完成）。
    pub fn engine(self: *SftpEngine) manager.TransferEngine {
        return .{ .ctx = self, .open = engineOpen, .cancel = engineCancel, .pause = enginePause, .resume_job = engineResume, .can_resume = engineCanResume, .poll = enginePoll, .conflict_snapshot = engineConflictSnapshot, .resolve_conflict = engineResolveConflict };
    }

    pub fn open(self: *SftpEngine, spec: JobSpec) anyerror!EngineJobId {
        try validateSpec(spec);
        const captured = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.transport_failed) return error.TransferTransportClosed;
            break :blk .{ .session = self.session orelse return error.SessionNotAttached, .exec_service = self.exec_service, .exec_key = self.exec_key, .remote_metadata = self.remote_metadata, .remote_files = self.remote_files };
        };
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .id = 0, .spec = undefined, .started_ms = nowMs(), .session = captured.session, .exec_service = captured.exec_service, .exec_key = captured.exec_key, .remote_metadata = captured.remote_metadata, .remote_files = captured.remote_files };
        job.spec = try OwnedSpec.clone(self.allocator, spec);
        errdefer job.spec.deinit(self.allocator);

        self.mutex.lock();
        // Detach may have drained the previous workers while input was being
        // copied. Do not spawn a new user of that released binding afterward.
        if (self.stopping or self.transport_failed or self.session != captured.session) {
            self.mutex.unlock();
            return error.SessionChanged;
        }
        for (self.jobs.items) |existing| {
            if (existing.session == captured.session and existing.release_unknown.load(.acquire)) {
                self.mutex.unlock();
                return error.CleanupUnknown;
            }
        }
        if (self.next_id == std.math.maxInt(EngineJobId)) {
            self.mutex.unlock();
            return error.JobIdExhausted;
        }
        // Config permits at most 255 simultaneously running jobs. Manager
        // owns the lower configured limit; this is the engine memory/channel cap.
        var active: usize = 0;
        for (self.jobs.items) |existing| if (!existing.worker_done.load(.acquire)) {
            active += 1;
        };
        if (active >= 255) {
            self.mutex.unlock();
            return error.TransferCapacityExceeded;
        }
        const id = self.next_id;
        self.next_id += 1;
        job.id = id;
        self.jobs.append(self.allocator, job) catch |err| {
            self.mutex.unlock();
            return err;
        };
        if (self.owner_done.load(.acquire)) {
            if (self.owner_thread) |thread| thread.join();
            self.owner_thread = null;
            self.owner_done.store(false, .release);
            self.owner_thread = std.Thread.spawn(.{}, ownerRun, .{self}) catch |err| {
                self.owner_done.store(true, .release);
                _ = self.jobs.pop();
                self.mutex.unlock();
                return err;
            };
        }
        self.mutex.unlock();
        return id;
    }

    pub fn pause(self: *SftpEngine, id: EngineJobId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.cancel_flag.load(.acquire)) return error.Cancelling;
            if (job.terminal.load(.acquire)) {
                if (engineStateOf(job.state.load(.acquire)) == .paused) return;
                return error.InvalidState;
            }
            job.pause_flag.store(true, .release);
            return;
        };
        return error.UnknownJob;
    }

    fn canResumeLocked(self: *SftpEngine, job: *Job) bool {
        const captured = job.session orelse return false;
        if (self.stopping or self.transport_failed or self.session != captured or job.handed_off or job.cancel_flag.load(.acquire) or
            job.release_unknown.load(.acquire) or !job.worker_done.load(.acquire) or
            engineStateOf(job.state.load(.acquire)) != .paused or job.checkpoint == null) return false;
        // Controlled adapters explicitly own their fake Session. Native jobs
        // must still have this exact live SSH binding, never a new active tab.
        if (job.remote_files.open_read == RemoteFiles.openRead and (captured.state != .active or captured.handle == null)) return false;
        const saved = &job.checkpoint.?;
        if (job.spec.direction == .upload and saved.file.upload_opened and saved.file.target_stamp == null) return false;
        return !saved.file.final_published;
    }

    pub fn canResume(self: *SftpEngine, id: EngineJobId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) return self.canResumeLocked(job);
        return false;
    }

    /// Acceptance only moves exact-ID owned state. All filesystem and remote
    /// revalidation runs later on the sole IO owner, under the new attempt ID.
    pub fn resumeJob(self: *SftpEngine, id: EngineJobId) !EngineJobId {
        self.mutex.lock();
        defer self.mutex.unlock();
        var original: ?*Job = null;
        for (self.jobs.items) |job| if (job.id == id) {
            original = job;
            break;
        };
        const previous = original orelse return error.UnknownJob;
        if (!self.canResumeLocked(previous)) return error.SafeResumeUnavailable;
        if (self.next_id == std.math.maxInt(EngineJobId)) return error.JobIdExhausted;
        var active: usize = 0;
        for (self.jobs.items) |job| if (!job.worker_done.load(.acquire)) {
            active += 1;
        };
        if (active >= 255) return error.TransferCapacityExceeded;
        const child = try self.allocator.create(Job);
        errdefer self.allocator.destroy(child);
        const owned = try OwnedSpec.clone(self.allocator, previous.spec.view());
        errdefer {
            var copy = owned;
            copy.deinit(self.allocator);
        }
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        child.* = .{ .id = self.next_id, .spec = owned, .started_ms = nowMs(), .session = previous.session, .exec_service = previous.exec_service, .exec_key = previous.exec_key, .remote_metadata = previous.remote_metadata, .remote_files = previous.remote_files, .runtime = previous.checkpoint.?, .owned_temp = previous.owned_temp };
        if (child.spec.conflict_context) |*context| context.attempt += 1;
        child.conflicts.policy = previous.conflicts.policy;
        child.skipped_files.store(previous.skipped_files.load(.acquire), .release);
        child.skipped_bytes.store(previous.skipped_bytes.load(.acquire), .release);
        child.runtime.file.execution = null;
        if (child.spec.direction == .download) child.runtime.file.approved_target = null;
        child.runtime.resume_validation = true;
        child.runtime.metadata_started = 0;
        child.runtime.resume_failure = null;
        child.runtime.outcome = .succeeded;
        child.runtime.unknown_release_attempted = false;
        child.runtime.file.restoring = true;
        child.runtime.file.remote = null;
        child.runtime.file.local = null;
        child.runtime.phase = if (child.runtime.source_sizes == null or child.runtime.metadata_index < child.spec.sources.len) .metadata else if (child.runtime.source_index == child.spec.sources.len) .cleanup else if (child.runtime.file.local_path == null) .prepare else if (child.runtime.verification_pending) .checksum_open else .source_open;
        if (previous.verification.get().value) |diagnostic| {
            var current = diagnostic;
            if (child.runtime.verification_pending) {
                current.state = .pending;
                current.source_md5 = null;
                current.target_md5 = null;
            }
            child.verification.set(current);
        }
        child.done.store(previous.done.load(.acquire), .release);
        child.total.store(previous.total.load(.acquire), .release);
        child.total_ready.store(previous.total_ready.load(.acquire), .release);
        self.jobs.appendAssumeCapacity(child);
        if (self.owner_done.load(.acquire)) {
            if (self.owner_thread) |thread| thread.join();
            self.owner_thread = null;
            self.owner_done.store(false, .release);
            self.owner_thread = std.Thread.spawn(.{}, ownerRun, .{self}) catch |err| {
                self.owner_done.store(true, .release);
                _ = self.jobs.pop();
                return err;
            };
        }
        previous.checkpoint = null;
        previous.owned_temp = null;
        previous.handed_off = true;
        self.next_id += 1;
        return child.id;
    }

    /// Pure-memory handoff after the exact worker's real paused/released ack.
    /// Failure leaves its original temp, checkpoint and cancel route unchanged.
    pub fn exportPaused(self: *SftpEngine, id: EngineJobId) !OwnedCheckpoint {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.handed_off) return error.CheckpointAlreadyExported;
            if (job.cancel_flag.load(.acquire)) return error.Cancelling;
            if (engineStateOf(job.state.load(.acquire)) != .paused or !job.worker_done.load(.acquire) or job.release_unknown.load(.acquire)) return error.CheckpointNotReleased;
            const saved = job.checkpoint orelse return error.CheckpointUnavailable;
            if (saved.file.local != null or saved.file.remote != null or saved.unknown_close or saved.unknown_temp or saved.file.final_published) return error.CheckpointNotReleased;
            // This last fallible allocation uses an engine-independent allocator.
            // No state is consumed until it succeeds.
            const owned = try OwnedSpec.clone(std.heap.c_allocator, job.spec.view());
            var continuation = saved;
            continuation.file.execution = null;
            continuation.file.approved_target = null;
            const exported: OwnedCheckpoint = .{ ._payload = .{ .spec = owned, .original_engine_job = job.id, .continuation = continuation, .temp = job.owned_temp, .done_bytes = job.done.load(.acquire), .total_bytes = job.total.load(.acquire), .total_ready = job.total_ready.load(.acquire), .skipped_files = job.skipped_files.load(.acquire), .skipped_bytes = job.skipped_bytes.load(.acquire), .verification = job.verification.get().value, .remaining_policy = job.conflicts.policy } };
            job.checkpoint = null;
            job.owned_temp = null;
            job.handed_off = true;
            job.conflict_waiting.store(false, .release);
            return exported;
        };
        return error.UnknownJob;
    }

    /// Accepts only this same frozen transfer under a caller-authorized new
    /// binding. The source/target fingerprints are rechecked on the new IO
    /// owner. Success consumes the checkpoint; every rejection leaves it owned.
    pub fn importPaused(self: *SftpEngine, checkpoint: *OwnedCheckpoint, new_spec: JobSpec) !EngineJobId {
        const payload = checkpoint._payload orelse return error.CheckpointConsumed;
        try validateSpec(new_spec);
        try validateImportedSpec(payload.spec.view(), new_spec);
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.session orelse return error.SessionNotAttached;
        if (self.stopping or self.transport_failed) return error.SessionChanged;
        if (self.remote_files.open_read == RemoteFiles.openRead and (session.state != .active or session.handle == null)) return error.SessionNotActive;
        if (self.next_id == std.math.maxInt(EngineJobId)) return error.JobIdExhausted;
        var active: usize = 0;
        for (self.jobs.items) |existing| {
            if (existing.session == session and existing.release_unknown.load(.acquire)) return error.CleanupUnknown;
            if (!existing.worker_done.load(.acquire)) active += 1;
        }
        if (active >= 255) return error.TransferCapacityExceeded;
        const child = try self.allocator.create(Job);
        errdefer self.allocator.destroy(child);
        const owned = try OwnedSpec.clone(self.allocator, new_spec);
        errdefer {
            var copy = owned;
            copy.deinit(self.allocator);
        }
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        child.* = .{ .id = self.next_id, .spec = owned, .started_ms = nowMs(), .session = session, .exec_service = self.exec_service, .exec_key = self.exec_key, .remote_metadata = self.remote_metadata, .remote_files = self.remote_files, .runtime = payload.continuation, .owned_temp = payload.temp };
        const rt = &child.runtime;
        rt.file.execution = null;
        rt.file.approved_target = null;
        rt.resume_validation = true;
        rt.metadata_started = 0;
        rt.resume_failure = null;
        rt.outcome = .succeeded;
        rt.unknown_release_attempted = false;
        rt.file.restoring = true;
        rt.file.remote = null;
        rt.file.local = null;
        rt.phase = if (rt.source_sizes == null or rt.metadata_index < owned.sources.len) .metadata else if (rt.source_index == owned.sources.len) .cleanup else if (rt.file.local_path == null) .prepare else if (rt.verification_pending) .checksum_open else .source_open;
        child.conflicts.policy = payload.remaining_policy;
        child.done.store(payload.done_bytes, .release);
        child.total.store(payload.total_bytes, .release);
        child.total_ready.store(payload.total_ready, .release);
        child.skipped_files.store(payload.skipped_files, .release);
        child.skipped_bytes.store(payload.skipped_bytes, .release);
        if (payload.verification) |diagnostic| {
            var current = diagnostic;
            if (rt.verification_pending) {
                current.state = .pending;
                current.source_md5 = null;
                current.target_md5 = null;
            }
            child.verification.set(current);
        }
        self.jobs.appendAssumeCapacity(child);
        if (self.owner_done.load(.acquire)) {
            if (self.owner_thread) |thread| thread.join();
            self.owner_thread = null;
            self.owner_done.store(false, .release);
            self.owner_thread = std.Thread.spawn(.{}, ownerRun, .{self}) catch |err| {
                self.owner_done.store(true, .release);
                _ = self.jobs.pop();
                return err;
            };
        }
        // The owner cannot run until this mutex is released. The checkpoint's
        // path/buffer ownership moves exactly once, after all acceptance work.
        var old_spec = checkpoint._payload.?.spec;
        checkpoint._payload = null;
        old_spec.deinit(std.heap.c_allocator);
        self.next_id += 1;
        return child.id;
    }

    fn validateImportedSpec(old: JobSpec, new: JobSpec) !void {
        if (old.chunk_kb != new.chunk_kb or old.window_chunks != new.window_chunks or old.pacing_kbps != new.pacing_kbps) return error.CheckpointSpecMismatch;
        if (old.session_id != new.session_id or old.direction != new.direction or old.resume_transfer != new.resume_transfer or old.md5_check != new.md5_check or old.notify_complete != new.notify_complete or old.sources.len != new.sources.len or !std.mem.eql(u8, old.local_dir, new.local_dir) or !std.mem.eql(u8, old.remote_dir, new.remote_dir)) return error.CheckpointSpecMismatch;
        if ((old.rename == null) != (new.rename == null)) return error.CheckpointSpecMismatch;
        if (old.rename) |name| if (!std.mem.eql(u8, name, new.rename.?)) return error.CheckpointSpecMismatch;
        for (old.sources, new.sources) |a, b| if (!std.mem.eql(u8, a, b)) return error.CheckpointSpecMismatch;
        if ((old.conflict_context == null) != (new.conflict_context == null)) return error.CheckpointIdentityMismatch;
        if (old.conflict_context) |prior| {
            const next = new.conflict_context.?;
            const attempt = std.math.add(u32, prior.attempt, 1) catch return error.AttemptExhausted;
            if (prior.intent_id != next.intent_id or prior.job != next.job or next.attempt != attempt or !prior.original_owner.eql(next.original_owner)) return error.CheckpointIdentityMismatch;
            const binding = new.transfer_binding orelse return error.MissingTransferBinding;
            if (binding.kind != .transfer or binding.binding_id == 0 or binding.binding_generation == 0 or !binding.resource_owner.eql(next.resource_owner)) return error.CheckpointIdentityMismatch;
            const origin = binding.origin_session orelse return error.CheckpointIdentityMismatch;
            if (!origin.eql(prior.original_owner)) return error.CheckpointIdentityMismatch;
            if (old.transfer_binding) |previous| if (previous.eql(binding)) return error.StaleTransferBinding;
            try validateImportedEndpoint(prior.source_endpoint, next.source_endpoint, next);
            try validateImportedEndpoint(prior.target_endpoint, next.target_endpoint, next);
        } else if (old.transfer_binding != null or new.transfer_binding != null) return error.CheckpointIdentityMismatch;
    }

    fn validateImportedEndpoint(old: conflict.Endpoint, new: conflict.Endpoint, context: conflict_types.Context) !void {
        switch (old) {
            .local_fs => if (!old.eql(new)) return error.CheckpointEndpointMismatch,
            .sftp => |prior| {
                if (new != .sftp) return error.CheckpointEndpointMismatch;
                const endpoint = new.sftp;
                if (endpoint.binding_id == 0 or endpoint.binding_generation == 0 or !endpoint.resource_owner.eql(context.resource_owner) or endpoint.connection_snapshot_id != prior.connection_snapshot_id) return error.CheckpointEndpointMismatch;
                const origin = endpoint.origin_session orelse return error.CheckpointEndpointMismatch;
                if (!origin.eql(context.original_owner)) return error.CheckpointEndpointMismatch;
            },
        }
    }

    pub fn cancel(self: *SftpEngine, id: EngineJobId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.handed_off) return; // stale attempt cannot stop its successor
            job.cancel_flag.store(true, .release);
            // The completed paused attempt still owns its temporary artifact.
            // Wake the same native ID; never match a new Job by a file path.
            if (engineStateOf(job.state.load(.acquire)) == .paused and self.owner_done.load(.acquire)) {
                if (self.owner_thread) |thread| thread.join();
                self.owner_thread = null;
                self.owner_done.store(false, .release);
                self.owner_thread = std.Thread.spawn(.{}, ownerRun, .{self}) catch {
                    self.owner_done.store(true, .release);
                    job.worker_done.store(false, .release);
                    job.release_unknown.store(true, .release);
                    finishCancelled(job);
                    return;
                };
            }
            return;
        };
    }

    /// Caller owns this diagnostic snapshot of a quiescent paused or failed
    /// attempt's exact retained path. This is not a safe-resume token.
    pub fn retainedTemp(self: *SftpEngine, allocator: std.mem.Allocator, id: EngineJobId) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            const state = engineStateOf(job.state.load(.acquire));
            if (!job.worker_done.load(.acquire) or (state != .paused and state != .failed)) return null;
            const temp = job.owned_temp orelse return null;
            if (!temp.created) return null;
            return try allocator.dupe(u8, temp.path);
        };
        return error.UnknownJob;
    }

    pub fn conflictSnapshot(self: *SftpEngine, allocator: std.mem.Allocator, id: EngineJobId) !?conflict_types.OwnedSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.handed_off or job.cancel_flag.load(.acquire) or job.terminal.load(.acquire)) return null;
            job.conflicts.mutex.lock();
            defer job.conflicts.mutex.unlock();
            if (!job.conflict_waiting.load(.acquire)) return null;
            return if (job.conflicts.snapshot) |snapshot| try conflict_types.OwnedSnapshot.clone(allocator, snapshot) else null;
        };
        return error.UnknownJob;
    }

    /// Validates the exact published identity and copies the command only. All
    /// target stat/create/replace work remains on this binding's IO owner.
    pub fn resolveConflict(self: *SftpEngine, id: EngineJobId, request: conflict_types.Request) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.id == id) {
            if (job.handed_off or self.session != job.session or self.stopping) return error.StaleConflict;
            if (job.cancel_flag.load(.acquire) or job.pause_flag.load(.acquire) or job.terminal.load(.acquire)) return error.InvalidState;
            job.conflicts.mutex.lock();
            defer job.conflicts.mutex.unlock();
            const slot = &job.conflicts;
            if (!job.conflict_waiting.load(.acquire) or slot.input != null) return error.ConflictNotWaiting;
            const key = slot.key orelse return error.ConflictContextRequired;
            if (!std.meta.eql(request.key(), key)) return error.StaleConflict;
            var copy = request;
            if (copy == .select) {
                if (copy.select.selection.rename.len > 4096) return error.InvalidName;
                copy.select.selection.rename = try std.heap.c_allocator.dupe(u8, request.select.selection.rename);
            }
            slot.input = copy;
            job.conflict_waiting.store(false, .release);
            _ = job.conflict_revision.fetchAdd(1, .release);
            return;
        };
        return error.UnknownJob;
    }

    fn targetRemoteEql(a: TargetStamp, b: TargetStamp) bool {
        return a.kind == b.kind and a.size == b.size and a.mtime_ns == b.mtime_ns;
    }

    fn sourceMetadata(job: *Job) conflict.Metadata {
        const file = &job.runtime.file;
        return .{ .kind = .file, .size = file.size, .modified_at = if (file.fingerprint) |fp| if (fp.stamp.mtime_ns) |n| @intCast(@max(0, @divFloor(n, std.time.ns_per_s))) else null else null };
    }

    fn observeTarget(io: std.Io, job: *Job, path: []const u8) !conflict.Observation {
        const file = &job.runtime.file;
        const stamp: ?TargetStamp = if (job.spec.direction == .download) blk: {
            const value = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
            break :blk TargetStamp.local(value);
        } else blk: {
            const zpath = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
            defer std.heap.c_allocator.free(zpath);
            const value = job.remote_metadata.target_stat(job.remote_metadata.context, job.session.?, zpath) catch |err| {
                if (err == error.FileNotFound or err == error.SftpNotFound) break :blk null;
                return err;
            };
            break :blk TargetStamp.remote(value);
        };
        try stopCheckpoint(job);
        file.last_checked_target = stamp;
        if (std.mem.eql(u8, path, file.original_target_path.?)) {
            if (file.target_revision == 0 or !std.meta.eql(file.observed_target, stamp)) {
                file.target_revision = std.math.add(u64, file.target_revision, 1) catch return error.RevisionExhausted;
                file.observed_target = stamp;
            }
        }
        return if (stamp) |value| .{ .present = .{ .revision = @max(1, file.target_revision), .metadata = value.metadata() } } else .absent;
    }

    fn ensureConflictModel(job: *Job) !?*conflict.Model {
        const slot = &job.conflicts;
        if (slot.model) |model| return model;
        const context = job.spec.conflict_context orelse return null;
        const allocator = std.heap.c_allocator;
        const first = job.runtime.source_index;
        const seeds = try allocator.alloc(conflict.EntrySeed, job.spec.sources.len - first);
        defer allocator.free(seeds);
        var initialized: usize = 0;
        defer for (seeds[0..initialized]) |seed| {
            allocator.free(seed.source_path);
            allocator.free(seed.target_path);
        };
        for (seeds, first..) |*seed, index| {
            const source = job.spec.sources[index];
            const source_path = if (job.spec.direction == .upload) try uploadLocalPath(allocator, job.spec.view(), source) else try downloadRemotePath(allocator, job.spec.view(), source);
            errdefer allocator.free(source_path);
            const target = if (job.spec.direction == .upload) try uploadRemotePath(allocator, job.spec.view(), source) else blk: {
                const directory = try expandLocalHome(allocator, job.spec.local_dir);
                defer allocator.free(directory);
                break :blk try joinPath(allocator, &.{ directory, job.spec.rename orelse std.fs.path.basename(source) });
            };
            seed.* = .{ .job = context.job, .attempt = context.attempt, .source_path = source_path, .source_metadata = if (index == first) sourceMetadata(job) else .{ .kind = .file, .size = job.runtime.source_sizes.?[index] }, .target_path = target };
            initialized += 1;
        }
        const model = try allocator.create(conflict.Model);
        errdefer allocator.destroy(model);
        model.* = try conflict.Model.init(allocator, .{ .id = context.intent_id, .original_owner = context.original_owner, .resource_owner = context.resource_owner, .direction = job.spec.direction, .source_endpoint = context.source_endpoint, .target_endpoint = context.target_endpoint, .entries = seeds });
        slot.entry_base = first;
        if (slot.policy) |policy| model.inheritRemainingPolicy(policy);
        slot.model = model;
        return model;
    }

    fn publishConflict(job: *Job, next: conflict.Next) !void {
        const slot = &job.conflicts;
        slot.next = next;
        const context = job.spec.conflict_context;
        switch (next) {
            .waiting => |prompt| {
                slot.key = prompt.key;
                slot.snapshot = .{ .engine_job = job.id, .context = context, .pending = .{ .choice = prompt } };
                job.conflict_waiting.store(true, .release);
            },
            .overwrite_confirmation => |confirmation| {
                slot.key = (try slot.model.?.snapshot(job.runtime.source_index - slot.entry_base)).key;
                slot.snapshot = .{ .engine_job = job.id, .context = context, .pending = .{ .overwrite_confirmation = confirmation } };
                job.conflict_waiting.store(true, .release);
            },
            else => job.conflict_waiting.store(false, .release),
        }
        _ = job.conflict_revision.fetchAdd(1, .release);
        job.runtime.phase = .conflict_step;
    }

    fn offerConflict(job: *Job, actual: conflict.Observation, after: Runtime.Phase) !void {
        const slot = &job.conflicts;
        slot.mutex.lock();
        defer slot.mutex.unlock();
        job.runtime.conflict_next_phase = after;
        const model = try ensureConflictModel(job) orelse {
            const file = &job.runtime.file;
            slot.key = null;
            slot.next = null;
            slot.snapshot = .{ .engine_job = job.id, .context = null, .pending = .{ .context_required = .{ .entry = @intCast(job.runtime.source_index), .revision = file.target_revision, .source_path = if (job.spec.direction == .upload) file.local_path.? else file.remote_path.?, .target_path = file.original_target_path.?, .source_metadata = sourceMetadata(job), .target = actual } } };
            job.runtime.phase = .conflict_step;
            job.conflict_waiting.store(true, .release);
            _ = job.conflict_revision.fetchAdd(1, .release);
            return;
        };
        const index = job.runtime.source_index - slot.entry_base;
        try model.setUnseenSourceMetadata(index, sourceMetadata(job));
        const next = if (job.runtime.file.execution) |ticket| blk: {
            job.runtime.file.execution = null;
            break :blk try model.finish(ticket, .{ .target_changed = actual });
        } else blk: {
            if (actual != .present) return error.TargetChanged;
            const prompt = try model.offer(index, actual.present);
            break :blk if (prompt.selection.choice != null) try model.next(prompt.key) else conflict.Next{ .waiting = prompt };
        };
        try publishConflict(job, next);
    }

    fn targetGate(io: std.Io, job: *Job, after: Runtime.Phase) !void {
        const file = &job.runtime.file;
        const path = if (job.spec.direction == .download) file.local_path.? else file.remote_path.?;
        const actual = try observeTarget(io, job, path);
        if (actual == .present) try offerConflict(job, actual, after) else {
            file.target_action = .exclusive_create;
            file.approved_target = null;
            job.runtime.phase = after;
        }
    }

    fn targetChangedBeforeWrite(io: std.Io, job: *Job) !bool {
        const file = &job.runtime.file;
        const expected = file.approved_target;
        const path = if (job.spec.direction == .download) file.local_path.? else file.remote_path.?;
        const actual = try observeTarget(io, job, path);
        const valid = if (file.target_action == .exclusive_create) actual == .absent else expected != null and std.meta.eql(expected, file.last_checked_target);
        if (valid) return false;
        const after: Runtime.Phase = if (job.spec.direction == .download) .publish_file else .open_remote;
        if (file.target_action == .exclusive_create and file.execution != null and actual == .present) {
            try nameRace(io, job, after);
        } else try offerConflict(job, actual, after);
        return true;
    }

    fn nameRace(io: std.Io, job: *Job, after: Runtime.Phase) !void {
        const file = &job.runtime.file;
        const slot = &job.conflicts;
        const path = if (job.spec.direction == .download) file.local_path.? else file.remote_path.?;
        const actual = try observeTarget(io, job, path);
        if (file.execution) |ticket| {
            slot.mutex.lock();
            defer slot.mutex.unlock();
            file.execution = null;
            const next = try slot.model.?.finish(ticket, .name_exists);
            job.runtime.conflict_next_phase = after;
            try publishConflict(job, next);
        } else try offerConflict(job, actual, after);
    }

    fn conflictTurn(io: std.Io, job: *Job) !Turn {
        const slot = &job.conflicts;
        slot.mutex.lock();
        defer slot.mutex.unlock();
        const model = slot.model orelse return .waiting;
        const index = job.runtime.source_index - slot.entry_base;
        if (slot.input) |request| {
            defer slot.clearInput();
            const applied = switch (request) {
                .select => |value| model.select(value.key, value.selection),
                .confirm_overwrite => |value| model.confirmOverwrite(value.ticket),
                .return_to_choice => |value| blk: {
                    _ = model.returnToChoice(value.ticket) catch |err| break :blk @as(anyerror!void, err);
                    break :blk @as(anyerror!void, {});
                },
            };
            applied catch |err| {
                try publishConflict(job, .{ .waiting = try model.snapshot(index) });
                slot.snapshot.?.issue = if (err == error.InvalidName) .invalid_name else .invalid_decision;
                return .waiting;
            };
            const prompt = try model.snapshot(index);
            if (request == .return_to_choice) {
                try publishConflict(job, .{ .waiting = prompt });
                return .waiting;
            }
            const next = model.next(prompt.key) catch |err| {
                try publishConflict(job, .{ .waiting = prompt });
                if (err != error.NoSelection) slot.snapshot.?.issue = if (err == error.InvalidName) .invalid_name else .invalid_decision;
                return .waiting;
            };
            try publishConflict(job, next);
        }
        const next = slot.next orelse return .waiting;
        switch (next) {
            .waiting, .overwrite_confirmation => return .waiting,
            .target_revalidate, .candidate_stat => |check| {
                // Only this worker mutates the Model; UI commands merely queue.
                // Release the control lock across filesystem/network IO.
                slot.mutex.unlock();
                const actual = observeTarget(io, job, check.path) catch |err| {
                    slot.mutex.lock();
                    return err;
                };
                slot.mutex.lock();
                const observed = model.observe(check, actual) catch |err| {
                    if (err != error.UnsupportedOverwrite) return err;
                    try publishConflict(job, .{ .waiting = try model.snapshot(index) });
                    slot.snapshot.?.issue = .unsupported;
                    return .waiting;
                };
                try publishConflict(job, observed);
            },
            .execute => |execution| {
                const file = &job.runtime.file;
                if (execution.action == .replace_verified) {
                    const stamp = file.last_checked_target orelse return error.TargetChanged;
                    if (stamp.kind != .file or stamp.size == null or stamp.mtime_ns == null) {
                        try publishConflict(job, try model.finish(execution.ticket, .failed));
                        slot.snapshot.?.issue = .unsupported;
                        return .waiting;
                    }
                    file.approved_target = stamp;
                    file.target_action = .replace_verified;
                } else {
                    file.approved_target = null;
                    file.target_action = .exclusive_create;
                }
                if (job.spec.direction == .upload) {
                    const path = try std.heap.c_allocator.dupeSentinel(u8, execution.target_path, 0);
                    std.heap.c_allocator.free(file.remote_path.?);
                    file.remote_path = path;
                } else {
                    const path = try std.heap.c_allocator.dupe(u8, execution.target_path);
                    std.heap.c_allocator.free(file.local_path.?);
                    file.local_path = path;
                }
                file.execution = execution.ticket;
                slot.policy = model.remainingPolicy();
                job.runtime.phase = job.runtime.conflict_next_phase;
                job.conflict_waiting.store(false, .release);
                _ = job.conflict_revision.fetchAdd(1, .release);
            },
            .completed => |completion| {
                if (completion.kind != .skipped) return error.InvalidState;
                const file = &job.runtime.file;
                if (file.local) |handle| {
                    handle.close(io);
                    file.local = null;
                }
                // A publish race can happen after data already reached this
                // Job's temp. Count actual bytes once; only untransferred bytes
                // are excluded, while the file is still explicitly skipped.
                try removeOwnedTemp(io, job);
                _ = job.skipped_files.fetchAdd(1, .release);
                _ = job.skipped_bytes.fetchAdd(file.size - file.offset, .release);
                slot.policy = model.remainingPolicy();
                completeSource(job);
                job.conflict_waiting.store(false, .release);
                _ = job.conflict_revision.fetchAdd(1, .release);
            },
            .pause => return error.Paused,
        }
        return .advanced;
    }

    fn finishConflictExecution(job: *Job) !void {
        const slot = &job.conflicts;
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (slot.model) |model| {
            const file = &job.runtime.file;
            if (file.execution) |ticket| {
                _ = try model.finish(ticket, if (file.target_action == .replace_verified) .replaced else .{ .created = if (job.spec.direction == .download) file.local_path.? else file.remote_path.? });
                file.execution = null;
            } else try model.finishUncontested(job.runtime.source_index - slot.entry_base);
        }
    }

    fn cleanupOf(job: *Job) manager.JobCleanup {
        if (job.release_unknown.load(.acquire)) return .unknown;
        return if (job.worker_done.load(.acquire)) .released else .awaiting;
    }

    /// 逐任务轮询：进行中的任务仅在进度变化时发事件（Manager.tick 会 drain
    /// 到 null，若总是发重复事件会导致死循环）；仅发布状态/清理回执的变化。
    pub fn poll(self: *SftpEngine) ?EngineProgress {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.jobs.items.len;
        if (count == 0) return null;
        var scanned: usize = 0;
        var event: ?EngineProgress = null;
        while (scanned < count) : (scanned += 1) {
            const job = self.jobs.items[(self.poll_cursor + scanned) % count];
            const diagnostic = job.verification.get();
            if (job.terminal.load(.acquire)) {
                const cleanup = cleanupOf(job);
                const state = engineStateOf(job.state.load(.acquire));
                if (job.reported_state == state and job.reported_cleanup == cleanup and job.reported_verification == diagnostic.revision) continue;
                job.reported_state = state;
                job.reported_cleanup = cleanup;
                job.reported_verification = diagnostic.revision;
                event = .{
                    .job = job.id,
                    .done_bytes = job.done.load(.acquire),
                    .total_bytes = job.total.load(.acquire),
                    .speed_bps = job.speed.load(.acquire),
                    .state = state,
                    .job_cleanup = cleanup,
                    .retryable = job.retryable.load(.acquire),
                    .failure = job.failure.get(),
                    .verification = diagnostic.value,
                    .skipped_files = job.skipped_files.load(.acquire),
                    .skipped_bytes = job.skipped_bytes.load(.acquire),
                    .conflict_waiting = job.conflict_waiting.load(.acquire),
                };
                break;
            }
            // Manager's first published total is immutable. Publishing the
            // placeholder zero here would reject the later metadata result.
            if (!job.total_ready.load(.acquire)) continue;
            const done = job.done.load(.acquire);
            const conflict_revision = job.conflict_revision.load(.acquire);
            const skipped_bytes = job.skipped_bytes.load(.acquire);
            if (!job.emitted or done != job.emitted_done or job.emitted_verification != diagnostic.revision or job.emitted_conflict != conflict_revision or job.emitted_skipped != skipped_bytes) {
                job.emitted_conflict = conflict_revision;
                job.emitted_skipped = skipped_bytes;
                job.emitted = true;
                job.emitted_done = done;
                job.emitted_verification = diagnostic.revision;
                event = .{
                    .job = job.id,
                    .done_bytes = done,
                    .total_bytes = job.total.load(.acquire),
                    .speed_bps = job.speed.load(.acquire),
                    .state = .running,
                    .job_cleanup = .awaiting,
                    .verification = diagnostic.value,
                    .skipped_files = job.skipped_files.load(.acquire),
                    .skipped_bytes = job.skipped_bytes.load(.acquire),
                    .conflict_waiting = job.conflict_waiting.load(.acquire),
                };
                break;
            }
        }
        if (event != null) self.poll_cursor = (self.poll_cursor + scanned + 1) % count;
        return event;
    }

    const Turn = enum { advanced, waiting };

    fn ownerRun(self: *SftpEngine) void {
        var io_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        defer io_threaded.deinit();
        const io = io_threaded.io();
        while (true) {
            self.mutex.lock();
            const count = self.jobs.items.len;
            var rate: u32 = 0;
            for (self.jobs.items) |candidate| {
                if (candidate.handed_off or candidate.worker_done.load(.acquire)) continue;
                const requested = candidate.spec.pacing_kbps;
                if (requested != 0 and (rate == 0 or requested < rate)) rate = requested;
            }
            self.pacing.setRate(rate, pacingNow());
            var next: ?*Job = null;
            var scanned: usize = 0;
            while (scanned < count) : (scanned += 1) {
                const candidate = self.jobs.items[(self.io_cursor + scanned) % count];
                if (!candidate.handed_off and candidate.worker_done.load(.acquire) and
                    engineStateOf(candidate.state.load(.acquire)) == .paused and candidate.cancel_flag.load(.acquire))
                {
                    candidate.worker_done.store(false, .release);
                    candidate.runtime.phase = .cleanup;
                    candidate.runtime.outcome = .cancelled;
                }
                if (candidate.worker_done.load(.acquire) or candidate.runtime.phase == .done) continue;
                if (candidate.runtime.phase == .cleanup_unknown and candidate.runtime.unknown_release_attempted) {
                    if (self.stopping) discardRuntime(candidate);
                    continue;
                }
                next = candidate;
                self.io_cursor = (self.io_cursor + scanned + 1) % count;
                break;
            }
            if (next == null) {
                // Atomic with open(): an arriving Job either belongs to this
                // loop or joins this ended owner and starts exactly one new one.
                self.owner_done.store(true, .release);
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            const job = next.?;
            const turn = self.advance(io, job) catch |err| blk: {
                if (err == error.TransferPacingPending) break :blk Turn.waiting;
                // A native read can observe FIN before Runtime's descriptor
                // observer wakes. Preserve the checkpoint before error cleanup
                // discards it, but never infer a transport fault from errno.
                _ = self.observeTransportFailure(job);
                failContinuation(job, err);
                break :blk Turn.advanced;
            };
            if (turn == .waiting) pauseOwner();
        }
    }

    fn pacingNow() u64 {
        return @intCast(@max(0, monotonicNs()));
    }

    fn readRemote(self: *SftpEngine, job: *Job, bytes: []u8) !usize {
        if (bytes.len == 0) return 0;
        const allowed = self.pacing.allowance(pacingNow(), bytes.len);
        if (allowed == 0) return error.TransferPacingPending;
        try stopCheckpoint(job);
        const n = try job.remote_files.read(job.remote_files.context, &job.runtime.file.remote.?, bytes[0..allowed]);
        if (n > allowed) return error.SftpReadFailed;
        self.pacing.consume(n);
        return n;
    }

    fn writeRemote(self: *SftpEngine, job: *Job, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;
        const allowed = self.pacing.allowance(pacingNow(), bytes.len);
        if (allowed == 0) return error.TransferPacingPending;
        try stopCheckpoint(job);
        const n = try job.remote_files.write(job.remote_files.context, &job.runtime.file.remote.?, bytes[0..allowed]);
        if (n > allowed) return error.SftpWriteFailed;
        self.pacing.consume(n);
        return n;
    }

    fn pauseOwner() void {
        var delay: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&delay, null);
    }

    fn observeTransportFailure(self: *SftpEngine, job: *Job) bool {
        const session = job.session orelse return false;
        if (session.socket_fd < 0) return false;
        var descriptor = [_]std.c.pollfd{.{ .fd = session.socket_fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&descriptor, 1, 0) <= 0 or descriptor[0].revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL) == 0) return false;
        self.transportFailed();
        return true;
    }

    fn failContinuation(job: *Job, err: anyerror) void {
        if (job.spec.md5_check and err != error.Cancelled and err != error.Paused and
            !job.cancel_flag.load(.acquire) and !job.pause_flag.load(.acquire))
        {
            if (job.runtime.phase != .publish_file or err == error.SourceChanged or err == error.PrefixChanged or err == error.TempOwnershipChanged)
                verificationState(job, if (err == error.ChecksumMismatch) .failed else .unavailable);
        }
        if (job.cancel_flag.load(.acquire) or err == error.Cancelled) {
            job.runtime.outcome = .cancelled;
        } else if (job.pause_flag.load(.acquire) or err == error.Paused) {
            job.runtime.outcome = .paused;
        } else if (job.runtime.resume_validation) {
            job.runtime.outcome = .paused;
            job.runtime.resume_failure = switch (err) {
                error.SourceChanged, error.PrefixChanged, error.TempOwnershipChanged, error.PathAlreadyExists => .conflict,
                error.FileNotFound, error.SftpNotFound => .not_found,
                error.AccessDenied, error.PermissionDenied, error.SftpPermissionDenied => .permission_denied,
                else => .io,
            };
        } else {
            job.runtime.outcome = .{ .failed = .{
                .failure = switch (err) {
                    error.MetadataTimeout => .timeout,
                    error.TotalSizeOverflow => .invalid_request,
                    error.InvalidWindow, error.InvalidAck, error.InvalidResumeOffset => .protocol,
                    error.ChecksumMismatch => .checksum,
                    error.SourceChanged, error.PrefixChanged, error.TempOwnershipChanged => .conflict,
                    error.PathAlreadyExists, error.OperationUnsupported => .io,
                    else => classifyError(err),
                },
                .retryable = if (job.runtime.verification_pending) false else switch (err) {
                    error.AccessDenied, error.PermissionDenied, error.SftpPermissionDenied, error.TotalSizeOverflow, error.InvalidWindow, error.InvalidAck, error.InvalidResumeOffset, error.SourceChanged, error.PrefixChanged, error.ChecksumMismatch, error.PathAlreadyExists, error.OperationUnsupported, error.TempOwnershipChanged => false,
                    else => true,
                },
            } };
        }
        job.runtime.phase = .cleanup;
    }

    fn advance(self: *SftpEngine, io: std.Io, job: *Job) !Turn {
        const rt = &job.runtime;
        if (rt.phase != .cleanup_unknown and job.cancel_flag.load(.acquire)) {
            rt.outcome = .cancelled;
            rt.phase = .cleanup;
        } else if (rt.phase != .cleanup and rt.phase != .cleanup_unknown and job.pause_flag.load(.acquire)) {
            rt.outcome = .paused;
            rt.phase = .cleanup;
        }
        // A late cancel of a released paused attempt only touches its owned
        // local artifact; detach may already have returned the native Session.
        if (rt.phase == .cleanup) {
            job.conflict_waiting.store(false, .release);
            return self.cleanupTurn(io, job);
        }
        const session = job.session orelse return error.SessionNotActive;
        switch (rt.phase) {
            .metadata => {
                if (rt.source_sizes == null) {
                    // Every attached binding is exclusive to this IO owner.
                    // The legacy SFTP API completes EAGAIN internally only in
                    // blocking mode; never switch Jobs inside such a call.
                    if (session.state == .active and session.handle != null) session.setBlocking();
                    rt.source_sizes = try std.heap.c_allocator.alloc(u64, job.spec.sources.len);
                    rt.metadata_started = monotonicNs();
                }
                if (rt.metadata_started == 0) rt.metadata_started = monotonicNs();
                try metadataCheckpoint(job, rt.metadata_started);
                const source = job.spec.sources[rt.metadata_index];
                const size = switch (job.spec.direction) {
                    .upload => blk: {
                        const path = try uploadLocalPath(std.heap.c_allocator, job.spec.view(), source);
                        defer std.heap.c_allocator.free(path);
                        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
                        defer file.close(io);
                        break :blk (try file.stat(io)).size;
                    },
                    .download => blk: {
                        const path = try downloadRemotePath(std.heap.c_allocator, job.spec.view(), source);
                        defer std.heap.c_allocator.free(path);
                        break :blk try job.remote_metadata.size(job.remote_metadata.context, session, path);
                    },
                };
                try metadataCheckpoint(job, rt.metadata_started);
                rt.source_sizes.?[rt.metadata_index] = size;
                rt.metadata_sum = std.math.add(u64, rt.metadata_sum, size) catch return error.TotalSizeOverflow;
                rt.metadata_index += 1;
                if (rt.metadata_index == job.spec.sources.len) {
                    job.total.store(rt.metadata_sum, .release);
                    job.total_ready.store(true, .release);
                    rt.phase = .prepare;
                }
            },
            .prepare => try prepareFile(io, job),
            .source_open => try sourceScanOpen(io, job),
            .source_scan => try self.sourceScanTurn(io, job),
            .source_close => {
                if (!self.closeFileHandle(job)) return .waiting;
                const file = &rt.file;
                const has_partial = if (job.spec.direction == .download)
                    (if (job.owned_temp) |temp| temp.created else false)
                else
                    file.target_stamp != null;
                if (rt.resume_validation and file.restoring and has_partial) {
                    rt.phase = .prefix_open;
                } else {
                    file.restoring = false;
                    rt.resume_validation = false;
                    file.offset = 0;
                    file.resume_offset = 0;
                    file.window = try transfer_window.Window.init(file.size, try window_policy.chunkBytes(job.spec.chunk_kb), job.spec.window_chunks);
                    rt.phase = .target_stat;
                }
            },
            .target_retry_close => {
                if (!self.closeFileHandle(job)) return .waiting;
                const actual = try observeTarget(io, job, rt.file.remote_path.?);
                try offerConflict(job, actual, .open_remote);
            },
            .target_stat => try targetGate(io, job, .open_remote),
            .conflict_step => return conflictTurn(io, job),
            .prefix_open => try prefixOpen(io, job),
            .prefix_scan => try self.prefixTurn(io, job),
            .prefix_close => {
                if (!self.closeFileHandle(job)) return .waiting;
                const file = &rt.file;
                if (job.spec.direction == .download) {
                    file.local.?.close(io);
                    file.local = null;
                }
                const logical_chunk_bytes = try window_policy.chunkBytes(job.spec.chunk_kb);
                file.resume_offset = rt.prefix_length - rt.prefix_length % logical_chunk_bytes;
                file.offset = file.resume_offset;
                file.chunk = null;
                file.chunk_done = 0;
                file.buffered = false;
                file.skipped = 0;
                file.window = try transfer_window.Window.init(file.size, try window_policy.chunkBytes(job.spec.chunk_kb), job.spec.window_chunks);
                try file.window.?.resumeAt(file.resume_offset);
                rt.phase = .open_remote;
            },
            .open_remote => {
                const file = &rt.file;
                if (job.spec.direction == .upload and !file.restoring) {
                    if (try targetChangedBeforeWrite(io, job)) return .advanced;
                    if (file.target_action == .exclusive_create) {
                        file.remote = job.remote_files.create_exclusive(job.remote_files.context, session, file.remote_path.?) catch |err| {
                            const actual = try observeTarget(io, job, file.remote_path.?);
                            if (actual == .present) {
                                try nameRace(io, job, .open_remote);
                                return .advanced;
                            }
                            return err;
                        };
                    } else {
                        // WRITE only first. Verify this opened handle before
                        // fsetstat(size=0), so a path race cannot TRUNC on open.
                        file.remote = try job.remote_files.open_write(job.remote_files.context, session, file.remote_path.?, 0, true);
                        const opened = TargetStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, session, &file.remote.?));
                        if (file.approved_target == null or !targetRemoteEql(opened, file.approved_target.?)) {
                            rt.phase = .target_retry_close;
                            return .advanced;
                        }
                        try stopCheckpoint(job);
                        try job.remote_files.truncate(job.remote_files.context, session, &file.remote.?);
                    }
                } else file.remote = if (job.spec.direction == .upload)
                    try job.remote_files.open_write(job.remote_files.context, session, file.remote_path.?, file.resume_offset, true)
                else
                    try job.remote_files.open_read(job.remote_files.context, session, file.remote_path.?, .transfer);
                if (job.spec.direction == .download) {
                    const current = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, session, &file.remote.?));
                    if (file.fingerprint == null or !current.same(file.fingerprint.?.stamp)) return error.SourceChanged;
                }
                if (job.spec.direction == .upload) file.upload_opened = true;
                if (job.spec.direction == .upload and file.restoring) {
                    const current = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, session, &file.remote.?));
                    if (file.target_stamp == null or !current.same(file.target_stamp.?)) return error.PrefixChanged;
                }
                if (job.spec.direction == .upload) {
                    file.target_capture_needed = true;
                    rt.resume_validation = false;
                }
                rt.phase = if (job.spec.direction == .download) .open_local else .transfer;
            },
            .open_local => {
                const file = &rt.file;
                if (file.restoring) {
                    try verifyOwnedTemp(io, job);
                    file.local = try std.Io.Dir.cwd().openFile(io, file.part_path.?, .{ .mode = .read_write });
                    const stat = try file.local.?.stat(io);
                    const reopened = try FileStamp.local(stat);
                    if (stat.inode != job.owned_temp.?.inode.? or file.target_stamp == null or !reopened.same(file.target_stamp.?)) return error.PrefixChanged;
                    rt.resume_validation = false;
                } else {
                    file.local = try std.Io.Dir.cwd().createFile(io, file.part_path.?, .{ .exclusive = true });
                    job.owned_temp.?.created = true;
                    job.owned_temp.?.inode = (try file.local.?.stat(io)).inode;
                }
                rt.phase = if (file.resume_offset > 0) .skip_remote else .transfer;
            },
            .skip_remote => {
                const file = &rt.file;
                const want: usize = @intCast(@min(chunk_bytes, file.resume_offset - file.skipped));
                const n = try self.readRemote(job, file.buffer[0..want]);
                if (n == 0 or n > want) return error.SftpReadFailed;
                file.skipped += n;
                if (file.skipped == file.resume_offset) rt.phase = .transfer;
            },
            .transfer => try self.transferSlice(io, job),
            .close_remote => {
                const file = &rt.file;
                if (file.fingerprint) |original| {
                    const current = if (job.spec.direction == .download)
                        try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, session, &file.remote.?))
                    else
                        try FileStamp.local(try file.local.?.stat(io));
                    if (!current.same(original.stamp)) return error.SourceChanged;
                }
                if (job.spec.direction == .upload and file.target_capture_needed) {
                    const target = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, session, &file.remote.?));
                    if (target.size != @max(file.offset, rt.prefix_length)) return error.PrefixChanged;
                    file.target_stamp = target;
                    file.target_capture_needed = false;
                }
                if (!self.closeFileHandle(job)) return .waiting;
                rt.phase = .finalize_file;
            },
            .finalize_file => {
                const file = &rt.file;
                if (file.local) |local| {
                    if (job.spec.direction == .download) {
                        try local.sync(io);
                        file.target_stamp = try FileStamp.local(try local.stat(io));
                        file.target_capture_needed = false;
                    }
                    local.close(io);
                    file.local = null;
                }
                try stopCheckpoint(job);
                updateProgress(job, rt.base + file.size);
                rt.repairing = false;
                if (job.spec.md5_check) {
                    rt.verification_pending = true;
                    verificationState(job, .pending);
                    rt.phase = .checksum_open;
                } else rt.phase = .publish_file;
            },
            .checksum_open => try checksumOpen(io, job),
            .checksum_local => try checksumLocalTurn(io, job),
            .checksum_remote => try self.checksumRemoteTurn(job),
            .checksum_close => {
                if (!self.closeFileHandle(job)) return .waiting;
                rt.phase = .checksum_compare;
            },
            .checksum_compare => try checksumCompare(job),
            .repair_open => try repairOpen(io, job),
            .publish_file => try publishFile(io, job),
            .cleanup => return self.cleanupTurn(io, job),
            .cleanup_unknown => return self.releaseConsumedContext(job),
            .done => unreachable,
        }
        return .advanced;
    }

    fn metadataCheckpoint(job: *Job, started: i128) !void {
        try stopCheckpoint(job);
        // Blocking native calls retain the existing Session timeout. Cancel
        // never frees their frozen arguments or binding while they are in flight.
        if (monotonicNs() -| started >= metadata_budget_ns) return error.MetadataTimeout;
    }

    fn prepareFile(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        const allocator = std.heap.c_allocator;
        const spec = job.spec.view();
        const source = spec.sources[rt.source_index];
        if (spec.md5_check) {
            rt.local_md5 = null;
            rt.remote_md5 = null;
            job.verification.clear();
        }
        file.size = rt.source_sizes.?[rt.source_index];
        file.remote_path = try if (spec.direction == .upload)
            uploadRemotePath(allocator, spec, source)
        else
            downloadRemotePath(allocator, spec, source);
        if (spec.direction == .upload) {
            file.local_path = try uploadLocalPath(allocator, spec, source);
            file.local = try std.Io.Dir.cwd().openFile(io, file.local_path.?, .{});
            if ((try file.local.?.stat(io)).size != file.size) return error.SourceChanged;
        } else {
            var nonce: [16]u8 = undefined;
            io.random(&nonce);
            var identity: [80]u8 = undefined;
            const temp_id = try std.fmt.bufPrint(&identity, "{d}-{s}", .{ job.id, std.fmt.bytesToHex(nonce, .lower) });
            const paths = try downloadLocalPaths(allocator, spec, source, temp_id);
            file.local_path = paths.final;
            file.part_path = paths.part;
            std.debug.assert(job.owned_temp == null);
            job.owned_temp = .{ .path = try allocator.dupe(u8, paths.part) };
            // A new attempt never adopts an unrelated legacy .part. Safe
            // resume requires a future explicit original-Job ownership token.
        }
        file.original_target_path = try allocator.dupe(u8, if (spec.direction == .download) file.local_path.? else file.remote_path.?);
        file.offset = file.resume_offset;
        file.window = try transfer_window.Window.init(file.size, try window_policy.chunkBytes(job.spec.chunk_kb), job.spec.window_chunks);
        try file.window.?.resumeAt(file.resume_offset);
        rt.phase = .source_open;
    }

    fn sourceScanOpen(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        rt.scan_hash = .init(.{});
        rt.scan_offset = 0;
        if (job.spec.direction == .upload) {
            if (file.local == null) file.local = try std.Io.Dir.cwd().openFile(io, file.local_path.?, .{});
            rt.scan_stamp = try FileStamp.local(try file.local.?.stat(io));
        } else {
            const by_path = try FileStamp.remote(try job.remote_metadata.stat(job.remote_metadata.context, job.session.?, file.remote_path.?));
            file.remote = try job.remote_files.open_read(job.remote_files.context, job.session.?, file.remote_path.?, .fingerprint);
            rt.scan_stamp = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
            if (!by_path.same(rt.scan_stamp.?)) return error.SourceChanged;
        }
        if (rt.scan_stamp.?.size != file.size) return error.SourceChanged;
        if (file.initial_stamp) |original| {
            if (!original.same(rt.scan_stamp.?)) return error.SourceChanged;
        } else file.initial_stamp = rt.scan_stamp;
        if (file.fingerprint) |original| if (!original.stamp.same(rt.scan_stamp.?)) return error.SourceChanged;
        rt.phase = .source_scan;
    }

    fn sourceScanTurn(self: *SftpEngine, io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        const want: usize = @intCast(@min(chunk_bytes, file.size - rt.scan_offset));
        if (want > 0) {
            const count = if (job.spec.direction == .upload)
                try file.local.?.readPositional(io, &.{file.buffer[0..want]}, rt.scan_offset)
            else
                try self.readRemote(job, file.buffer[0..want]);
            try stopCheckpoint(job);
            if (count == 0 or count > want) return error.SourceChanged;
            rt.scan_hash.update(file.buffer[0..count]);
            rt.scan_offset += count;
            return;
        }
        const after = if (job.spec.direction == .upload)
            try FileStamp.local(try file.local.?.stat(io))
        else
            try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
        if (!after.same(rt.scan_stamp.?)) return error.SourceChanged;
        var digest: [32]u8 = undefined;
        rt.scan_hash.final(&digest);
        if (file.fingerprint) |original| {
            if (!std.mem.eql(u8, &original.sha256, &digest)) return error.SourceChanged;
        } else file.fingerprint = .{ .stamp = after, .sha256 = digest };
        rt.phase = .source_close;
    }

    fn prefixOpen(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        if (job.spec.direction == .download) {
            try verifyOwnedTemp(io, job);
            file.local = try std.Io.Dir.cwd().openFile(io, file.part_path.?, .{});
            const stamp = try FileStamp.local(try file.local.?.stat(io));
            if (stamp.inode != job.owned_temp.?.inode.? or stamp.size != @max(file.offset, rt.prefix_length)) return error.PrefixChanged;
            rt.prefix_length = stamp.size;
            file.target_stamp = stamp;
        } else {
            const current = try FileStamp.remote(try job.remote_metadata.stat(job.remote_metadata.context, job.session.?, file.remote_path.?));
            const original = file.target_stamp orelse return error.PrefixChanged;
            if (!current.same(original) or current.size != @max(file.offset, rt.prefix_length)) return error.PrefixChanged;
            rt.prefix_length = current.size;
        }
        if (rt.prefix_length > file.size) return error.PrefixChanged;
        file.remote = try job.remote_files.open_read(job.remote_files.context, job.session.?, file.remote_path.?, .prefix);
        const actual = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
        const expected = if (job.spec.direction == .download) file.fingerprint.?.stamp else file.target_stamp.?;
        if (!actual.same(expected)) return error.PrefixChanged;
        rt.scan_offset = 0;
        rt.phase = .prefix_scan;
    }

    fn prefixTurn(self: *SftpEngine, io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        const want: usize = @intCast(@min(chunk_bytes, rt.prefix_length - rt.scan_offset));
        if (want > 0) {
            const count = try self.readRemote(job, file.buffer[0..want]);
            try stopCheckpoint(job);
            if (count == 0 or count > want) return error.PrefixChanged;
            const actual = try file.local.?.readPositionalAll(io, rt.compare_buffer[0..count], rt.scan_offset);
            if (actual != count or !std.mem.eql(u8, file.buffer[0..count], rt.compare_buffer[0..count])) return error.PrefixChanged;
            rt.scan_offset += count;
            return;
        }
        const remote = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
        const expected = if (job.spec.direction == .download) file.fingerprint.?.stamp else file.target_stamp.?;
        if (!remote.same(expected)) return error.PrefixChanged;
        if (job.spec.direction == .upload) {
            const local = try FileStamp.local(try file.local.?.stat(io));
            if (!local.same(file.fingerprint.?.stamp)) return error.SourceChanged;
        } else {
            try verifyOwnedTemp(io, job);
            const current = try FileStamp.local(try file.local.?.stat(io));
            if (file.target_stamp == null or !current.same(file.target_stamp.?)) return error.PrefixChanged;
        }
        rt.phase = .prefix_close;
    }

    /// One bounded data API call per turn. A short native read/write retains
    /// its buffer and chunk state and resumes after every other runnable Job.
    fn transferSlice(self: *SftpEngine, io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        if (file.chunk == null) {
            file.chunk = file.window.?.next();
            if (file.chunk == null) {
                if (!file.window.?.complete()) return error.InvalidAck;
                rt.phase = .close_remote;
                return;
            }
            file.chunk_done = 0;
            file.buffered = false;
        }
        const chunk = file.chunk.?;
        const start = file.chunk_done;
        const want = @min(chunk.len - start, file.buffer.len);
        const n: usize = switch (job.spec.direction) {
            .upload => blk: {
                if (!file.buffered) {
                    file.buffer_len = want;
                    file.buffer_done = 0;
                    const got = try file.local.?.readPositionalAll(io, file.buffer[0..want], chunk.offset + start);
                    if (got != want) return error.SourceChanged;
                    file.buffered = true;
                }
                try stopCheckpoint(job);
                const written = try self.writeRemote(job, file.buffer[file.buffer_done..file.buffer_len]);
                if (written > file.buffer_len - file.buffer_done) return error.SftpWriteFailed;
                file.buffer_done += written;
                if (file.buffer_done == file.buffer_len) file.buffered = false;
                break :blk written;
            },
            .download => blk: {
                const got = try self.readRemote(job, file.buffer[0..want]);
                if (got > want) return error.SftpReadFailed;
                try stopCheckpoint(job);
                if (got > 0) try file.local.?.writePositionalAll(io, file.buffer[0..got], chunk.offset + start);
                break :blk got;
            },
        };
        if (n == 0 or n > chunk.len - start) return error.SftpReadFailed;
        file.target_capture_needed = true;
        if (rt.repairing) {
            if (rt.repair_count == 0) {
                rt.repair_count = 1;
                rt.repair_start = lastBlockOffset(file.size, try window_policy.chunkBytes(job.spec.chunk_kb));
            }
            rt.repair_end = @max(rt.repair_end orelse 0, file.offset + n);
            verificationState(job, .repairing);
        }
        file.chunk_done += n;
        file.offset += n;
        updateProgress(job, @max(job.done.load(.acquire), rt.base + file.offset));
        if (file.chunk_done == chunk.len) {
            try file.window.?.ack(chunk.index);
            file.chunk = null;
        }
    }

    fn closeFileHandle(self: *SftpEngine, job: *Job) bool {
        const rt = &job.runtime;
        if (rt.file.remote) |*handle| {
            const result = job.remote_files.close(job.remote_files.context, handle);
            if (result.consumed) rt.file.remote = null;
            if (result.receipt == .awaiting) return false;
            if (result.receipt != .released) {
                _ = self.observeTransportFailure(job);
                rt.unknown_close = true;
                job.release_unknown.store(true, .release);
                if (job.spec.md5_check) verificationState(job, .unavailable);
                if (!job.cancel_flag.load(.acquire) and (rt.resume_validation or job.pause_flag.load(.acquire) or rt.outcome == .paused)) {
                    rt.outcome = .paused;
                    rt.resume_failure = .io;
                    // Unknown remains pinned; only the original IO owner's
                    // actual context release may produce paused/released.
                    finishPaused(job);
                } else {
                    rt.outcome = .{ .failed = .{ .failure = .io, .retryable = false } };
                    finishFailed(job, .io, false);
                }
                rt.phase = .cleanup;
                return false;
            }
        }
        return true;
    }

    fn verificationState(job: *Job, state: @FieldType(manager.Verification, "state")) void {
        const rt = &job.runtime;
        job.verification.set(.{ .state = state, .source_md5 = if (job.spec.direction == .upload) rt.local_md5 else rt.remote_md5, .target_md5 = if (job.spec.direction == .upload) rt.remote_md5 else rt.local_md5, .repair_count = rt.repair_count, .repair_start = rt.repair_start, .repair_end = rt.repair_end });
    }

    fn checksumOpen(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        try stopCheckpoint(job);
        if (job.spec.direction == .download) try verifyOwnedTemp(io, job);
        const local_path = if (job.spec.direction == .download) file.part_path.? else file.local_path.?;
        file.local = try std.Io.Dir.cwd().openFile(io, local_path, .{});
        const local = try FileStamp.local(try file.local.?.stat(io));
        const expected_local = if (job.spec.direction == .upload) file.fingerprint.?.stamp else file.target_stamp orelse return error.TempOwnershipChanged;
        if (!local.same(expected_local) or local.size != file.size) return error.PrefixChanged;
        const by_path = try FileStamp.remote(try job.remote_metadata.stat(job.remote_metadata.context, job.session.?, file.remote_path.?));
        const expected_remote = if (job.spec.direction == .download) file.fingerprint.?.stamp else file.target_stamp orelse return error.PrefixChanged;
        if (!by_path.same(expected_remote)) return error.SourceChanged;
        file.remote = try job.remote_files.open_read(job.remote_files.context, job.session.?, file.remote_path.?, .checksum);
        const remote = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
        if (!remote.same(expected_remote) or remote.size != file.size) return error.SourceChanged;
        rt.checksum_local_stamp = local;
        rt.checksum_remote_stamp = remote;
        rt.local_md5 = null;
        rt.remote_md5 = null;
        rt.checksum = .init(.{});
        rt.checksum_sha = .init(.{});
        rt.checksum_offset = 0;
        verificationState(job, .reading);
        rt.phase = .checksum_local;
    }

    fn checksumLocalTurn(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        const want: usize = @intCast(@min(chunk_bytes, file.size - rt.checksum_offset));
        if (want > 0) {
            const n = try file.local.?.readPositional(io, &.{file.buffer[0..want]}, rt.checksum_offset);
            try stopCheckpoint(job);
            if (n == 0 or n > want) return error.SourceChanged;
            rt.checksum.update(file.buffer[0..n]);
            rt.checksum_sha.update(file.buffer[0..n]);
            rt.checksum_offset += n;
            return;
        }
        const after = try FileStamp.local(try file.local.?.stat(io));
        if (!after.same(rt.checksum_local_stamp.?)) return error.PrefixChanged;
        if (job.spec.direction == .download) try verifyOwnedTemp(io, job);
        var sha: [32]u8 = undefined;
        rt.checksum_sha.final(&sha);
        if (job.spec.direction == .upload and !std.mem.eql(u8, &sha, &file.fingerprint.?.sha256)) return error.SourceChanged;
        var md5: [16]u8 = undefined;
        rt.checksum.final(&md5);
        rt.local_md5 = md5;
        file.local.?.close(io);
        file.local = null;
        rt.checksum = .init(.{});
        rt.checksum_sha = .init(.{});
        rt.checksum_offset = 0;
        verificationState(job, .reading);
        rt.phase = .checksum_remote;
    }

    fn checksumRemoteTurn(self: *SftpEngine, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        const want: usize = @intCast(@min(chunk_bytes, file.size - rt.checksum_offset));
        if (want > 0) {
            const n = try self.readRemote(job, file.buffer[0..want]);
            try stopCheckpoint(job);
            if (n == 0 or n > want) return error.SourceChanged;
            rt.checksum.update(file.buffer[0..n]);
            rt.checksum_sha.update(file.buffer[0..n]);
            rt.checksum_offset += n;
            return;
        }
        const after = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
        if (!after.same(rt.checksum_remote_stamp.?)) return error.SourceChanged;
        var sha: [32]u8 = undefined;
        rt.checksum_sha.final(&sha);
        if (job.spec.direction == .download and !std.mem.eql(u8, &sha, &file.fingerprint.?.sha256)) return error.SourceChanged;
        var md5: [16]u8 = undefined;
        rt.checksum.final(&md5);
        rt.remote_md5 = md5;
        verificationState(job, .reading);
        rt.phase = .checksum_close;
    }

    fn checksumCompare(job: *Job) !void {
        const rt = &job.runtime;
        std.debug.assert(rt.file.local == null and rt.file.remote == null);
        rt.resume_validation = false;
        const unfinished_repair = rt.repairing and rt.repair_count == 1 and (rt.repair_end orelse 0) < rt.file.size;
        if (std.mem.eql(u8, &rt.local_md5.?, &rt.remote_md5.?) and !unfinished_repair) {
            verificationState(job, .passed);
            rt.phase = .publish_file;
        } else if ((rt.repair_count == 0 or unfinished_repair) and rt.file.size > 0) {
            rt.phase = .repair_open;
        } else {
            verificationState(job, .failed);
            return error.ChecksumMismatch;
        }
    }

    fn repairOpen(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        try stopCheckpoint(job);
        const from = lastBlockOffset(file.size, try window_policy.chunkBytes(job.spec.chunk_kb));
        if (file.size == 0 or (rt.repair_count != 0 and !(rt.repairing and (rt.repair_end orelse 0) < file.size))) return error.ChecksumMismatch;
        if (job.spec.direction == .download) {
            try verifyOwnedTemp(io, job);
            file.local = try std.Io.Dir.cwd().openFile(io, file.part_path.?, .{ .mode = .read_write });
            const target = try FileStamp.local(try file.local.?.stat(io));
            if (!target.same(rt.checksum_local_stamp.?)) return error.PrefixChanged;
            file.remote = try job.remote_files.open_read(job.remote_files.context, job.session.?, file.remote_path.?, .repair);
            const source = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
            if (!source.same(file.fingerprint.?.stamp)) return error.SourceChanged;
        } else {
            file.local = try std.Io.Dir.cwd().openFile(io, file.local_path.?, .{});
            const source = try FileStamp.local(try file.local.?.stat(io));
            if (!source.same(file.fingerprint.?.stamp)) return error.SourceChanged;
            file.remote = try job.remote_files.open_write(job.remote_files.context, job.session.?, file.remote_path.?, from, true);
            const target = try FileStamp.remote(try job.remote_files.stat_handle(job.remote_files.context, job.session.?, &file.remote.?));
            if (!target.same(rt.checksum_remote_stamp.?)) return error.PrefixChanged;
        }
        rt.repairing = true;
        file.resume_offset = from;
        file.offset = from;
        file.skipped = 0;
        file.window = try transfer_window.Window.init(file.size, try window_policy.chunkBytes(job.spec.chunk_kb), job.spec.window_chunks);
        try file.window.?.resumeAt(from);
        file.chunk = null;
        file.chunk_done = 0;
        file.buffered = false;
        rt.phase = if (job.spec.direction == .download and from > 0) .skip_remote else .transfer;
    }

    fn publishFile(io: std.Io, job: *Job) !void {
        const rt = &job.runtime;
        const file = &rt.file;
        std.debug.assert(file.local == null and file.remote == null);
        try stopCheckpoint(job);
        if (job.spec.md5_check) {
            const remote = try FileStamp.remote(try job.remote_metadata.stat(job.remote_metadata.context, job.session.?, file.remote_path.?));
            const expected = if (job.spec.direction == .download) file.fingerprint.?.stamp else file.target_stamp.?;
            if (!remote.same(expected)) return error.SourceChanged;
            if (job.spec.direction == .upload) {
                const source = try FileStamp.local(try std.Io.Dir.cwd().statFile(io, file.local_path.?, .{}));
                if (!source.same(file.fingerprint.?.stamp)) return error.SourceChanged;
            }
        }
        if (job.spec.direction == .download) {
            try verifyOwnedTemp(io, job);
            const actual = try FileStamp.local(try std.Io.Dir.cwd().statFile(io, file.part_path.?, .{ .follow_symlinks = false }));
            if (file.target_stamp == null or !actual.same(file.target_stamp.?)) return error.PrefixChanged;
            if (try targetChangedBeforeWrite(io, job)) return;
            if (file.target_action == .replace_verified) {
                try std.Io.Dir.cwd().rename(file.part_path.?, std.Io.Dir.cwd(), file.local_path.?, io);
            } else std.Io.Dir.cwd().renamePreserve(file.part_path.?, std.Io.Dir.cwd(), file.local_path.?, io) catch |err| {
                if (err == error.PathAlreadyExists) {
                    try nameRace(io, job, .publish_file);
                    return;
                }
                return err;
            };
            clearTempRecord(job);
        }
        try finishConflictExecution(job);
        file.final_published = true;
        rt.verification_pending = false;
        completeSource(job);
    }

    fn cleanupTurn(self: *SftpEngine, io: std.Io, job: *Job) Turn {
        const rt = &job.runtime;
        if (rt.file.remote != null) {
            if (rt.outcome == .paused and job.spec.direction == .upload and rt.file.target_capture_needed) {
                rt.file.target_stamp = if (job.remote_files.stat_handle(job.remote_files.context, job.session.?, &rt.file.remote.?)) |value|
                    FileStamp.remote(value) catch null
                else |_|
                    null;
                rt.file.target_capture_needed = false;
            }
            if (!self.closeFileHandle(job)) return .waiting;
            return .advanced;
        }
        if (rt.file.local) |file| {
            if (rt.outcome == .paused and job.spec.direction == .download and rt.file.target_capture_needed) {
                rt.file.target_stamp = if (file.stat(io)) |value| FileStamp.local(value) catch null else |_| null;
                rt.file.target_capture_needed = false;
            }
            file.close(io);
            rt.file.local = null;
        }
        if (rt.outcome == .cancelled) {
            removeOwnedTemp(io, job) catch {
                // A changed path or failed unlink cannot acknowledge cleanup.
                rt.unknown_temp = true;
                rt.phase = .cleanup_unknown;
                rt.unknown_release_attempted = true;
                job.release_unknown.store(true, .release);
                finishCancelled(job);
                return .waiting;
            };
        }
        if (rt.unknown_close) {
            rt.phase = .cleanup_unknown;
            return .waiting;
        }
        const outcome = rt.outcome;
        const resume_failure = rt.resume_failure;
        if (outcome == .paused) {
            std.debug.assert(job.checkpoint == null);
            job.checkpoint = rt.*;
            rt.* = .{};
            rt.phase = .done;
        } else {
            discardRuntime(job);
            discardCheckpoint(job);
        }
        switch (outcome) {
            .succeeded => finishSucceeded(job),
            .paused => {
                if (resume_failure) |reason| job.failure.set(reason);
                finishPaused(job);
            },
            .cancelled => finishCancelled(job),
            .failed => |failure| finishFailed(job, failure.failure, failure.retryable),
        }
        // Release publication follows the final outcome and all owned IO.
        job.worker_done.store(true, .release);
        return .advanced;
    }

    fn releaseConsumedContext(self: *SftpEngine, job: *Job) Turn {
        self.mutex.lock();
        const stopping = self.stopping;
        self.mutex.unlock();
        if (stopping) {
            discardRuntime(job);
            return .advanced;
        }
        const session = job.session.?;
        // The Session still belongs to this sole IO owner. Wait until no other
        // Job can have an open file or an unfinished call on its SFTP context.
        self.mutex.lock();
        for (self.jobs.items) |other| {
            if (other.session == session and other != job and !other.worker_done.load(.acquire) and other.runtime.phase != .cleanup_unknown) {
                self.mutex.unlock();
                return .waiting;
            }
        }
        self.mutex.unlock();
        const receipt = job.remote_files.release(job.remote_files.context, session);
        if (receipt == .awaiting) return .waiting;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |other| {
            if (other.session != session or other.runtime.phase != .cleanup_unknown or other.runtime.unknown_temp) continue;
            if (receipt == .released) {
                other.runtime.unknown_close = false;
                other.release_unknown.store(false, .release);
                other.runtime.phase = .cleanup;
            } else other.runtime.unknown_release_attempted = true;
        }
        return .advanced;
    }

    fn clearFile(job: *Job) void {
        const file = &job.runtime.file;
        std.debug.assert(file.local == null and file.remote == null);
        if (file.local_path) |path| std.heap.c_allocator.free(path);
        if (file.part_path) |path| std.heap.c_allocator.free(path);
        if (file.remote_path) |path| std.heap.c_allocator.free(path);
        if (file.original_target_path) |path| std.heap.c_allocator.free(path);
        file.* = .{};
    }

    fn completeSource(job: *Job) void {
        const rt = &job.runtime;
        rt.base += rt.file.size;
        clearFile(job);
        rt.repair_count = 0;
        rt.repair_start = null;
        rt.repair_end = null;
        rt.repairing = false;
        rt.verification_pending = false;
        rt.source_index += 1;
        // A completed file's diagnostic is not the next file's IO phase.
        if (rt.source_index < job.spec.sources.len) job.verification.clear();
        rt.phase = if (rt.source_index < job.spec.sources.len) .prepare else .cleanup;
    }

    fn discardRuntime(job: *Job) void {
        const rt = &job.runtime;
        clearFile(job);
        if (rt.source_sizes) |sizes| std.heap.c_allocator.free(sizes);
        rt.source_sizes = null;
        rt.phase = .done;
    }
};

fn engineOpen(ctx: *anyopaque, spec: JobSpec) anyerror!EngineJobId {
    const self: *SftpEngine = @ptrCast(@alignCast(ctx));
    return self.open(spec);
}

fn engineConflictSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator, id: EngineJobId) anyerror!?conflict_types.OwnedSnapshot {
    return (@as(*SftpEngine, @ptrCast(@alignCast(ctx)))).conflictSnapshot(allocator, id);
}
fn engineResolveConflict(ctx: *anyopaque, id: EngineJobId, request: conflict_types.Request) anyerror!void {
    return (@as(*SftpEngine, @ptrCast(@alignCast(ctx)))).resolveConflict(id, request);
}

fn stopCheckpoint(job: *Job) !void {
    if (job.cancel_flag.load(.acquire)) return error.Cancelled;
    if (job.pause_flag.load(.acquire)) return error.Paused;
}

fn verifyOwnedTemp(io: std.Io, job: *Job) !void {
    const temp = job.owned_temp orelse return error.TempOwnershipChanged;
    if (!temp.created or temp.inode == null) return error.TempOwnershipChanged;
    const stat = try std.Io.Dir.cwd().statFile(io, temp.path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.inode != temp.inode.?) return error.TempOwnershipChanged;
}

fn discardCheckpoint(job: *Job) void {
    if (job.checkpoint) |*saved| {
        std.debug.assert(saved.file.local == null and saved.file.remote == null);
        if (saved.file.local_path) |path| std.heap.c_allocator.free(path);
        if (saved.file.part_path) |path| std.heap.c_allocator.free(path);
        if (saved.file.remote_path) |path| std.heap.c_allocator.free(path);
        if (saved.file.original_target_path) |path| std.heap.c_allocator.free(path);
        if (saved.source_sizes) |sizes| std.heap.c_allocator.free(sizes);
    }
    job.checkpoint = null;
}

fn clearTempRecord(job: *Job) void {
    if (job.owned_temp) |temp| std.heap.c_allocator.free(temp.path);
    job.owned_temp = null;
}

fn removeOwnedTemp(io: std.Io, job: *Job) !void {
    if (job.owned_temp) |temp| {
        if (temp.created) {
            verifyOwnedTemp(io, job) catch |err| switch (err) {
                error.FileNotFound => {
                    clearTempRecord(job);
                    return;
                },
                else => return err,
            };
            try std.Io.Dir.cwd().deleteFile(io, temp.path);
        }
        clearTempRecord(job);
    }
}

fn engineResume(ctx: *anyopaque, id: EngineJobId) anyerror!EngineJobId {
    const self: *SftpEngine = @ptrCast(@alignCast(ctx));
    return self.resumeJob(id);
}
fn engineCanResume(ctx: *anyopaque, id: EngineJobId) bool {
    const self: *SftpEngine = @ptrCast(@alignCast(ctx));
    return self.canResume(id);
}

fn enginePause(ctx: *anyopaque, id: EngineJobId) anyerror!void {
    const self: *SftpEngine = @ptrCast(@alignCast(ctx));
    return self.pause(id);
}

fn engineCancel(ctx: *anyopaque, id: EngineJobId) void {
    const self: *SftpEngine = @ptrCast(@alignCast(ctx));
    self.cancel(id);
}

fn enginePoll(ctx: *anyopaque) ?EngineProgress {
    const self: *SftpEngine = @ptrCast(@alignCast(ctx));
    return self.poll();
}

// ---------------------------------------------------------------------------
// 测试（无真实 SSH：不触碰 Session 的 C 绑定路径）
// ---------------------------------------------------------------------------

const MetadataGate = struct {
    caller: std.Thread.Id,
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    session: ?*ssh_session.Session = null,
    path: [4096]u8 = undefined,
    path_len: usize = 0,
    returned_size: u64 = 42,

    fn noStat(_: ?*anyopaque, _: *ssh_session.Session, _: [:0]const u8) !ssh_session.SftpAttributes {
        return error.SessionNotActive;
    }
    fn read(raw: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !u64 {
        const self: *MetadataGate = @ptrCast(@alignCast(raw.?));
        if (std.Thread.getCurrentId() == self.caller) return error.MetadataOnCallerThread;
        if (path.len > self.path.len) return error.TestPathTooLong;
        self.session = session;
        self.path_len = path.len;
        @memcpy(self.path[0..path.len], path);
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.entered.store(true, .release);
        const start = monotonicNs();
        while (!self.release.load(.acquire)) {
            if (monotonicNs() - start > 5 * std.time.ns_per_s) return error.TestMetadataGateTimeout;
            workerTestPause();
        }
        return self.returned_size;
    }
};
fn workerTestPause() void {
    var delay: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
    _ = std.c.nanosleep(&delay, null);
}
fn awaitWorker(flag: *const std.atomic.Value(bool)) !void {
    const started = monotonicNs();
    while (!flag.load(.acquire)) {
        if (monotonicNs() - started > 5 * std.time.ns_per_s) return error.TestWorkerTimeout;
        workerTestPause();
    }
}
test "sftp engine worker open returns while metadata waits and owns original input and binding" {
    const engine = try SftpEngine.init(std.testing.allocator);
    var gate: MetadataGate = .{ .caller = std.Thread.getCurrentId() };
    defer {
        gate.release.store(true, .release);
        engine.deinit();
    }
    var first_session: ssh_session.Session = .{};
    var later_session: ssh_session.Session = .{};
    engine.attachSession(&first_session);
    engine.remote_metadata = .{ .context = &gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    const source = try std.testing.allocator.dupe(u8, "input a,b.bin");
    const remote = try std.testing.allocator.dupe(u8, "/srv/original");
    const local = try std.testing.allocator.dupe(u8, "/tmp/original");
    const rename = try std.testing.allocator.dupe(u8, "output a,b.bin");
    var sources = [_][]const u8{source};
    const accepted = engine.open(.{ .direction = .download, .sources = &sources, .remote_dir = remote, .local_dir = local, .rename = rename, .resume_transfer = false });
    std.testing.allocator.free(source);
    std.testing.allocator.free(remote);
    std.testing.allocator.free(local);
    std.testing.allocator.free(rename);
    sources[0] = "caller replaced source slice";
    const job_id = try accepted;
    try awaitWorker(&gate.entered);
    try std.testing.expectEqual(@as(usize, 1), gate.calls.load(.acquire));
    try std.testing.expectEqual(&first_session, gate.session.?);
    try std.testing.expectEqualStrings("/srv/original/input a,b.bin", gate.path[0..gate.path_len]);
    const job = engine.jobs.items[0];
    try std.testing.expectEqual(job_id, job.id);
    try std.testing.expectEqualStrings("input a,b.bin", job.spec.sources[0]);
    try std.testing.expectEqualStrings("/srv/original", job.spec.remote_dir);
    try std.testing.expectEqualStrings("/tmp/original", job.spec.local_dir);
    try std.testing.expectEqualStrings("output a,b.bin", job.spec.rename.?);
    try std.testing.expect(!job.spec.resume_transfer);
    try std.testing.expect(!job.total_ready.load(.acquire));
    try std.testing.expect(engine.poll() == null);
    engine.attachSession(&later_session);
    try std.testing.expectEqual(&first_session, job.session.?);
    gate.release.store(true, .release);
    try awaitWorker(&job.terminal);
    const event = engine.poll().?;
    try std.testing.expectEqual(@as(u64, 42), event.total_bytes);
    try std.testing.expectEqual(@as(u64, 0), event.done_bytes);
    // Idle Session intentionally refuses transfer IO after real worker metadata.
    try std.testing.expectEqual(manager.EngineState.failed, event.state);
    try std.testing.expect(engine.poll() == null);
}
test "sftp engine worker cancellation returns during stat and prevents following sources or transfer IO" {
    const engine = try SftpEngine.init(std.testing.allocator);
    var gate: MetadataGate = .{ .caller = std.Thread.getCurrentId() };
    defer {
        gate.release.store(true, .release);
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    engine.remote_metadata = .{ .context = &gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    const job_id = try engine.open(.{ .direction = .download, .sources = &.{ "first", "must-not-stat-next" }, .remote_dir = "/srv", .local_dir = "/tmp" });
    try awaitWorker(&gate.entered);
    const job = engine.jobs.items[0];
    engine.cancel(job_id);
    try std.testing.expect(job.cancel_flag.load(.acquire));
    try std.testing.expect(!job.terminal.load(.acquire));
    try std.testing.expect(engine.poll() == null);
    gate.release.store(true, .release);
    try awaitWorker(&job.terminal);
    try std.testing.expectEqual(@as(usize, 1), gate.calls.load(.acquire));
    try std.testing.expect(!job.total_ready.load(.acquire));
    const event = engine.poll().?;
    try std.testing.expectEqual(manager.EngineState.cancelled, event.state);
    try std.testing.expectEqual(manager.JobCleanup.released, event.job_cleanup);
    try std.testing.expect(!event.retryable);
    try std.testing.expect(event.failure == null);
    try std.testing.expectEqual(@as(u64, 0), event.total_bytes);
    try std.testing.expect(engine.poll() == null);
}
test "sftp engine worker metadata sum overflow becomes typed failure without file transfer" {
    const engine = try SftpEngine.init(std.testing.allocator);
    var gate: MetadataGate = .{ .caller = std.Thread.getCurrentId(), .returned_size = std.math.maxInt(u64) };
    gate.release.store(true, .release);
    defer engine.deinit();
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    engine.remote_metadata = .{ .context = &gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    _ = try engine.open(.{ .direction = .download, .sources = &.{ "one", "two" }, .remote_dir = "/srv", .local_dir = "/tmp" });
    try awaitWorker(&engine.jobs.items[0].terminal);
    const event = engine.poll().?;
    try std.testing.expectEqual(manager.EngineState.failed, event.state);
    try std.testing.expectEqual(manager.Failure.invalid_request, event.failure.?);
    try std.testing.expect(!event.retryable);
    try std.testing.expectEqual(@as(usize, 2), gate.calls.load(.acquire));
    try std.testing.expect(engine.poll() == null);
}
test "sftp engine worker publishes no placeholder total into real Manager while metadata is pending" {
    const engine = try SftpEngine.init(std.testing.allocator);
    var gate: MetadataGate = .{ .caller = std.Thread.getCurrentId() };
    defer {
        gate.release.store(true, .release);
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    engine.remote_metadata = .{ .context = &gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 1, .{ .max_attempts = 1 });
    defer controller.deinit();
    const id = try controller.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"source"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    controller.tick(0);
    try awaitWorker(&gate.entered);
    controller.tick(1);
    try std.testing.expectEqual(manager.State.running, controller.progress(id).?.state);
    try std.testing.expect(controller.progress(id).?.failure == null);
    gate.release.store(true, .release);
    try awaitWorker(&engine.jobs.items[0].terminal);
    controller.tick(2);
    const progress = controller.progress(id).?;
    try std.testing.expectEqual(@as(u64, 42), progress.total_bytes);
    try std.testing.expectEqual(manager.State.failed, progress.state);
    try std.testing.expectEqual(manager.Failure.connection, progress.failure.?);
}

test "sftp engine idle detach waits for cancelled Manager worker cleanup before releasing session" {
    const UnexpectedExec = struct {
        fn exec(_: *anyopaque, _: []const u8, _: exec_api.ExecOpts) !exec_api.ExecHandle {
            return error.UnexpectedExec;
        }
        fn abort(_: exec_api.ExecHandle) void {
            unreachable;
        }
        fn poll(_: exec_api.ExecHandle) ?exec_api.ExecResult {
            unreachable;
        }
        fn close(_: *anyopaque) void {
            unreachable;
        }
    };
    var session: ?*ssh_session.Session = try std.testing.allocator.create(ssh_session.Session);
    session.?.* = .{};
    defer if (session) |live| {
        live.close();
        std.testing.allocator.destroy(live);
    };
    const engine = try SftpEngine.init(std.testing.allocator);
    var gate: MetadataGate = .{ .caller = std.Thread.getCurrentId() };
    defer {
        gate.release.store(true, .release);
        engine.deinit();
    }
    engine.attachSession(session.?);
    engine.remote_metadata = .{ .context = &gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    const key: OperationKey = .{ .owner = .app, .operation_id = 73 };
    engine.attachExecService(.{ .ctx = &gate, .exec_fn = UnexpectedExec.exec, .abort_fn = UnexpectedExec.abort, .poll_fn = UnexpectedExec.poll, .close_fn = UnexpectedExec.close }, key);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 1, .{});
    defer controller.deinit();
    const id = try controller.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"source"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    controller.tick(0);
    try awaitWorker(&gate.entered);
    const job = engine.jobs.items[0];
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(!job.cancel_flag.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expect(!job.cancel_flag.load(.acquire));
    try std.testing.expectEqual(session.?, engine.session.?);
    try std.testing.expectEqual(session.?, job.session.?);
    try std.testing.expectEqual(@as(*anyopaque, &gate), engine.exec_service.?.ctx);
    try std.testing.expectEqual(@as(*anyopaque, &gate), job.exec_service.?.ctx);
    try std.testing.expect(key.eql(engine.exec_key.?));
    try std.testing.expect(key.eql(job.exec_key.?));
    try std.testing.expect(engine.owner_thread != null);

    try controller.cancel(id);
    try std.testing.expectEqual(manager.State.cancelling, controller.progress(id).?.state);
    try std.testing.expect(job.cancel_flag.load(.acquire));
    try std.testing.expect(!job.terminal.load(.acquire));
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expectEqual(session.?, engine.session.?);
    try std.testing.expectEqual(session.?, job.session.?);
    try std.testing.expect(engine.owner_thread != null);

    gate.release.store(true, .release);
    try awaitWorker(&job.worker_done);
    try std.testing.expect(job.terminal.load(.acquire));
    try awaitWorker(&engine.owner_done);
    try std.testing.expect(engine.detachIfIdle());
    try std.testing.expect(engine.session == null);
    try std.testing.expect(engine.exec_service == null);
    try std.testing.expect(engine.exec_key == null);
    try std.testing.expect(engine.owner_thread == null);
    try std.testing.expect(job.session == null);
    try std.testing.expect(job.exec_service == null);
    try std.testing.expect(job.exec_key == null);
    controller.tick(2);
    try std.testing.expectEqual(manager.State.cancelled, controller.progress(id).?.state);
    try std.testing.expectError(error.SessionNotAttached, engine.open(.{ .direction = .download, .sources = &.{"source"}, .remote_dir = "/srv", .local_dir = "/tmp" }));
    // The old allocation is released only after the actual worker has ended.
    session.?.close();
    std.testing.allocator.destroy(session.?);
    session = null;
    try awaitWorker(&engine.owner_done);
    try std.testing.expect(engine.detachIfIdle());

    var next_session: ssh_session.Session = .{};
    engine.attachSession(&next_session);
    const next = try engine.open(.{ .direction = .download, .sources = &.{"new-source"}, .remote_dir = "/next", .local_dir = "/tmp" });
    try std.testing.expect(next != job.id);
    const next_job = engine.jobs.items[1];
    try awaitWorker(&next_job.worker_done);
    try std.testing.expectEqual(&next_session, gate.session.?);
    try std.testing.expectEqualStrings("/next/new-source", gate.path[0..gate.path_len]);
    try awaitWorker(&engine.owner_done);
    try std.testing.expect(engine.detachIfIdle());
}

test "sftp engine idle detach retains completed bindings while its single owner is busy" {
    const engine = try SftpEngine.init(std.testing.allocator);
    var first_gate: MetadataGate = .{ .caller = std.Thread.getCurrentId() };
    first_gate.release.store(true, .release);
    var second_gate: MetadataGate = .{ .caller = std.Thread.getCurrentId() };
    defer {
        second_gate.release.store(true, .release);
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    engine.remote_metadata = .{ .context = &first_gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    _ = try engine.open(.{ .direction = .download, .sources = &.{"first"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    const first = engine.jobs.items[0];
    try awaitWorker(&first.worker_done);
    engine.remote_metadata = .{ .context = &second_gate, .size = MetadataGate.read, .stat = MetadataGate.noStat };
    const second_id = try engine.open(.{ .direction = .download, .sources = &.{"second"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    try awaitWorker(&second_gate.entered);
    const second = engine.jobs.items[1];
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expect(engine.owner_thread != null);
    try std.testing.expectEqual(&session, engine.session.?);
    try std.testing.expectEqual(&session, first.session.?);
    try std.testing.expectEqual(&session, second.session.?);
    try std.testing.expect(!second.cancel_flag.load(.acquire));
    engine.cancel(second_id);
    second_gate.release.store(true, .release);
    try awaitWorker(&second.worker_done);
    try awaitWorker(&engine.owner_done);
    try std.testing.expect(engine.detachIfIdle());
    try std.testing.expect(engine.owner_thread == null);
    try std.testing.expect(first.session == null);
    try std.testing.expect(second.session == null);
}

test "SFTP checksum does not require an Exec service before file or network IO" {
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    const id = try engine.open(.{ .direction = .upload, .sources = &.{"missing-source-must-not-be-read"}, .remote_dir = "/srv", .local_dir = "/does-not-exist", .md5_check = true });
    try awaitWorker(&engine.jobs.items[0].worker_done);
    try std.testing.expectEqual(id, engine.jobs.items[0].id);
    try std.testing.expect(engine.jobs.items[0].exec_service == null);
    try std.testing.expectEqual(manager.Failure.not_found, engine.jobs.items[0].failure.get().?);
}

test "open validates JobSpec like manager semantics" {
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expectError(error.NoSources, engine.open(.{
        .direction = .upload,
        .sources = &.{},
        .remote_dir = "/srv",
        .local_dir = "/tmp",
    }));
    try std.testing.expectError(error.EmptySource, engine.open(.{
        .direction = .upload,
        .sources = &.{""},
        .remote_dir = "/srv",
        .local_dir = "/tmp",
    }));
    try std.testing.expectError(error.MissingRemoteDirectory, engine.open(.{
        .direction = .upload,
        .sources = &.{"a.txt"},
        .remote_dir = "",
        .local_dir = "/tmp",
    }));
    try std.testing.expectError(error.MissingLocalDirectory, engine.open(.{
        .direction = .download,
        .sources = &.{"a.txt"},
        .remote_dir = "/srv",
        .local_dir = "",
    }));
    try std.testing.expectError(error.InvalidRename, engine.open(.{
        .direction = .upload,
        .sources = &.{ "a.txt", "b.txt" },
        .remote_dir = "/srv",
        .local_dir = "/tmp",
        .rename = "c.txt",
    }));
}

test "window resumeAt yields aligned first chunk and tail chunk" {
    const total: u64 = 100_000;

    // 从第 1 块继续：首块 index=1、offset 对齐、长度为整块。
    var window = try transfer_window.Window.init(total, chunk_bytes, window_capacity);
    try window.resumeAt(1 * chunk_bytes);
    const first = window.next().?;
    try std.testing.expectEqual(@as(u64, 1), first.index);
    try std.testing.expectEqual(@as(u64, chunk_bytes), first.offset);
    try std.testing.expectEqual(chunk_bytes, first.len);

    // 从第 3 块继续（尾部）：首块即收尾块，长度为余数 100_000 - 3*32KiB。
    var tail_window = try transfer_window.Window.init(total, chunk_bytes, window_capacity);
    try tail_window.resumeAt(3 * chunk_bytes);
    const tail = tail_window.next().?;
    try std.testing.expectEqual(@as(u64, 3), tail.index);
    try std.testing.expectEqual(3 * @as(u64, chunk_bytes), tail.offset);
    try std.testing.expectEqual(@as(u32, @intCast(total - 3 * chunk_bytes)), tail.len);
    try std.testing.expect(tail_window.next() == null);
    try tail_window.ack(tail.index);
    try std.testing.expect(tail_window.complete());

    // 对齐约束仍在：未对齐偏移被拒绝。
    var fresh = try transfer_window.Window.init(total, chunk_bytes, window_capacity);
    try std.testing.expectError(error.InvalidResumeOffset, fresh.resumeAt(3));
}

test "poll progress is monotonic and terminal is emitted once" {
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();

    const spec = JobSpec{
        .direction = .upload,
        .sources = &.{"a.txt"},
        .remote_dir = "/srv",
        .local_dir = "/tmp",
    };
    const job = try std.testing.allocator.create(Job);
    job.* = .{ .id = 7, .spec = try OwnedSpec.clone(std.testing.allocator, spec) };
    job.total.store(100, .release);
    job.total_ready.store(true, .release);
    try engine.jobs.append(std.testing.allocator, job);

    var last_done: u64 = 0;
    const steps = [_]u64{ 0, 25, 50, 50, 75, 75 };
    for (steps) |step| {
        job.done.store(step, .release);
        const event = engine.poll() orelse continue; // 重复值不发事件
        try std.testing.expect(event.done_bytes >= last_done);
        try std.testing.expect(event.done_bytes <= event.total_bytes);
        try std.testing.expectEqual(manager.EngineState.running, event.state);
        last_done = event.done_bytes;
        while (engine.poll()) |more| {
            try std.testing.expect(more.done_bytes >= last_done);
            last_done = more.done_bytes;
        }
    }
    try std.testing.expectEqual(@as(u64, 75), last_done);

    finishFailed(job, .io, true);
    var saw_terminal = false;
    while (engine.poll()) |event| {
        try std.testing.expect(!saw_terminal);
        saw_terminal = true;
        try std.testing.expectEqual(manager.EngineState.failed, event.state);
        try std.testing.expectEqual(manager.Failure.io, event.failure.?);
        try std.testing.expect(event.retryable);
        try std.testing.expectEqual(@as(u64, 75), event.done_bytes);
    }
    try std.testing.expect(saw_terminal);
    try std.testing.expect(engine.poll() == null); // 终态只发一次
}

test "engine vtable dispatches through ctx and open fails without session" {
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    const vtable = engine.engine();
    const back: *SftpEngine = @ptrCast(@alignCast(vtable.ctx));
    try std.testing.expect(back == engine);

    try std.testing.expectError(error.SessionNotAttached, vtable.open(vtable.ctx, .{
        .direction = .upload,
        .sources = &.{"a.txt"},
        .remote_dir = "/srv",
        .local_dir = "/tmp",
    }));
    try std.testing.expectError(error.SessionNotAttached, vtable.open(vtable.ctx, .{
        .direction = .download,
        .sources = &.{"a.txt"},
        .remote_dir = "/srv",
        .local_dir = "/tmp",
    }));
    vtable.cancel(vtable.ctx, 42); // 未知 id：静默无副作用
    try std.testing.expect(vtable.poll(vtable.ctx) == null);
}

test "path builders preserve source directories and derive destination basenames" {
    const allocator = std.testing.allocator;
    const spec = JobSpec{
        .direction = .download,
        .sources = &.{"dir/b.bin"},
        .remote_dir = "/srv/files",
        .local_dir = "/tmp/zw",
    };
    const remote = try downloadRemotePath(allocator, spec, "dir/b.bin");
    defer allocator.free(remote);
    try std.testing.expectEqualStrings("/srv/files/dir/b.bin", remote);

    const local = try uploadLocalPath(allocator, spec, "dir/b.bin");
    defer allocator.free(local);
    try std.testing.expectEqualStrings("/tmp/zw/dir/b.bin", local);

    const renamed_spec = JobSpec{
        .direction = .download,
        .sources = &.{"dir/b.bin"},
        .remote_dir = "/srv/files",
        .local_dir = "/tmp/zw",
        .rename = "c.bin",
    };
    const paths = try downloadLocalPaths(allocator, renamed_spec, "dir/b.bin", "test");
    defer allocator.free(paths.final);
    defer allocator.free(paths.part);
    try std.testing.expectEqualStrings("/tmp/zw/c.bin", paths.final);
    try std.testing.expectEqualStrings("/tmp/zw/c.bin.zerowork-test.part", paths.part);

    const absolute = try uploadLocalPath(allocator, spec, "/data/dir/b.bin");
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/data/dir/b.bin", absolute);
}

test "classifyError maps sftp io and local path classes" {
    try std.testing.expectEqual(manager.Failure.io, classifyError(error.SftpWriteFailed));
    try std.testing.expectEqual(manager.Failure.io, classifyError(error.SftpReadFailed));
    try std.testing.expectEqual(manager.Failure.connection, classifyError(error.SftpOpenFailed));
    try std.testing.expectEqual(manager.Failure.connection, classifyError(error.SessionNotActive));
    try std.testing.expectEqual(manager.Failure.not_found, classifyError(error.FileNotFound));
    try std.testing.expectEqual(manager.Failure.permission_denied, classifyError(error.AccessDenied));
}

test "absolute sources with spaces and commas upload basename or explicit rename" {
    const allocator = std.testing.allocator;
    var spec: JobSpec = .{ .direction = .upload, .sources = &.{"/tmp/build 1,2/release a,b.tar.gz"}, .remote_dir = "/opt/deploy/", .local_dir = "" };
    const local = try uploadLocalPath(allocator, spec, spec.sources[0]);
    defer allocator.free(local);
    try std.testing.expectEqualStrings(spec.sources[0], local);
    const remote = try uploadRemotePath(allocator, spec, spec.sources[0]);
    defer allocator.free(remote);
    try std.testing.expectEqualStrings("/opt/deploy/release a,b.tar.gz", remote);
    spec.rename = "release-v2.4.0.tar.gz";
    const renamed = try uploadRemotePath(allocator, spec, spec.sources[0]);
    defer allocator.free(renamed);
    try std.testing.expectEqualStrings("/opt/deploy/release-v2.4.0.tar.gz", renamed);
    try validateSpec(spec);
}

test "download absolute remote source does not duplicate its parent and local uses basename" {
    const allocator = std.testing.allocator;
    var spec: JobSpec = .{ .direction = .download, .sources = &.{"/var/log/app a,b.log"}, .remote_dir = "/var/log", .local_dir = "/tmp/Downloads" };
    const remote = try downloadRemotePath(allocator, spec, spec.sources[0]);
    defer allocator.free(remote);
    try std.testing.expectEqualStrings("/var/log/app a,b.log", remote);
    const paths = try downloadLocalPaths(allocator, spec, spec.sources[0], "test");
    defer allocator.free(paths.final);
    defer allocator.free(paths.part);
    try std.testing.expectEqualStrings("/tmp/Downloads/app a,b.log", paths.final);
    try std.testing.expectEqualStrings("/tmp/Downloads/app a,b.log.zerowork-test.part", paths.part);
    spec.rename = "app-k8s.log";
    const renamed = try downloadLocalPaths(allocator, spec, spec.sources[0], "test");
    defer allocator.free(renamed.final);
    defer allocator.free(renamed.part);
    try std.testing.expectEqualStrings("/tmp/Downloads/app-k8s.log", renamed.final);
}

test "local home expansion supports tilde and leaves literal user and embedded tildes" {
    const allocator = std.testing.allocator;
    const expanded = try expandLocalHomeWith(allocator, "~/Downloads/a b,c", "/Users/test/");
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("/Users/test/Downloads/a b,c", expanded);
    const home = try expandLocalHomeWith(allocator, "~", "/Users/test");
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/Users/test", home);
    for ([_][]const u8{ "~other/a", "/tmp/~/a", "a~b" }) |path| {
        const literal = try expandLocalHomeWith(allocator, path, null);
        defer allocator.free(literal);
        try std.testing.expectEqualStrings(path, literal);
    }
    try std.testing.expectError(error.HomeUnavailable, expandLocalHomeWith(allocator, "~/Downloads", null));
    try std.testing.expectError(error.HomeUnavailable, expandLocalHomeWith(allocator, "~/Downloads", "relative"));
}

test "rename is a single filename within the selected destination directory" {
    var spec: JobSpec = .{ .direction = .upload, .sources = &.{"/tmp/a"}, .remote_dir = "/srv", .local_dir = "" };
    for ([_][]const u8{ "", "/other/a", "../a", ".", "..", "a\x00b" }) |name| {
        spec.rename = name;
        try std.testing.expectError(error.InvalidRename, validateSpec(spec));
    }
}

test "upload and download resolve local home at their file IO boundary" {
    const allocator = std.testing.allocator;
    const home = try @import("../platform/account.zig").home(allocator);
    defer allocator.free(home);
    var spec: JobSpec = .{ .direction = .upload, .sources = &.{"nested/a b,c"}, .remote_dir = "/srv", .local_dir = "~/Downloads" };
    const expected = try joinPath(allocator, &.{ home, "Downloads/nested/a b,c" });
    defer allocator.free(expected);
    const local = try uploadLocalPath(allocator, spec, spec.sources[0]);
    defer allocator.free(local);
    try std.testing.expectEqualStrings(expected, local);
    const direct = try uploadLocalPath(allocator, spec, "~/Downloads/nested/a b,c");
    defer allocator.free(direct);
    try std.testing.expectEqualStrings(expected, direct);
    spec.direction = .download;
    const paths = try downloadLocalPaths(allocator, spec, "/remote/nested/a b,c", "test");
    defer allocator.free(paths.final);
    defer allocator.free(paths.part);
    const destination = try joinPath(allocator, &.{ home, "Downloads/a b,c" });
    defer allocator.free(destination);
    try std.testing.expectEqualStrings(destination, paths.final);
}

test "remote MD5 parser validates actual hex result and normalizes uppercase" {
    const expected = try parseMd5("900150983cd24fb0d6963f7d28e17f72  -\n");
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &expected);
    const upper = try parseMd5("900150983CD24FB0D6963F7D28E17F72  -\n");
    try std.testing.expect(checksumEqual(expected, upper));
    const other = try parseMd5("d41d8cd98f00b204e9800998ecf8427e  -\n");
    try std.testing.expect(!checksumEqual(expected, other));
    try std.testing.expectError(error.InvalidRemoteChecksum, parseMd5("md5sum: file unavailable"));
    try std.testing.expectError(error.InvalidRemoteChecksum, parseMd5("z00150983cd24fb0d6963f7d28e17f72"));
    try std.testing.expectError(error.InvalidRemoteChecksum, parseMd5(""));
}

test "remote checksum paths are quoted as shell data" {
    const allocator = std.testing.allocator;
    const quoted = try shellQuote(allocator, "/tmp/a b,c'$(touch x);.log");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/a b,c'\\''$(touch x);.log'", quoted);
}

test "MD5 retry selects only the last transfer block including aligned and empty files" {
    try std.testing.expectEqual(@as(u64, 0), lastBlockOffset(0, chunk_bytes));
    try std.testing.expectEqual(@as(u64, 0), lastBlockOffset(1, chunk_bytes));
    try std.testing.expectEqual(@as(u64, 0), lastBlockOffset(chunk_bytes, chunk_bytes));
    try std.testing.expectEqual(@as(u64, chunk_bytes), lastBlockOffset(chunk_bytes + 1, chunk_bytes));
    try std.testing.expectEqual(@as(u64, chunk_bytes), lastBlockOffset(chunk_bytes * 2, chunk_bytes));
}

test "local MD5 hashes real file bytes including zero-length file" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(std.testing.io, "checksum a,b", .{});
    try file.writePositionalAll(std.testing.io, "abc", 0);
    file.close(std.testing.io);
    const path = try std.mem.concat(allocator, u8, &.{ ".zig-cache/tmp/", &temp.sub_path, "/checksum a,b" });
    defer allocator.free(path);
    const hash = try md5File(allocator, path);
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &hash);
    const empty = try temp.dir.createFile(std.testing.io, "checksum a,b", .{});
    empty.close(std.testing.io);
    const empty_hash = try md5File(allocator, path);
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", &empty_hash);
}

/// A bounded SFTP service drives the actual owner continuation and real local
/// files. Every native-shaped callback records thread, handle and IO slice.
const OwnerTestService = struct {
    const Slot = struct { id: usize, offset: u64 = 0, closes: usize = 0, consumed: bool = false, purpose: ReadPurpose = .transfer };
    const length = 4 * chunk_bytes + 13;
    caller: std.Thread.Id = undefined,
    owner: ?std.Thread.Id = null,
    calls_in_flight: std.atomic.Value(usize) = .init(0),
    concurrent_calls: std.atomic.Value(bool) = .init(false),
    wrong_thread: bool = false,
    changed_thread: bool = false,
    oversize: bool = false,
    bad_bytes: bool = false,
    metadata_entered: std.atomic.Value(bool) = .init(false),
    metadata_release: std.atomic.Value(bool) = .init(false),
    read_blocked: std.atomic.Value(bool) = .init(false),
    read_release: std.atomic.Value(bool) = .init(false),
    close_entered: std.atomic.Value(bool) = .init(false),
    close_release: std.atomic.Value(bool) = .init(false),
    context_entered: std.atomic.Value(bool) = .init(false),
    context_release: std.atomic.Value(bool) = .init(false),
    block_read_slot: ?usize = null,
    pending_close_slot: ?usize = null,
    unknown_close_slot: ?usize = null,
    context_unknown: bool = false,
    sizes: [3]?u64 = .{ null, null, null },
    slots: [3]Slot = .{ .{ .id = 0 }, .{ .id = 1 }, .{ .id = 2 } },
    probe_slots: [3]Slot = .{ .{ .id = 0, .purpose = .fingerprint }, .{ .id = 1, .purpose = .fingerprint }, .{ .id = 2, .purpose = .fingerprint } },
    data_turns: [256]usize = undefined,
    data_count: usize = 0,
    progressed_mask: u8 = 0,
    first_close_mask: ?u8 = null,

    fn begin(self: *OwnerTestService) void {
        if (self.calls_in_flight.fetchAdd(1, .acq_rel) != 0) self.concurrent_calls.store(true, .release);
        const current = std.Thread.getCurrentId();
        self.wrong_thread = self.wrong_thread or current == self.caller;
        if (self.owner) |owner| self.changed_thread = self.changed_thread or current != owner else self.owner = current;
    }
    fn end(self: *OwnerTestService) void {
        _ = self.calls_in_flight.fetchSub(1, .acq_rel);
    }
    fn service(raw: ?*anyopaque) *OwnerTestService {
        return @ptrCast(@alignCast(raw.?));
    }
    fn slot(handle: *ssh_session.SftpHandle) *Slot {
        return @ptrCast(@alignCast(handle.handle));
    }
    fn index(path: [:0]const u8) !usize {
        const base = std.fs.path.basename(path);
        if (base.len != 1 or base[0] < 'a' or base[0] > 'c') return error.InvalidTestPath;
        return base[0] - 'a';
    }
    fn size(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8) !u64 {
        const self = service(raw);
        self.begin();
        defer self.end();
        self.metadata_entered.store(true, .release);
        try awaitWorker(&self.metadata_release);
        return self.sizes[try index(path)] orelse length;
    }
    fn openRead(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8, purpose: ReadPurpose) !ssh_session.SftpHandle {
        const self = service(raw);
        self.begin();
        defer self.end();
        const item = if (purpose == .transfer) &self.slots[try index(path)] else &self.probe_slots[try index(path)];
        item.offset = 0;
        item.consumed = false;
        item.purpose = purpose;
        return .{ .handle = @ptrCast(item) };
    }
    fn openWrite(raw: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8, offset: u64, _: bool) !ssh_session.SftpHandle {
        var handle = try openRead(raw, session, path, .transfer);
        slot(&handle).offset = offset;
        return handle;
    }
    fn createExclusive(raw: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpHandle {
        return openWrite(raw, session, path, 0, false);
    }
    fn targetStat(raw: ?*anyopaque, session: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpAttributes {
        const self = service(raw);
        if (self.slots[try index(path)].offset == 0) return error.FileNotFound;
        return stat(raw, session, path);
    }
    fn record(self: *OwnerTestService, item: *Slot, size_bytes: usize) void {
        self.oversize = self.oversize or size_bytes > 32 * 1024;
        self.progressed_mask |= @as(u8, 1) << @intCast(item.id);
        if (self.data_count < self.data_turns.len) self.data_turns[self.data_count] = item.id;
        self.data_count += 1;
    }
    fn read(raw: ?*anyopaque, handle: *ssh_session.SftpHandle, bytes: []u8) !usize {
        const self = service(raw);
        self.begin();
        defer self.end();
        const item = slot(handle);
        if (item.purpose == .transfer and self.block_read_slot == item.id and item.offset >= chunk_bytes and !self.read_release.load(.acquire)) {
            self.read_blocked.store(true, .release);
            try awaitWorker(&self.read_release);
        }
        const n: usize = @intCast(@min(bytes.len, @min(8191, (self.sizes[item.id] orelse length) - item.offset)));
        if (n > 0) {
            @memset(bytes[0..n], @as(u8, @intCast('A' + item.id)));
            if (item.purpose == .transfer) self.record(item, bytes.len);
            item.offset += n;
        }
        return n;
    }
    fn write(raw: ?*anyopaque, handle: *ssh_session.SftpHandle, bytes: []const u8) !usize {
        const self = service(raw);
        self.begin();
        defer self.end();
        const item = slot(handle);
        const n = @min(bytes.len, 4093);
        for (bytes[0..n]) |byte| self.bad_bytes = self.bad_bytes or byte != @as(u8, @intCast('A' + item.id));
        self.record(item, bytes.len);
        item.offset += n;
        return n;
    }
    fn close(raw: ?*anyopaque, handle: *ssh_session.SftpHandle) ssh_session.SftpCloseResult {
        const self = service(raw);
        self.begin();
        defer self.end();
        const item = slot(handle);
        if (item.purpose == .transfer and self.pending_close_slot == item.id and !self.close_release.load(.acquire)) {
            self.close_entered.store(true, .release);
            return .{ .receipt = .awaiting, .consumed = false };
        }
        item.closes += 1;
        if (item.consumed) self.bad_bytes = true;
        item.consumed = true;
        if (item.purpose == .transfer and self.first_close_mask == null) self.first_close_mask = self.progressed_mask;
        return .{ .receipt = if (item.purpose == .transfer and self.unknown_close_slot == item.id) .unknown else .released, .consumed = true };
    }
    fn release(raw: ?*anyopaque, _: *ssh_session.Session) ssh_session.ReleaseReceipt {
        const self = service(raw);
        self.begin();
        defer self.end();
        self.context_entered.store(true, .release);
        if (self.context_unknown) return .unknown;
        return if (self.context_release.load(.acquire)) .released else .awaiting;
    }
    fn stat(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpAttributes {
        const self = service(raw);
        return .{ .kind = .file, .size = self.sizes[try index(path)] orelse length, .modified_at = 1 };
    }
    fn statHandle(raw: ?*anyopaque, _: *ssh_session.Session, handle: *ssh_session.SftpHandle) !ssh_session.SftpAttributes {
        const self = service(raw);
        const item = slot(handle);
        return .{ .kind = .file, .size = self.sizes[item.id] orelse length, .modified_at = 1 };
    }
    fn bind(self: *OwnerTestService, engine: *SftpEngine) void {
        self.caller = std.Thread.getCurrentId();
        engine.remote_metadata = .{ .context = self, .size = size, .stat = stat, .target_stat = targetStat };
        engine.remote_files = .{ .context = self, .open_read = openRead, .stat_handle = statHandle, .open_write = openWrite, .create_exclusive = createExclusive, .read = read, .write = write, .close = close, .release = release };
    }
    fn unblock(self: *OwnerTestService) void {
        self.metadata_release.store(true, .release);
        self.read_release.store(true, .release);
        self.close_release.store(true, .release);
        self.context_release.store(true, .release);
    }
    fn expectSingleOwner(self: *OwnerTestService) !void {
        try std.testing.expect(!self.concurrent_calls.load(.acquire));
        try std.testing.expect(!self.wrong_thread);
        try std.testing.expect(!self.changed_thread);
        try std.testing.expect(!self.oversize);
        try std.testing.expect(!self.bad_bytes);
    }
};

fn expectLocalPattern(dir: std.Io.Dir, name: []const u8, byte: u8) !void {
    const file = try dir.openFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, OwnerTestService.length), (try file.stat(std.testing.io)).size);
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < OwnerTestService.length) {
        const n = try file.readPositional(std.testing.io, &.{&buffer}, offset);
        try std.testing.expect(n > 0);
        for (buffer[0..n]) |value| try std.testing.expectEqual(byte, value);
        offset += n;
    }
}

test "sftp engine one IO owner fairly rotates three real Manager jobs and partial IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var contents: [OwnerTestService.length]u8 = undefined;
    for ([_]u8{ 'b', 'c' }) |name| {
        @memset(&contents, name - 'a' + 'A');
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = &.{name}, .data = &contents });
    }
    var service: OwnerTestService = .{};
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 3, .{ .max_attempts = 1 });
    defer controller.deinit();
    var ids: [3]manager.JobId = undefined;
    for (&ids, 0..) |*id, i| id.* = try controller.enqueue(.{ .session_id = 517, .direction = if (i == 0) .download else .upload, .sources = &.{&.{@as(u8, @intCast('a' + i))}}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = false });
    controller.tick(0);
    try awaitWorker(&service.metadata_entered);
    try std.testing.expectEqual(@as(usize, 3), engine.jobs.items.len);
    for (ids) |id| try std.testing.expectEqual(manager.State.running, controller.progress(id).?.state);
    try std.testing.expect(!engine.detachIfIdle());
    service.metadata_release.store(true, .release);
    for (engine.jobs.items) |job| try awaitWorker(&job.worker_done);
    try awaitWorker(&engine.owner_done);
    controller.tick(1);
    for (ids) |id| {
        try std.testing.expectEqual(manager.State.succeeded, controller.progress(id).?.state);
        try std.testing.expectEqual(@as(u64, OwnerTestService.length), controller.progress(id).?.done_bytes);
    }
    for (engine.jobs.items) |job| try std.testing.expectEqual(@as(u64, 517), job.spec.view().session_id);
    try service.expectSingleOwner();
    try std.testing.expectEqual(@as(u8, 0b111), service.first_close_mask.?);
    try std.testing.expect(service.data_count > 20);
    for (service.slots) |item| {
        try std.testing.expectEqual(@as(u64, OwnerTestService.length), item.offset);
        try std.testing.expectEqual(@as(usize, 1), item.closes);
    }
    try expectLocalPattern(tmp.dir, "a", 'A');
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "a.part", .{}));
    try std.testing.expect(engine.detachIfIdle());
}

test "sftp engine captured cancel waits for close receipt while another job completes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var service: OwnerTestService = .{ .block_read_slot = 0, .pending_close_slot = 0 };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 2, .{ .max_attempts = 1 });
    defer controller.deinit();
    const first = try controller.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = false });
    const second = try controller.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"b"}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = false });
    controller.tick(0);
    try awaitWorker(&service.metadata_entered);
    service.metadata_release.store(true, .release);
    try awaitWorker(&service.read_blocked);
    try controller.cancel(first);
    const original = engine.jobs.items[0];
    const other = engine.jobs.items[1];
    try std.testing.expect(original.cancel_flag.load(.acquire));
    try std.testing.expect(!other.cancel_flag.load(.acquire));
    try std.testing.expect(!original.worker_done.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    service.read_release.store(true, .release);
    try awaitWorker(&service.close_entered);
    try awaitWorker(&other.worker_done);
    try std.testing.expect(!original.worker_done.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    service.close_release.store(true, .release);
    try awaitWorker(&original.worker_done);
    try awaitWorker(&engine.owner_done);
    controller.tick(1);
    try std.testing.expectEqual(manager.State.cancelled, controller.progress(first).?.state);
    try std.testing.expectEqual(manager.State.succeeded, controller.progress(second).?.state);
    try std.testing.expect(original.done.load(.acquire) < original.total.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), service.slots[0].closes);
    try std.testing.expectEqual(@as(usize, 1), service.slots[1].closes);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "a", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "a.part", .{}));
    try expectLocalPattern(tmp.dir, "b", 'B');
    try service.expectSingleOwner();
    try std.testing.expect(engine.detachIfIdle());
}

test "sftp engine consumed failed handle close pins binding until whole context release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var service: OwnerTestService = .{ .unknown_close_slot = 0 };
    service.metadata_release.store(true, .release);
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    _ = try engine.open(.{ .session_id = 101, .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = false });
    try awaitWorker(&service.context_entered);
    const job = engine.jobs.items[0];
    try std.testing.expect(job.terminal.load(.acquire));
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expectEqual(&session, engine.session.?);
    try std.testing.expectError(error.CleanupUnknown, engine.open(.{ .direction = .download, .sources = &.{"b"}, .remote_dir = "/frozen", .local_dir = directory }));
    const unresolved = engine.poll().?;
    try std.testing.expectEqual(manager.EngineState.failed, unresolved.state);
    try std.testing.expectEqual(manager.JobCleanup.unknown, unresolved.job_cleanup);
    try std.testing.expect(engine.poll() == null);
    service.context_release.store(true, .release);
    try awaitWorker(&job.worker_done);
    try awaitWorker(&engine.owner_done);
    const event = engine.poll().?;
    try std.testing.expectEqual(manager.EngineState.failed, event.state);
    try std.testing.expectEqual(manager.JobCleanup.released, event.job_cleanup);
    try std.testing.expect(engine.poll() == null);
    try std.testing.expectEqual(manager.Failure.io, event.failure.?);
    try std.testing.expect(!event.retryable);
    try std.testing.expectEqual(@as(usize, 1), service.slots[0].closes);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "a", .{}));
    try service.expectSingleOwner();
    try std.testing.expect(engine.detachIfIdle());
}

test "sftp engine optional VM single owner downloads two frozen files without shell or remote mutation" {
    const password_raw = std.c.getenv("ZEROWORK_VM_PASSWORD") orelse return error.SkipZigTest;
    const password = try std.testing.allocator.dupeSentinel(u8, std.mem.span(password_raw), 0);
    defer std.testing.allocator.free(password);
    var library = try ssh_session.Library.init();
    defer library.deinit();
    var session = try ssh_session.Session.connect(&library, .{
        .host = "192.0.2.10",
        .user = "root",
        .auth = .{ .password = password },
        .host_key_decision = .trust_once,
        .open_shell = false,
        .connect_timeout_ms = 5_000,
    });
    defer session.close();
    try std.testing.expect(session.channel == null);
    session.setBlocking();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.attachSession(&session);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 2, .{ .max_attempts = 1 });
    defer controller.deinit();
    var ids: [2]manager.JobId = undefined;
    for (&ids, 0..) |*id, i| id.* = try controller.enqueue(.{ .session_id = 128, .direction = .download, .sources = &.{"/etc/services"}, .remote_dir = "/etc", .local_dir = directory, .rename = if (i == 0) "services-a" else "services-b", .resume_transfer = false });
    controller.tick(0);
    try std.testing.expectEqual(@as(usize, 2), engine.jobs.items.len);
    const deadline = monotonicNs() + 20 * std.time.ns_per_s;
    while (true) {
        controller.tick(nowMs());
        var done: usize = 0;
        for (engine.jobs.items) |job| if (job.worker_done.load(.acquire)) {
            done += 1;
        };
        if (done == 2) break;
        if (monotonicNs() >= deadline) return error.VmDownloadTimeout;
        workerTestPause();
    }
    try awaitWorker(&engine.owner_done);
    controller.tick(nowMs());
    for (ids) |id| {
        const progress = controller.progress(id).?;
        try std.testing.expectEqual(manager.State.succeeded, progress.state);
        try std.testing.expect(progress.done_bytes > 0);
        try std.testing.expectEqual(progress.total_bytes, progress.done_bytes);
    }
    const first_path = try tmp.dir.realPathFileAlloc(std.testing.io, "services-a", std.testing.allocator);
    defer std.testing.allocator.free(first_path);
    const second_path = try tmp.dir.realPathFileAlloc(std.testing.io, "services-b", std.testing.allocator);
    defer std.testing.allocator.free(second_path);
    try std.testing.expect(checksumEqual(try md5File(std.testing.allocator, first_path), try md5File(std.testing.allocator, second_path)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "services-a.part", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "services-b.part", .{}));
    try std.testing.expect(session.channel == null);
    try std.testing.expect(engine.detachIfIdle());
    const descriptor = session.socket_fd;
    const close_deadline = monotonicNs() + 5 * std.time.ns_per_s;
    while (session.closeReceipt() != .released) {
        if (monotonicNs() >= close_deadline) return error.VmSessionCleanupTimeout;
        workerTestPause();
    }
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(descriptor, std.c.F.GETFL, @as(c_int, 0)));
    try std.testing.expectEqual(std.c.E.BADF, @as(std.c.E, @fromBackingInt(@intCast(std.c._errno().*))));
    std.debug.print("SFTP_VM_PASS jobs=2 bytes_each={d} session=128 owner_threads=1 equal_md5=true shell=false remote_mutation=false fd_closed=true\n", .{controller.progress(ids[0]).?.done_bytes});
}

test "sftp engine unknown context release keeps idle detach false and explicit teardown does not fake released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var service: OwnerTestService = .{ .unknown_close_slot = 0, .context_unknown = true };
    service.metadata_release.store(true, .release);
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    _ = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = false });
    try awaitWorker(&service.context_entered);
    try awaitWorker(&engine.owner_done);
    const job = engine.jobs.items[0];
    try std.testing.expect(job.terminal.load(.acquire));
    try std.testing.expect(job.release_unknown.load(.acquire));
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expect(engine.owner_thread != null);
    try std.testing.expectEqual(&session, job.session.?);
    engine.detachSession();
    try std.testing.expect(engine.owner_thread == null);
    try std.testing.expect(job.session == null);
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(job.release_unknown.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    try std.testing.expectEqual(ssh_session.State.idle, session.state);
    try std.testing.expectEqual(@as(usize, 1), service.slots[0].closes);
    try service.expectSingleOwner();
}

test "sftp engine pause waits for IO and close then retains exact temp until original ID cancel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var service: OwnerTestService = .{ .block_read_slot = 0, .pending_close_slot = 0 };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 1, .{ .max_attempts = 1 });
    defer controller.deinit();
    const id = try controller.enqueue(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory, .chunk_kb = 32 });
    controller.tick(0);
    service.metadata_release.store(true, .release);
    try awaitWorker(&service.read_blocked);
    const job = engine.jobs.items[0];
    const native_id = job.id;
    try controller.pause(id);
    try std.testing.expectEqual(manager.State.pausing, controller.progress(id).?.state);
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(!job.cancel_flag.load(.acquire));
    try std.testing.expect((try engine.retainedTemp(std.testing.allocator, native_id)) == null);
    service.read_release.store(true, .release);
    try awaitWorker(&service.close_entered);
    // The read that was in flight when pause arrived must not write its bytes.
    const active_path = job.owned_temp.?.path;
    try std.testing.expectEqual(@as(u64, chunk_bytes), (try std.Io.Dir.cwd().statFile(std.testing.io, active_path, .{})).size);
    try std.testing.expect(!job.worker_done.load(.acquire));
    controller.tick(1);
    try std.testing.expectEqual(manager.State.pausing, controller.progress(id).?.state);
    service.close_release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    controller.tick(2);
    try std.testing.expectEqual(manager.State.paused, controller.progress(id).?.state);
    try std.testing.expectEqual(manager.JobCleanup.released, controller.progress(id).?.job_cleanup);
    const retained = (try engine.retainedTemp(std.testing.allocator, native_id)).?;
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings(active_path, retained);
    const stable_size = (try std.Io.Dir.cwd().statFile(std.testing.io, retained, .{})).size;
    try std.testing.expectEqual(@as(u64, chunk_bytes), stable_size);
    const calls_at_release = service.data_count;
    const done_at_release = job.done.load(.acquire);
    try std.testing.expect(engine.detachIfIdle());
    try std.testing.expectError(error.UnsupportedResume, controller.resumeJob(id));
    // Cancel still routes to this exact paused native ID after Session detach.
    try controller.cancel(id);
    try std.testing.expectEqual(manager.State.cancelling, controller.progress(id).?.state);
    try awaitWorker(&engine.owner_done);
    controller.tick(3);
    try std.testing.expectEqual(manager.State.cancelled, controller.progress(id).?.state);
    try std.testing.expectEqual(manager.JobCleanup.released, controller.progress(id).?.job_cleanup);
    try std.testing.expectEqual(native_id, job.id);
    try std.testing.expectEqual(calls_at_release, service.data_count);
    try std.testing.expectEqual(done_at_release, job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), service.slots[0].closes);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, retained, .{}));
    try std.testing.expect((try engine.retainedTemp(std.testing.allocator, native_id)) == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "a", .{}));
    try service.expectSingleOwner();
}

test "sftp engine cancel upgrades pending pause without reporting premature release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var service: OwnerTestService = .{ .block_read_slot = 0, .pending_close_slot = 0 };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    const id = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory });
    service.metadata_release.store(true, .release);
    try awaitWorker(&service.read_blocked);
    try engine.pause(id);
    engine.cancel(id);
    service.read_release.store(true, .release);
    try awaitWorker(&service.close_entered);
    const job = engine.jobs.items[0];
    const path = try std.testing.allocator.dupe(u8, job.owned_temp.?.path);
    defer std.testing.allocator.free(path);
    try std.testing.expect(!job.worker_done.load(.acquire));
    while (engine.poll()) |event| try std.testing.expectEqual(manager.JobCleanup.awaiting, event.job_cleanup);
    service.close_release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    const final = engine.poll().?;
    try std.testing.expectEqual(manager.EngineState.cancelled, final.state);
    try std.testing.expectEqual(manager.JobCleanup.released, final.job_cleanup);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{}));
    try std.testing.expect(engine.poll() == null);
}

test "sftp engine new download never adopts stranger part and never overwrites final" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.part", .data = "STRANGER-PART" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "EXISTING-FINAL" });
    var service: OwnerTestService = .{};
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    _ = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = true });
    _ = try engine.open(.{ .direction = .download, .sources = &.{"b"}, .remote_dir = "/frozen", .local_dir = directory, .resume_transfer = true });
    service.metadata_release.store(true, .release);
    var waiting = try awaitConflictSnapshot(engine, engine.jobs.items[1].id);
    defer waiting.deinit();
    try std.testing.expect(waiting.value.pending == .context_required);
    try awaitWorker(&engine.jobs.items[0].worker_done);
    engine.cancel(engine.jobs.items[1].id);
    try awaitWorker(&engine.owner_done);
    try expectLocalPattern(tmp.dir, "a", 'A');
    const stranger = try tmp.dir.readFileAlloc(std.testing.io, "a.part", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(stranger);
    try std.testing.expectEqualStrings("STRANGER-PART", stranger);
    const final = try tmp.dir.readFileAlloc(std.testing.io, "b", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(final);
    try std.testing.expectEqualStrings("EXISTING-FINAL", final);
    var successes: usize = 0;
    var failures: usize = 0;
    while (engine.poll()) |event| {
        try std.testing.expectEqual(manager.JobCleanup.released, event.job_cleanup);
        switch (event.state) {
            .succeeded => successes += 1,
            .cancelled => {
                failures += 1;
                try std.testing.expect(event.failure == null);
            },
            else => return error.UnexpectedTransferState,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), successes);
    try std.testing.expectEqual(@as(usize, 1), failures);
}

test "sftp engine cancel refuses a replaced owned temp and publishes cleanup unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var service: OwnerTestService = .{ .block_read_slot = 0 };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        service.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    service.bind(engine);
    const id = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/frozen", .local_dir = directory, .chunk_kb = 32 });
    service.metadata_release.store(true, .release);
    try awaitWorker(&service.read_blocked);
    const job = engine.jobs.items[0];
    const path = try std.testing.allocator.dupe(u8, job.owned_temp.?.path);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().renamePreserve(path, tmp.dir, "preserved-original", std.testing.io);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "FOREIGN-REPLACEMENT" });
    engine.cancel(id);
    service.read_release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    const event = engine.poll().?;
    try std.testing.expectEqual(manager.EngineState.cancelled, event.state);
    try std.testing.expectEqual(manager.JobCleanup.unknown, event.job_cleanup);
    try std.testing.expect(!job.worker_done.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    const foreign = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("FOREIGN-REPLACEMENT", foreign);
    try std.testing.expectEqual(@as(u64, chunk_bytes), (try tmp.dir.statFile(std.testing.io, "preserved-original", .{})).size);
    try std.testing.expect(engine.poll() == null);
}

/// A local directory acts as the remote filesystem. Production owner phases,
/// positional IO, fingerprints and close receipts remain real; no SSH/VM writes.
const ResumePeer = struct {
    const Handle = struct { file: ?std.Io.File = null, offset: u64 = 0, purpose: ReadPurpose = .transfer, name: u8 = 'a', writing: bool = false, preserve: bool = false };
    dir: std.Io.Dir,
    corrupt_offsets: [2]?u64 = .{ null, null },
    deny_checksum_read: bool = false,
    deny_repair_read: bool = false,
    preserve_opens: std.atomic.Value(usize) = .init(0),
    preserve_bytes: std.atomic.Value(u64) = .init(0),
    deny_preserve_write: bool = false,
    block_checksum_close: bool = false,
    checksum_opens: std.atomic.Value(usize) = .init(0),
    checksum_bytes: std.atomic.Value(u64) = .init(0),
    repair_opens: std.atomic.Value(usize) = .init(0),
    oversize: std.atomic.Value(bool) = .init(false),
    caller: std.Thread.Id = undefined,
    caller_io: std.atomic.Value(bool) = .init(false),
    block_transfer_open: bool = false,
    open_blocked: std.atomic.Value(bool) = .init(false),
    open_release: std.atomic.Value(bool) = .init(false),
    unknown_prefix_close: bool = false,
    block_upload_close: bool = false,
    close_blocked: std.atomic.Value(bool) = .init(false),
    close_release: std.atomic.Value(bool) = .init(false),
    context_blocked: std.atomic.Value(bool) = .init(false),
    context_release: std.atomic.Value(bool) = .init(true),
    handles: [12]Handle = @splat(.{}),
    block_at: ?u64 = 7000,
    block_name: u8 = 'a',
    block_purpose: ReadPurpose = .transfer,
    block_preserve_write: bool = false,
    blocked: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    stat_blocked: std.atomic.Value(bool) = .init(false),
    stat_release: std.atomic.Value(bool) = .init(true),
    writes: std.atomic.Value(usize) = .init(0),
    truncates: std.atomic.Value(usize) = .init(0),
    preserve_zero: std.atomic.Value(usize) = .init(0),
    transfer_opens: [3]std.atomic.Value(usize) = .{ .init(0), .init(0), .init(0) },
    exclusive_race_name: ?[]const u8 = null,
    exclusive_races: std.atomic.Value(usize) = .init(0),
    fingerprint_opens: std.atomic.Value(usize) = .init(0),
    wire_bytes: std.atomic.Value(u64) = .init(0),
    transfer_bytes: [3]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0) },

    fn of(raw: ?*anyopaque) *ResumePeer {
        return @ptrCast(@alignCast(raw.?));
    }
    fn handle(value: *ssh_session.SftpHandle) *Handle {
        return @ptrCast(@alignCast(value.handle));
    }
    fn name(path: [:0]const u8) !u8 {
        const base = std.fs.path.basename(path);
        if (base.len == 0 or base[0] < 'a' or base[0] > 'c') return error.InvalidTestPath;
        return base[0];
    }
    fn check(self: *ResumePeer) void {
        if (std.Thread.getCurrentId() == self.caller) self.caller_io.store(true, .release);
    }
    fn attrs(value: std.Io.File.Stat) ssh_session.SftpAttributes {
        return .{ .kind = if (value.kind == .file) .file else .other, .size = value.size, .modified_at = @intCast(@max(0, @divFloor(value.mtime.toNanoseconds(), std.time.ns_per_s))) };
    }
    fn size(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8) !u64 {
        const self = of(raw);
        self.check();
        if (!self.stat_release.load(.acquire)) {
            self.stat_blocked.store(true, .release);
            try awaitWorker(&self.stat_release);
        }
        return (try self.dir.statFile(std.testing.io, std.fs.path.basename(path), .{})).size;
    }
    fn stat(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpAttributes {
        const self = of(raw);
        self.check();
        return attrs(try self.dir.statFile(std.testing.io, std.fs.path.basename(path), .{ .follow_symlinks = false }));
    }
    fn statHandle(raw: ?*anyopaque, _: *ssh_session.Session, value: *ssh_session.SftpHandle) !ssh_session.SftpAttributes {
        const self = of(raw);
        self.check();
        return attrs(try handle(value).file.?.stat(std.testing.io));
    }
    fn allocate(self: *ResumePeer, file: std.Io.File, offset: u64, purpose: ReadPurpose, filename: u8, writing: bool) !ssh_session.SftpHandle {
        for (&self.handles) |*slot| if (slot.file == null) {
            slot.* = .{ .file = file, .offset = offset, .purpose = purpose, .name = filename, .writing = writing };
            return .{ .handle = @ptrCast(slot) };
        };
        file.close(std.testing.io);
        return error.TestHandleCapacity;
    }
    fn openRead(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8, purpose: ReadPurpose) !ssh_session.SftpHandle {
        const self = of(raw);
        self.check();
        const filename = try name(path);
        if (purpose == .checksum) {
            _ = self.checksum_opens.fetchAdd(1, .acq_rel);
            if (self.deny_checksum_read) return error.AccessDenied;
        }
        if (purpose == .repair) {
            _ = self.repair_opens.fetchAdd(1, .acq_rel);
            if (self.deny_repair_read) return error.AccessDenied;
        }
        if (purpose == .transfer and self.block_transfer_open and !self.open_release.load(.acquire)) {
            self.open_blocked.store(true, .release);
            try awaitWorker(&self.open_release);
        }
        if (purpose == .transfer) _ = self.transfer_opens[filename - 'a'].fetchAdd(1, .acq_rel);
        if (purpose == .fingerprint) _ = self.fingerprint_opens.fetchAdd(1, .acq_rel);
        const file = try self.dir.openFile(std.testing.io, std.fs.path.basename(path), .{});
        return self.allocate(file, 0, purpose, filename, false);
    }
    fn openWrite(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8, offset: u64, preserve: bool) !ssh_session.SftpHandle {
        const self = of(raw);
        self.check();
        const filename = try name(path);
        if (preserve and self.deny_preserve_write) return error.AccessDenied;
        if (self.block_transfer_open and !self.open_release.load(.acquire)) {
            self.open_blocked.store(true, .release);
            try awaitWorker(&self.open_release);
        }
        _ = self.transfer_opens[filename - 'a'].fetchAdd(1, .acq_rel);
        const file = if (preserve) blk: {
            _ = self.preserve_opens.fetchAdd(1, .acq_rel);
            if (offset == 0) _ = self.preserve_zero.fetchAdd(1, .acq_rel);
            break :blk try self.dir.openFile(std.testing.io, std.fs.path.basename(path), .{ .mode = .read_write });
        } else blk: {
            _ = self.truncates.fetchAdd(1, .acq_rel);
            break :blk try self.dir.createFile(std.testing.io, std.fs.path.basename(path), .{});
        };
        var result = try self.allocate(file, offset, .transfer, filename, true);
        handle(&result).preserve = preserve;
        return result;
    }
    fn createExclusive(raw: ?*anyopaque, _: *ssh_session.Session, path: [:0]const u8) !ssh_session.SftpHandle {
        const self = of(raw);
        self.check();
        const filename = try name(path);
        if (self.block_transfer_open and !self.open_release.load(.acquire)) {
            self.open_blocked.store(true, .release);
            try awaitWorker(&self.open_release);
        }
        if (self.exclusive_race_name) |race| if (std.mem.eql(u8, race, std.fs.path.basename(path)) and self.exclusive_races.fetchAdd(1, .acq_rel) == 0) {
            try self.dir.writeFile(std.testing.io, .{ .sub_path = race, .data = "RACED-TARGET" });
        };
        const file = try self.dir.createFile(std.testing.io, std.fs.path.basename(path), .{ .exclusive = true });
        _ = self.transfer_opens[filename - 'a'].fetchAdd(1, .acq_rel);
        return self.allocate(file, 0, .transfer, filename, true);
    }
    fn truncate(raw: ?*anyopaque, _: *ssh_session.Session, value: *ssh_session.SftpHandle) !void {
        const self = of(raw);
        self.check();
        try handle(value).file.?.setLength(std.testing.io, 0);
        _ = self.truncates.fetchAdd(1, .acq_rel);
    }
    fn gate(self: *ResumePeer, slot: *Handle) !void {
        if (self.block_at) |threshold| if (slot.name == self.block_name and (slot.purpose == self.block_purpose or (slot.writing and slot.preserve and self.block_preserve_write)) and slot.offset >= threshold and !self.release.load(.acquire)) {
            self.blocked.store(true, .release);
            try awaitWorker(&self.release);
        };
    }
    fn read(raw: ?*anyopaque, value: *ssh_session.SftpHandle, bytes: []u8) !usize {
        const self = of(raw);
        self.check();
        const slot = handle(value);
        try self.gate(slot);
        if (bytes.len > chunk_bytes) self.oversize.store(true, .release);
        const count = try slot.file.?.readPositional(std.testing.io, &.{bytes[0..@min(bytes.len, 4093)]}, slot.offset);
        if (slot.purpose == .transfer) for (self.corrupt_offsets) |maybe_offset| {
            if (maybe_offset) |offset| if (offset >= slot.offset and offset < slot.offset + count) {
                bytes[@intCast(offset - slot.offset)] ^= 0x40;
            };
        };
        if (slot.purpose == .checksum) _ = self.checksum_bytes.fetchAdd(count, .acq_rel);
        slot.offset += count;
        _ = self.wire_bytes.fetchAdd(count, .acq_rel);
        if (slot.purpose == .transfer) _ = self.transfer_bytes[slot.name - 'a'].fetchAdd(count, .acq_rel);
        return count;
    }
    fn write(raw: ?*anyopaque, value: *ssh_session.SftpHandle, bytes: []const u8) !usize {
        const self = of(raw);
        self.check();
        const slot = handle(value);
        try self.gate(slot);
        if (bytes.len > chunk_bytes) self.oversize.store(true, .release);
        const count = @min(bytes.len, 4093);
        var chunk: [4093]u8 = undefined;
        @memcpy(chunk[0..count], bytes[0..count]);
        if (!slot.preserve) for (self.corrupt_offsets) |maybe_offset| {
            if (maybe_offset) |offset| if (offset >= slot.offset and offset < slot.offset + count) {
                chunk[@intCast(offset - slot.offset)] ^= 0x40;
            };
        };
        try slot.file.?.writePositionalAll(std.testing.io, chunk[0..count], slot.offset);
        slot.offset += count;
        if (slot.preserve) _ = self.preserve_bytes.fetchAdd(count, .acq_rel);
        _ = self.writes.fetchAdd(1, .acq_rel);
        _ = self.wire_bytes.fetchAdd(count, .acq_rel);
        _ = self.transfer_bytes[slot.name - 'a'].fetchAdd(count, .acq_rel);
        return count;
    }
    fn close(raw: ?*anyopaque, value: *ssh_session.SftpHandle) ssh_session.SftpCloseResult {
        const self = of(raw);
        self.check();
        const slot = handle(value);
        if (((self.block_upload_close and slot.writing) or (self.block_checksum_close and slot.purpose == .checksum)) and !self.close_release.load(.acquire)) {
            self.close_blocked.store(true, .release);
            return .{ .receipt = .awaiting, .consumed = false };
        }
        if (slot.file) |file| {
            file.close(std.testing.io);
            slot.file = null;
        }
        return .{ .receipt = if (self.unknown_prefix_close and slot.purpose == .prefix) .unknown else .released, .consumed = true };
    }
    fn releaseContext(raw: ?*anyopaque, _: *ssh_session.Session) ssh_session.ReleaseReceipt {
        const self = of(raw);
        self.check();
        self.context_blocked.store(true, .release);
        return if (self.context_release.load(.acquire)) .released else .awaiting;
    }
    fn bind(self: *ResumePeer, engine: *SftpEngine) void {
        self.caller = std.Thread.getCurrentId();
        engine.remote_metadata = .{ .context = self, .size = size, .stat = stat, .target_stat = stat };
        engine.remote_files = .{ .context = self, .open_read = openRead, .open_write = openWrite, .create_exclusive = createExclusive, .truncate = truncate, .stat_handle = statHandle, .read = read, .write = write, .close = close, .release = releaseContext };
    }
    fn unblock(self: *ResumePeer) void {
        self.release.store(true, .release);
        self.stat_release.store(true, .release);
        self.open_release.store(true, .release);
        self.close_release.store(true, .release);
        self.context_release.store(true, .release);
    }
};

fn pauseResumePeer(engine: *SftpEngine, peer: *ResumePeer, id: EngineJobId) !*Job {
    try awaitWorker(&peer.blocked);
    try engine.pause(id);
    peer.release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    for (engine.jobs.items) |job| if (job.id == id) {
        try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(job.state.load(.acquire)));
        try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
        try std.testing.expect(job.checkpoint != null);
        return job;
    };
    return error.UnknownJob;
}
fn expectFileBytes(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4 * chunk_bytes));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, bytes, actual);
}

const resume_test_size = 2 * chunk_bytes + 733;
fn resumeBytes() [resume_test_size]u8 {
    var bytes: [resume_test_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(33 + index % 89);
    return bytes;
}

test "sftp engine safe resume downloads and uploads partial first chunk using exact checkpoint" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const bytes = resumeBytes();
        if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
        var peer: ResumePeer = .{ .dir = remote.dir };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const first = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
        const paused = try pauseResumePeer(engine, &peer, first);
        const partial = paused.checkpoint.?.file.offset;
        try std.testing.expect(partial > 0 and partial < chunk_bytes);
        try std.testing.expect(engine.canResume(first));
        const temp = if (direction == .download) (try engine.retainedTemp(std.testing.allocator, first)).? else null;
        defer if (temp) |path| std.testing.allocator.free(path);
        const second = try engine.resumeJob(first);
        try std.testing.expect(second != first);
        try std.testing.expect(!engine.canResume(first));
        try std.testing.expect(paused.handed_off and paused.checkpoint == null and paused.owned_temp == null);
        engine.cancel(first); // stale attempt must not affect its successor
        try awaitWorker(&engine.owner_done);
        const resumed = engine.jobs.items[1];
        try std.testing.expectEqual(second, resumed.id);
        try std.testing.expect(!resumed.cancel_flag.load(.acquire));
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(resumed.state.load(.acquire)));
        try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(resumed));
        try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", &bytes);
        if (direction == .upload) {
            try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), peer.preserve_zero.load(.acquire));
        } else try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, temp.?, .{}));
        try std.testing.expect(!peer.caller_io.load(.acquire));
    }
}

test "sftp engine resume rejects source or complete prefix tampering and retains cancellable original data" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]bool{ false, true }) |change_source| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            const first = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
            const paused = try pauseResumePeer(engine, &peer, first);
            const temp = if (direction == .download) (try engine.retainedTemp(std.testing.allocator, first)).? else null;
            defer if (temp) |path| std.testing.allocator.free(path);
            const target_dir = if (change_source) (if (direction == .download) remote.dir else local.dir) else (if (direction == .download) std.Io.Dir.cwd() else remote.dir);
            const target_path = if (!change_source and direction == .download) temp.? else "a";
            const file = try target_dir.openFile(std.testing.io, target_path, .{ .mode = .read_write });
            try file.writePositionalAll(std.testing.io, "CHANGED", if (change_source) resume_test_size - 32 else 25);
            file.close(std.testing.io);
            const before_writes = peer.writes.load(.acquire);
            const partial = paused.checkpoint.?.file.offset;
            const second = try engine.resumeJob(first);
            try awaitWorker(&engine.owner_done);
            const rejected = engine.jobs.items[1];
            try std.testing.expectEqual(second, rejected.id);
            try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(rejected.state.load(.acquire)));
            try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(rejected));
            try std.testing.expectEqual(manager.Failure.conflict, rejected.failure.get().?);
            try std.testing.expect(rejected.checkpoint != null);
            try std.testing.expectEqual(partial, rejected.checkpoint.?.file.offset);
            try std.testing.expectEqual(before_writes, peer.writes.load(.acquire));
            if (direction == .download) try std.testing.expectEqual(partial, (try std.Io.Dir.cwd().statFile(std.testing.io, temp.?, .{})).size);
            engine.cancel(second);
            try awaitWorker(&engine.owner_done);
            try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(rejected.state.load(.acquire)));
            try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(rejected));
            if (direction == .download) try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, temp.?, .{}));
            try std.testing.expect(!peer.caller_io.load(.acquire));
        }
    }
}

test "sftp engine safe resume preserves completed source index and never repeats earlier final placement" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "ALREADY-COMPLETED" });
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_name = 'b' };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{ "a", "b" }, .remote_dir = "/remote", .local_dir = directory });
    const paused = try pauseResumePeer(engine, &peer, first);
    try std.testing.expectEqual(@as(usize, 1), paused.checkpoint.?.source_index);
    try std.testing.expectEqual(@as(u64, "ALREADY-COMPLETED".len), paused.checkpoint.?.base);
    const second = try engine.resumeJob(first);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(second, engine.jobs.items[1].id);
    try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[1].state.load(.acquire)));
    try std.testing.expectEqual(@as(usize, 1), peer.transfer_opens[0].load(.acquire));
    try expectFileBytes(local.dir, "a", "ALREADY-COMPLETED");
    try expectFileBytes(local.dir, "b", &bytes);
}

test "sftp engine resume before metadata or source hash completion restarts only unfinished preflight" {
    for ([_]bool{ false, true }) |hash_started| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const bytes = resumeBytes();
        try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_purpose = .fingerprint };
        if (!hash_started) peer.stat_release.store(false, .release);
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const first = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
        if (hash_started) try awaitWorker(&peer.blocked) else try awaitWorker(&peer.stat_blocked);
        try engine.pause(first);
        peer.unblock();
        try awaitWorker(&engine.owner_done);
        const paused = engine.jobs.items[0];
        try std.testing.expectEqual(@as(u64, 0), paused.done.load(.acquire));
        try std.testing.expect(engine.canResume(first));
        const second = try engine.resumeJob(first);
        try awaitWorker(&engine.owner_done);
        try std.testing.expectEqual(second, engine.jobs.items[1].id);
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[1].state.load(.acquire)));
        try expectFileBytes(local.dir, "a", &bytes);
        try std.testing.expect(!peer.caller_io.load(.acquire));
    }
}

test "sftp engine cancel during resumed prefix verification cleans exact new attempt without writes" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
    _ = try pauseResumePeer(engine, &peer, first);
    const temp = (try engine.retainedTemp(std.testing.allocator, first)).?;
    defer std.testing.allocator.free(temp);
    peer.block_purpose = .prefix;
    peer.block_at = 0;
    peer.blocked.store(false, .release);
    peer.release.store(false, .release);
    const second = try engine.resumeJob(first);
    try awaitWorker(&peer.blocked);
    engine.cancel(first);
    try std.testing.expect(!engine.jobs.items[1].cancel_flag.load(.acquire));
    engine.cancel(second);
    try std.testing.expect(!engine.jobs.items[1].worker_done.load(.acquire));
    peer.release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(engine.jobs.items[1].state.load(.acquire)));
    try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(engine.jobs.items[1]));
    try std.testing.expectEqual(@as(usize, 0), peer.writes.load(.acquire));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, temp, .{}));
}

test "sftp engine repeated pause preserves validated short tail independently from aligned write cursor" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]bool{ true, false }) |at_open| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            const first = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
            const original = try pauseResumePeer(engine, &peer, first);
            const original_length = original.checkpoint.?.file.offset;
            if (at_open) {
                peer.block_transfer_open = true;
            } else {
                peer.block_at = 4093;
                peer.blocked.store(false, .release);
                peer.release.store(false, .release);
            }
            const second = try engine.resumeJob(first);
            if (at_open) try awaitWorker(&peer.open_blocked) else try awaitWorker(&peer.blocked);
            try engine.pause(second);
            peer.release.store(true, .release);
            peer.open_release.store(true, .release);
            try awaitWorker(&engine.owner_done);
            const paused_again = engine.jobs.items[1];
            try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(paused_again.state.load(.acquire)));
            try std.testing.expectEqual(original_length, paused_again.checkpoint.?.prefix_length);
            try std.testing.expect(paused_again.checkpoint.?.file.offset < original_length);
            try std.testing.expect(engine.canResume(second));
            const third = try engine.resumeJob(second);
            try awaitWorker(&engine.owner_done);
            try std.testing.expectEqual(third, engine.jobs.items[2].id);
            try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[2].state.load(.acquire)));
            try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", &bytes);
            if (direction == .upload) try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
        }
    }
}

test "sftp engine interrupted source hash preserves the already observed source version" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_purpose = .fingerprint };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
    const paused = try pauseResumePeer(engine, &peer, first);
    try std.testing.expect(paused.checkpoint.?.file.fingerprint == null);
    const original = paused.checkpoint.?.file.initial_stamp.?;
    const source = try remote.dir.openFile(std.testing.io, "a", .{ .mode = .read_write });
    try source.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@intCast(original.mtime_ns.? + 2 * std.time.ns_per_s)) } });
    source.close(std.testing.io);
    const second = try engine.resumeJob(first);
    try awaitWorker(&engine.owner_done);
    const rejected = engine.jobs.items[1];
    try std.testing.expectEqual(second, rejected.id);
    try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(rejected.state.load(.acquire)));
    try std.testing.expectEqual(manager.Failure.conflict, rejected.failure.get().?);
    try std.testing.expectEqual(@as(usize, 0), peer.transfer_opens[0].load(.acquire));
    try std.testing.expect(original.same(rejected.checkpoint.?.file.initial_stamp.?));
    engine.cancel(second);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(rejected.state.load(.acquire)));
}

test "sftp engine resumed validation close unknown pins original temp until actual context receipt" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
    _ = try pauseResumePeer(engine, &peer, first);
    const temp = (try engine.retainedTemp(std.testing.allocator, first)).?;
    defer std.testing.allocator.free(temp);
    peer.unknown_prefix_close = true;
    peer.context_release.store(false, .release);
    const second = try engine.resumeJob(first);
    try awaitWorker(&peer.context_blocked);
    const held = engine.jobs.items[1];
    try std.testing.expectEqual(second, held.id);
    try std.testing.expectEqual(manager.JobCleanup.unknown, SftpEngine.cleanupOf(held));
    try std.testing.expect(!held.worker_done.load(.acquire));
    try std.testing.expect(!engine.canResume(second));
    try std.testing.expect(!engine.detachIfIdle());
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, temp, .{});
    peer.context_release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(held.state.load(.acquire)));
    try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(held));
    try std.testing.expectEqual(manager.Failure.io, held.failure.get().?);
    const retained = (try engine.retainedTemp(std.testing.allocator, second)).?;
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings(temp, retained);
    engine.cancel(second);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(held.state.load(.acquire)));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, temp, .{}));
}

test "sftp engine download detects already compared temp bytes changed during prefix scan" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = chunk_bytes + 7000 };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
    const original = try pauseResumePeer(engine, &peer, first);
    const partial = original.checkpoint.?.file.offset;
    try std.testing.expect(partial > chunk_bytes);
    const temp = (try engine.retainedTemp(std.testing.allocator, first)).?;
    defer std.testing.allocator.free(temp);
    peer.block_purpose = .prefix;
    peer.block_at = 4093;
    peer.blocked.store(false, .release);
    peer.release.store(false, .release);
    const second = try engine.resumeJob(first);
    try awaitWorker(&peer.blocked);
    // Offset 25 has already been compared. The resume cursor will be >=32KiB,
    // so a resumed write would not repair this external modification.
    const changing = try std.Io.Dir.cwd().openFile(std.testing.io, temp, .{ .mode = .read_write });
    const before = try changing.stat(std.testing.io);
    try changing.writePositionalAll(std.testing.io, "TAMPER", 25);
    try changing.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(before.mtime.toNanoseconds() + 2 * std.time.ns_per_s) } });
    changing.close(std.testing.io);
    peer.release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    const held = engine.jobs.items[1];
    try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(held.state.load(.acquire)));
    try std.testing.expectEqual(manager.Failure.conflict, held.failure.get().?);
    try std.testing.expectEqual(partial, (try std.Io.Dir.cwd().statFile(std.testing.io, temp, .{})).size);
    try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
    engine.cancel(second);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(held.state.load(.acquire)));
}

test "sftp engine upload resume preserves zero byte opened target and fully written target before close" {
    for ([_]bool{ true, false }) |before_write| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const bytes = resumeBytes();
        try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .block_transfer_open = before_write, .block_upload_close = !before_write };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const first = try engine.open(.{ .direction = .upload, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
        if (before_write) try awaitWorker(&peer.open_blocked) else try awaitWorker(&peer.close_blocked);
        try engine.pause(first);
        peer.open_release.store(true, .release);
        peer.close_release.store(true, .release);
        try awaitWorker(&engine.owner_done);
        const paused = engine.jobs.items[0];
        try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(paused.state.load(.acquire)));
        try std.testing.expectEqual(@as(u64, if (before_write) 0 else resume_test_size), paused.checkpoint.?.file.offset);
        try std.testing.expect(paused.checkpoint.?.file.target_stamp != null);
        try std.testing.expect(engine.canResume(first));
        const second = try engine.resumeJob(first);
        try awaitWorker(&engine.owner_done);
        try std.testing.expectEqual(second, engine.jobs.items[1].id);
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[1].state.load(.acquire)));
        try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
        try expectFileBytes(remote.dir, "a", &bytes);
    }
}

const NoChecksumExec = struct {
    calls: std.atomic.Value(usize) = .init(0),
    fn exec(raw: *anyopaque, _: []const u8, _: exec_api.ExecOpts) !exec_api.ExecHandle {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        return error.UnexpectedChecksumExec;
    }
    fn cancel(_: exec_api.ExecHandle) void {
        unreachable;
    }
    fn poll(_: exec_api.ExecHandle) ?exec_api.ExecResult {
        unreachable;
    }
    fn close(_: *anyopaque) void {
        unreachable;
    }
    fn bridge(self: *@This()) exec_api.ExecBridge {
        return .{ .ctx = self, .exec_fn = exec, .abort_fn = cancel, .poll_fn = poll, .close_fn = close };
    }
};

fn md5Bytes(bytes: []const u8) [16]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &digest, .{});
    return digest;
}

test "sftp engine SFTP-only full MD5 succeeds both directions for empty aligned and tail files without Exec" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]usize{ 0, chunk_bytes, resume_test_size }) |size| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = bytes[0..size] }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = bytes[0..size] });
            var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            var forbidden: NoChecksumExec = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            engine.attachExecService(forbidden.bridge(), .{ .owner = .app, .operation_id = 501 });
            var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 1, .{ .max_attempts = 1 });
            defer controller.deinit();
            const id = try controller.enqueue(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
            controller.tick(0);
            try awaitWorker(&engine.owner_done);
            controller.tick(1);
            const progress = controller.progress(id).?;
            try std.testing.expectEqual(manager.State.succeeded, progress.state);
            try std.testing.expectEqual(manager.JobCleanup.released, progress.job_cleanup);
            const verified = progress.verification.?;
            try std.testing.expectEqual(.passed, verified.state);
            const expected = md5Bytes(bytes[0..size]);
            try std.testing.expectEqualSlices(u8, &expected, &verified.source_md5.?);
            try std.testing.expectEqualSlices(u8, &expected, &verified.target_md5.?);
            try std.testing.expectEqual(@as(u8, 0), verified.repair_count);
            try std.testing.expect(verified.repair_start == null and verified.repair_end == null);
            try std.testing.expectEqual(@as(u64, size), peer.checksum_bytes.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), forbidden.calls.load(.acquire));
            try std.testing.expect(!peer.oversize.load(.acquire));
            try std.testing.expect(!peer.caller_io.load(.acquire));
            try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", bytes[0..size]);
            if (direction == .download) try std.testing.expect(engine.jobs.items[0].owned_temp == null);
        }
    }
}

test "sftp engine MD5 repairs exactly the final logical block once then recomputes complete digests" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]bool{ false, true }) |middle_damage| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .corrupt_offsets = .{ resume_test_size - 8, if (middle_damage) 25 else null } };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            _ = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
            try awaitWorker(&engine.owner_done);
            const job = engine.jobs.items[0];
            const verified = job.verification.get().value.?;
            try std.testing.expectEqual(@as(u8, 1), verified.repair_count);
            try std.testing.expectEqual(lastBlockOffset(resume_test_size, chunk_bytes), verified.repair_start.?);
            try std.testing.expectEqual(@as(u64, resume_test_size), verified.repair_end.?);
            try std.testing.expectEqual(@as(usize, 2), peer.checksum_opens.load(.acquire));
            try std.testing.expectEqual(@as(u64, 2 * resume_test_size), peer.checksum_bytes.load(.acquire));
            if (direction == .upload) {
                try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
                try std.testing.expectEqual(@as(usize, 1), peer.preserve_opens.load(.acquire));
                try std.testing.expectEqual(@as(u64, resume_test_size - lastBlockOffset(resume_test_size, chunk_bytes)), peer.preserve_bytes.load(.acquire));
            }
            if (!middle_damage) {
                try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(job.state.load(.acquire)));
                try std.testing.expectEqual(.passed, verified.state);
                try std.testing.expectEqualSlices(u8, &verified.source_md5.?, &verified.target_md5.?);
                try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", &bytes);
            } else {
                try std.testing.expectEqual(manager.EngineState.failed, engineStateOf(job.state.load(.acquire)));
                try std.testing.expectEqual(manager.Failure.checksum, job.failure.get().?);
                try std.testing.expect(!job.retryable.load(.acquire));
                try std.testing.expectEqual(.failed, verified.state);
                try std.testing.expect(!std.mem.eql(u8, &verified.source_md5.?, &verified.target_md5.?));
                if (direction == .download) {
                    try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
                    const retained = (try engine.retainedTemp(std.testing.allocator, job.id)).?;
                    defer std.testing.allocator.free(retained);
                    const damaged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, retained, std.testing.allocator, .limited(2 * resume_test_size));
                    defer std.testing.allocator.free(damaged);
                    try std.testing.expectEqual(bytes[25] ^ 0x40, damaged[25]);
                    try std.testing.expectEqual(bytes[resume_test_size - 8], damaged[resume_test_size - 8]);
                }
            }
            try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
        }
    }
}

test "sftp engine checksum unavailable and forbidden repair never claim pass or performed repair" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]bool{ false, true }) |deny_repair| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .deny_checksum_read = !deny_repair, .deny_repair_read = deny_repair and direction == .download, .deny_preserve_write = deny_repair and direction == .upload, .corrupt_offsets = .{ if (deny_repair) resume_test_size - 8 else null, null } };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            _ = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
            try awaitWorker(&engine.owner_done);
            const job = engine.jobs.items[0];
            try std.testing.expectEqual(manager.EngineState.failed, engineStateOf(job.state.load(.acquire)));
            try std.testing.expectEqual(manager.Failure.permission_denied, job.failure.get().?);
            try std.testing.expect(!job.retryable.load(.acquire));
            const diagnostic = job.verification.get().value.?;
            try std.testing.expectEqual(.unavailable, diagnostic.state);
            try std.testing.expectEqual(@as(u8, 0), diagnostic.repair_count);
            try std.testing.expect(diagnostic.repair_start == null and diagnostic.repair_end == null);
            if (direction == .download) {
                try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
                try std.testing.expect(job.owned_temp != null);
            }
            try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
        }
    }
}

test "sftp engine download waits real checksum close and shares owner before safe publication" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "OTHER-JOB" });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .block_checksum_close = true };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
    try awaitWorker(&peer.close_blocked);
    const held = engine.jobs.items[0];
    try std.testing.expect(!held.worker_done.load(.acquire));
    try std.testing.expect(!held.terminal.load(.acquire));
    try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
    _ = try engine.open(.{ .direction = .download, .sources = &.{"b"}, .remote_dir = "/remote", .local_dir = directory });
    try awaitWorker(&engine.jobs.items[1].worker_done);
    try expectFileBytes(local.dir, "b", "OTHER-JOB");
    try std.testing.expect(!held.worker_done.load(.acquire));
    try engine.pause(first);
    try std.testing.expect(!engine.detachIfIdle());
    peer.close_release.store(true, .release);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(held.state.load(.acquire)));
    try std.testing.expect(engine.canResume(first));
    const retained = (try engine.retainedTemp(std.testing.allocator, first)).?;
    defer std.testing.allocator.free(retained);
    try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
    const resumed = try engine.resumeJob(first);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(resumed, engine.jobs.items[2].id);
    try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[2].state.load(.acquire)));
    try std.testing.expectEqual(@as(usize, 1), peer.transfer_opens[0].load(.acquire));
    try expectFileBytes(local.dir, "a", &bytes);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, retained, .{}));
}

test "sftp engine verified download rename conflict preserves existing final and exact owned temp" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .block_checksum_close = true };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const id = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
    try awaitWorker(&peer.close_blocked);
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "EXISTING-FINAL-MUST-SURVIVE" });
    peer.close_release.store(true, .release);
    var waiting = try awaitConflictSnapshot(engine, id);
    defer waiting.deinit();
    try std.testing.expect(waiting.value.pending == .context_required);
    const job = engine.jobs.items[0];
    try std.testing.expectEqual(manager.EngineState.running, engineStateOf(job.state.load(.acquire)));
    try std.testing.expectEqual(.passed, job.verification.get().value.?.state);
    try std.testing.expect(job.failure.get() == null);
    try expectFileBytes(local.dir, "a", "EXISTING-FINAL-MUST-SURVIVE");
    const retained = try std.testing.allocator.dupe(u8, job.owned_temp.?.path);
    defer std.testing.allocator.free(retained);
    try expectFileBytes(std.Io.Dir.cwd(), retained, &bytes);
    engine.cancel(id);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, retained, .{}));
}

test "sftp engine MD5 read pause resumes verification without transfer rewrite and cancel waits for read" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]bool{ true, false }) |cancel_request| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir, .block_purpose = .checksum, .block_at = 0 };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            const first = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
            try awaitWorker(&peer.blocked);
            const job = engine.jobs.items[0];
            try std.testing.expectEqual(.reading, job.verification.get().value.?.state);
            if (direction == .download) try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
            if (cancel_request) engine.cancel(first) else try engine.pause(first);
            try std.testing.expect(!job.worker_done.load(.acquire));
            try std.testing.expect(!engine.detachIfIdle());
            peer.release.store(true, .release);
            try awaitWorker(&engine.owner_done);
            if (cancel_request) {
                try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(job.state.load(.acquire)));
                try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
                if (direction == .download) try std.testing.expect(job.owned_temp == null);
                try std.testing.expect(job.verification.get().value.?.state != .passed);
            } else {
                try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(job.state.load(.acquire)));
                try std.testing.expect(job.checkpoint.?.verification_pending);
                try std.testing.expect(engine.canResume(first));
                const second = try engine.resumeJob(first);
                try awaitWorker(&engine.owner_done);
                try std.testing.expectEqual(second, engine.jobs.items[1].id);
                try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[1].state.load(.acquire)));
                try std.testing.expectEqual(.passed, engine.jobs.items[1].verification.get().value.?.state);
                try std.testing.expectEqual(@as(usize, 1), peer.transfer_opens[0].load(.acquire));
                try std.testing.expectEqual(@as(usize, 0), peer.preserve_opens.load(.acquire));
                try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", &bytes);
            }
        }
    }
}

test "sftp engine MD5 rechecks source and target versions after hash handle close before publish" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        for ([_]bool{ true, false }) |change_source| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir, .block_checksum_close = true, .block_at = null };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            _ = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true });
            try awaitWorker(&peer.close_blocked);
            const job = engine.jobs.items[0];
            const changing_dir = if (change_source) (if (direction == .download) remote.dir else local.dir) else (if (direction == .download) std.Io.Dir.cwd() else remote.dir);
            const changing_path = if (!change_source and direction == .download) job.owned_temp.?.path else "a";
            const changing = try changing_dir.openFile(std.testing.io, changing_path, .{ .mode = .read_write });
            const stamp = try changing.stat(std.testing.io);
            try changing.writePositionalAll(std.testing.io, "AFTER-HASH", 25);
            try changing.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(stamp.mtime.toNanoseconds() + 2 * std.time.ns_per_s) } });
            changing.close(std.testing.io);
            peer.close_release.store(true, .release);
            try awaitWorker(&engine.owner_done);
            try std.testing.expectEqual(manager.EngineState.failed, engineStateOf(job.state.load(.acquire)));
            try std.testing.expectEqual(manager.Failure.conflict, job.failure.get().?);
            try std.testing.expectEqual(.unavailable, job.verification.get().value.?.state);
            try std.testing.expectEqual(@as(u8, 0), job.verification.get().value.?.repair_count);
            if (direction == .download) try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "a", .{}));
        }
    }
}

test "sftp engine paused MD5 final block repair retains one repair and revalidates before completing it" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const all = resumeBytes();
        const bytes = all[0 .. 2 * chunk_bytes];
        if (direction == .download) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = bytes }) else try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = bytes });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_purpose = .repair, .block_preserve_write = true, .block_at = chunk_bytes + 4093, .corrupt_offsets = .{ 2 * chunk_bytes - 8, null } };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const first = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true, .chunk_kb = 32 });
        try awaitWorker(&peer.blocked);
        try engine.pause(first);
        peer.release.store(true, .release);
        try awaitWorker(&engine.owner_done);
        const paused = engine.jobs.items[0];
        try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(paused.state.load(.acquire)));
        const partial = paused.verification.get().value.?;
        try std.testing.expectEqual(@as(u8, 1), partial.repair_count);
        try std.testing.expectEqual(@as(u64, chunk_bytes), partial.repair_start.?);
        try std.testing.expect(partial.repair_end.? > chunk_bytes and partial.repair_end.? < 2 * chunk_bytes);
        try std.testing.expect(engine.canResume(first));
        const second = try engine.resumeJob(first);
        try awaitWorker(&engine.owner_done);
        const done = engine.jobs.items[1];
        try std.testing.expectEqual(second, done.id);
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(done.state.load(.acquire)));
        const verified = done.verification.get().value.?;
        try std.testing.expectEqual(.passed, verified.state);
        try std.testing.expectEqual(@as(u8, 1), verified.repair_count);
        try std.testing.expectEqual(@as(u64, chunk_bytes), verified.repair_start.?);
        try std.testing.expectEqual(@as(u64, 2 * chunk_bytes), verified.repair_end.?);
        try std.testing.expectEqual(@as(u64, 3 * 2 * chunk_bytes), peer.checksum_bytes.load(.acquire));
        try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", bytes);
    }
}

test "sftp conflict preflight existing upload cannot truncate before a decision" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "EXISTING-APPROVAL-REQUIRED" });
    var peer: ResumePeer = .{ .dir = remote.dir };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    _ = try engine.open(.{ .direction = .upload, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory });
    var snapshot = try awaitConflictSnapshot(engine, engine.jobs.items[0].id);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.value.pending == .context_required);
    try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), peer.writes.load(.acquire));
    try std.testing.expect(!engine.detachIfIdle());
    try expectFileBytes(remote.dir, "a", "EXISTING-APPROVAL-REQUIRED");
    engine.cancel(engine.jobs.items[0].id);
    try awaitWorker(&engine.owner_done);
}

fn conflictTestContext(direction: manager.Direction) conflict_types.Context {
    const owner: @import("../host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 3 };
    const local: conflict.Endpoint = .{ .local_fs = .{ .binding_id = 1, .binding_generation = 1 } };
    const remote: conflict.Endpoint = .{ .sftp = .{ .binding_id = 8, .binding_generation = 5, .resource_owner = .{ .session = owner }, .origin_session = owner } };
    return .{ .intent_id = 77, .job = 11, .attempt = 1, .original_owner = owner, .resource_owner = .{ .session = owner }, .source_endpoint = if (direction == .upload) local else remote, .target_endpoint = if (direction == .upload) remote else local };
}
fn awaitConflictSnapshot(engine: *SftpEngine, id: EngineJobId) !conflict_types.OwnedSnapshot {
    const started = monotonicNs();
    while (true) {
        if (try engine.conflictSnapshot(std.testing.allocator, id)) |snapshot| return snapshot;
        if (monotonicNs() - started > 5 * std.time.ns_per_s) return error.ConflictWaitTimeout;
        workerTestPause();
    }
}
fn chooseConflict(engine: *SftpEngine, id: EngineJobId, choice: conflict.Choice, rename: []const u8, remaining: bool) !void {
    var snapshot = try awaitConflictSnapshot(engine, id);
    defer snapshot.deinit();
    if (snapshot.value.pending != .choice) return error.UnexpectedConflictStage;
    try engine.resolveConflict(id, .{ .select = .{ .key = snapshot.value.pending.choice.key, .selection = .{ .choice = choice, .rename = rename, .apply_to_remaining = remaining } } });
}
fn confirmConflict(engine: *SftpEngine, id: EngineJobId) !void {
    var snapshot = try awaitConflictSnapshot(engine, id);
    defer snapshot.deinit();
    if (snapshot.value.pending != .overwrite_confirmation) return error.UnexpectedConflictStage;
    const confirmation = snapshot.value.pending.overwrite_confirmation;
    try std.testing.expectEqual(@as(usize, 1), confirmation.targets.len);
    try engine.resolveConflict(id, .{ .confirm_overwrite = .{ .key = confirmation.targets[0].key, .ticket = confirmation.ticket } });
}

test "sftp conflict preflight skip batches preserve real done bytes and original Manager identity" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "AAAA" });
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "BBBBBB" });
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "KEEP-A" });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 1, .{ .max_attempts = 1 });
    defer controller.deinit();
    const job = try controller.enqueue(.{ .direction = .download, .sources = &.{ "a", "b" }, .remote_dir = "/remote", .local_dir = directory, .conflict_context = conflictTestContext(.download) });
    controller.tick(0);
    const native = engine.jobs.items[0].id;
    var snapshot = try awaitConflictSnapshot(engine, native);
    defer snapshot.deinit();
    const key = snapshot.value.pending.choice.key;
    try std.testing.expectEqual(job, key.job);
    try std.testing.expectEqual(@as(u32, 1), key.attempt);
    try std.testing.expect(snapshot.value.pending.choice.selection.choice == null);
    try std.testing.expectError(error.FileNotFound, local.dir.statFile(std.testing.io, "b", .{}));
    controller.tick(1);
    try std.testing.expect(controller.progress(job).?.conflict_waiting);
    var stale = key;
    stale.attempt += 1;
    try std.testing.expectError(error.StaleConflict, engine.resolveConflict(native, .{ .select = .{ .key = stale, .selection = .{ .choice = .overwrite } } }));
    try engine.resolveConflict(native, .{ .select = .{ .key = key, .selection = .{ .choice = .skip } } });
    try awaitWorker(&engine.owner_done);
    controller.tick(2);
    const progress = controller.progress(job).?;
    try std.testing.expectEqual(manager.State.succeeded, progress.state);
    try std.testing.expectEqual(@as(u64, 6), progress.done_bytes);
    try std.testing.expectEqual(@as(u64, 4), progress.skipped_bytes);
    try std.testing.expectEqual(@as(u32, 1), progress.skipped_files);
    try std.testing.expectEqual(@as(u64, 10), progress.total_bytes);
    try expectFileBytes(local.dir, "a", "KEEP-A");
    try expectFileBytes(local.dir, "b", "BBBBBB");
    // The caller-owned old snapshot outlives worker completion and paths.
    try std.testing.expect(std.mem.endsWith(u8, snapshot.value.pending.choice.target_path, "/a"));
}

test "sftp conflict preflight both directions require second overwrite approval and exact unchanged version" {
    inline for (.{ manager.Direction.upload, manager.Direction.download }) |direction| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const source = if (direction == .upload) local.dir else remote.dir;
        const target = if (direction == .upload) remote.dir else local.dir;
        const bytes = resumeBytes();
        try source.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
        try target.writeFile(std.testing.io, .{ .sub_path = "a", .data = "ORIGINAL-LARGER-TARGET-REQUIRES-APPROVAL" });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const id = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true, .conflict_context = conflictTestContext(direction) });
        try chooseConflict(engine, id, .overwrite, "", false);
        var confirmation = try awaitConflictSnapshot(engine, id);
        defer confirmation.deinit();
        try std.testing.expect(confirmation.value.pending == .overwrite_confirmation);
        try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
        try expectFileBytes(target, "a", "ORIGINAL-LARGER-TARGET-REQUIRES-APPROVAL");
        const old = confirmation.value.pending.overwrite_confirmation;
        // Returning leaves the same target untouched, and no grant is consumed.
        try engine.resolveConflict(id, .{ .return_to_choice = .{ .key = old.targets[0].key, .ticket = old.ticket } });
        try chooseConflict(engine, id, .overwrite, "", false);
        var second = try awaitConflictSnapshot(engine, id);
        defer second.deinit();
        const approved = second.value.pending.overwrite_confirmation;
        try target.writeFile(std.testing.io, .{ .sub_path = "a", .data = "CHANGED-VERSION" });
        try engine.resolveConflict(id, .{ .confirm_overwrite = .{ .key = approved.targets[0].key, .ticket = approved.ticket } });
        var changed = try awaitConflictSnapshot(engine, id);
        defer changed.deinit();
        try std.testing.expect(changed.value.pending == .choice);
        try std.testing.expect(changed.value.pending.choice.selection.choice == null);
        try std.testing.expectEqual(conflict.Issue.target_changed, changed.value.pending.choice.issue.?);
        try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
        try expectFileBytes(target, "a", "CHANGED-VERSION");
        try chooseConflict(engine, id, .overwrite, "", false);
        try confirmConflict(engine, id);
        try awaitWorker(&engine.owner_done);
        const completed = engine.jobs.items[0];
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(completed.state.load(.acquire)));
        try std.testing.expectEqual(.passed, completed.verification.get().value.?.state);
        try expectFileBytes(target, "a", &bytes);
        try std.testing.expectEqual(@as(usize, if (direction == .upload) 1 else 0), peer.truncates.load(.acquire));
    }
}

test "sftp conflict preflight save-as retains invalid input and keep-both uses exclusive raced names" {
    inline for (.{ manager.Direction.upload, manager.Direction.download }) |direction| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const source = if (direction == .upload) local.dir else remote.dir;
        const target = if (direction == .upload) remote.dir else local.dir;
        try source.writeFile(std.testing.io, .{ .sub_path = "a.tar.gz", .data = "SOURCE-CONTENT" });
        try target.writeFile(std.testing.io, .{ .sub_path = "a.tar.gz", .data = "KEEP-ORIGINAL" });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .exclusive_race_name = if (direction == .upload) "a (1).tar.gz" else null };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const id = try engine.open(.{ .direction = direction, .sources = &.{"a.tar.gz"}, .remote_dir = "/remote", .local_dir = directory, .conflict_context = conflictTestContext(direction) });
        try chooseConflict(engine, id, .save_as, "../escape", false);
        var invalid = try awaitConflictSnapshot(engine, id);
        defer invalid.deinit();
        try std.testing.expectEqualStrings("../escape", invalid.value.pending.choice.selection.rename);
        try std.testing.expectEqual(@as(usize, 0), peer.writes.load(.acquire));
        try chooseConflict(engine, id, .keep_both, "", false);
        try awaitWorker(&engine.owner_done);
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[0].state.load(.acquire)));
        try expectFileBytes(target, "a.tar.gz", "KEEP-ORIGINAL");
        if (direction == .upload) {
            try expectFileBytes(target, "a (1).tar.gz", "RACED-TARGET");
            try expectFileBytes(target, "a (2).tar.gz", "SOURCE-CONTENT");
        } else try expectFileBytes(target, "a (1).tar.gz", "SOURCE-CONTENT");
    }
}

test "sftp conflict preflight save-as copies input checks actual collision and never changes source" {
    inline for (.{ manager.Direction.upload, manager.Direction.download }) |direction| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const source = if (direction == .upload) local.dir else remote.dir;
        const target = if (direction == .upload) remote.dir else local.dir;
        try source.writeFile(std.testing.io, .{ .sub_path = "a", .data = "SOURCE" });
        try target.writeFile(std.testing.io, .{ .sub_path = "a", .data = "ORIGINAL" });
        try target.writeFile(std.testing.io, .{ .sub_path = "a-copy", .data = "OTHER" });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        const id = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .conflict_context = conflictTestContext(direction) });
        var initial = try awaitConflictSnapshot(engine, id);
        defer initial.deinit();
        var raw = "a-copy".*;
        try engine.resolveConflict(id, .{ .select = .{ .key = initial.value.pending.choice.key, .selection = .{ .choice = .save_as, .rename = &raw } } });
        @memset(&raw, 'x');
        var collision = try awaitConflictSnapshot(engine, id);
        defer collision.deinit();
        try std.testing.expectEqualStrings("a-copy", collision.value.pending.choice.selection.rename);
        try std.testing.expectEqual(conflict.Issue.name_exists, collision.value.pending.choice.issue.?);
        try std.testing.expectEqual(@as(usize, 0), peer.writes.load(.acquire));
        try chooseConflict(engine, id, .save_as, "a-new", false);
        try awaitWorker(&engine.owner_done);
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[0].state.load(.acquire)));
        try expectFileBytes(source, "a", "SOURCE");
        try expectFileBytes(target, "a", "ORIGINAL");
        try expectFileBytes(target, "a-copy", "OTHER");
        try expectFileBytes(target, "a-new", "SOURCE");
        try std.testing.expectEqual(@as(usize, 0), peer.truncates.load(.acquire));
    }
}

test "sftp conflict preflight remaining policy excludes a later Intent and paused old keys cannot approve a successor" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    inline for (.{ "a", "b" }) |name| {
        try remote.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "SOURCE" });
        try local.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "KEEP" });
    }
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const first = try engine.open(.{ .direction = .download, .sources = &.{ "a", "b" }, .remote_dir = "/remote", .local_dir = directory, .conflict_context = conflictTestContext(.download) });
    try chooseConflict(engine, first, .skip, "", true);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(@as(u32, 2), engine.jobs.items[0].skipped_files.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), engine.jobs.items[0].done.load(.acquire));
    var context = conflictTestContext(.download);
    context.intent_id += 1;
    context.job += 1;
    const next = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .conflict_context = context });
    var waiting = try awaitConflictSnapshot(engine, next);
    defer waiting.deinit();
    const old = waiting.value.pending.choice.key;
    try std.testing.expect(waiting.value.pending.choice.selection.choice == null);
    try engine.pause(next);
    try awaitWorker(&engine.owner_done);
    const resumed = try engine.resumeJob(next);
    var current = try awaitConflictSnapshot(engine, resumed);
    defer current.deinit();
    try std.testing.expectEqual(@as(u32, 2), current.value.pending.choice.key.attempt);
    try std.testing.expectError(error.StaleConflict, engine.resolveConflict(resumed, .{ .select = .{ .key = old, .selection = .{ .choice = .overwrite } } }));
    try std.testing.expectError(error.StaleConflict, engine.resolveConflict(next, .{ .select = .{ .key = old, .selection = .{ .choice = .skip } } }));
    engine.cancel(resumed);
    try awaitWorker(&engine.owner_done);
    try expectFileBytes(local.dir, "a", "KEEP");
    try expectFileBytes(local.dir, "b", "KEEP");
}

test "sftp conflict preflight late publish skip preserves actual byte count and cleans only its verified temp" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .block_checksum_close = true };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    var controller = try manager.Manager.init(std.testing.allocator, engine.engine(), 1, .{ .max_attempts = 1 });
    defer controller.deinit();
    const job = try controller.enqueue(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true, .conflict_context = conflictTestContext(.download) });
    controller.tick(0);
    try awaitWorker(&peer.close_blocked);
    controller.tick(1);
    try std.testing.expectEqual(@as(u64, bytes.len), controller.progress(job).?.done_bytes);
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "RACED-FINAL" });
    peer.close_release.store(true, .release);
    const native = engine.jobs.items[0].id;
    var waiting = try awaitConflictSnapshot(engine, native);
    defer waiting.deinit();
    const temp = try std.testing.allocator.dupe(u8, engine.jobs.items[0].owned_temp.?.path);
    defer std.testing.allocator.free(temp);
    try expectFileBytes(std.Io.Dir.cwd(), temp, &bytes);
    try chooseConflict(engine, native, .skip, "", false);
    try awaitWorker(&engine.owner_done);
    controller.tick(2);
    const progress = controller.progress(job).?;
    try std.testing.expectEqual(manager.State.succeeded, progress.state);
    try std.testing.expectEqual(@as(u32, 1), progress.skipped_files);
    try std.testing.expectEqual(@as(u64, 0), progress.skipped_bytes);
    try std.testing.expectEqual(@as(u64, bytes.len), progress.done_bytes);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, temp, .{}));
    try expectFileBytes(local.dir, "a", "RACED-FINAL");
}

test "sftp conflict native peer validates EXCL and approved handle truncate using real libssh2" {
    const raw_port = std.c.getenv("ZEROWORK_CONFLICT_PEER_PORT") orelse return error.SkipZigTest;
    const port = try std.fmt.parseInt(u16, std.mem.span(raw_port), 10);
    var library = try ssh_session.Library.init();
    defer library.deinit();
    var session = try ssh_session.Session.connect(&library, .{ .host = "127.0.0.1", .port = port, .user = "test", .auth = .{ .password = "test" }, .host_key_decision = .trust_once, .open_shell = false, .connect_timeout_ms = 3000 });
    defer session.close();
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const original = resumeBytes();
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &original });
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.attachSession(&session);
    const first = try engine.open(.{ .direction = .upload, .sources = &.{"a"}, .remote_dir = "/", .local_dir = directory, .md5_check = true });
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(first, engine.jobs.items[0].id);
    try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(engine.jobs.items[0].state.load(.acquire)));
    try std.testing.expectEqual(.passed, engine.jobs.items[0].verification.get().value.?.state);
    const replacement = "EXPLICIT-SECOND-APPROVAL-THEN-HANDLE-TRUNCATE";
    try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = replacement });
    const second = try engine.open(.{ .direction = .upload, .sources = &.{"a"}, .remote_dir = "/", .local_dir = directory, .md5_check = true, .conflict_context = conflictTestContext(.upload) });
    try chooseConflict(engine, second, .overwrite, "", false);
    var pending = try awaitConflictSnapshot(engine, second);
    defer pending.deinit();
    try std.testing.expect(pending.value.pending == .overwrite_confirmation);
    // A second real job on the same owner reads the unchanged destination
    // while approval waits. The caller never drives the borrowed Session.
    _ = try engine.open(.{ .direction = .download, .sources = &.{"/a"}, .remote_dir = "/", .local_dir = directory, .rename = "a-before" });
    try awaitWorker(&engine.jobs.items[2].worker_done);
    try expectFileBytes(local.dir, "a-before", &original);
    try confirmConflict(engine, second);
    try awaitWorker(&engine.owner_done);
    const approved = engine.jobs.items[1];
    try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(approved.state.load(.acquire)));
    try std.testing.expectEqual(.passed, approved.verification.get().value.?.state);
    _ = try engine.open(.{ .direction = .download, .sources = &.{"/a"}, .remote_dir = "/", .local_dir = directory, .rename = "a-after" });
    try awaitWorker(&engine.owner_done);
    try expectFileBytes(local.dir, "a-after", replacement);
    try std.testing.expect(session.channel == null);
    try std.testing.expect(engine.detachIfIdle());
    const deadline = monotonicNs() + 3 * std.time.ns_per_s;
    while (session.closeReceipt() != .released) {
        if (monotonicNs() >= deadline) return error.NativeCloseTimeout;
        workerTestPause();
    }
    std.debug.print("CONFLICT_NATIVE {{\"passed\":true,\"original_bytes\":{d},\"replacement_bytes\":{d},\"no_shell\":true,\"session_released\":true}}\n", .{ original.len, replacement.len });
}

fn retainedCheckpointSpec(old: JobSpec) JobSpec {
    var result = old;
    var context = old.conflict_context.?;
    context.attempt += 1;
    context.resource_owner = .{ .retained_transfer = @fromBackingInt(901) };
    var binding = old.transfer_binding.?;
    binding.binding_id += 100;
    binding.binding_generation += 1;
    binding.resource_owner = context.resource_owner;
    binding.origin_session = context.original_owner;
    switch (context.source_endpoint) {
        .sftp => |*endpoint| {
            endpoint.binding_id = binding.binding_id;
            endpoint.binding_generation = binding.binding_generation;
            endpoint.resource_owner = context.resource_owner;
            endpoint.origin_session = context.original_owner;
        },
        else => {},
    }
    switch (context.target_endpoint) {
        .sftp => |*endpoint| {
            endpoint.binding_id = binding.binding_id;
            endpoint.binding_generation = binding.binding_generation;
            endpoint.resource_owner = context.resource_owner;
            endpoint.origin_session = context.original_owner;
        },
        else => {},
    }
    result.transfer_binding = binding;
    result.conflict_context = context;
    return result;
}
fn checkpointSourceSpec(directory: []const u8, direction: manager.Direction) JobSpec {
    const context = conflictTestContext(direction);
    return .{ .session_id = @backingInt(context.original_owner.session_id), .transfer_binding = .{ .resource_owner = context.resource_owner, .origin_session = context.original_owner, .kind = .transfer, .binding_id = 8, .binding_generation = 5 }, .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true, .conflict_context = context };
}

test "sftp checkpoint normal and fault export freeze configured policy across destroyed owners" {
    for ([_]bool{ false, true }) |fault| {
        inline for (.{ manager.Direction.download, manager.Direction.upload }) |direction| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            const source = if (direction == .upload) local.dir else remote.dir;
            const target = if (direction == .upload) remote.dir else local.dir;
            try source.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var old_peer: ResumePeer = .{ .dir = remote.dir };
            const old_engine = try SftpEngine.init(std.testing.allocator);
            var old_alive = true;
            defer if (old_alive) {
                old_peer.unblock();
                old_engine.deinit();
            };
            var old_session: ssh_session.Session = .{};
            old_engine.attachSession(&old_session);
            old_peer.bind(old_engine);
            var original_spec = checkpointSourceSpec(directory, direction);
            original_spec.chunk_kb = 48;
            original_spec.notify_complete = false;
            original_spec.window_chunks = 7;
            original_spec.pacing_kbps = 4096;
            const first = try old_engine.open(original_spec);
            try awaitWorker(&old_peer.blocked);
            try std.testing.expectError(error.CheckpointNotReleased, old_engine.exportPaused(first));
            const paused = try pauseResumePeer(old_engine, &old_peer, first);
            try std.testing.expect(paused.checkpoint.?.file.offset > 0);
            if (fault) {
                old_engine.transportFailed();
                try std.testing.expect(!old_engine.canResume(first));
            }
            var checkpoint = try old_engine.exportPaused(first);
            try std.testing.expectEqual(@as(u16, 48), checkpoint.describe().?.spec.chunk_kb);
            try std.testing.expect(!checkpoint.describe().?.spec.notify_complete);
            try std.testing.expectEqual(@as(u8, 7), checkpoint.describe().?.spec.window_chunks);
            try std.testing.expectEqual(@as(u32, 4096), checkpoint.describe().?.spec.pacing_kbps);
            defer {
                _ = checkpoint.cancel(std.testing.io);
                checkpoint.deinit() catch {};
            }
            try std.testing.expectError(error.Busy, checkpoint.deinit());
            try std.testing.expectError(error.CheckpointAlreadyExported, old_engine.exportPaused(first));
            try std.testing.expect(paused.checkpoint == null and paused.owned_temp == null and paused.handed_off);
            try std.testing.expect(checkpoint._payload.?.continuation.file.local == null and checkpoint._payload.?.continuation.file.remote == null);
            try std.testing.expect(!@hasField(CheckpointPayload, "session") and !@hasField(CheckpointPayload, "remote_files") and !@hasField(CheckpointPayload, "exec_service"));
            const new_spec = retainedCheckpointSpec(checkpoint.describe().?.spec);
            const old_probes = old_peer.fingerprint_opens.load(.acquire);
            try std.testing.expect(old_engine.detachIfIdle());
            old_engine.deinit();
            old_alive = false;
            old_session.state = .closed;
            var new_peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
            const new_engine = try SftpEngine.init(std.testing.allocator);
            defer {
                new_peer.unblock();
                new_engine.deinit();
            }
            var new_session: ssh_session.Session = .{};
            new_engine.attachSession(&new_session);
            new_peer.bind(new_engine);
            var different_policy = new_spec;
            different_policy.chunk_kb = 96;
            try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, different_policy));
            different_policy = new_spec;
            different_policy.window_chunks = 3;
            try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, different_policy));
            different_policy = new_spec;
            different_policy.pacing_kbps = 8192;
            try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, different_policy));
            different_policy = new_spec;
            different_policy.notify_complete = true;
            try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, different_policy));
            try std.testing.expect(checkpoint.describe() != null);
            const accepted = try new_engine.importPaused(&checkpoint, new_spec);
            try std.testing.expect(checkpoint.describe() == null);
            try checkpoint.deinit();
            try std.testing.expectError(error.CheckpointConsumed, new_engine.importPaused(&checkpoint, new_spec));
            try awaitWorker(&new_engine.owner_done);
            try std.testing.expectEqual(accepted, new_engine.jobs.items[0].id);
            try std.testing.expectEqual(@as(u16, 48), new_engine.jobs.items[0].spec.chunk_kb);
            try std.testing.expect(!new_engine.jobs.items[0].spec.notify_complete);
            try std.testing.expectEqual(@as(u8, 7), new_engine.jobs.items[0].spec.window_chunks);
            try std.testing.expectEqual(@as(u32, 4096), new_engine.jobs.items[0].spec.pacing_kbps);
            try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(new_engine.jobs.items[0].state.load(.acquire)));
            try std.testing.expectEqual(.passed, new_engine.jobs.items[0].verification.get().value.?.state);
            try std.testing.expectEqual(old_probes, old_peer.fingerprint_opens.load(.acquire));
            if (direction == .download) try std.testing.expect(new_peer.fingerprint_opens.load(.acquire) > 0) else {
                try std.testing.expect(new_peer.preserve_opens.load(.acquire) > 0);
                try std.testing.expect(new_peer.writes.load(.acquire) > 0);
            }
            try expectFileBytes(target, "a", &bytes);
        }
    }
}

test "sftp checkpoint import rejects changed identity or allocation failure without consuming owned temp" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var old_peer: ResumePeer = .{ .dir = remote.dir };
    const old_engine = try SftpEngine.init(std.testing.allocator);
    defer {
        old_peer.unblock();
        old_engine.deinit();
    }
    var old_session: ssh_session.Session = .{};
    old_engine.attachSession(&old_session);
    old_peer.bind(old_engine);
    const first = try old_engine.open(checkpointSourceSpec(directory, .download));
    _ = try pauseResumePeer(old_engine, &old_peer, first);
    var checkpoint = try old_engine.exportPaused(first);
    defer {
        _ = checkpoint.cancel(std.testing.io);
        checkpoint.deinit() catch {};
    }
    const spec = retainedCheckpointSpec(checkpoint.describe().?.spec);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const new_engine = try SftpEngine.init(failing.allocator());
    var new_peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
    defer {
        failing.fail_index = std.math.maxInt(usize);
        new_peer.unblock();
        new_engine.deinit();
    }
    var new_session: ssh_session.Session = .{};
    new_engine.attachSession(&new_session);
    new_peer.bind(new_engine);
    var wrong = spec;
    wrong.chunk_kb = 48;
    try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, wrong));
    try std.testing.expectEqual(spec.chunk_kb, checkpoint.describe().?.spec.chunk_kb);
    wrong = spec;
    wrong.window_chunks = 7;
    try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, wrong));
    try std.testing.expectEqual(spec.window_chunks, checkpoint.describe().?.spec.window_chunks);
    wrong = spec;
    wrong.remote_dir = "/different";
    try std.testing.expectError(error.CheckpointSpecMismatch, new_engine.importPaused(&checkpoint, wrong));
    wrong = spec;
    wrong.conflict_context.?.attempt += 1;
    try std.testing.expectError(error.CheckpointIdentityMismatch, new_engine.importPaused(&checkpoint, wrong));
    wrong = spec;
    wrong.transfer_binding.?.origin_session.?.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, new_engine.importPaused(&checkpoint, wrong));
    const path = try std.testing.allocator.dupe(u8, checkpoint.describe().?.temp_path.?);
    defer std.testing.allocator.free(path);
    const before = (try std.Io.Dir.cwd().statFile(std.testing.io, path, .{})).size;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, new_engine.importPaused(&checkpoint, spec));
    try std.testing.expect(checkpoint.describe() != null);
    try std.testing.expectError(error.Busy, checkpoint.deinit());
    try std.testing.expectEqual(@as(usize, 0), new_engine.jobs.items.len);
    try std.testing.expectEqual(before, (try std.Io.Dir.cwd().statFile(std.testing.io, path, .{})).size);
    failing.fail_index = std.math.maxInt(usize);
    _ = try new_engine.importPaused(&checkpoint, spec);
    try awaitWorker(&new_engine.owner_done);
    try expectFileBytes(local.dir, "a", &bytes);
}

test "sftp checkpoint explicit detached cancel keeps replaced inode unknown until exact artifact returns" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir };
    const engine = try SftpEngine.init(std.testing.allocator);
    var alive = true;
    defer if (alive) {
        peer.unblock();
        engine.deinit();
    };
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const id = try engine.open(checkpointSourceSpec(directory, .download));
    _ = try pauseResumePeer(engine, &peer, id);
    var checkpoint = try engine.exportPaused(id);
    defer {
        _ = checkpoint.cancel(std.testing.io);
        checkpoint.deinit() catch {};
    }
    const path = try std.testing.allocator.dupe(u8, checkpoint.describe().?.temp_path.?);
    defer std.testing.allocator.free(path);
    const saved = try std.fmt.allocPrint(std.testing.allocator, "{s}.held", .{path});
    defer std.testing.allocator.free(saved);
    try std.testing.expect(engine.detachIfIdle());
    engine.deinit();
    alive = false;
    session.state = .closed;
    try std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), saved, std.testing.io);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "STRANGER" });
    try std.testing.expectEqual(manager.JobCleanup.unknown, checkpoint.cancel(std.testing.io));
    try std.testing.expectError(error.Busy, checkpoint.deinit());
    try expectFileBytes(std.Io.Dir.cwd(), path, "STRANGER");
    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    try std.Io.Dir.cwd().rename(saved, std.Io.Dir.cwd(), path, std.testing.io);
    try std.testing.expectEqual(manager.JobCleanup.released, checkpoint.cancel(std.testing.io));
    try checkpoint.deinit();
    try std.testing.expect(checkpoint.describe() == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{}));
}

test "sftp checkpoint import invalidates prior overwrite grant and revalidates source before writing" {
    for ([_]bool{ false, true }) |change_source| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const bytes = resumeBytes();
        try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
        try local.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "ORIGINAL-FINAL" });
        var peer: ResumePeer = .{ .dir = remote.dir };
        const old_engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            old_engine.deinit();
        }
        var old_session: ssh_session.Session = .{};
        old_engine.attachSession(&old_session);
        peer.bind(old_engine);
        const id = try old_engine.open(checkpointSourceSpec(directory, .download));
        try chooseConflict(old_engine, id, .overwrite, "", false);
        try confirmConflict(old_engine, id);
        _ = try pauseResumePeer(old_engine, &peer, id);
        var checkpoint = try old_engine.exportPaused(id);
        defer {
            _ = checkpoint.cancel(std.testing.io);
            checkpoint.deinit() catch {};
        }
        const info = checkpoint.describe().?;
        try std.testing.expect(checkpoint._payload.?.continuation.file.approved_target == null and checkpoint._payload.?.continuation.file.execution == null);
        if (change_source) try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "CHANGED" });
        var next_peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
        const next_engine = try SftpEngine.init(std.testing.allocator);
        defer {
            next_peer.unblock();
            next_engine.deinit();
        }
        var next_session: ssh_session.Session = .{};
        next_engine.attachSession(&next_session);
        next_peer.bind(next_engine);
        const child = try next_engine.importPaused(&checkpoint, retainedCheckpointSpec(info.spec));
        if (change_source) {
            try awaitWorker(&next_engine.owner_done);
            try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(next_engine.jobs.items[0].state.load(.acquire)));
            try std.testing.expectEqual(manager.Failure.conflict, next_engine.jobs.items[0].failure.get().?);
            try std.testing.expectEqual(@as(usize, 0), next_peer.transfer_opens[0].load(.acquire));
            next_engine.cancel(child);
            try awaitWorker(&next_engine.owner_done);
        } else {
            var waiting = try awaitConflictSnapshot(next_engine, child);
            defer waiting.deinit();
            try std.testing.expect(waiting.value.pending.choice.selection.choice == null);
            try std.testing.expectEqual(@as(u32, 2), waiting.value.pending.choice.key.attempt);
            try expectFileBytes(local.dir, "a", "ORIGINAL-FINAL");
            try chooseConflict(next_engine, child, .overwrite, "", false);
            try confirmConflict(next_engine, child);
            try awaitWorker(&next_engine.owner_done);
            try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(next_engine.jobs.items[0].state.load(.acquire)));
            try std.testing.expectEqual(.passed, next_engine.jobs.items[0].verification.get().value.?.state);
            try expectFileBytes(local.dir, "a", &bytes);
        }
    }
}

test "sftp configured policy snapshots survive short IO pause and resume" {
    for ([_]struct { chunk_kb: u16, window_chunks: u8 }{ .{ .chunk_kb = 64, .window_chunks = 16 }, .{ .chunk_kb = 48, .window_chunks = 7 }, .{ .chunk_kb = 1, .window_chunks = 255 }, .{ .chunk_kb = 96, .window_chunks = 2 } }) |policy| {
        for ([_]manager.Direction{ .download, .upload }) |direction| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const bytes = resumeBytes();
            try (if (direction == .download) remote.dir else local.dir).writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
            var peer: ResumePeer = .{ .dir = remote.dir };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            const first = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .chunk_kb = policy.chunk_kb, .window_chunks = policy.window_chunks, .md5_check = true });
            const paused = try pauseResumePeer(engine, &peer, first);
            try std.testing.expectEqual(@as(u32, policy.chunk_kb) * 1024, paused.checkpoint.?.file.window.?.chunk_bytes);
            try std.testing.expectEqual(@as(u16, policy.window_chunks), paused.checkpoint.?.file.window.?.capacity);
            try std.testing.expectEqual(policy.chunk_kb, paused.spec.view().chunk_kb);
            try std.testing.expectEqual(policy.window_chunks, paused.spec.view().window_chunks);
            const second = try engine.resumeJob(first);
            try awaitWorker(&engine.owner_done);
            const resumed = engine.jobs.items[1];
            try std.testing.expectEqual(second, resumed.id);
            try std.testing.expectEqual(policy.chunk_kb, resumed.spec.view().chunk_kb);
            try std.testing.expectEqual(policy.window_chunks, resumed.spec.view().window_chunks);
            try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(resumed.state.load(.acquire)));
            try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(resumed));
            try std.testing.expectEqual(.passed, resumed.verification.get().value.?.state);
            try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", &bytes);
            try std.testing.expect(!peer.oversize.load(.acquire));
            try std.testing.expect(!peer.caller_io.load(.acquire));
        }
    }
}

test "sftp configured logical final block controls MD5 repair while IO turns stay bounded" {
    for ([_]manager.Direction{ .download, .upload }) |direction| {
        var local = std.testing.tmpDir(.{});
        defer local.cleanup();
        var remote = std.testing.tmpDir(.{});
        defer remote.cleanup();
        const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(directory);
        const bytes = resumeBytes();
        try (if (direction == .download) remote.dir else local.dir).writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
        var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .corrupt_offsets = .{ resume_test_size - 8, null } };
        const engine = try SftpEngine.init(std.testing.allocator);
        defer {
            peer.unblock();
            engine.deinit();
        }
        var session: ssh_session.Session = .{};
        engine.attachSession(&session);
        peer.bind(engine);
        _ = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .chunk_kb = 48, .window_chunks = 7, .md5_check = true });
        try awaitWorker(&engine.owner_done);
        const done = engine.jobs.items[0];
        try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(done.state.load(.acquire)));
        const verified = done.verification.get().value.?;
        try std.testing.expectEqual(.passed, verified.state);
        try std.testing.expectEqual(@as(u8, 1), verified.repair_count);
        try std.testing.expectEqual(@as(u64, 48 * 1024), verified.repair_start.?);
        try std.testing.expectEqual(@as(u64, resume_test_size), verified.repair_end.?);
        try std.testing.expectEqual(@as(u64, 2 * resume_test_size), peer.checksum_bytes.load(.acquire));
        if (direction == .upload) try std.testing.expectEqual(@as(u64, resume_test_size - 48 * 1024), peer.preserve_bytes.load(.acquire));
        try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", &bytes);
        try std.testing.expect(!peer.oversize.load(.acquire));
        try std.testing.expect(!peer.caller_io.load(.acquire));
    }
}

test "sftp configured policy validation rejects before Session capture or IO" {
    const engine = try SftpEngine.init(std.testing.allocator);
    defer engine.deinit();
    var request: JobSpec = .{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = "/must-not-be-opened", .chunk_kb = 2049, .window_chunks = 1 };
    try std.testing.expectError(error.TransferWindowBudgetExceeded, engine.open(request));
    request.chunk_kb = 0;
    try std.testing.expectError(error.InvalidTransferChunk, engine.open(request));
    request.chunk_kb = 64;
    request.window_chunks = 0;
    try std.testing.expectError(error.InvalidTransferWindow, engine.open(request));
    try std.testing.expectEqual(@as(u64, 1), engine.next_id);
    try std.testing.expectEqual(@as(usize, 0), engine.jobs.items.len);
    try std.testing.expect(engine.owner_thread == null);
}

test "sftp pacing zero and positive rates govern actual bidirectional bytes including verification" {
    for ([_]u32{ 0, 64 }) |rate| {
        for ([_]manager.Direction{ .upload, .download }) |direction| {
            var local = std.testing.tmpDir(.{});
            defer local.cleanup();
            var remote = std.testing.tmpDir(.{});
            defer remote.cleanup();
            const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
            defer std.testing.allocator.free(directory);
            const all = resumeBytes();
            const bytes = all[0..8193];
            try (if (direction == .download) remote.dir else local.dir).writeFile(std.testing.io, .{ .sub_path = "a", .data = bytes });
            var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
            const engine = try SftpEngine.init(std.testing.allocator);
            defer {
                peer.unblock();
                engine.deinit();
            }
            var session: ssh_session.Session = .{};
            engine.attachSession(&session);
            peer.bind(engine);
            const started = monotonicNs();
            _ = try engine.open(.{ .direction = direction, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .md5_check = true, .pacing_kbps = rate });
            try awaitWorker(&engine.owner_done);
            const elapsed = monotonicNs() - started;
            const job = engine.jobs.items[0];
            try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(job.state.load(.acquire)));
            try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
            try std.testing.expectEqual(.passed, job.verification.get().value.?.state);
            try std.testing.expectEqual(rate, job.spec.view().pacing_kbps);
            try expectFileBytes(if (direction == .download) local.dir else remote.dir, "a", bytes);
            const expected_wire = bytes.len * @as(u64, if (direction == .download) 3 else 2);
            try std.testing.expectEqual(expected_wire, peer.wire_bytes.load(.acquire));
            if (rate != 0) {
                const minimum_ns = @divFloor(@as(i128, expected_wire) * std.time.ns_per_s, @as(i128, rate) * 1024);
                try std.testing.expect(elapsed + std.time.ns_per_ms >= minimum_ns);
            }
            try std.testing.expect(!peer.oversize.load(.acquire));
            try std.testing.expect(!peer.caller_io.load(.acquire));
        }
    }
}

test "sftp pacing one Session shares its actual budget fairly between jobs" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const all = resumeBytes();
    const bytes = all[0..8193];
    for ([_][]const u8{ "a", "b" }) |name| try remote.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null, .stat_release = .init(false) };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const started = monotonicNs();
    for ([_][]const u8{ "a", "b" }) |name| _ = try engine.open(.{ .direction = .download, .sources = &.{name}, .remote_dir = "/remote", .local_dir = directory, .pacing_kbps = 32 });
    peer.stat_release.store(true, .release);
    const deadline = monotonicNs() + 5 * std.time.ns_per_s;
    while (peer.transfer_bytes[0].load(.acquire) == 0 or peer.transfer_bytes[1].load(.acquire) == 0) {
        try std.testing.expect(!engine.jobs.items[0].terminal.load(.acquire));
        try std.testing.expect(!engine.jobs.items[1].terminal.load(.acquire));
        if (monotonicNs() >= deadline) return error.TestFairPacingTimeout;
        SftpEngine.pauseOwner();
    }
    try awaitWorker(&engine.owner_done);
    const elapsed = monotonicNs() - started;
    try std.testing.expectEqual(@as(u64, 4 * bytes.len), peer.wire_bytes.load(.acquire));
    const minimum_ns = @divFloor(@as(i128, 4 * bytes.len) * std.time.ns_per_s, 32 * 1024);
    try std.testing.expect(elapsed + std.time.ns_per_ms >= minimum_ns);
    for (engine.jobs.items) |job| try std.testing.expectEqual(manager.EngineState.succeeded, engineStateOf(job.state.load(.acquire)));
    try expectFileBytes(local.dir, "a", bytes);
    try expectFileBytes(local.dir, "b", bytes);
    try std.testing.expect(!peer.caller_io.load(.acquire));
}

test "sftp pacing pending credit yields promptly to pause and cancellation" {
    var local = std.testing.tmpDir(.{});
    defer local.cleanup();
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const directory = try local.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const bytes = resumeBytes();
    try remote.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = &bytes });
    var peer: ResumePeer = .{ .dir = remote.dir, .block_at = null };
    const engine = try SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: ssh_session.Session = .{};
    engine.attachSession(&session);
    peer.bind(engine);
    const id = try engine.open(.{ .direction = .download, .sources = &.{"a"}, .remote_dir = "/remote", .local_dir = directory, .pacing_kbps = 1 });
    const deadline = monotonicNs() + std.time.ns_per_s;
    while (peer.wire_bytes.load(.acquire) < 8) {
        if (monotonicNs() >= deadline) return error.TestPacingDidNotStart;
        SftpEngine.pauseOwner();
    }
    const pause_started = monotonicNs();
    try engine.pause(id);
    try awaitWorker(&engine.owner_done);
    try std.testing.expect(monotonicNs() - pause_started < std.time.ns_per_s);
    const job = engine.jobs.items[0];
    try std.testing.expectEqual(manager.EngineState.paused, engineStateOf(job.state.load(.acquire)));
    try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
    const bytes_at_pause = peer.wire_bytes.load(.acquire);
    try std.testing.expect(bytes_at_pause < bytes.len);
    engine.cancel(id);
    try awaitWorker(&engine.owner_done);
    try std.testing.expectEqual(manager.EngineState.cancelled, engineStateOf(job.state.load(.acquire)));
    try std.testing.expectEqual(manager.JobCleanup.released, SftpEngine.cleanupOf(job));
    try std.testing.expectEqual(bytes_at_pause, peer.wire_bytes.load(.acquire));
}
