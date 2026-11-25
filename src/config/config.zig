const std = @import("std");
pub const keybindings = @import("keybindings.zig");
pub const hosts = @import("hosts.zig");
pub const store = @import("store.zig");
pub const ai_extensions = @import("ai_extensions.zig");
pub const ai_role_templates = @import("ai_role_templates.zig");
pub const material = @import("background_asset.zig");
pub const ParseDetails = struct {
    line: ?usize = null,
    allow_unknown: bool = false,
    layout: LayoutPresence = .{},
    ui_insert_offset: ?usize = null,
};

pub const LayoutPresence = struct {
    ai_dock_width: bool = false,
    ai_dock_preferred: bool = false,
    mascot_anchor_x: bool = false,
    mascot_anchor_y: bool = false,

    pub fn complete(self: LayoutPresence) bool {
        return self.ai_dock_width and self.ai_dock_preferred and self.mascot_anchor_x and self.mascot_anchor_y;
    }
};

pub const Config = struct {
    /// Persisted monotonic identity of the committed global configuration.
    config_revision: u64 = 1,
    /// Runtime-only fence. Default permission/mode edits do not revoke agents.
    agent_policy_revision: ?u64 = null,
    ui: Ui = .{},
    completion: Completion = .{},
    transfer: Transfer = .{},
    ssh: Ssh = .{},
    ai: Ai = .{},
    log: Log = .{},
    notify: Notify = .{},
    updates: Updates = .{},
    keys: keybindings.Map = .{},
    plugin_preferences: []const PluginPreference = &.{},
    unknown_fields: []const UnknownField = &.{},

    pub fn agentPolicyRevision(self: Config) u64 {
        return self.agent_policy_revision orelse self.config_revision;
    }

    pub fn parse(text: []const u8) ParseError!Config {
        return parseWithAllocator(null, text);
    }

    pub fn parseWithAllocator(allocator: ?std.mem.Allocator, text: []const u8) ParseError!Config {
        return parseWithDetails(allocator, text, null);
    }

    pub fn parseWithDetails(allocator: ?std.mem.Allocator, text: []const u8, details: ?*ParseDetails) ParseError!Config {
        var result: Config = .{};
        const allow_unknown = if (details) |diagnostic| diagnostic.allow_unknown else false;
        var unknown: std.ArrayList(UnknownField) = .empty;
        var filtered_keys: ?[]u8 = null;
        var section: Section = .none;
        var provider_index: ?usize = null;
        var provider_array_started = false;
        var model_index: ?usize = null;
        var preference_index: ?usize = null;
        var unknown_scope: UnknownSectionScope = .independent;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_number: usize = 0;
        while (lines.next()) |raw| {
            line_number += 1;
            if (details) |diagnostic| diagnostic.line = line_number;
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
                    if (!provider_array_started) {
                        result.ai.providers = @constCast(&[_]AiProvider{});
                        result.ai.provider_count = 0;
                        provider_array_started = true;
                    }
                    const i = result.ai.provider_count;
                    const next = a.alloc(AiProvider, i + 1) catch return error.OutOfMemory;
                    @memcpy(next[0..i], result.ai.providers);
                    next[i] = .{};
                    result.ai.providers = next;
                    result.ai.provider_count = i + 1;
                    provider_index = i;
                    model_index = null;
                } else {
                    const i = provider_index orelse if (provider_array_started and result.ai.provider_count > 0) result.ai.provider_count - 1 else return error.InvalidSection;
                    provider_index = i;
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
                section = parseSection(line) catch |err| block: {
                    if (!allow_unknown) return err;
                    unknown_scope = unknownSectionScope(line) orelse return err;
                    switch (unknown_scope) {
                        .independent => {
                            preference_index = null;
                            provider_index = null;
                            model_index = null;
                        },
                        .provider, .model => {
                            if (provider_index == null and provider_array_started and result.ai.provider_count > 0) provider_index = result.ai.provider_count - 1;
                            const i = provider_index orelse return err;
                            if (unknown_scope == .model and result.ai.providers[i].model_count > result.ai.providers[i].models.len) return error.OutOfRange;
                            if (unknown_scope == .model and model_index == null and result.ai.providers[i].model_count > 0) model_index = result.ai.providers[i].model_count - 1;
                            if (unknown_scope == .model and model_index == null) return err;
                        },
                        .preference => {
                            if (preference_index == null and result.plugin_preferences.len > 0) preference_index = result.plugin_preferences.len - 1;
                            if (preference_index == null) return err;
                        },
                    }
                    const a = allocator orelse return error.RequiresAllocator;
                    unknown.append(a, unknownSectionField(line_number, line, unknown_scope, provider_index, model_index, preference_index, true)) catch return error.OutOfMemory;
                    break :block .unknown;
                };
                if (section != .unknown) {
                    preference_index = null;
                    provider_index = null;
                    model_index = null;
                }
                if (details) |diagnostic| if (section == .ui and diagnostic.ui_insert_offset == null) {
                    const end = @intFromPtr(raw.ptr) - @intFromPtr(text.ptr) + raw.len;
                    diagnostic.ui_insert_offset = end + @intFromBool(end < text.len);
                };
                continue;
            }
            if (section == .keys) {
                if (!allow_unknown) continue;
                const separator = assignmentSeparator(line) orelse return error.InvalidAssignment;
                const key = trim(line[0..separator]);
                if (!eq(key, "layout_version") and std.meta.stringToEnum(keybindings.Action, key) == null) {
                    var trailing = line;
                    _ = nextAssignment(&trailing);
                    if (trim(trailing).len != 0) return error.InvalidAssignment;
                    try recordUnknown(allocator, &unknown, .{ .line = line_number, .assignment = line, .section = section }, key, trim(line[separator + 1 ..]), text, &lines, &line_number, details, &trailing, &filtered_keys);
                    const a = allocator orelse return error.RequiresAllocator;
                    if (filtered_keys == null) filtered_keys = a.dupe(u8, text) catch return error.OutOfMemory;
                    const offset = @intFromPtr(raw.ptr) - @intFromPtr(text.ptr);
                    const assignment = unknown.items[unknown.items.len - 1].assignment;
                    const end = @max(offset + raw.len, @intFromPtr(assignment.ptr) - @intFromPtr(text.ptr) + assignment.len);
                    for (filtered_keys.?[offset..end]) |*byte| if (byte.* != '\n') {
                        byte.* = ' ';
                    };
                }
                continue;
            }
            var remaining = line;
            while (nextAssignment(&remaining)) |raw_pair| {
                const pair = trim(raw_pair);
                if (pair.len == 0) continue;
                const separator = assignmentSeparator(pair) orelse return error.InvalidAssignment;
                const key = trim(pair[0..separator]);
                const value = trim(pair[separator + 1 ..]);
                if (section == .none and allow_unknown) {
                    try recordUnknown(allocator, &unknown, .{ .line = line_number, .assignment = pair, .section = section }, key, value, text, &lines, &line_number, details, &remaining, &filtered_keys);
                } else if (section == .unknown) {
                    try recordUnknown(allocator, &unknown, unknownSectionField(line_number, pair, unknown_scope, provider_index, model_index, preference_index, false), key, value, text, &lines, &line_number, details, &remaining, &filtered_keys);
                } else if (preference_index) |i| {
                    const preference = &@constCast(result.plugin_preferences)[i];
                    if (eq(key, "plugin_id")) preference.plugin_id = try parseOwnedString(allocator, value) else if (eq(key, "key")) preference.key = try parseOwnedString(allocator, value) else if (eq(key, "value")) preference.value = try parseOwnedString(allocator, value) else {
                        if (!allow_unknown) return error.UnknownKey;
                        try recordUnknown(allocator, &unknown, .{ .line = line_number, .assignment = pair, .section = section, .preference_index = i }, key, value, text, &lines, &line_number, details, &remaining, &filtered_keys);
                    }
                } else if (provider_index) |i| {
                    if (!isKnownProviderField(key, model_index != null)) {
                        if (!allow_unknown) return error.UnknownKey;
                        try recordUnknown(allocator, &unknown, .{ .line = line_number, .assignment = pair, .section = section, .provider_index = i, .model_index = model_index }, key, value, text, &lines, &line_number, details, &remaining, &filtered_keys);
                        continue;
                    }
                    var key_buffer: [128]u8 = undefined;
                    const field = if (eq(key, "name") and model_index != null) "id" else if (eq(key, "id") and model_index == null) "name" else key;
                    const flat = if (model_index) |j| std.fmt.bufPrint(&key_buffer, "provider_{d}_model_{d}_{s}", .{ i, j, field }) catch return error.InvalidValue else std.fmt.bufPrint(&key_buffer, "provider_{d}_{s}", .{ i, field }) catch return error.InvalidValue;
                    try result.applyProvider(allocator, flat, value);
                } else {
                    result.apply(allocator, section, key, value) catch |err| {
                        if (err != error.UnknownKey or !allow_unknown) return err;
                        try recordUnknown(allocator, &unknown, .{ .line = line_number, .assignment = pair, .section = section }, key, value, text, &lines, &line_number, details, &remaining, &filtered_keys);
                        continue;
                    };
                    if (details) |diagnostic| if (section == .ui) {
                        inline for (@typeInfo(LayoutPresence).@"struct".field_names) |field| {
                            if (eq(key, field)) @field(diagnostic.layout, field) = true;
                        }
                    };
                }
            }
        }
        // Capture stable owners only after all their identifying fields have been parsed.
        for (unknown.items) |*field| {
            if (field.provider_index) |i| {
                field.provider_name = result.ai.providers[i].name;
                field.provider_signature = providerSignature(result.ai.providers[i]);
                for (result.ai.providers[0..@min(result.ai.provider_count, result.ai.providers.len)]) |provider| if (eq(provider.name, field.provider_name)) {
                    field.provider_name_count += 1;
                    if (providerSignature(provider) == field.provider_signature) field.provider_signature_count += 1;
                };
                if (field.model_index) |j| {
                    field.model_name = result.ai.providers[i].models[j].id;
                    field.model_signature = modelSignature(result.ai.providers[i].models[j]);
                    const provider = result.ai.providers[i];
                    for (provider.models[0..@min(provider.model_count, provider.models.len)]) |model| if (eq(model.id, field.model_name)) {
                        field.model_name_count += 1;
                        if (modelSignature(model) == field.model_signature) field.model_signature_count += 1;
                    };
                }
            }
            if (field.preference_index) |i| {
                const preference = result.plugin_preferences[i];
                field.preference_plugin_id = preference.plugin_id;
                field.preference_key = preference.key;
            }
        }
        // Retire only untouched protocol placeholders left by older versions.
        if (allocator != null and result.ai.provider_count > 0) {
            var count: usize = 0;
            for (result.ai.providers[0..@min(result.ai.provider_count, result.ai.providers.len)], 0..) |provider, original_index| {
                var has_unknown = false;
                for (unknown.items) |field| if (field.provider_index != null and field.provider_index.? == original_index) {
                    has_unknown = true;
                    break;
                };
                if (!has_unknown and !provider.enabled and provider.name.len == 0 and provider.endpoint.len == 0 and provider.api_key.len == 0 and provider.api_key_ref == null and provider.model_count == 0 and provider.model.len == 0) continue;
                for (unknown.items) |*field| if (field.provider_index != null and field.provider_index.? == original_index) {
                    field.provider_index = count;
                };
                result.ai.providers[count] = provider;
                count += 1;
            }
            result.ai.provider_count = count;
            result.ai.providers = result.ai.providers[0..count];
        }
        if (details) |diagnostic| diagnostic.line = null;
        result.keys = keybindings.Map.parse(if (filtered_keys) |filtered| filtered else text) catch return error.InvalidValue;
        if (allocator) |a| result.unknown_fields = unknown.toOwnedSlice(a) catch return error.OutOfMemory;
        try result.validate();
        return result;
    }

    pub fn format(self: Config, buffer: []u8) ![]const u8 {
        try self.validateUnknownOwners();
        var writer = std.Io.Writer.fixed(buffer);
        try self.writeUnknown(&writer, .none, null, null, null);
        try writer.print("[meta]\nconfig_revision = {d}\n", .{self.config_revision});
        try self.writeUnknown(&writer, .meta, null, null, null);
        try writer.writeByte('\n');
        try writer.print("[ui]\nicon_background = \"{s}\"\ntheme = \"{s}\"\nfont_family = \"{s}\"\nfont_size = {d}\nfont_weight = \"{s}\"\nline_height = {d}\ncursor_style = \"{s}\"\nsidebar_collapsed = {}\ninput_line_highlight = {}\ntimestamp_gutter = {}\ncommand_info = {}\nscrollback_limit = {d}\n\n", .{ @tagName(self.ui.icon_background), self.ui.theme, self.ui.font_family, self.ui.font_size, self.ui.font_weight, self.ui.line_height, self.ui.cursor_style, self.ui.sidebar_collapsed, self.ui.input_line_highlight, self.ui.timestamp_gutter, self.ui.command_info, self.ui.scrollback_limit });
        if (self.ui.sidebar_width) |width| try writer.print("sidebar_width = {d}\n\n", .{width});
        try writer.print("ai_dock_width = {d}\nai_dock_preferred = {}\nmascot_anchor_x = {d}\nmascot_anchor_y = {d}\n\n", .{ self.ui.ai_dock_width, self.ui.ai_dock_preferred, self.ui.mascot_anchor_x, self.ui.mascot_anchor_y });
        try self.writeUnknown(&writer, .ui, null, null, null);
        const background = self.ui.materials.background;
        try writer.print("[ui.materials]\nblur_px = {d}\n", .{self.ui.materials.blur_px});
        try self.writeUnknown(&writer, .@"ui.materials", null, null, null);
        try writer.print("\n[ui.materials.background]\nenabled = {}\npath = ", .{background.enabled});
        try std.json.Stringify.value(background.path, .{}, &writer);
        try writer.print("\nsource = \"{s}\"\norder = \"{s}\"\ninterval_minutes = {d}", .{ @tagName(background.source), @tagName(background.order), background.interval_minutes });
        try writer.print("\nfit = \"{s}\"\nalignment_x = \"{s}\"\nalignment_y = \"{s}\"\ntransparency = {d}\n\n", .{ @tagName(background.fit), @tagName(background.alignment_x), @tagName(background.alignment_y), background.transparency });
        try self.writeUnknown(&writer, .@"ui.materials.background", null, null, null);
        try writer.print("[updates]\nauto_check = {}\n", .{self.updates.auto_check});
        try self.writeUnknown(&writer, .updates, null, null, null);
        try writer.writeByte('\n');
        try writer.print("[completion]\nenabled = {}\n", .{self.completion.enabled});
        try self.writeUnknown(&writer, .completion, null, null, null);
        try writer.writeByte('\n');
        try writer.print("[transfer]\ndedicated_connection = {}\nwindow_chunks = {d}\nchunk_kb = {d}\ndownload_dir = \"{s}\"\nverify_md5 = {}\nshared_pacing_kbps = {d}\nresume = {}\nmax_tasks = {d}\nconflict_policy = \"{s}\"\n\n", .{ self.transfer.dedicated_connection, self.transfer.window_chunks, self.transfer.chunk_kb, self.transfer.download_dir, self.transfer.verify_md5, self.transfer.shared_pacing_kbps, self.transfer.@"resume", self.transfer.max_tasks, self.transfer.conflict_policy });
        try self.writeUnknown(&writer, .transfer, null, null, null);
        try writer.print("[ssh]\nkeepalive_sec = {d}\nreconnect_max = {d}\nreconnect_backoff = [{d},{d},{d},{d},{d}]\nconnect_timeout_sec = {d}\nterm = \"{s}\"\ncompression = {}\nauto_shell_integration = {}\nauto_reconnect = {}\nbuffer_input = {}\nsocks_port = {d}\nsocks_bind = \"{s}\"\notp_modal = {}\ntotp_autofill = {}\n\n", .{ self.ssh.keepalive_sec, self.ssh.reconnect_max, self.ssh.reconnect_backoff[0], self.ssh.reconnect_backoff[1], self.ssh.reconnect_backoff[2], self.ssh.reconnect_backoff[3], self.ssh.reconnect_backoff[4], self.ssh.connect_timeout_sec, self.ssh.term, self.ssh.compression, self.ssh.auto_shell_integration, self.ssh.auto_reconnect, self.ssh.buffer_input, self.ssh.socks_port, self.ssh.socks_bind, self.ssh.otp_modal, self.ssh.totp_autofill });
        try self.writeUnknown(&writer, .ssh, null, null, null);
        try writer.print("[ai]\ndefault_provider = \"{s}\"\npermission_mode = \"{s}\"\nexecution_mode = \"{s}\"\nsession_retention = \"{s}\"\nfollow_up_mode = \"{s}\"\nstep_display = \"{s}\"\nredact_ip = {}\nerror_hint = {}\nprovider_count = {d}\n", .{ self.ai.default_provider, @tagName(self.ai.permission_mode), @tagName(self.ai.execution_mode), @tagName(self.ai.session_retention), @tagName(self.ai.follow_up_mode), @tagName(self.ai.step_display), self.ai.redact_ip, self.ai.error_hint, self.ai.provider_count });
        if (self.ai.default_effort) |effort| try writer.print("default_effort = \"{s}\"\n", .{@tagName(effort)});
        try writer.print("child_context_mode = \"{s}\"\nchild_reuse_policy = \"{s}\"\n", .{ @tagName(self.ai.child_context_mode), @tagName(self.ai.child_reuse_policy) });
        try writer.print("interactive_batch_fallback = {}\nchild_max_active = {d}\nchild_request_concurrency = {d}\nmodel_slots = {d}\n", .{ self.ai.interactive_batch_fallback, self.ai.child_max_active, self.ai.child_request_concurrency, self.ai.model_slots });
        try writer.print("swarm_mode_default = \"{s}\"\nswarm_stall_minutes = {d}\nswarm_stall_parent_minutes = {d}\nboost_max_rounds = {d}\n", .{ @tagName(self.ai.swarm_mode_default), self.ai.swarm_stall_minutes, self.ai.swarm_stall_parent_minutes, self.ai.boost_max_rounds });
        if (self.ai.child_role_templates.len != 0) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const encoded = try @import("ai_role_templates.zig").Stored.encode(arena.allocator(), self.ai.child_role_templates);
            try writer.writeAll("child_role_templates = ");
            try std.json.Stringify.value(encoded, .{}, &writer);
            try writer.writeByte('\n');
        }
        if (self.ai.extensions.skills.len != 0 or self.ai.extensions.servers.len != 0) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), try self.ai.extensions.disk(arena.allocator()), .{});
            try writer.writeAll("extensions = ");
            try std.json.Stringify.value(encoded, .{}, &writer);
            try writer.writeAll("\n");
        }
        try self.writeUnknown(&writer, .ai, null, null, null);
        var has_provider = false;
        for (self.ai.providers) |p| if (p.endpoint.len > 0 or p.api_key.len > 0 or p.api_key_ref != null or p.name.len > 0 or p.model_count > 0 or p.enabled) {
            has_provider = true;
            break;
        };
        if (!has_provider) for (self.unknown_fields) |field| {
            if (field.provider_index != null) {
                has_provider = true;
                break;
            }
        };
        if (has_provider) for (self.ai.providers[0..self.ai.provider_count], 0..) |p, provider_i| {
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
            try self.writeUnknown(&writer, .ai, provider_i, null, null);
            try self.writeUnknown(&writer, .unknown, provider_i, null, null);
            for (p.models[0..p.model_count], 0..) |m, model_i| {
                try writer.print("[[ai.providers.models]]\nname = \"{s}\"\ncontext_window = {d}\ndefault = {}\nreasoning = {}\nvision = {}\nefforts = [", .{ m.id, m.context_window, m.default, m.reasoning, m.vision });
                const names = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "none", "ultra" };
                var first = true;
                for (m.efforts, 0..) |enabled, k| if (enabled) {
                    if (!first) try writer.writeAll(",");
                    try writer.print("\"{s}\"", .{names[k]});
                    first = false;
                };
                try writer.writeAll("]\n");
                if (m.catalog_managed) try writer.writeAll("catalog_managed = true\n");
                if (m.image_token_reservation) |reservation| try writer.print("image_token_reservation = {d}\n", .{reservation});
                if (m.image_token_max_width) |value| try writer.print("image_token_max_width = {d}\n", .{value});
                if (m.image_token_max_height) |value| try writer.print("image_token_max_height = {d}\n", .{value});
                try self.writeUnknown(&writer, .ai, provider_i, model_i, null);
                try self.writeUnknown(&writer, .unknown, provider_i, model_i, null);
            }
        };
        try writer.writeAll("\n");
        try writer.print("[log]\nring_mb = {d}\ncheckpoint_sec = {d}\nretention_days = {d}\nexport_format = \"{s}\"\n\n", .{ self.log.ring_mb, self.log.checkpoint_sec, self.log.retention_days, self.log.export_format });
        try self.writeUnknown(&writer, .log, null, null, null);
        try writer.print("[notify]\ntransfer_done = {}\nreconnect = {}\nai_ready = {}\nbell = {}\ntab_dot = {}\nquiet_hours = \"{s}\"\n\n", .{ self.notify.transfer_done, self.notify.reconnect, self.notify.ai_ready, self.notify.bell, self.notify.tab_dot, self.notify.quiet_hours });
        try self.writeUnknown(&writer, .notify, null, null, null);
        var key_buffer: [4096]u8 = undefined;
        try writer.writeAll(try self.keys.format(&key_buffer));
        try self.writeUnknown(&writer, .keys, null, null, null);
        for (self.plugin_preferences, 0..) |preference, preference_i| {
            try writer.writeAll("\n[[plugin_preferences]]\nplugin_id = ");
            try std.json.Stringify.value(preference.plugin_id, .{}, &writer);
            try writer.writeAll("\nkey = ");
            try std.json.Stringify.value(preference.key, .{}, &writer);
            try writer.writeAll("\nvalue = ");
            try std.json.Stringify.value(preference.value, .{}, &writer);
            try writer.writeAll("\n");
            try self.writeUnknown(&writer, .plugin_preferences, null, null, preference_i);
            try self.writeUnknown(&writer, .unknown, null, null, preference_i);
        }
        try self.writeUnknown(&writer, .unknown, null, null, null);
        return writer.buffered();
    }

    /// Clone preserved assignments and owner identities into the caller's arena.
    pub fn cloneUnknownFields(self: *Config, allocator: std.mem.Allocator, fields: []const UnknownField) !void {
        const copy = try allocator.alloc(UnknownField, fields.len);
        for (copy, fields) |*dst, src| {
            dst.* = src;
            dst.assignment = try allocator.dupe(u8, src.assignment);
            dst.provider_name = try allocator.dupe(u8, src.provider_name);
            dst.model_name = try allocator.dupe(u8, src.model_name);
            dst.preference_plugin_id = try allocator.dupe(u8, src.preference_plugin_id);
            dst.preference_key = try allocator.dupe(u8, src.preference_key);
        }
        self.unknown_fields = copy;
    }

    fn unknownProviderIndex(self: Config, field: UnknownField) !usize {
        var first: ?usize = null;
        var same_name: usize = 0;
        var same_signature: usize = 0;
        var signature_index: usize = 0;
        for (self.ai.providers[0..self.ai.provider_count], 0..) |provider, index| {
            if (!eq(provider.name, field.provider_name)) continue;
            if (first == null) first = index;
            same_name += 1;
            if (providerSignature(provider) == field.provider_signature) {
                same_signature += 1;
                signature_index = index;
            }
        }
        if (same_name == 0) return error.MissingUnknownFieldOwner;
        if (field.provider_signature_count > 1 and same_signature < field.provider_signature_count) return error.AmbiguousUnknownFieldOwner;
        if (same_name == 1) {
            if (field.provider_name_count > 1 and same_signature != 1) return error.AmbiguousUnknownFieldOwner;
            return first.?;
        }
        if (same_signature == 1) return signature_index;
        if (same_signature > 1) {
            const index = field.provider_index.?;
            if (index < self.ai.provider_count and eq(self.ai.providers[index].name, field.provider_name) and providerSignature(self.ai.providers[index]) == field.provider_signature) return index;
        }
        return error.AmbiguousUnknownFieldOwner;
    }

    fn unknownModelIndex(self: Config, field: UnknownField, provider_index: usize) !usize {
        const provider = self.ai.providers[provider_index];
        var first: ?usize = null;
        var same_name: usize = 0;
        var same_signature: usize = 0;
        var signature_index: usize = 0;
        for (provider.models[0..provider.model_count], 0..) |model, index| {
            if (!eq(model.id, field.model_name)) continue;
            if (first == null) first = index;
            same_name += 1;
            if (modelSignature(model) == field.model_signature) {
                same_signature += 1;
                signature_index = index;
            }
        }
        if (same_name == 0) return error.MissingUnknownFieldOwner;
        if (field.model_signature_count > 1 and same_signature < field.model_signature_count) return error.AmbiguousUnknownFieldOwner;
        if (same_name == 1) {
            if (field.model_name_count > 1 and same_signature != 1) return error.AmbiguousUnknownFieldOwner;
            return first.?;
        }
        if (same_signature == 1) return signature_index;
        if (same_signature > 1) {
            const index = field.model_index.?;
            if (index < provider.model_count and eq(provider.models[index].id, field.model_name) and modelSignature(provider.models[index]) == field.model_signature) return index;
        }
        return error.AmbiguousUnknownFieldOwner;
    }

    fn unknownPreferenceIndex(self: Config, field: UnknownField) !usize {
        for (self.plugin_preferences, 0..) |preference, index| {
            if (eq(preference.plugin_id, field.preference_plugin_id) and eq(preference.key, field.preference_key)) return index;
        }
        return error.MissingUnknownFieldOwner;
    }

    fn validateUnknownOwners(self: Config) !void {
        for (self.unknown_fields) |field| {
            if (field.provider_index != null) {
                const index = try self.unknownProviderIndex(field);
                if (field.model_index != null) _ = try self.unknownModelIndex(field, index);
            }
            if (field.preference_index != null) _ = try self.unknownPreferenceIndex(field);
        }
    }

    fn writeUnknown(self: Config, writer: *std.Io.Writer, section: Section, provider_index: ?usize, model_index: ?usize, preference_index: ?usize) !void {
        for (self.unknown_fields) |field| {
            if (field.section != section or (field.provider_index == null) != (provider_index == null) or
                (field.model_index == null) != (model_index == null) or (field.preference_index == null) != (preference_index == null)) continue;
            if (provider_index) |index| if (try self.unknownProviderIndex(field) != index) continue;
            if (model_index) |index| if (try self.unknownModelIndex(field, provider_index.?) != index) continue;
            if (preference_index) |index| if (try self.unknownPreferenceIndex(field) != index) continue;
            try writer.print("{s}\n", .{field.assignment});
        }
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
                if (eq(key, "ai_dock_width")) self.ui.ai_dock_width = try parseBoundedFloat(value, 360, 2400) else if (eq(key, "ai_dock_preferred")) self.ui.ai_dock_preferred = try parseBool(value) else if (eq(key, "mascot_anchor_x")) self.ui.mascot_anchor_x = try parseBoundedFloat(value, 0, 1) else if (eq(key, "mascot_anchor_y")) self.ui.mascot_anchor_y = try parseBoundedFloat(value, 0, 1) else if (eq(key, "scrollback_limit")) self.ui.scrollback_limit = try parseInt(u32, value) else if (eq(key, "icon_background")) self.ui.icon_background = std.meta.stringToEnum(IconBackground, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "theme")) self.ui.theme = try parseString(value) else if (eq(key, "font_family")) self.ui.font_family = try parseString(value) else if (eq(key, "font_size")) self.ui.font_size = try parseInt(u8, value) else if (eq(key, "font_weight")) self.ui.font_weight = try parseString(value) else if (eq(key, "line_height")) self.ui.line_height = try parseFloat(value) else if (eq(key, "cursor_style")) self.ui.cursor_style = try parseString(value) else if (eq(key, "sidebar_collapsed")) self.ui.sidebar_collapsed = try parseBool(value) else if (eq(key, "sidebar_width")) self.ui.sidebar_width = try parseFloat(value) else if (eq(key, "input_line_highlight")) self.ui.input_line_highlight = try parseBool(value) else if (eq(key, "timestamp_gutter")) self.ui.timestamp_gutter = try parseBool(value) else if (eq(key, "command_info")) self.ui.command_info = try parseBool(value) else return error.UnknownKey;
            },
            .@"ui.materials" => {
                if (eq(key, "blur_px")) self.ui.materials.blur_px = try parseInt(u8, value) else return error.UnknownKey;
            },
            .@"ui.materials.background" => {
                const background = &self.ui.materials.background;
                if (eq(key, "source")) background.source = std.meta.stringToEnum(material.Source, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "order")) background.order = std.meta.stringToEnum(material.Order, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "interval_minutes")) background.interval_minutes = try parseInt(u16, value) else if (eq(key, "enabled")) background.enabled = try parseBool(value) else if (eq(key, "path")) background.path = try parseOwnedString(allocator, value) else if (eq(key, "fit")) background.fit = std.meta.stringToEnum(material.Fit, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "alignment_x")) background.alignment_x = std.meta.stringToEnum(material.Horizontal, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "alignment_y")) background.alignment_y = std.meta.stringToEnum(material.Vertical, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "transparency")) background.transparency = try parseFloat(value) else return error.UnknownKey;
            },
            .completion => {
                if (eq(key, "enabled")) self.completion.enabled = try parseBool(value) else return error.UnknownKey;
            },
            .transfer => {
                if (eq(key, "dedicated_connection")) self.transfer.dedicated_connection = try parseBool(value) else if (eq(key, "window_chunks")) self.transfer.window_chunks = try parseInt(u8, value) else if (eq(key, "chunk_kb")) self.transfer.chunk_kb = try parseInt(u16, value) else if (eq(key, "download_dir")) self.transfer.download_dir = try parseString(value) else if (eq(key, "verify_md5")) self.transfer.verify_md5 = try parseBool(value) else if (eq(key, "shared_pacing_kbps")) self.transfer.shared_pacing_kbps = try parseInt(u32, value) else if (eq(key, "resume")) self.transfer.@"resume" = try parseBool(value) else if (eq(key, "max_tasks")) self.transfer.max_tasks = try parseInt(u8, value) else if (eq(key, "conflict_policy")) self.transfer.conflict_policy = try parseString(value) else return error.UnknownKey;
            },
            .ssh => {
                if (eq(key, "keepalive_sec")) self.ssh.keepalive_sec = try parseInt(u16, value) else if (eq(key, "reconnect_max")) self.ssh.reconnect_max = try parseInt(u8, value) else if (eq(key, "reconnect_backoff")) self.ssh.reconnect_backoff = try parseBackoff(value) else if (eq(key, "connect_timeout_sec")) self.ssh.connect_timeout_sec = try parseInt(u16, value) else if (eq(key, "term")) self.ssh.term = try parseString(value) else if (eq(key, "compression")) self.ssh.compression = try parseBool(value) else if (eq(key, "auto_shell_integration")) self.ssh.auto_shell_integration = try parseBool(value) else if (eq(key, "auto_reconnect")) self.ssh.auto_reconnect = try parseBool(value) else if (eq(key, "buffer_input")) self.ssh.buffer_input = try parseBool(value) else if (eq(key, "socks_port")) self.ssh.socks_port = try parseInt(u16, value) else if (eq(key, "socks_bind")) self.ssh.socks_bind = try parseString(value) else if (eq(key, "otp_modal")) self.ssh.otp_modal = try parseBool(value) else if (eq(key, "totp_autofill")) self.ssh.totp_autofill = try parseBool(value) else return error.UnknownKey;
            },
            .ai => {
                if (eq(key, "extensions")) {
                    const a = allocator orelse return error.RequiresAllocator;
                    const encoded = try parseOwnedString(allocator, value);
                    self.ai.extensions = std.json.parseFromSliceLeaky(ai_extensions.Extensions, a, encoded, .{ .allocate = .alloc_always }) catch return error.InvalidValue;
                } else if (eq(key, "child_context_mode")) self.ai.child_context_mode = std.meta.stringToEnum(ChildContextMode, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "child_reuse_policy")) self.ai.child_reuse_policy = std.meta.stringToEnum(ChildReusePolicy, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "interactive_batch_fallback")) self.ai.interactive_batch_fallback = try parseBool(value) else if (eq(key, "child_max_active")) {
                    self.ai.child_max_active = try parseInt(u8, value);
                    if (self.ai.child_max_active < 1 or self.ai.child_max_active > 16) return error.OutOfRange;
                } else if (eq(key, "child_request_concurrency")) {
                    self.ai.child_request_concurrency = try parseInt(u8, value);
                    if (self.ai.child_request_concurrency < 1 or self.ai.child_request_concurrency > 8) return error.OutOfRange;
                } else if (eq(key, "model_slots")) {
                    self.ai.model_slots = try parseInt(u8, value);
                    if (self.ai.model_slots < 2 or self.ai.model_slots > 8) return error.OutOfRange;
                } else if (eq(key, "swarm_mode_default")) self.ai.swarm_mode_default = std.meta.stringToEnum(SwarmModeDefault, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "swarm_stall_minutes")) {
                    self.ai.swarm_stall_minutes = try parseInt(u8, value);
                    if (self.ai.swarm_stall_minutes < 1 or self.ai.swarm_stall_minutes > 30) return error.OutOfRange;
                } else if (eq(key, "swarm_stall_parent_minutes")) {
                    self.ai.swarm_stall_parent_minutes = try parseInt(u8, value);
                    if (self.ai.swarm_stall_parent_minutes < 1 or self.ai.swarm_stall_parent_minutes > 30) return error.OutOfRange;
                } else if (eq(key, "boost_max_rounds")) {
                    self.ai.boost_max_rounds = try parseInt(u8, value);
                    if (self.ai.boost_max_rounds < 1 or self.ai.boost_max_rounds > 8) return error.OutOfRange;
                } else if (eq(key, "child_role_templates")) {
                    const a = allocator orelse return error.RequiresAllocator;
                    const encoded = try parseOwnedString(allocator, value);
                    const decoded = @import("ai_role_templates.zig").Stored.decode(a, encoded) catch return error.InvalidValue;
                    for (decoded) |template| template.validate() catch return error.InvalidValue;
                    self.ai.child_role_templates = decoded;
                } else if (eq(key, "default_provider")) self.ai.default_provider = try parseString(value) else if (eq(key, "default_effort")) self.ai.default_effort = std.meta.stringToEnum(@import("../ai/provider.zig").Effort, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "permission_mode")) self.ai.permission_mode = std.meta.stringToEnum(PermissionMode, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "execution_mode")) self.ai.execution_mode = ExecutionMode.parse(try parseString(value)) orelse return error.InvalidExecutionMode else if (eq(key, "session_retention")) self.ai.session_retention = std.meta.stringToEnum(SessionRetention, try parseString(value)) orelse return error.InvalidSessionRetention else if (eq(key, "follow_up_mode")) self.ai.follow_up_mode = std.meta.stringToEnum(FollowUpMode, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "step_display")) self.ai.step_display = std.meta.stringToEnum(StepDisplay, try parseString(value)) orelse return error.InvalidValue else if (eq(key, "redact_ip")) self.ai.redact_ip = try parseBool(value) else if (eq(key, "error_hint")) self.ai.error_hint = try parseBool(value) else if (eq(key, "provider_count")) self.ai.provider_count = try parseInt(usize, value) else try self.applyProvider(allocator, key, value);
            },
            .log => {
                if (eq(key, "ring_mb")) self.log.ring_mb = try parseInt(u16, value) else if (eq(key, "checkpoint_sec")) self.log.checkpoint_sec = try parseInt(u16, value) else if (eq(key, "retention_days")) self.log.retention_days = try parseInt(u16, value) else if (eq(key, "export_format")) self.log.export_format = try parseString(value) else return error.UnknownKey;
            },
            .updates => {
                if (eq(key, "auto_check")) self.updates.auto_check = try parseBool(value) else return error.UnknownKey;
            },
            .notify => {
                if (eq(key, "transfer_done")) self.notify.transfer_done = try parseBool(value) else if (eq(key, "reconnect")) self.notify.reconnect = try parseBool(value) else if (eq(key, "ai_ready")) self.notify.ai_ready = try parseBool(value) else if (eq(key, "bell")) self.notify.bell = try parseBool(value) else if (eq(key, "tab_dot")) self.notify.tab_dot = try parseBool(value) else if (eq(key, "quiet_hours")) self.notify.quiet_hours = try parseString(value) else return error.UnknownKey;
            },
            .keys => unreachable,
            .plugin_preferences, .unknown => return error.InvalidSection,
            .none => return error.MissingSection,
        }
    }

    fn applyProvider(self: *Config, allocator: ?std.mem.Allocator, key: []const u8, value: []const u8) ParseError!void {
        // Reject unknown flat fields before allocating from their untrusted indexes.
        if (!isKnownFlatProviderField(key)) return error.UnknownKey;
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
            if (eq(field, "id")) m.id = try parseString(value) else if (eq(field, "context_window")) m.context_window = try parseInt(u32, value) else if (eq(field, "default")) m.default = try parseBool(value) else if (eq(field, "catalog_managed")) m.catalog_managed = try parseBool(value) else if (eq(field, "reasoning")) m.reasoning = try parseBool(value) else if (eq(field, "vision")) m.vision = try parseBool(value) else if (eq(field, "image_token_reservation")) {
                const reservation = try parseInt(u32, value);
                if (reservation == 0 or reservation > 131072) return error.OutOfRange;
                m.image_token_reservation = reservation;
            } else if (eq(field, "image_token_max_width") or eq(field, "image_token_max_height")) {
                const bound = try parseInt(u32, value);
                if (bound == 0 or bound > 8192) return error.OutOfRange;
                if (eq(field, "image_token_max_width")) m.image_token_max_width = bound else m.image_token_max_height = bound;
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
        self.ai.extensions.validate() catch return error.InvalidValue;
        if (self.ai.provider_count > self.ai.providers.len) return error.OutOfRange;
        for (self.ai.providers[0..self.ai.provider_count]) |p| {
            for ([_][]const u8{ p.name, p.endpoint, p.api_key, p.model }) |text| {
                if (std.mem.indexOfAny(u8, text, "\"\\\n\r;#") != null) return error.InvalidValue;
            }
            if (p.model_count > p.models.len) return error.OutOfRange;
            if (p.enabled and p.model_count > 0 and p.endpoint.len == 0) return error.InvalidValue;
            for (p.models[0..p.model_count]) |m| {
                if (std.mem.indexOfAny(u8, m.id, "\"\\\n\r;#") != null) return error.InvalidValue;
                if (m.image_token_reservation) |reservation| if (reservation == 0 or reservation > 131072) return error.OutOfRange;
                if ((m.image_token_max_width == null) != (m.image_token_max_height == null) or (m.image_token_max_width != null and m.image_token_reservation == null)) return error.OutOfRange;
                if (!p.enabled) continue;
                if (m.id.len == 0 or (m.context_window == 0 and !m.catalog_managed)) return error.InvalidValue;
                if (m.reasoning and !m.reasoning_toggle and !m.efforts[0] and !m.efforts[1] and !m.efforts[2] and !m.efforts[3] and !m.efforts[4] and !m.efforts[5] and !m.efforts[6]) return error.InvalidValue;
            }
        }
        if (self.ssh.connect_timeout_sec == 0 or self.ssh.socks_port == 0 or self.transfer.max_tasks == 0 or self.log.retention_days == 0) return error.OutOfRange;
        if (self.ssh.term.len == 0 or !validBind(self.ssh.socks_bind) or !eq(self.transfer.conflict_policy, "ask") or !validQuietHours(self.notify.quiet_hours)) return error.InvalidValue;
        if (!eq(self.log.export_format, "txt") and !eq(self.log.export_format, "cast") and !eq(self.log.export_format, "txt_cast")) return error.InvalidValue;

        if (self.ui.font_size < 8 or self.ui.font_size > 48) return error.OutOfRange;
        if (self.ui.sidebar_width) |width| if (!std.math.isFinite(width) or width < 220 or width > 480) return error.OutOfRange;
        if (!inRange(self.ui.ai_dock_width, 360, 2400) or !inRange(self.ui.mascot_anchor_x, 0, 1) or !inRange(self.ui.mascot_anchor_y, 0, 1)) return error.OutOfRange;
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
pub const Ui = struct { scrollback_limit: u32 = 25000, icon_background: IconBackground = .transparent, theme: []const u8 = "dark", font_family: []const u8 = "Monaco", font_size: u8 = 14, font_weight: []const u8 = "regular", line_height: f32 = 1.5, cursor_style: []const u8 = "bar", sidebar_collapsed: bool = false, sidebar_width: ?f32 = null, ai_dock_width: f32 = 468, ai_dock_preferred: bool = false, mascot_anchor_x: f32 = 1, mascot_anchor_y: f32 = 1, input_line_highlight: bool = true, timestamp_gutter: bool = false, command_info: bool = true, materials: material.Materials = .{} };
pub fn resetDefaults() Config {
    var value: Config = .{};
    value.ui.theme = "sauber";
    return value;
}
pub fn validFontWeight(value: []const u8) bool {
    return @import("font_weight.zig").parse(value) != null;
}
pub fn validCursorStyle(value: []const u8) bool {
    return eq(value, "block") or eq(value, "bar") or eq(value, "underline");
}
pub const Completion = struct { enabled: bool = true };
pub const Transfer = struct { dedicated_connection: bool = false, window_chunks: u8 = 16, chunk_kb: u16 = 64, download_dir: []const u8 = "~/Downloads", verify_md5: bool = false, shared_pacing_kbps: u32 = 2048, @"resume": bool = true, max_tasks: u8 = 3, conflict_policy: []const u8 = "ask" };
pub const Ssh = struct { keepalive_sec: u16 = 30, reconnect_max: u8 = 5, reconnect_backoff: [5]u8 = .{ 1, 2, 4, 8, 16 }, connect_timeout_sec: u16 = 15, term: []const u8 = "xterm-256color", compression: bool = false, auto_shell_integration: bool = true, auto_reconnect: bool = true, buffer_input: bool = true, socks_port: u16 = 1080, socks_bind: []const u8 = "127.0.0.1", otp_modal: bool = true, totp_autofill: bool = false };
pub const PermissionMode = enum { confirm, auto };
/// Command routing is independent of the existing permission approval policy.
pub const ExecutionMode = enum {
    auto,
    ask,
    isolated_exec,
    interactive,

    pub fn parse(value: []const u8) ?ExecutionMode {
        if (eq(value, "attached_pty") or eq(value, "new_pty")) return .interactive;
        return std.meta.stringToEnum(ExecutionMode, value);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ExecutionMode {
        return parse(try std.json.innerParse([]const u8, allocator, source, options)) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !ExecutionMode {
        if (value != .string) return error.UnexpectedToken;
        return parse(value.string) orelse error.InvalidEnumTag;
    }
};
pub const SessionRetention = enum { auto_idle, ask, keep };
pub const ExecutionPolicy = struct { execution_mode: ExecutionMode, session_retention: SessionRetention };

/// Resolve only when preparing a new execution/resource. Existing executions and
/// resources keep their captured policy; changing a default never closes them.
pub fn resolveExecutionPolicy(ai: Ai, execution_mode_override: ?ExecutionMode, session_retention_override: ?SessionRetention) ExecutionPolicy {
    return .{ .execution_mode = execution_mode_override orelse ai.execution_mode, .session_retention = session_retention_override orelse ai.session_retention };
}
pub fn executionModeLabel(mode: ExecutionMode) []const u8 {
    return switch (mode) {
        .auto => "自行判断",
        .ask => "每次询问",
        .isolated_exec => "批处理",
        .interactive => "交互式",
    };
}
pub fn sessionRetentionLabel(retention: SessionRetention) []const u8 {
    return switch (retention) {
        .auto_idle => "空闲后关闭",
        .ask => "每次询问",
        .keep => "保留任务会话",
    };
}
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
    /// Imported from the provider catalog and eligible for automatic replacement.
    catalog_managed: bool = false,
    context_window: u32 = 0,
    default: bool = false,
    reasoning: bool = false,
    /// Discovery-only metadata, never persisted into the user configuration.
    context_discovered: bool = false,
    output_discovered: ?u32 = null,
    reasoning_toggle: bool = false,
    reasoning_discovered: bool = false,
    reasoning_adaptive: bool = false,
    thinking_default: ?bool = null,
    vision: bool = false,
    /// Conservative configured budget for models without a known image token formula.
    image_token_reservation: ?u32 = null,
    image_token_max_width: ?u32 = null,
    image_token_max_height: ?u32 = null,
    efforts: [7]bool = .{ true, true, true, false, false, false, false },
};
pub const default_providers = [_]AiProvider{ .{ .kind = .anthropic }, .{ .kind = .openai_compat }, .{ .kind = .ollama } };
pub const StepDisplay = enum { collapsed, expanded };
pub const FollowUpMode = enum { queue, steer };

pub const ChildContextMode = enum { independent, inherit };
pub const SwarmModeDefault = enum { auto, swarm, boost };
pub const ChildReusePolicy = enum { new, prefer_reuse, model };
pub const Ai = struct {
    child_context_mode: ChildContextMode = .independent,
    child_reuse_policy: ChildReusePolicy = .new,
    /// V0.7 §2.2.3: interactive mode may run a stateless command through batch
    /// execution while the terminal is occupied (default on). Turning this off
    /// restores the strict V0.4 interactive-only rule.
    interactive_batch_fallback: bool = true,
    /// V0.7 §2.3: per-active-root child task budget (1–16). Default keeps the
    /// V0.4 value; the 16 ceiling is a memory guardrail and cannot be exceeded.
    child_max_active: u8 = 4,
    /// V0.7 §2.3: concurrent provider requests per root task (1–8).
    child_request_concurrency: u8 = 2,
    /// V0.7 §2.3: process-level concurrent model request slots (2–8).
    model_slots: u8 = 4,
    /// V0.7 §12.3: session initial swarm mode (auto/swarm/boost).
    swarm_mode_default: SwarmModeDefault = .auto,
    /// V0.7 §12.3: stall level-one threshold in minutes (1–30).
    swarm_stall_minutes: u8 = 3,
    /// V0.7 §12.3: stall level-two threshold in minutes (1–30).
    swarm_stall_parent_minutes: u8 = 2,
    /// V0.7 §12.3: boost chain round ceiling (1–8, declared by parent ≤8).
    boost_max_rounds: u8 = 5,
    /// V0.7 §3.7/§5: custom role templates (JSON on [ai]; the built-in
    /// 均衡 template is implicit and always available).
    child_role_templates: []const @import("ai_role_templates.zig").Stored = &.{},
    extensions: ai_extensions.Extensions = .{},
    follow_up_mode: FollowUpMode = .steer,
    default_provider: []const u8 = "anthropic",
    default_effort: ?@import("../ai/provider.zig").Effort = null,
    permission_mode: PermissionMode = .confirm,
    step_display: StepDisplay = .collapsed,
    execution_mode: ExecutionMode = .auto,
    session_retention: SessionRetention = .auto_idle,
    redact_ip: bool = false,
    error_hint: bool = true,
    /// Legacy backing slots retain protocol identities for flat-key migration.
    /// New installations have no Provider until the user adds one.
    provider_count: usize = 0,
    providers: []AiProvider = @constCast(&default_providers),
};
pub const Log = struct { ring_mb: u16 = 64, checkpoint_sec: u16 = 30, retention_days: u16 = 14, export_format: []const u8 = "txt_cast" };

pub const Updates = struct { auto_check: bool = true };

pub const Notify = struct { transfer_done: bool = false, reconnect: bool = true, ai_ready: bool = false, bell: bool = false, tab_dot: bool = true, quiet_hours: []const u8 = "22:00-08:00" };

const Section = enum { plugin_preferences, unknown, none, meta, ui, @"ui.materials", @"ui.materials.background", completion, transfer, ssh, ai, log, notify, updates, keys };

/// Unknown assignment text borrows the input, just like ordinary parsed strings.
pub const UnknownField = struct {
    line: usize,
    assignment: []const u8,
    section: Section,
    is_section: bool = false,
    provider_index: ?usize = null,
    model_index: ?usize = null,
    preference_index: ?usize = null,
    provider_name: []const u8 = "",
    model_name: []const u8 = "",
    provider_signature: u64 = 0,
    model_signature: u64 = 0,
    provider_name_count: usize = 0,
    provider_signature_count: usize = 0,
    model_name_count: usize = 0,
    model_signature_count: usize = 0,
    preference_plugin_id: []const u8 = "",
    preference_key: []const u8 = "",
};

fn providerSignature(provider: AiProvider) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(provider.name);
    hash.update("\x00");
    hash.update(@tagName(provider.kind));
    hash.update("\x00");
    hash.update(provider.endpoint);
    for (provider.models[0..@min(provider.model_count, provider.models.len)]) |model| {
        hash.update("\x00");
        hash.update(model.id);
    }
    return hash.final();
}

fn modelSignature(model: AiModel) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(model.id);
    hash.update(std.mem.asBytes(&model.context_window));
    return hash.final();
}

fn recordUnknown(
    allocator: ?std.mem.Allocator,
    fields: *std.ArrayList(UnknownField),
    initial: UnknownField,
    key: []const u8,
    value: []const u8,
    text: []const u8,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_number: *usize,
    details: ?*ParseDetails,
    remaining: *[]const u8,
    filtered_keys: *?[]u8,
) ParseError!void {
    if (!validUnknownKey(key)) return error.InvalidAssignment;
    if (value.len == 0) return error.InvalidValue;
    const a = allocator orelse return error.RequiresAllocator;
    var field = initial;
    var scan: UnknownValueScanner = .{};
    try scan.feed(value);
    if (!scan.complete()) {
        if (trim(remaining.*).len != 0 or (scan.quote != 0 and !scan.multiline)) return error.InvalidValue;
        const start = @intFromPtr(initial.assignment.ptr) - @intFromPtr(text.ptr);
        while (lines.next()) |raw| {
            line_number.* += 1;
            if (details) |diagnostic| diagnostic.line = line_number.*;
            scan.comment = false;
            try scan.feed(raw);
            if (scan.complete()) {
                const end = @intFromPtr(raw.ptr) - @intFromPtr(text.ptr) + raw.len;
                field.assignment = text[start..end];
                break;
            }
            if (scan.quote != 0 and !scan.multiline) return error.InvalidValue;
        }
        if (!scan.complete()) return error.InvalidValue;
    }
    // A literal "[keys]" in a multi-line unknown value is not a section.
    if (std.mem.indexOfScalar(u8, field.assignment, '\n') != null) {
        if (filtered_keys.* == null) filtered_keys.* = a.dupe(u8, text) catch return error.OutOfMemory;
        const start = @intFromPtr(field.assignment.ptr) - @intFromPtr(text.ptr);
        const end = start + field.assignment.len;
        for (filtered_keys.*.?[start..end]) |*byte| if (byte.* != '\n') {
            byte.* = ' ';
        };
    }
    fields.append(a, field) catch return error.OutOfMemory;
}

const UnknownValueScanner = struct {
    stack: [128]u8 = undefined,
    depth: usize = 0,
    quote: u8 = 0,
    multiline: bool = false,
    escaped: bool = false,
    comment: bool = false,
    terminal: bool = false,

    fn complete(self: UnknownValueScanner) bool {
        return self.depth == 0 and self.quote == 0;
    }

    fn feed(self: *UnknownValueScanner, input: []const u8) ParseError!void {
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const byte = input[i];
            if (self.comment) continue;
            if (self.quote != 0) {
                if (self.quote == '"' and !self.escaped and byte == '\\') {
                    self.escaped = true;
                    continue;
                }
                if (!self.escaped and byte == self.quote) {
                    if (self.multiline) {
                        if (i + 2 < input.len and input[i + 1] == byte and input[i + 2] == byte) {
                            self.quote = 0;
                            self.multiline = false;
                            i += 2;
                            if (self.depth == 0) self.terminal = true;
                        }
                    } else {
                        self.quote = 0;
                        if (self.depth == 0) self.terminal = true;
                    }
                }
                self.escaped = false;
                continue;
            }
            if (byte == '#') {
                self.comment = true;
                continue;
            }
            if (byte == ' ' or byte == '\t' or byte == '\r') continue;
            if (self.terminal) return error.InvalidValue;
            if (byte == '"' or byte == '\'') {
                self.quote = byte;
                self.multiline = i + 2 < input.len and input[i + 1] == byte and input[i + 2] == byte;
                if (self.multiline) i += 2;
            } else if (byte == '[' or byte == '{') {
                if (self.depth == self.stack.len) return error.InvalidValue;
                self.stack[self.depth] = byte;
                self.depth += 1;
            } else if (byte == ']' or byte == '}') {
                if (self.depth == 0 or (byte == ']' and self.stack[self.depth - 1] != '[') or (byte == '}' and self.stack[self.depth - 1] != '{')) return error.InvalidValue;
                self.depth -= 1;
                if (self.depth == 0) self.terminal = true;
            }
        }
    }
};

