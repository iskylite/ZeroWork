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
    repository: struct { revision: []const u8, dirty: bool },
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
    artifacts: struct { directory: []const u8, log: []const u8 },
};

const required_gates = [_][]const u8{
    "release-truth",
    "renderer-boundary",
    "capability-matrix",
    "test-headless",
    "package-consumer",
    "allocation-campaign",
    "performance-regression",
    "test-metal",
    "storybook-e2e",
    "soak-4h",
    "macos-current",
    "macos-previous",
    "display-transition",
    "menu-acceptance",
    "voiceover-acceptance",
    "finder-drag",
    "distribution-clean-install",
};

fn reject(gate: []const u8, reason: []const u8) noreturn {
    std.debug.print("release candidate invalid [{s}]: {s}\n", .{ gate, reason });
    std.process.exit(65);
}

fn validRevision(revision: []const u8) bool {
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
    if (args.len != 3) {
        std.debug.print("usage: release-candidate-validator EVIDENCE_ROOT REVISION\n", .{});
        std.process.exit(64);
    }
    const evidence_root = args[1];
    const expected_revision = args[2];
    if (!validRevision(expected_revision)) reject("matrix", "expected revision is not a full hash");

    var current_macos: ?[]const u8 = null;
    var previous_macos: ?[]const u8 = null;
    for (required_gates) |gate| {
        const manifest_path = try std.fs.path.join(allocator, &.{ evidence_root, gate, "manifest.json" });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024)) catch
            reject(gate, "manifest is missing or unreadable");
        const parsed = std.json.parseFromSlice(Manifest, allocator, bytes, .{
            .ignore_unknown_fields = false,
        }) catch reject(gate, "manifest does not match evidence schema");
        const manifest = parsed.value;

        if (manifest.schema_version != 1) reject(gate, "unsupported schema version");
        if (!std.mem.eql(u8, manifest.gate, gate)) reject(gate, "manifest gate name does not match directory");
        if (!std.mem.eql(u8, manifest.status, "PASS") or manifest.exit_code != 0 or
            !std.mem.eql(u8, manifest.failure_kind, "none"))
            reject(gate, "required candidate gate is not a valid PASS");
        if (!std.mem.eql(u8, manifest.repository.revision, expected_revision))
            reject(gate, "evidence belongs to another revision");
        if (manifest.repository.dirty) reject(gate, "dirty-worktree evidence cannot qualify a candidate");
        if (manifest.command.len == 0 or manifest.timestamp_utc.len < 20)
            reject(gate, "command or timestamp is missing");
        if (manifest.environment.architecture.len == 0 or manifest.environment.zig.len == 0)
            reject(gate, "architecture or Zig version is missing");
        std.Io.Dir.cwd().access(io, manifest.artifacts.directory, .{}) catch
            reject(gate, "artifact directory does not exist");
        std.Io.Dir.cwd().access(io, manifest.artifacts.log, .{}) catch
            reject(gate, "gate log does not exist");

        if (std.mem.eql(u8, gate, "macos-current")) current_macos = manifest.environment.macos_version;
        if (std.mem.eql(u8, gate, "macos-previous")) previous_macos = manifest.environment.macos_version;
    }

    const current = current_macos orelse reject("macos-current", "macOS version is missing");
    const previous = previous_macos orelse reject("macos-previous", "macOS version is missing");
    if (current.len == 0 or previous.len == 0 or std.mem.eql(u8, current, previous))
        reject("matrix", "current and previous macOS evidence must come from distinct versions");

    std.debug.print(
        "release candidate evidence: PASS ({d} gates, revision {s}, macOS {s} + {s})\n",
        .{ required_gates.len, expected_revision, current, previous },
    );
}
