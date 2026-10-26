const std = @import("std");
pub const keybindings = @import("keybindings.zig");
pub const hosts = @import("hosts.zig");
pub const store = @import("store.zig");
pub const material = @import("background_asset.zig");

pub const Config = struct {
    /// Persisted monotonic identity of the committed global configuration.
    config_revision: u64 = 1,
    ui: Ui = .{},
    completion: Completion = .{},
    transfer: Transfer = .{},
    ssh: Ssh = .{},
    ai: Ai = .{},
    log: Log = .{},
    notify: Notify = .{},
    keys: keybindings.Map = .{},
    plugin_preferences: []const PluginPreference = &.{},

    pub fn parse(text: []const u8) ParseError!Config {
        return parseWithAllocator(null, text);
    }

    pub fn parseWithAllocator(allocator: ?std.mem.Allocator, text: []const u8) ParseError!Config {
        var result: Config = .{};
        var section: Section = .none;
        var provider_index: ?usize = null;
        var model_index: ?usize = null;
        var preference_index: ?usize = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = trim(stripComment(raw));
            if (line.len == 0) continue;
            if (eq(line, "[[plugin_preferences]]")) {
                const a = allocator orelse return error.RequiresAllocator;
                if (result.plugin_preferences.len == 1024) return error.OutOfRange;
                const next = a.alloc(PluginPreference, result.plugin_preferences.len + 1) catch return error.OutOfMemory;
                @memcpy(next[0..result.plugin_preferences.len], result.plugin_preferences);
                preference_index = result.plugin_preferences.len;
                next[preference_index.?] = .{};
                result.plugin_preferences = next;
                provider_index = null;
                model_index = null;
                section = .plugin_preferences;
                continue;
            }
            if (eq(line, "[[ai.providers]]") or eq(line, "[[ai.providers.models]]")) {
                const a = allocator orelse return error.RequiresAllocator;
                section = .ai;
                preference_index = null;
                if (eq(line, "[[ai.providers]]")) {
                    const i = if (provider_index) |index| index + 1 else 0;
                    if (i == 0) {
                        result.ai.providers = @constCast(&[_]AiProvider{});
                        result.ai.provider_count = 0;
                    }
                    const next = a.alloc(AiProvider, i + 1) catch return error.OutOfMemory;
                    @memcpy(next[0..i], result.ai.providers);
                    next[i] = .{};
                    result.ai.providers = next;
                    result.ai.provider_count = i + 1;
                    provider_index = i;
                    model_index = null;
                } else {
                    const i = provider_index orelse return error.InvalidSection;
                    const p = &result.ai.providers[i];
                    const j = p.model_count;
                    const next = a.alloc(AiModel, j + 1) catch return error.OutOfMemory;
                    @memcpy(next[0..j], p.models);
                    next[j] = .{};
                    p.models = next;
                    p.model_count = j + 1;
                    model_index = j;
                }
                continue;
            }
            if (line[0] == '[') {
                preference_index = null;
                provider_index = null;
                model_index = null;
                section = try parseSection(line);
                continue;
            }
            if (section == .keys) continue;
            var remaining = line;
            while (nextAssignment(&remaining)) |raw_pair| {
                const pair = trim(raw_pair);
                if (pair.len == 0) continue;
                const separator = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidAssignment;
                const key = trim(pair[0..separator]);
                const value = trim(pair[separator + 1 ..]);
                if (preference_index) |i| {
                    const preference = &@constCast(result.plugin_preferences)[i];
                    if (eq(key, "plugin_id")) preference.plugin_id = try parseOwnedString(allocator, value) else if (eq(key, "key")) preference.key = try parseOwnedString(allocator, value) else if (eq(key, "value")) preference.value = try parseOwnedString(allocator, value) else return error.UnknownKey;
                } else if (provider_index) |i| {
                    var key_buffer: [128]u8 = undefined;
                    const field = if (eq(key, "name") and model_index != null) "id" else if (eq(key, "id") and model_index == null) "name" else key;
                    const flat = if (model_index) |j| std.fmt.bufPrint(&key_buffer, "provider_{d}_model_{d}_{s}", .{ i, j, field }) catch return error.InvalidValue else std.fmt.bufPrint(&key_buffer, "provider_{d}_{s}", .{ i, field }) catch return error.InvalidValue;
                    try result.applyProvider(allocator, flat, value);
                } else try result.apply(allocator, section, key, value);
            }
        }
        result.keys = keybindings.Map.parse(text) catch return error.InvalidValue;
        try result.validate();
        return result;
    }

    pub fn format(self: Config, buffer: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("[meta]\nconfig_revision = {d}\n\n", .{self.config_revision});
        try writer.print("[ui]\nicon_background = \"{s}\"\ntheme = \"{s}\"\nfont_family = \"{s}\"\nfont_size = {d}\nfont_weight = \"{s}\"\nline_height = {d}\ncursor_style = \"{s}\"\nsidebar_collapsed = {}\ninput_line_highlight = {}\ntimestamp_gutter = {}\n\n", .{ @tagName(self.ui.icon_background), self.ui.theme, self.ui.font_family, self.ui.font_size, self.ui.font_weight, self.ui.line_height, self.ui.cursor_style, self.ui.sidebar_collapsed, self.ui.input_line_highlight, self.ui.timestamp_gutter });
        const background = self.ui.materials.background;
        try writer.print("[ui.materials]\nblur_px = {d}\n\n[ui.materials.background]\nenabled = {}\npath = ", .{ self.ui.materials.blur_px, background.enabled });
        try std.json.Stringify.value(background.path, .{}, &writer);
        try writer.print("\nfit = \"{s}\"\nalignment_x = \"{s}\"\nalignment_y = \"{s}\"\ntransparency = {d}\n\n", .{ @tagName(background.fit), @tagName(background.alignment_x), @tagName(background.alignment_y), background.transparency });
        try writer.print("[completion]\nenabled = {}\n\n", .{self.completion.enabled});
        try writer.print("[transfer]\ndedicated_connection = {}\nwindow_chunks = {d}\nchunk_kb = {d}\ndownload_dir = \"{s}\"\nverify_md5 = {}\nshared_pacing_kbps = {d}\nresume = {}\nmax_tasks = {d}\nconflict_policy = \"{s}\"\n\n", .{ self.transfer.dedicated_connection, self.transfer.window_chunks, self.transfer.chunk_kb, self.transfer.download_dir, self.transfer.verify_md5, self.transfer.shared_pacing_kbps, self.transfer.@"resume", self.transfer.max_tasks, self.transfer.conflict_policy });
        try writer.print("[ssh]\nkeepalive_sec = {d}\nreconnect_max = {d}\nreconnect_backoff = [{d},{d},{d},{d},{d}]\nconnect_timeout_sec = {d}\nterm = \"{s}\"\ncompression = {}\nauto_reconnect = {}\nbuffer_input = {}\nsocks_port = {d}\nsocks_bind = \"{s}\"\notp_modal = {}\ntotp_autofill = {}\n\n", .{ self.ssh.keepalive_sec, self.ssh.reconnect_max, self.ssh.reconnect_backoff[0], self.ssh.reconnect_backoff[1], self.ssh.reconnect_backoff[2], self.ssh.reconnect_backoff[3], self.ssh.reconnect_backoff[4], self.ssh.connect_timeout_sec, self.ssh.term, self.ssh.compression, self.ssh.auto_reconnect, self.ssh.buffer_input, self.ssh.socks_port, self.ssh.socks_bind, self.ssh.otp_modal, self.ssh.totp_autofill });
        try writer.print("[ai]\ndefault_provider = \"{s}\"\npermission_mode = \"{s}\"\nredact_ip = {}\nerror_hint = {}\nprovider_count = {d}\n", .{ self.ai.default_provider, @tagName(self.ai.permission_mode), self.ai.redact_ip, self.ai.error_hint, self.ai.provider_count });
        var has_provider = false;
        for (self.ai.providers) |p| if (p.endpoint.len > 0 or p.api_key.len > 0 or p.api_key_ref != null or p.name.len > 0 or p.model_count > 0 or p.enabled) {
            has_provider = true;
            break;
        };
        if (has_provider) for (self.ai.providers[0..self.ai.provider_count]) |p| {
            const id = p.name;
            try writer.print("[[ai.providers]]\nid = \"{s}\"\nkind = \"{s}\"\nendpoint = \"{s}\"\n", .{ id, @tagName(p.kind), p.endpoint });
            if (p.api_key_ref) |reference| {
                try writer.writeAll("api_key_ref = ");
                try std.json.Stringify.value(reference, .{}, &writer);
                try writer.writeByte('\n');
            } else {
                try writer.writeAll("api_key = ");
                try std.json.Stringify.value(p.api_key, .{}, &writer);
                try writer.writeByte('\n');
            }
            try writer.print("enabled = {}\n", .{p.enabled});
            for (p.models[0..p.model_count]) |m| {
                try writer.print("[[ai.providers.models]]\nname = \"{s}\"\ncontext_window = {d}\ndefault = {}\nreasoning = {}\nvision = {}\nefforts = [", .{ m.id, m.context_window, m.default, m.reasoning, m.vision });
                const names = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "none", "ultra" };
                var first = true;
                for (m.efforts, 0..) |enabled, k| if (enabled) {
                    if (!first) try writer.writeAll(",");
                    try writer.print("\"{s}\"", .{names[k]});
                    first = false;
                };
                try writer.writeAll("]\n");
                if (m.image_token_reservation) |reservation| try writer.print("image_token_reservation = {d}\n", .{reservation});
            }
        };
        try writer.writeAll("\n");
        try writer.print("[log]\nring_mb = {d}\ncheckpoint_sec = {d}\nretention_days = {d}\nexport_format = \"{s}\"\n\n", .{ self.log.ring_mb, self.log.checkpoint_sec, self.log.retention_days, self.log.export_format });
        try writer.print("[notify]\ntransfer_done = {}\nreconnect = {}\nai_ready = {}\nbell = {}\ntab_dot = {}\nquiet_hours = \"{s}\"\n\n", .{ self.notify.transfer_done, self.notify.reconnect, self.notify.ai_ready, self.notify.bell, self.notify.tab_dot, self.notify.quiet_hours });
        var key_buffer: [4096]u8 = undefined;
        try writer.writeAll(try self.keys.format(&key_buffer));
        for (self.plugin_preferences) |preference| {
            try writer.writeAll("\n[[plugin_preferences]]\nplugin_id = ");
            try std.json.Stringify.value(preference.plugin_id, .{}, &writer);
            try writer.writeAll("\nkey = ");
            try std.json.Stringify.value(preference.key, .{}, &writer);
            try writer.writeAll("\nvalue = ");
            try std.json.Stringify.value(preference.value, .{}, &writer);
            try writer.writeAll("\n");
        }
        return writer.buffered();
    }

    pub fn pluginPreference(self: Config, plugin_id: []const u8, key: []const u8) ?[]const u8 {
        for (self.plugin_preferences) |preference| if (eq(plugin_id, preference.plugin_id) and eq(key, preference.key)) return preference.value;
        return null;
    }
    /// Caller owns allocator lifetime, matching Config.parseWithAllocator.
    pub fn putPluginPreference(self: *Config, allocator: std.mem.Allocator, plugin_id: []const u8, key: []const u8, value: []const u8) !void {
        var index = self.plugin_preferences.len;
        for (self.plugin_preferences, 0..) |preference, i| if (eq(plugin_id, preference.plugin_id) and eq(key, preference.key)) {
            index = i;
            break;
        };
        const next = try allocator.alloc(PluginPreference, self.plugin_preferences.len + @intFromBool(index == self.plugin_preferences.len));
        @memcpy(next[0..self.plugin_preferences.len], self.plugin_preferences);
        next[index] = .{ .plugin_id = try allocator.dupe(u8, plugin_id), .key = try allocator.dupe(u8, key), .value = try allocator.dupe(u8, value) };
        self.plugin_preferences = next;
    }

    fn apply(self: *Config, allocator: ?std.mem.Allocator, section: Section, key: []const u8, value: []const u8) ParseError!void {
        switch (section) {
            .meta => {
                if (eq(key, "config_revision")) self.config_revision = try parseInt(u64, value) else return error.UnknownKey;
            },
            .ui => {
                if (eq(key, "icon_background")) self.ui.icon_background = std.meta.stringToEnum(IconBackground, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "theme")) self.ui.theme = try parseString(value) else if (eq(key, "font_family")) self.ui.font_family = try parseString(value) else if (eq(key, "font_size")) self.ui.font_size = try parseInt(u8, value) else if (eq(key, "font_weight")) self.ui.font_weight = try parseString(value) else if (eq(key, "line_height")) self.ui.line_height = try parseFloat(value) else if (eq(key, "cursor_style")) self.ui.cursor_style = try parseString(value) else if (eq(key, "sidebar_collapsed")) self.ui.sidebar_collapsed = try parseBool(value) else if (eq(key, "input_line_highlight")) self.ui.input_line_highlight = try parseBool(value) else if (eq(key, "timestamp_gutter")) self.ui.timestamp_gutter = try parseBool(value) else return error.UnknownKey;
            },
            .@"ui.materials" => {
                if (eq(key, "blur_px")) self.ui.materials.blur_px = try parseInt(u8, value) else return error.UnknownKey;
            },
            .@"ui.materials.background" => {
                const background = &self.ui.materials.background;
                if (eq(key, "enabled")) background.enabled = try parseBool(value) else if (eq(key, "path")) background.path = try parseOwnedString(allocator, value) else if (eq(key, "fit")) background.fit = std.meta.stringToEnum(material.Fit, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "alignment_x")) background.alignment_x = std.meta.stringToEnum(material.Horizontal, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "alignment_y")) background.alignment_y = std.meta.stringToEnum(material.Vertical, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "transparency")) background.transparency = try parseFloat(value) else return error.UnknownKey;
            },
            .completion => {
                if (eq(key, "enabled")) self.completion.enabled = try parseBool(value) else return error.UnknownKey;
            },
            .transfer => {
                if (eq(key, "dedicated_connection")) self.transfer.dedicated_connection = try parseBool(value) else if (eq(key, "window_chunks")) self.transfer.window_chunks = try parseInt(u8, value) else if (eq(key, "chunk_kb")) self.transfer.chunk_kb = try parseInt(u16, value) else if (eq(key, "download_dir")) self.transfer.download_dir = try parseString(value) else if (eq(key, "verify_md5")) self.transfer.verify_md5 = try parseBool(value) else if (eq(key, "shared_pacing_kbps")) self.transfer.shared_pacing_kbps = try parseInt(u32, value) else if (eq(key, "resume")) self.transfer.@"resume" = try parseBool(value) else if (eq(key, "max_tasks")) self.transfer.max_tasks = try parseInt(u8, value) else if (eq(key, "conflict_policy")) self.transfer.conflict_policy = try parseString(value) else return error.UnknownKey;
            },
            .ssh => {
                if (eq(key, "keepalive_sec")) self.ssh.keepalive_sec = try parseInt(u16, value) else if (eq(key, "reconnect_max")) self.ssh.reconnect_max = try parseInt(u8, value) else if (eq(key, "reconnect_backoff")) self.ssh.reconnect_backoff = try parseBackoff(value) else if (eq(key, "connect_timeout_sec")) self.ssh.connect_timeout_sec = try parseInt(u16, value) else if (eq(key, "term")) self.ssh.term = try parseString(value) else if (eq(key, "compression")) self.ssh.compression = try parseBool(value) else if (eq(key, "auto_reconnect")) self.ssh.auto_reconnect = try parseBool(value) else if (eq(key, "buffer_input")) self.ssh.buffer_input = try parseBool(value) else if (eq(key, "socks_port")) self.ssh.socks_port = try parseInt(u16, value) else if (eq(key, "socks_bind")) self.ssh.socks_bind = try parseString(value) else if (eq(key, "otp_modal")) self.ssh.otp_modal = try parseBool(value) else if (eq(key, "totp_autofill")) self.ssh.totp_autofill = try parseBool(value) else return error.UnknownKey;
            },
            .ai => {
                if (eq(key, "default_provider")) self.ai.default_provider = try parseString(value) else if (eq(key, "permission_mode")) self.ai.permission_mode = std.meta.stringToEnum(PermissionMode, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "redact_ip")) self.ai.redact_ip = try parseBool(value) else if (eq(key, "error_hint")) self.ai.error_hint = try parseBool(value) else if (eq(key, "provider_count")) self.ai.provider_count = try parseInt(usize, value) else try self.applyProvider(allocator, key, value);
            },
            .log => {
                if (eq(key, "ring_mb")) self.log.ring_mb = try parseInt(u16, value) else if (eq(key, "checkpoint_sec")) self.log.checkpoint_sec = try parseInt(u16, value) else if (eq(key, "retention_days")) self.log.retention_days = try parseInt(u16, value) else if (eq(key, "export_format")) self.log.export_format = try parseString(value) else return error.UnknownKey;
            },
            .notify => {
                if (eq(key, "transfer_done")) self.notify.transfer_done = try parseBool(value) else if (eq(key, "reconnect")) self.notify.reconnect = try parseBool(value) else if (eq(key, "ai_ready")) self.notify.ai_ready = try parseBool(value) else if (eq(key, "bell")) self.notify.bell = try parseBool(value) else if (eq(key, "tab_dot")) self.notify.tab_dot = try parseBool(value) else if (eq(key, "quiet_hours")) self.notify.quiet_hours = try parseString(value) else return error.UnknownKey;
            },
            .keys => unreachable,
            .plugin_preferences => return error.InvalidSection,
            .none => return error.MissingSection,
        }
    }

    fn applyProvider(self: *Config, allocator: ?std.mem.Allocator, key: []const u8, value: []const u8) ParseError!void {
        if (!std.mem.startsWith(u8, key, "provider_")) return error.UnknownKey;
        const rest = key[9..];
        const sep = std.mem.indexOfScalar(u8, rest, '_') orelse return error.UnknownKey;
        const i = try parseInt(usize, rest[0..sep]);
        const a = allocator orelse return error.RequiresAllocator;
        if (i >= self.ai.providers.len) {
            const next = a.alloc(AiProvider, i + 1) catch return error.OutOfMemory;
            @memcpy(next[0..self.ai.providers.len], self.ai.providers);
            @memset(next[self.ai.providers.len..], .{});
            self.ai.providers = next;
        } else if (self.ai.providers.ptr == default_providers[0..].ptr) {
            self.ai.providers = a.dupe(AiProvider, self.ai.providers) catch return error.OutOfMemory;
        }
        self.ai.provider_count = @max(self.ai.provider_count, i + 1);
        const suffix = rest[sep + 1 ..];
        const p = &self.ai.providers[i];
        if (eq(suffix, "name")) {
            p.name = try parseString(value);
            if (eq(p.name, "anthropic")) p.kind = .anthropic else if (eq(p.name, "ollama")) p.kind = .ollama;
        } else if (eq(suffix, "kind")) p.kind = std.meta.stringToEnum(ProviderKind, try parseString(value)) orelse return error.InvalidValue else if (eq(suffix, "endpoint")) p.endpoint = try parseString(value) else if (eq(suffix, "api_key")) p.api_key = try parseString(value) else if (eq(suffix, "api_key_ref")) p.api_key_ref = try parseString(value) else if (eq(suffix, "enabled")) p.enabled = try parseBool(value) else if (eq(suffix, "model_count")) p.model_count = try parseInt(usize, value) else {
            if (!std.mem.startsWith(u8, suffix, "model_")) return error.UnknownKey;
            const fields = suffix[6..];
            const split = std.mem.indexOfScalar(u8, fields, '_') orelse return error.UnknownKey;
            const j = try parseInt(usize, fields[0..split]);
            if (j >= p.models.len) {
                const next = a.alloc(AiModel, j + 1) catch return error.OutOfMemory;
                @memcpy(next[0..p.models.len], p.models);
                @memset(next[p.models.len..], .{});
                p.models = next;
            }
            const field = fields[split + 1 ..];
            const m = &p.models[j];
            if (eq(field, "id")) m.id = try parseString(value) else if (eq(field, "context_window")) m.context_window = try parseInt(u32, value) else if (eq(field, "default")) m.default = try parseBool(value) else if (eq(field, "reasoning")) m.reasoning = try parseBool(value) else if (eq(field, "vision")) m.vision = try parseBool(value) else if (eq(field, "image_token_reservation")) {
                const reservation = try parseInt(u32, value);
                if (reservation == 0 or reservation > 131072) return error.OutOfRange;
                m.image_token_reservation = reservation;
            } else if (eq(field, "efforts")) {
                if (eq(value, "[]")) {
                    m.efforts = @splat(false);
                    return;
                }
                if (value.len < 3 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidValue;
                var entries = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
                if (std.mem.indexOfScalar(u8, value, '"') != null) {
                    @memset(&m.efforts, false);
                    while (entries.next()) |entry| {
                        const effort = std.meta.stringToEnum(@import("../ai/provider.zig").Effort, try parseString(trim(entry))) orelse return error.InvalidValue;
                        m.efforts[@backingInt(effort)] = true;
                    }
                } else {
                    for (&m.efforts) |*effort| effort.* = try parseBool(trim(entries.next() orelse return error.InvalidValue));
                    if (entries.next() != null) return error.InvalidValue;
                }
            } else return error.UnknownKey;
        }
    }

    pub fn validate(self: Config) ParseError!void {
        if (self.plugin_preferences.len > 1024) return error.OutOfRange;
        for (self.plugin_preferences, 0..) |preference, i| {
            if (!validPreferenceId(preference.plugin_id) or !validPreferenceId(preference.key) or preference.value.len > 4096 or !std.unicode.utf8ValidateSlice(preference.value) or std.mem.indexOfScalar(u8, preference.value, 0) != null) return error.InvalidValue;
            for (self.plugin_preferences[0..i]) |previous| if (eq(preference.plugin_id, previous.plugin_id) and eq(preference.key, previous.key)) return error.InvalidValue;
        }
        if (self.config_revision == 0) return error.OutOfRange;
        if (self.ai.provider_count > self.ai.providers.len) return error.OutOfRange;
        for (self.ai.providers[0..self.ai.provider_count]) |p| {
            for ([_][]const u8{ p.name, p.endpoint, p.api_key, p.model }) |text| {
                if (std.mem.indexOfAny(u8, text, "\"\\\n\r;#") != null) return error.InvalidValue;
            }
            if (p.model_count > p.models.len) return error.OutOfRange;
            if (p.enabled and (p.endpoint.len == 0 or p.model_count == 0)) return error.InvalidValue;
            for (p.models[0..p.model_count]) |m| {
                if (std.mem.indexOfAny(u8, m.id, "\"\\\n\r;#") != null) return error.InvalidValue;
                if (m.image_token_reservation) |reservation| if (reservation == 0 or reservation > 131072) return error.OutOfRange;
                if (!p.enabled) continue;
                if (m.id.len == 0 or m.context_window == 0) return error.InvalidValue;
                if (m.reasoning and !m.reasoning_toggle and !m.efforts[0] and !m.efforts[1] and !m.efforts[2] and !m.efforts[3] and !m.efforts[4] and !m.efforts[5] and !m.efforts[6]) return error.InvalidValue;
            }
        }
        if (self.ssh.connect_timeout_sec == 0 or self.ssh.socks_port == 0 or self.transfer.max_tasks == 0 or self.log.retention_days == 0) return error.OutOfRange;
        if (self.ssh.term.len == 0 or !validBind(self.ssh.socks_bind) or !eq(self.transfer.conflict_policy, "ask") or !validQuietHours(self.notify.quiet_hours)) return error.InvalidValue;
        if (!eq(self.log.export_format, "txt") and !eq(self.log.export_format, "cast") and !eq(self.log.export_format, "txt_cast")) return error.InvalidValue;

        if (self.ui.font_size < 8 or self.ui.font_size > 48) return error.OutOfRange;
        if (!std.math.isFinite(self.ui.line_height) or self.ui.line_height < 1.0 or self.ui.line_height > 3.0) return error.OutOfRange;
        if (std.mem.trim(u8, self.ui.font_family, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(self.ui.font_family) or std.mem.indexOfAny(u8, self.ui.font_family, "\"\\\n\r") != null) return error.InvalidValue;
        if (!validFontWeight(self.ui.font_weight) or !validCursorStyle(self.ui.cursor_style)) return error.InvalidValue;
        try self.ui.materials.validate();
        if (self.transfer.window_chunks == 0 or self.transfer.chunk_kb == 0) return error.OutOfRange;
        if (self.ssh.reconnect_max > self.ssh.reconnect_backoff.len) return error.OutOfRange;
        if (self.log.ring_mb == 0 or self.log.checkpoint_sec == 0) return error.OutOfRange;
    }
};

pub const PluginPreference = struct { plugin_id: []const u8 = "", key: []const u8 = "", value: []const u8 = "" };
fn validPreferenceId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return false;
    return true;
}

