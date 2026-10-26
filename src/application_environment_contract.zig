//! Standalone contract probe compiled with the same defaults as a formal App.
//! No filesystem writes or native Keychain access.
const std = @import("std");
const Paths = @import("config/paths.zig").Paths;
const providers = @import("ai/provider_config.zig");
const Config = @import("config/config.zig");

pub fn main() !void {
    const a = std.heap.c_allocator;
    if (@import("platform/runtime_mode.zig").automation) return error.UnexpectedAutomation;
    const framework = @import("formal_environment");
    inline for (.{ "ZENIT_NO_BLUR", "ZENIT_DISABLE_SCROLL_CLIP", "ZENIT_A11Y_PREFS", "ZENIT_RENDER_SCALE", "ZENIT_E2E_BACKGROUND", "ZENIT_VISUAL_QUALITY", "ZENIT_INPUT_DEBUG" }) |name| {
        if (framework.has(name) or framework.getRaw(name) != null or framework.getBorrowed(name) != null) return error.EnvironmentChangedFramework;
        if (framework.getOwned(a, name)) |value| {
            a.free(value);
            return error.EnvironmentChangedFramework;
        } else |err| if (err != error.EnvironmentVariableNotFound) return err;
    }
    const home = try @import("platform/account.zig").home(a);
    defer a.free(home);
    var actual = try Paths.forApplication(a);
    defer actual.deinit();
    var expected = try Paths.fromHome(a, home);
    defer expected.deinit();
    if (actual.is_override or !std.mem.eql(u8, actual.directory, expected.directory) or
        !std.mem.eql(u8, actual.cache_directory, expected.cache_directory) or
        !std.mem.eql(u8, actual.diagnostic_directory, expected.diagnostic_directory) or
        !std.mem.eql(u8, actual.known_hosts, expected.known_hosts)) return error.EnvironmentChangedPaths;

    var models = [_]Config.AiModel{.{ .id = "saved-model", .context_window = 32768, .default = true }};
    var saved = [_]Config.AiProvider{.{ .name = "saved-provider", .kind = .openai_compat, .enabled = true, .endpoint = "http://127.0.0.1:1/v1/chat/completions", .api_key = "saved-fixture-key", .model_count = 1, .models = &models }};
    const ai: Config.Ai = .{ .default_provider = "saved-provider", .provider_count = 1, .providers = &saved };
    const selected = try providers.fromSettings(ai);
    if (!std.mem.eql(u8, selected.model, "saved-model") or
        !std.mem.eql(u8, selected.endpoint, saved[0].endpoint) or
        !std.mem.eql(u8, selected.auth.value().?, "saved-fixture-key") or
        selected.context_window != 32768) return error.EnvironmentChangedProvider;
    saved[0].api_key = "";
    // The explicit loopback gateway policy permits no-auth. This must not
    // acquire an implicit credential from the process environment.
    if ((try providers.fromSettings(ai)).auth != .none) return error.UnexpectedImplicitCredential;
    saved[0].endpoint = "https://example.test/v1/chat/completions";
    if (providers.fromSettings(ai)) |_| return error.UnexpectedImplicitCredential else |err| {
        if (err != error.MissingApiKey) return err;
    }
    std.debug.print("PASS: formal defaults use the system account and explicit App settings; missing credentials never fall back; framework overrides are disabled\n", .{});
}