fn validUnknownKey(key: []const u8) bool {
    var i: usize = 0;
    while (true) {
        while (i < key.len and (key[i] == ' ' or key[i] == '\t')) : (i += 1) {}
        if (i == key.len) return false;
        if (key[i] == '"' or key[i] == '\'') {
            const quote = key[i];
            i += 1;
            var closed = false;
            while (i < key.len) : (i += 1) {
                if (key[i] < 0x20 or key[i] == 0x7f) return false;
                if (quote == '"' and key[i] == '\\') {
                    i += 1;
                    if (i == key.len or std.mem.indexOfScalar(u8, "\"\\btnfruU", key[i]) == null) return false;
                    continue;
                }
                if (key[i] == quote) {
                    i += 1;
                    closed = true;
                    break;
                }
            }
            if (!closed) return false;
        } else {
            const start = i;
            while (i < key.len and (std.ascii.isAlphanumeric(key[i]) or key[i] == '_' or key[i] == '-')) : (i += 1) {}
            if (i == start) return false;
        }
        while (i < key.len and (key[i] == ' ' or key[i] == '\t')) : (i += 1) {}
        if (i == key.len) return true;
        if (key[i] != '.') return false;
        i += 1;
    }
}

const UnknownSectionScope = enum { independent, provider, model, preference };