pub const IconBackground = enum { transparent, light, dark };
pub const Ui = struct { icon_background: IconBackground = .transparent, theme: []const u8 = "dark", font_family: []const u8 = "JetBrains Mono", font_size: u8 = 14, font_weight: []const u8 = "regular", line_height: f32 = 11.0 / 7.0, cursor_style: []const u8 = "block", sidebar_collapsed: bool = false, input_line_highlight: bool = true, timestamp_gutter: bool = false, materials: material.Materials = .{} };
pub fn resetDefaults() Config {
    var value: Config = .{};
    value.ui.theme = "sauber";
    return value;
}
pub fn validFontWeight(value: []const u8) bool {
    return eq(value, "light") or eq(value, "regular") or eq(value, "medium") or eq(value, "bold");
}
pub fn validCursorStyle(value: []const u8) bool {
    return eq(value, "block") or eq(value, "bar") or eq(value, "underline");
}
pub const Completion = struct { enabled: bool = true };
pub const Transfer = struct { dedicated_connection: bool = true, window_chunks: u8 = 16, chunk_kb: u16 = 64, download_dir: []const u8 = "~/Downloads", verify_md5: bool = false, shared_pacing_kbps: u32 = 2048, @"resume": bool = true, max_tasks: u8 = 3, conflict_policy: []const u8 = "ask" };
pub const Ssh = struct { keepalive_sec: u16 = 30, reconnect_max: u8 = 5, reconnect_backoff: [5]u8 = .{ 1, 2, 4, 8, 16 }, connect_timeout_sec: u16 = 15, term: []const u8 = "xterm-256color", compression: bool = false, auto_reconnect: bool = true, buffer_input: bool = true, socks_port: u16 = 1080, socks_bind: []const u8 = "127.0.0.1", otp_modal: bool = true, totp_autofill: bool = false };
pub const PermissionMode = enum { confirm, auto };
pub const ProviderKind = @import("../ai/registry.zig").Kind;
pub const AiProvider = struct {
    name: []const u8 = "",
    kind: ProviderKind = .openai_compat,
    model_count: usize = 0,
    endpoint: []const u8 = "",
    model: []const u8 = "",
    context_window: u32 = 0,
    enabled: bool = false,
    api_key: []const u8 = "",
    api_key_ref: ?[]const u8 = null,
    models: []AiModel = @constCast(&[_]AiModel{}),
};
pub const AiModel = struct {
    id: []const u8 = "",
    context_window: u32 = 0,
    default: bool = false,
    reasoning: bool = false,
    /// Discovery-only metadata, never persisted into the user configuration.
    context_discovered: bool = false,
    reasoning_toggle: bool = false,
    reasoning_discovered: bool = false,
    reasoning_adaptive: bool = false,
    thinking_default: ?bool = null,
    vision: bool = false,
    /// Conservative configured budget for models without a known image token formula.
    image_token_reservation: ?u32 = null,
    efforts: [7]bool = .{ true, true, true, false, false, false, false },
};
pub const default_providers = [_]AiProvider{ .{ .kind = .anthropic }, .{ .kind = .openai_compat }, .{ .kind = .ollama } };
pub const Ai = struct {
    default_provider: []const u8 = "anthropic",
    permission_mode: PermissionMode = .confirm,
    redact_ip: bool = false,
    error_hint: bool = true,
    /// Legacy backing slots retain protocol identities for flat-key migration.
    /// New installations have no Provider until the user adds one.
    provider_count: usize = 0,
    providers: []AiProvider = @constCast(&default_providers),
};
pub const Log = struct { ring_mb: u16 = 64, checkpoint_sec: u16 = 30, retention_days: u16 = 14, export_format: []const u8 = "txt_cast" };

