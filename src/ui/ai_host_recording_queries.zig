//! Trusted controller grant construction. These functions are called only
//! after the same terminal-content permission used for live read_terminal.
const std = @import("std");
const backend = @import("../ai/host_recording_queries.zig");
const host = @import("../ai/host_tools.zig");
const identity = @import("../host/identity.zig");
const archive = @import("../vt/session_archive.zig");
pub const Backend = backend.Backend;
pub const Grant = backend.Grant;

/// Preserve a captured authorized source across close. The caller owns the
/// path storage and must remove this grant when Task/content permission ends.
pub fn capturedSource(context: host.Context, owner: identity.SessionHandle, recording_id: [32]u8, recording_generation: u64, manifest_path: []const u8) !Grant {
    try context.validate();
    try archive.manifest.validatePath(manifest_path);
    _ = try identity.RecordingId.parse(&recording_id);
    if (owner.generation == 0 or @backingInt(owner.session_id) == 0 or recording_generation == 0) return error.InvalidRecordingGrant;
    return .{ .context = context, .owner = owner, .recording_id = recording_id, .recording_generation = recording_generation, .manifest_path = manifest_path, .origin = .captured_source };
}

/// A user-selected history document supplies the identity and commit. Merely
/// listing archive metadata or parsing a model reference never calls this API.
pub fn selectedHistory(context: host.Context, descriptor: archive.Descriptor, recording_generation: u64) !Grant {
    try context.validate();
    const document = descriptor.document orelse return error.RecordingBaselineUnavailable;
    if (document.state != .closed) return error.RecordingNotClosed;
    const generation = for (document.recording.generations) |item| {
        if (item.recording_generation == recording_generation) break item;
    } else return error.StaleGeneration;
    const id = document.recording_id;
    if (id.len != 32) return error.InvalidRecordingGrant;
    var recording_id: [32]u8 = undefined;
    @memcpy(&recording_id, id);
    var grant = try capturedSource(context, .{ .session_id = @fromBackingInt(generation.session_id), .generation = generation.session_generation }, recording_id, recording_generation, descriptor.manifest_path orelse return error.RecordingUnavailable);
    grant.origin = .explicit_history_selection;
    grant.manifest_revision = document.manifest_revision;
    return grant;
}