fn unknownSectionField(line: usize, assignment: []const u8, scope: UnknownSectionScope, provider: ?usize, model: ?usize, preference: ?usize, is_section: bool) UnknownField {
    return .{
        .line = line,
        .assignment = assignment,
        .section = .unknown,
        .is_section = is_section,
        .provider_index = if (scope == .provider or scope == .model) provider else null,
        .model_index = if (scope == .model) model else null,
        .preference_index = if (scope == .preference) preference else null,
    };
}

fn unknownSectionScope(line: []const u8) ?UnknownSectionScope {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const array = line.len >= 4 and line[1] == '[';
    if (array and line[line.len - 2] != ']') return null;
    const name = trim(if (array) line[2 .. line.len - 2] else line[1 .. line.len - 1]);
    if (!validUnknownKey(name)) return null;
    var segments: [4][]const u8 = @splat("");
    var count: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        while (i < name.len and (name[i] == ' ' or name[i] == '\t')) : (i += 1) {}
        const quoted = name[i] == '"' or name[i] == '\'';
        const quote: u8 = if (quoted) name[i] else 0;
        if (quoted) i += 1;
        const start = i;
        while (i < name.len and (if (quoted) name[i] != quote else name[i] != '.' and name[i] != ' ' and name[i] != '\t')) : (i += 1) {
            // Escaped table segments require full TOML decoding to classify.
            if (quoted and name[i] == '\\') return null;
        }
        if (count < segments.len) segments[count] = name[start..i];
        count += 1;
        if (quoted) i += 1;
        while (i < name.len and (name[i] == ' ' or name[i] == '\t')) : (i += 1) {}
        if (i < name.len) i += 1; // dot, validated above
    }
    const first = segments[0];
    const second = segments[1];
    const third = segments[2];
    if (eq(first, "ai") and count > 1 and eq(second, "providers")) {
        if (count == 2) return null;
        if (eq(third, "models")) return if (count > 3) .model else null;
        return .provider;
    }
    if (eq(first, "plugin_preferences")) return if (count > 1) .preference else null;
    if (count == 1 and std.mem.indexOfScalar(u8, first, '.') == null) {
        if (std.meta.stringToEnum(Section, first)) |section| {
            if (section != .unknown and section != .none) return null;
        }
    }
    if (eq(first, "ui") and count >= 2 and eq(second, "materials") and (count == 2 or (count == 3 and eq(third, "background")))) return null;
    return .independent;
}