pub const Notify = struct { transfer_done: bool = true, reconnect: bool = true, ai_ready: bool = true, bell: bool = false, tab_dot: bool = true, quiet_hours: []const u8 = "22:00-08:00" };

const Section = enum { plugin_preferences, none, meta, ui, @"ui.materials", @"ui.materials.background", completion, transfer, ssh, ai, log, notify, keys };
pub const ParseError = error{ InvalidSection, InvalidAssignment, InvalidValue, UnknownKey, MissingSection, OutOfRange, Overflow, RequiresAllocator, OutOfMemory };

fn parseSection(line: []const u8) ParseError!Section {
    if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSection;
    return std.meta.stringToEnum(Section, line[1 .. line.len - 1]) orelse error.InvalidSection;
}
fn stripComment(line: []const u8) []const u8 {
    var quoted = false;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (quoted and !escaped and byte == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and byte == '"') quoted = !quoted;
        if (!quoted and byte == '#') return line[0..index];
        escaped = false;
    }
    return line;
}
fn nextAssignment(remaining: *[]const u8) ?[]const u8 {
    if (remaining.len == 0) return null;
    const text = remaining.*;
    var quoted = false;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (quoted and !escaped and byte == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and byte == '"') quoted = !quoted;
        if (!quoted and byte == ';') {
            remaining.* = text[index + 1 ..];
            return text[0..index];
        }
        escaped = false;
    }
    remaining.* = "";
    return text;
}
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn parseString(value: []const u8) ParseError![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidValue;
    return value[1 .. value.len - 1];
}
fn parseOwnedString(allocator: ?std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    const raw = try parseString(value);
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    return std.json.parseFromSliceLeaky([]const u8, allocator orelse return error.RequiresAllocator, value, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
}
fn parseBool(value: []const u8) ParseError!bool {
    if (eq(value, "true")) return true;
    if (eq(value, "false")) return false;
    return error.InvalidValue;
}
fn parseInt(comptime T: type, value: []const u8) ParseError!T {
    return std.fmt.parseInt(T, value, 10) catch |err| switch (err) {
        error.Overflow => error.Overflow,
        else => error.InvalidValue,
    };
}
fn parseFloat(value: []const u8) ParseError!f32 {
    return std.fmt.parseFloat(f32, value) catch error.InvalidValue;
}
fn parseBackoff(value: []const u8) ParseError![5]u8 {
    if (value.len < 3 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidValue;
    var out: [5]u8 = undefined;
    var i: usize = 0;
    var parts = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
    while (parts.next()) |part| {
        if (i == out.len) return error.InvalidValue;
        out[i] = try parseInt(u8, trim(part));
        i += 1;
    }
    if (i != out.len) return error.InvalidValue;
    return out;
}

test "default config matches the product baseline" {
    const cfg: Config = .{};
    try std.testing.expectEqual(@as(u8, 14), cfg.ui.font_size);
    try std.testing.expectEqual(@as(u8, 16), cfg.transfer.window_chunks);
    try std.testing.expectEqual(PermissionMode.confirm, cfg.ai.permission_mode);
}

test "config parses and round trips the documented subset" {
    const source = "[ui]\ntheme = \"sauber\"\nfont_family = \"JetBrains Mono\"\nfont_size = 14\nfont_weight = \"regular\"\nline_height = 1.50\ncursor_style = \"block\"\nsidebar_collapsed = false\ninput_line_highlight = true\n\n[completion]\nenabled = true\n\n[transfer]\ndedicated_connection = true\nwindow_chunks = 16\nchunk_kb = 64\ndownload_dir = \"~/Downloads\"\nverify_md5 = false\nshared_pacing_kbps = 2048\n\n[ssh]\nkeepalive_sec = 30\nreconnect_max = 5\nreconnect_backoff = [1,2,4,8,16]\n\n[ai]\ndefault_provider = \"anthropic\"\npermission_mode = \"confirm\"\nredact_ip = false\nerror_hint = true\n\n[log]\nring_mb = 64\ncheckpoint_sec = 30\n";
    const first = try Config.parse(source);
    var buffer: [2048]u8 = undefined;
    const encoded = try first.format(&buffer);
    const second = try Config.parse(encoded);
    try std.testing.expectEqual(first.ui.font_size, second.ui.font_size);
    try std.testing.expectEqual(first.ssh.reconnect_backoff, second.ssh.reconnect_backoff);
    try std.testing.expectEqual(first.ai.permission_mode, second.ai.permission_mode);
}

test "unknown configuration is rejected instead of silently guessed" {
    try std.testing.expectError(error.UnknownKey, Config.parse("[ui]\nmade_up = true\n"));
    try std.testing.expectError(error.OutOfRange, Config.parse("[ui]\nfont_size = 2\n"));
}

pub fn validBind(text: []const u8) bool {
    return eq(text, "127.0.0.1") or eq(text, "0.0.0.0");
}
pub fn validQuietHours(text: []const u8) bool {
    if (text.len != 11 or text[2] != ':' or text[5] != '-' or text[8] != ':') return false;
    for ([_]usize{ 0, 1, 3, 4, 6, 7, 9, 10 }) |at| if (!std.ascii.isDigit(text[at])) return false;
    const h1 = std.fmt.parseInt(u8, text[0..2], 10) catch return false;
    const m1 = std.fmt.parseInt(u8, text[3..5], 10) catch return false;
    const h2 = std.fmt.parseInt(u8, text[6..8], 10) catch return false;
    const m2 = std.fmt.parseInt(u8, text[9..11], 10) catch return false;
    return h1 < 24 and h2 < 24 and m1 < 60 and m2 < 60;
}

test "settings extensions survive non-default roundtrip and validate ranges" {
    const original = try Config.parse("[ssh]\nconnect_timeout_sec = 42\nterm = \"vt100\"\ncompression = true\nauto_reconnect = false\nbuffer_input = false\nsocks_port = 9090\nsocks_bind = \"0.0.0.0\"\notp_modal = false\ntotp_autofill = true\n[transfer]\nresume = false\nmax_tasks = 7\nconflict_policy = \"ask\"\n[notify]\ntransfer_done = false\nreconnect = false\nai_ready = false\nbell = true\ntab_dot = false\nquiet_hours = \"23:30-07:15\"\n[log]\nretention_days = 90\nexport_format = \"cast\"\n[completion]\nenabled = false\n");
    var buffer: [4096]u8 = undefined;
    const encoded = try original.format(&buffer);
    const loaded = try Config.parse(encoded);
    try std.testing.expectEqualDeep(original, loaded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "[ssh]") == std.mem.lastIndexOf(u8, encoded, "[ssh]"));
    try std.testing.expectError(error.OutOfRange, Config.parse("[ssh]\nsocks_port = 0\n"));
    try std.testing.expectError(error.OutOfRange, Config.parse("[transfer]\nmax_tasks = 0\n"));
    try std.testing.expectError(error.InvalidValue, Config.parse("[notify]\nquiet_hours = \"25:00-08:00\"\n"));
    try std.testing.expectError(error.InvalidValue, Config.parse("[log]\nexport_format = \"html\"\n"));
}

test "provider models roundtrip with allocator ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "[ai]\nprovider_0_model_count = 1\nprovider_0_model_0_id = \"first\"\nprovider_0_model_0_context_window = 200000\nprovider_0_api_key = \"secret\"\n";
    const c = try Config.parseWithAllocator(arena.allocator(), source);
    var b: [8192]u8 = undefined;
    const loaded = try Config.parseWithAllocator(arena.allocator(), try c.format(&b));
    // Flat legacy input retains spare migration slots; compare all active data.
    var expected = c.ai;
    expected.providers = expected.providers[0..expected.provider_count];
    try std.testing.expectEqualDeep(expected, loaded.ai);
    try std.testing.expectError(error.RequiresAllocator, Config.parse(source));
}

