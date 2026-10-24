const std = @import("std");

const Manifest = struct {
    schema_version: u32,
    gate: []const u8,
    status: []const u8,
    exit_code: u32,
    duration_ms: u64,
    failure_kind: []const u8,
    command: []const u8,
    timestamp_utc: []const u8,
    repository: struct {
        revision: []const u8,
        dirty: bool,
    },
    environment: struct {
        macos_version: []const u8,
        macos_build: []const u8,
        architecture: []const u8,
        cpu: []const u8,
        gpu: []const u8,
        display_scale: []const u8,
        zig: []const u8,
        bun: []const u8,
    },
    test_seed: []const u8,
    artifacts: struct {
        directory: []const u8,
        log: []const u8,
    },
};

fn fail(message: []const u8) noreturn {
    std.debug.print("evidence manifest invalid: {s}\n", .{message});
    std.process.exit(65);
}

fn validStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or
        std.mem.eql(u8, status, "FAIL") or
        std.mem.eql(u8, status, "BLOCKED") or
        std.mem.eql(u8, status, "NOT RUN") or
        std.mem.eql(u8, status, "N/A");
}

fn isHexRevision(revision: []const u8) bool {
    if (revision.len != 40 and revision.len != 64) return false;
    for (revision) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("usage: evidence-manifest-validator MANIFEST [--require-artifacts] [--expected-revision HASH] [--require-clean]\n", .{});
        std.process.exit(64);
    }
    var require_artifacts = false;
    var require_clean = false;
    var expected_revision: ?[]const u8 = null;
    var arg_index: usize = 2;
    while (arg_index < args.len) : (arg_index += 1) {
        if (std.mem.eql(u8, args[arg_index], "--require-artifacts")) {
            require_artifacts = true;
        } else if (std.mem.eql(u8, args[arg_index], "--require-clean")) {
            require_clean = true;
        } else if (std.mem.eql(u8, args[arg_index], "--expected-revision")) {
            arg_index += 1;
            if (arg_index >= args.len or !isHexRevision(args[arg_index])) fail("--expected-revision requires a full hash");
            expected_revision = args[arg_index];
        } else {
            fail("unknown option");
        }
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(1024 * 1024)) catch fail("cannot read manifest");
    const parsed = std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .ignore_unknown_fields = false,
    }) catch fail("JSON does not match schema");
    const manifest = parsed.value;

    if (manifest.schema_version != 1) fail("unsupported schema_version");
    if (manifest.gate.len == 0 or manifest.command.len == 0) fail("gate and command are required");
    if (!validStatus(manifest.status)) fail("unknown status");
    if (!isHexRevision(manifest.repository.revision)) fail("repository revision is not a full hash");
    if (expected_revision) |revision| {
        if (!std.mem.eql(u8, manifest.repository.revision, revision))
            fail("evidence belongs to another revision");
    }
    if (require_clean and manifest.repository.dirty) fail("dirty-worktree evidence is not allowed");
    if (manifest.timestamp_utc.len < 20) fail("timestamp_utc is missing or truncated");
    if (manifest.environment.architecture.len == 0 or manifest.environment.zig.len == 0)
        fail("architecture and Zig version are required");
    if (manifest.artifacts.directory.len == 0 or manifest.artifacts.log.len == 0)
        fail("artifact paths are required");

    if (std.mem.eql(u8, manifest.status, "PASS")) {
        if (manifest.exit_code != 0) fail("PASS requires exit_code 0");
        if (!std.mem.eql(u8, manifest.failure_kind, "none")) fail("PASS requires failure_kind none");
    } else if (std.mem.eql(u8, manifest.status, "FAIL") or std.mem.eql(u8, manifest.status, "BLOCKED")) {
        if (manifest.exit_code == 0) fail("FAIL/BLOCKED requires a non-zero exit_code");
        if (manifest.failure_kind.len == 0 or std.mem.eql(u8, manifest.failure_kind, "none"))
            fail("FAIL/BLOCKED requires a classified failure_kind");
    }

    if (require_artifacts) {
        std.Io.Dir.cwd().access(io, manifest.artifacts.directory, .{}) catch fail("artifact directory does not exist");
        std.Io.Dir.cwd().access(io, manifest.artifacts.log, .{}) catch fail("declared gate log does not exist");
    }
    std.debug.print("evidence manifest: PASS ({s}, {s})\n", .{ manifest.gate, manifest.status });
}