fn isKnownProviderField(key: []const u8, model: bool) bool {
    const provider_fields = [_][]const u8{ "id", "name", "kind", "endpoint", "api_key", "api_key_ref", "enabled", "model_count" };
    const model_fields = [_][]const u8{ "id", "name", "context_window", "default", "catalog_managed", "reasoning", "vision", "image_token_reservation", "image_token_max_width", "image_token_max_height", "efforts" };
    const fields: []const []const u8 = if (model) &model_fields else &provider_fields;
    for (fields) |field| if (eq(key, field)) return true;
    if (!model and std.mem.startsWith(u8, key, "model_")) {
        const rest = key[6..];
        const split = std.mem.indexOfScalar(u8, rest, '_') orelse return false;
        if (split == 0) return false;
        for (rest[0..split]) |byte| if (!std.ascii.isDigit(byte)) return false;
        return isKnownProviderField(rest[split + 1 ..], true) and !eq(rest[split + 1 ..], "name");
    }
    return false;
}

fn isKnownFlatProviderField(key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "provider_")) return false;
    const rest = key[9..];
    const sep = std.mem.indexOfScalar(u8, rest, '_') orelse return false;
    if (sep == 0) return false;
    for (rest[0..sep]) |byte| if (!std.ascii.isDigit(byte)) return false;
    const suffix = rest[sep + 1 ..];
    if (isKnownProviderField(suffix, false) and !eq(suffix, "id")) return true;
    if (!std.mem.startsWith(u8, suffix, "model_")) return false;
    const model = suffix[6..];
    const split = std.mem.indexOfScalar(u8, model, '_') orelse return false;
    if (split == 0) return false;
    for (model[0..split]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return isKnownProviderField(model[split + 1 ..], true) and !eq(model[split + 1 ..], "name");
}