test "documented provider array tables with effort names parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try Config.parseWithAllocator(arena.allocator(), "[ai]\ndefault_provider = \"anthropic\"\n[[ai.providers]]\nid = \"anthropic\"; endpoint = \"https://api.anthropic.com\"; api_key = \"sk-test\"\n[[ai.providers.models]]\nname = \"claude-sonnet-4\"; default = true\nefforts = [\"low\",\"medium\",\"high\"]\nreasoning = true\ncontext_window = 200_000\n");
    try std.testing.expectEqual(@as(u32, 200000), c.ai.providers[0].models[0].context_window);
    try std.testing.expect(c.ai.providers[0].models[0].efforts[2]);
    try std.testing.expect(!c.ai.providers[0].models[0].efforts[3]);
}

test "provider and model lists exceed former artificial capacities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    try w.writeAll("[ai]\n");
    for (0..10) |i| {
        try w.print("[[ai.providers]]\nid = \"provider-{d}\"\n", .{i});
        for (0..6) |j| try w.print("[[ai.providers.models]]\nname = \"model-{d}\"\ncontext_window = 8192\n", .{j});
    }
    const c = try Config.parseWithAllocator(arena.allocator(), w.buffered());
    try std.testing.expectEqual(@as(usize, 10), c.ai.provider_count);
    try std.testing.expectEqual(@as(usize, 6), c.ai.providers[9].model_count);
}

