//! Context comes from the registered provider contribution. Terminal text is an
//! optional builtin contribution and never gates an assistant's existence.
const std = @import("std");
const App = @import("application_host.zig").ApplicationHost;
const identity = @import("../host/identity.zig");
pub fn assemble(allocator: std.mem.Allocator, app: *App, owner: identity.SessionHandle, context_window: u32, redact: bool) !@import("../ai/assembler.zig").Assembled {
    const manifest = app.sessions.manifestFor(owner) orelse return error.StaleSession;
    if (!manifest.integration.ai) return error.AssistantUnavailable;
    if (manifest.ai_adapter_factory) |factory| {
        const bridge = try factory(allocator);
        defer bridge.vtable.destroy(bridge.context, allocator);
        return bridge.vtable.assemble_context(allocator, app, owner, context_window, redact);
    }
    const contribution = manifest.ai_context orelse return error.AssistantContextUnavailable;
    const summary = if (contribution.summarize) |summarize| try summarize(contribution.context, owner, allocator) else try allocator.dupe(u8, "");
    defer allocator.free(summary);
    const text = try std.fmt.allocPrint(allocator, "provider={s} session_id={d} generation={d}\n{s}", .{ contribution.identity, @backingInt(owner.session_id), owner.generation, summary });
    if (text.len > @import("../ai/card.zig").contextBudget(context_window) * 4) {
        allocator.free(text);
        return error.GroupContextBudget;
    }
    return .{ .text = text, .tokens = @import("../ai/card.zig").estimateTokens(text.len), .truncated = false };
}