pub const ParseError = error{ InvalidSection, InvalidAssignment, InvalidValue, InvalidExecutionMode, InvalidSessionRetention, UnknownKey, MissingSection, OutOfRange, Overflow, RequiresAllocator, OutOfMemory };

fn parseSection(line: []const u8) ParseError!Section {
    if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSection;
    const section = std.meta.stringToEnum(Section, line[1 .. line.len - 1]) orelse return error.InvalidSection;
    if (section == .unknown or section == .none or section == .plugin_preferences) return error.InvalidSection;
    return section;
}
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (quote == '"' and !escaped and byte == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and quote == 0 and (byte == '"' or byte == '\'')) quote = byte else if (!escaped and quote != 0 and byte == quote) quote = 0;
        if (quote == 0 and byte == '#') return line[0..index];
        escaped = false;
    }
    return line;
}
fn nextAssignment(remaining: *[]const u8) ?[]const u8 {
    if (remaining.len == 0) return null;
    const text = remaining.*;
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (quote == '"' and !escaped and byte == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and quote == 0 and (byte == '"' or byte == '\'')) quote = byte else if (!escaped and quote != 0 and byte == quote) quote = 0;
        if (quote == 0 and byte == ';') {
            remaining.* = text[index + 1 ..];
            return text[0..index];
        }
        escaped = false;
    }
    remaining.* = "";
    return text;
}
fn assignmentSeparator(pair: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    for (pair, 0..) |byte, index| {
        if (quote == '"' and !escaped and byte == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and quote == 0 and (byte == '"' or byte == '\'')) quote = byte else if (!escaped and quote != 0 and byte == quote) quote = 0;
        if (quote == 0 and byte == '=') return index;
        escaped = false;
    }
    return null;
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
fn inRange(value: f32, min: f32, max: f32) bool {
    return std.math.isFinite(value) and value >= min and value <= max;
}
fn parseBoundedFloat(value: []const u8, min: f32, max: f32) ParseError!f32 {
    const number = try parseFloat(value);
    if (!inRange(number, min, max)) return error.OutOfRange;
    return number;
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
    var buffer: [4096]u8 = undefined;
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
test "auto shell integration global defaults on and persists off" {
    try std.testing.expect((try Config.parse("")).ssh.auto_shell_integration);
    const configured = try Config.parse("[ssh]\nauto_shell_integration = false\n");
    var buffer: [8192]u8 = undefined;
    const reloaded = try Config.parse(try configured.format(&buffer));
    try std.testing.expect(!reloaded.ssh.auto_shell_integration);
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
    try std.testing.expectEqual(@as(usize, 1), old.ai.provider_count);
    try std.testing.expectEqual(ProviderKind.openai_compat, old.ai.providers[0].kind);
    try std.testing.expectEqualStrings("https://gateway.example.test/v1", old.ai.providers[0].endpoint);
    var buffer: [8192]u8 = undefined;
    const written = try old.format(&buffer);
    const loaded = try Config.parseWithAllocator(arena.allocator(), written);
    try std.testing.expectEqual(@as(usize, 1), loaded.ai.provider_count);
    try std.testing.expectEqualStrings(old.ai.providers[0].endpoint, loaded.ai.providers[0].endpoint);
}

test "automatic catalog models round trip while missing context stays unknown" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        "[ai]\ndefault_provider=\"catalog\"\n[[ai.providers]]\nid=\"catalog\"\n" ++
        "endpoint=\"http://127.0.0.1:9/v1\"\nenabled=true\n" ++
        "[[ai.providers.models]]\nname=\"remote-model\"\ncontext_window=0\ndefault=true\n";
    try std.testing.expectError(error.InvalidValue, Config.parseWithAllocator(a, source));
    const value = try Config.parseWithAllocator(a, source ++ "catalog_managed=true\n");
    var buffer: [8192]u8 = undefined;
    const restored = try Config.parseWithAllocator(a, try value.format(&buffer));
    const model = restored.ai.providers[0].models[0];
    try std.testing.expect(model.catalog_managed);
    try std.testing.expectEqual(@as(u32, 0), model.context_window);
    try std.testing.expectError(error.InvalidContextWindow, @import("../ai/provider_config.zig").fromSettings(restored.ai));
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

test "terminal scrollback default and unlimited survive config serialization" {
    try std.testing.expectEqual(@as(u32, 25000), (Config{}).ui.scrollback_limit);
    for ([_]u32{ 0, 25000, 100000 }) |limit| {
        var config_value: Config = .{};
        config_value.ui.scrollback_limit = limit;
        var buffer: [32768]u8 = undefined;
        const encoded = try config_value.format(&buffer);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const decoded = try Config.parseWithAllocator(arena.allocator(), encoded);
        try std.testing.expectEqual(limit, decoded.ui.scrollback_limit);
    }
}

test "execution policy defaults migrate legacy config and invalid values fail explicitly" {
    const legacy = try Config.parse("[ai]\npermission_mode = \"auto\"\n");
    try std.testing.expectEqual(PermissionMode.auto, legacy.ai.permission_mode);
    try std.testing.expectEqual(ExecutionMode.auto, legacy.ai.execution_mode);
    try std.testing.expectEqual(SessionRetention.auto_idle, legacy.ai.session_retention);
    inline for (.{ "attached_pty", "new_pty" }) |mode| {
        const from_toml = try Config.parse("[ai]\nexecution_mode = \"" ++ mode ++ "\"\n");
        try std.testing.expectEqual(ExecutionMode.interactive, from_toml.ai.execution_mode);
        const from_history = try std.json.parseFromSlice(struct { execution_mode: ?ExecutionMode }, std.testing.allocator, "{\"execution_mode\":\"" ++ mode ++ "\"}", .{});
        defer from_history.deinit();
        try std.testing.expectEqual(ExecutionMode.interactive, from_history.value.execution_mode.?);
    }
    try std.testing.expectError(error.InvalidExecutionMode, Config.parse("[ai]\nexecution_mode = \"unsafe\"\n"));
    try std.testing.expectError(error.InvalidSessionRetention, Config.parse("[ai]\nsession_retention = \"always_close\"\n"));
}

test "execution policy modes and retention round trip separately from permissions" {
    inline for (@typeInfo(ExecutionMode).@"enum".field_names) |name| {
        var value: Config = .{};
        value.ai.execution_mode = @field(ExecutionMode, name);
        value.ai.session_retention = .keep;
        var buffer: [16384]u8 = undefined;
        const encoded = try value.format(&buffer);
        const decoded = try Config.parse(encoded);
        try std.testing.expectEqual(value.ai.execution_mode, decoded.ai.execution_mode);
        try std.testing.expectEqual(SessionRetention.keep, decoded.ai.session_retention);
        try std.testing.expectEqual(PermissionMode.confirm, decoded.ai.permission_mode);
    }
    const defaults: Ai = .{ .execution_mode = .isolated_exec, .session_retention = .ask };
    const frozen = resolveExecutionPolicy(defaults, null, .keep);
    try std.testing.expectEqual(ExecutionMode.isolated_exec, frozen.execution_mode);
    try std.testing.expectEqual(SessionRetention.keep, frozen.session_retention);
    try std.testing.expectEqual(ExecutionMode.interactive, resolveExecutionPolicy(.{}, .interactive, null).execution_mode);
    try std.testing.expectEqual(ExecutionMode.isolated_exec, frozen.execution_mode);
}

test "command info defaults enabled and persists the visual opt out" {
    try std.testing.expect((try Config.parse("")).ui.command_info);
    const configured = try Config.parse("[ui]\ncommand_info = false\n");
    var bytes: [16 * 1024]u8 = undefined;
    const reloaded = try Config.parse(try configured.format(&bytes));
    try std.testing.expect(!reloaded.ui.command_info);
    try std.testing.expect(reloaded.ssh.auto_shell_integration);
    try std.testing.expect(!reloaded.ui.timestamp_gutter);
}

test "AI step aggregation config defaults collapsed and persists both display choices" {
    const legacy = try Config.parse("[ai]\npermission_mode = \"confirm\"\n");
    try std.testing.expectEqual(StepDisplay.collapsed, legacy.ai.step_display);
    inline for (@typeInfo(StepDisplay).@"enum".field_names) |name| {
        var value: Config = .{};
        value.ai.step_display = @field(StepDisplay, name);
        var buffer: [16384]u8 = undefined;
        const decoded = try Config.parse(try value.format(&buffer));
        try std.testing.expectEqual(value.ai.step_display, decoded.ai.step_display);
    }
    try std.testing.expectError(error.InvalidValue, Config.parse("[ai]\nstep_display = \"sometimes\"\n"));
}

test "efficiency bounded image calibration validates and roundtrips paired dimensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prefix = "[[ai.providers]]\nid=\"calibrated\"\nkind=\"openai_compat\"\nendpoint=\"http://127.0.0.1:3425/v1\"\n[[ai.providers.models]]\nname=\"grok/grok-4.7@500k\"\ncontext_window=500000\nvision=true\nimage_token_reservation=8192\n";
    const configured = try Config.parseWithAllocator(arena.allocator(), prefix ++ "image_token_max_width=1920\nimage_token_max_height=1200\n");
    try configured.validate();
    var buffer: [65536]u8 = undefined;
    const wire = try configured.format(&buffer);
    const restored = try Config.parseWithAllocator(arena.allocator(), wire);
    try std.testing.expectEqual(@as(?u32, 1920), restored.ai.providers[0].models[0].image_token_max_width);
    try std.testing.expectEqual(@as(?u32, 1200), restored.ai.providers[0].models[0].image_token_max_height);
    try std.testing.expectError(error.OutOfRange, Config.parseWithAllocator(arena.allocator(), prefix ++ "image_token_max_width=1920\n"));
}

test "unknown fields preserve their owning sections and entities" {
    const source =
        "[ui]\nfont_size=17\nfuture_ui = [1, 2, 3]\n" ++
        "[ui.materials]\nfuture_blur = { strength = 1 }\n" ++
        "[ai]\nprovider_999999999999999999999_future = 5\n" ++
        "[[ai.providers]]\nid=\"first\"\nprovider_future=\"first-value\"\n" ++
        "[[ai.providers.models]]\nname=\"first-model\"\nmodel_future=true\n" ++
        "[[ai.providers]]\nid=\"second\"\nprovider_future=\"second-value\"\n" ++
        "[[plugin_preferences]]\nplugin_id=\"plugin.one\"\nkey=\"setting\"\nvalue=\"one\"\npreference_future=42\n" ++
        "[keys]\nfuture_action=\"cmd+shift+u\"\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var details: ParseDetails = .{ .allow_unknown = true };
    var parsed = try Config.parseWithDetails(allocator, source, &details);
    try std.testing.expectEqual(@as(u8, 17), parsed.ui.font_size);
    try std.testing.expectEqual(@as(usize, 8), parsed.unknown_fields.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.unknown_fields[0].line);
    // Moving a provider must not move its future settings to the other one.
    std.mem.reverse(AiProvider, parsed.ai.providers);
    var buffer: [16384]u8 = undefined;
    const encoded = try parsed.format(&buffer);
    var again_details: ParseDetails = .{ .allow_unknown = true };
    const again = try Config.parseWithDetails(allocator, encoded, &again_details);
    try std.testing.expectEqual(@as(usize, 8), again.unknown_fields.len);
    for (again.unknown_fields) |field| {
        if (eq(field.assignment, "provider_future=\"first-value\"")) try std.testing.expectEqualStrings("first", field.provider_name);
        if (eq(field.assignment, "provider_future=\"second-value\"")) try std.testing.expectEqualStrings("second", field.provider_name);
        if (eq(field.assignment, "model_future=true")) {
            try std.testing.expectEqualStrings("first", field.provider_name);
            try std.testing.expectEqualStrings("first-model", field.model_name);
        }
        if (eq(field.assignment, "preference_future=42")) {
            try std.testing.expectEqualStrings("plugin.one", field.preference_plugin_id);
            try std.testing.expectEqualStrings("setting", field.preference_key);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, encoded, "future_ui = [1, 2, 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "future_action=\"cmd+shift+u\"") != null);
}

test "unknown fields do not hide malformed known settings or guess deleted owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var details: ParseDetails = .{ .allow_unknown = true };
    try std.testing.expectError(error.InvalidAssignment, Config.parseWithDetails(allocator, "[ui]\nmissing_equals\n", &details));
    try std.testing.expectError(error.InvalidAssignment, Config.parseWithDetails(allocator, "[ui]\nbad field = 3\n", &details));
    try std.testing.expectError(error.InvalidValue, Config.parseWithDetails(allocator, "[ui]\nfont_size = false\n", &details));
    try std.testing.expectError(error.InvalidValue, Config.parseWithDetails(allocator, "[ui]\nfuture = \n", &details));
    const source = "[[ai.providers]]\nid=\"old\"\nfuture=true\n";
    var parsed = try Config.parseWithDetails(allocator, source, &details);
    parsed.ai.providers[0].name = "replacement";
    var buffer: [8192]u8 = undefined;
    try std.testing.expectError(error.MissingUnknownFieldOwner, parsed.format(&buffer));
}