test "disabled provider models reject unserializable ids but allow incomplete roundtrip" {
    var models = [_]AiModel{.{ .efforts = @splat(false) }};
    var providers = [_]AiProvider{.{ .name = "disabled", .models = &models, .model_count = 1 }};
    var value: Config = .{};
    value.ai.providers = &providers;
    value.ai.provider_count = 1;
    for ([_][]const u8{ "bad\"id", "bad\\id", "bad\nid", "bad\rid", "bad;id", "bad#id" }) |id| {
        models[0].id = id;
        try std.testing.expectError(error.InvalidValue, value.validate());
    }
    models[0].id = "";
    try value.validate();
    var buffer: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loaded = try Config.parseWithAllocator(arena.allocator(), try value.format(&buffer));
    try std.testing.expect(!loaded.ai.providers[0].enabled);
    try std.testing.expectEqualStrings("", loaded.ai.providers[0].models[0].id);
    try std.testing.expectEqual(@as(u32, 0), loaded.ai.providers[0].models[0].context_window);
    try std.testing.expectEqualDeep(@as([7]bool, @splat(false)), loaded.ai.providers[0].models[0].efforts);
}

test "plugin preference strings preserve unknown plugin values through escaped serialization" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var value: Config = .{};
    try value.putPluginPreference(arena.allocator(), "unknown.future", "ordinary_value", "quoted \" text\\line\nnext");
    var buffer: [16384]u8 = undefined;
    const parsed = try Config.parseWithAllocator(arena.allocator(), try value.format(&buffer));
    try std.testing.expectEqualStrings("quoted \" text\\line\nnext", parsed.pluginPreference("unknown.future", "ordinary_value").?);
}