test "unknown field clone owns assignment and entity identity" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const source_allocator = source_arena.allocator();
    const text = try source_allocator.dupe(u8, "[[ai.providers]]\nid=\"provider\"\nfuture=\"value\"\n");
    var details: ParseDetails = .{ .allow_unknown = true };
    const parsed = try Config.parseWithDetails(source_allocator, text, &details);
    var destination_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer destination_arena.deinit();
    var destination: Config = .{};
    try destination.cloneUnknownFields(destination_arena.allocator(), parsed.unknown_fields);
    source_arena.deinit();
    try std.testing.expectEqualStrings("future=\"value\"", destination.unknown_fields[0].assignment);
    try std.testing.expectEqualStrings("provider", destination.unknown_fields[0].provider_name);
}

test "unknown fields in independent tables and multiline values round trip" {
    const source =
        "[future]\noptions = [\n  \"alpha#beta\", # comment\n  { tag = 'semi;#colon' },\n]\n" ++
        "\"key=with=equals\" = 'a#b'\n" ++
        "[[future.workers]]\nname=\"first\"\n[[future.workers]]\nname=\"second\"\n" ++
        "[unknown]\nvalue = \"\"\"\n[keys]\nnot_a_shortcut = bad\n\"\"\"\n" ++
        "[ui]\nfont_size=17\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var details: ParseDetails = .{ .allow_unknown = true };
    const parsed = try Config.parseWithDetails(arena.allocator(), source, &details);
    try std.testing.expectEqual(@as(u8, 17), parsed.ui.font_size);
    var buffer: [16384]u8 = undefined;
    const encoded = try parsed.format(&buffer);
    var again_details: ParseDetails = .{ .allow_unknown = true };
    const again = try Config.parseWithDetails(arena.allocator(), encoded, &again_details);
    try std.testing.expectEqual(parsed.unknown_fields.len, again.unknown_fields.len);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "[future]\noptions = [\n  \"alpha#beta\", # comment\n  { tag = 'semi;#colon' },\n]") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "[keys]\nnot_a_shortcut = bad\n\"\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"key=with=equals\" = 'a#b'") != null);
    try std.testing.expectError(error.InvalidValue, Config.parseWithDetails(arena.allocator(), "[ui]\nfuture = [1\n", &details));
    try std.testing.expectError(error.InvalidSection, Config.parseWithDetails(arena.allocator(), "[future\nvalue=1\n", &details));
}