test "AI image token reservation round trips only explicit bounded values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prefix = "[ai]\n[[ai.providers]]\nid=\"custom\"\n[[ai.providers.models]]\nname=\"custom-vision\"\ncontext_window=32768\nvision=true\n";
    const omitted = try Config.parseWithAllocator(arena.allocator(), prefix);
    try std.testing.expect(omitted.ai.providers[0].models[0].image_token_reservation == null);
    const configured = try Config.parseWithAllocator(arena.allocator(), prefix ++ "image_token_reservation=8192\n");
    try configured.validate();
    var buffer: [65536]u8 = undefined;
    const formatted = try configured.format(&buffer);
    const restored = try Config.parseWithAllocator(arena.allocator(), formatted);
    try std.testing.expectEqual(@as(?u32, 8192), restored.ai.providers[0].models[0].image_token_reservation);
    try std.testing.expectError(error.OutOfRange, Config.parseWithAllocator(arena.allocator(), prefix ++ "image_token_reservation=0\n"));
    try std.testing.expectError(error.OutOfRange, Config.parseWithAllocator(arena.allocator(), prefix ++ "image_token_reservation=131073\n"));
    try std.testing.expectError(error.Overflow, Config.parseWithAllocator(arena.allocator(), prefix ++ "image_token_reservation=-1\n"));
}