test "unknown fields allow unchanged duplicate and empty entity names" {
    const source =
        "[[ai.providers]]\nid=\"\"\nfirst_future=true\n" ++
        "[[ai.providers]]\nid=\"\"\nsecond_future=true\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var details: ParseDetails = .{ .allow_unknown = true };
    var parsed = try Config.parseWithDetails(arena.allocator(), source, &details);
    var buffer: [16384]u8 = undefined;
    const encoded = try parsed.format(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "first_future=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "second_future=true") != null);
    parsed.ai.provider_count = 1;
    try std.testing.expectError(error.AmbiguousUnknownFieldOwner, parsed.format(&buffer));
}

test "unknown fields preserve top-level keys and nested provider tables" {
    const source =
        "future_top=true\n" ++
        "[[ai.providers]]\nid=\"one\"\n" ++
        "[ai.providers.future]\nprovider_flag=1\n" ++
        "[[ai.providers.future.extra]]\nentry=\"owned-by-one\"\n" ++
        "[[ai.providers.models]]\nname=\"model-one\"\n" ++
        "[ai.providers.models.future]\nmodel_flag=2\n" ++
        "[standalone]\nflag=true\n" ++
        "[ai.providers.models.more]\nmore_flag=3\n" ++
        "[[ai.providers]]\nid=\"two\"\n" ++
        "[ai.providers.future]\nprovider_flag=4\n" ++
        "[[plugin_preferences]]\nplugin_id=\"plugin.id\"\nkey=\"option\"\nvalue=\"v\"\n" ++
        "[plugin_preferences.future]\npreference_flag=5\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var details: ParseDetails = .{ .allow_unknown = true };
    var parsed = try Config.parseWithDetails(arena.allocator(), source, &details);
    try std.testing.expectEqual(@as(usize, 2), parsed.ai.provider_count);
    try std.testing.expectEqualStrings("one", parsed.ai.providers[0].name);
    try std.testing.expectEqualStrings("two", parsed.ai.providers[1].name);
    std.mem.reverse(AiProvider, parsed.ai.providers);
    var buffer: [16384]u8 = undefined;
    const encoded = try parsed.format(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "future_top=true\n[meta]"));
    var again_details: ParseDetails = .{ .allow_unknown = true };
    const again = try Config.parseWithDetails(arena.allocator(), encoded, &again_details);
    try std.testing.expectEqual(@as(usize, 2), again.ai.provider_count);
    for (again.unknown_fields) |field| {
        if (eq(field.assignment, "provider_flag=1") or eq(field.assignment, "entry=\"owned-by-one\"")) try std.testing.expectEqualStrings("one", field.provider_name);
        if (eq(field.assignment, "provider_flag=4")) try std.testing.expectEqualStrings("two", field.provider_name);
        if (eq(field.assignment, "model_flag=2") or eq(field.assignment, "more_flag=3")) {
            try std.testing.expectEqualStrings("one", field.provider_name);
            try std.testing.expectEqualStrings("model-one", field.model_name);
        }
        if (eq(field.assignment, "preference_flag=5")) try std.testing.expectEqualStrings("plugin.id", field.preference_plugin_id);
    }
    try std.testing.expectError(error.InvalidSection, Config.parseWithDetails(arena.allocator(), "[ai.providers.future]\nflag=true\n", &details));
    try std.testing.expectError(error.MissingSection, Config.parse("future_top=true\n"));
}