test "new configuration starts with no provider and flat legacy providers retain their protocol" {
    const fresh = try Config.parse("");
    try std.testing.expectEqual(@as(usize, 0), fresh.ai.provider_count);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const old = try Config.parseWithAllocator(arena.allocator(), "[ai]\nprovider_1_endpoint = \"https://gateway.example.test/v1\"\nprovider_1_enabled = false\n");
    try std.testing.expectEqual(@as(usize, 2), old.ai.provider_count);
    try std.testing.expectEqual(ProviderKind.openai_compat, old.ai.providers[1].kind);
    try std.testing.expectEqualStrings("https://gateway.example.test/v1", old.ai.providers[1].endpoint);
    var buffer: [8192]u8 = undefined;
    const written = try old.format(&buffer);
    const loaded = try Config.parseWithAllocator(arena.allocator(), written);
    try std.testing.expectEqual(@as(usize, 2), loaded.ai.provider_count);
    try std.testing.expectEqualStrings(old.ai.providers[1].endpoint, loaded.ai.providers[1].endpoint);
}

test "none and ultra effort configuration roundtrips without enabling undeclared steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try Config.parseWithAllocator(arena.allocator(), "[ai]\ndefault_provider=\"gateway\"\n[[ai.providers]]\nid=\"gateway\"\nkind=\"openai_compat\"\nendpoint=\"http://127.0.0.1:9/v1/chat/completions\"\n[[ai.providers.models]]\nname=\"extended\"\nreasoning=true\nefforts=[\"none\",\"ultra\"]\n");
    var buffer: [8192]u8 = undefined;
    const loaded = try Config.parseWithAllocator(arena.allocator(), try c.format(&buffer));
    try std.testing.expectEqualDeep(c.ai.providers[0].models[0].efforts, loaded.ai.providers[0].models[0].efforts);
    try std.testing.expectEqual([7]bool{ false, false, false, false, false, true, true }, loaded.ai.providers[0].models[0].efforts);
}

test "app icon background defaults and persisted choice" {
    try std.testing.expectEqual(IconBackground.transparent, (try Config.parse("[ui]\ntheme = \"dark\"\n")).ui.icon_background);
    const parsed = try Config.parse("[ui]\nicon_background = \"light\"\n");
    try std.testing.expectEqual(IconBackground.light, parsed.ui.icon_background);
    var buffer: [32768]u8 = undefined;
    const restored = try Config.parse(try parsed.format(&buffer));
    try std.testing.expectEqual(IconBackground.light, restored.ui.icon_background);
    try std.testing.expectError(error.InvalidValue, Config.parse("[ui]\nicon_background = \"invalid\"\n"));
}
