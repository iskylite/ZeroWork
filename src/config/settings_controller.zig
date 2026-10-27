const std = @import("std");
const config = @import("config.zig");
const settings = @import("settings_model.zig");
const values = @import("settings_values.zig");
const view = @import("settings_view.zig");
const runtime = @import("runtime_config.zig");
const material = @import("background_asset.zig");
const themes = @import("theme_registry.zig");
const window_policy = @import("../transfer/window_policy.zig");
pub const schema = @import("settings_schema.zig");
pub const plugins = @import("plugin_page.zig");
pub const ai_draft = @import("settings_ai_draft.zig");

pub const State = enum { clean, dirty_valid, dirty_invalid, saving, save_failed };
pub const CloseDecision = enum { allow, confirmation_required, blocked_saving };
pub const RawField = struct { input: ?[]u8 = null, problem: ?anyerror = null };

pub const SaveRequest = struct {
    draft_id: u64,
    operation_id: u64,
    baseline_revision: u64,
    close_after_save: bool,
    prepared: runtime.Prepared,
    baseline: ?runtime.Snapshot,

    pub fn deinit(self: *SaveRequest) void {
        self.prepared.deinit();
        if (self.baseline) |*baseline| baseline.deinit();
        self.* = undefined;
    }
};

var next_draft_id: std.atomic.Value(u64) = .init(1);

fn allocateDraftId() !u64 {
    var current = next_draft_id.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.DraftIdExhausted;
        if (next_draft_id.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| current = observed else return current;
    }
}

pub const Controller = struct {
    model: settings.Model,
    allocator: std.mem.Allocator,
    original: runtime.Snapshot,
    draft: ?runtime.Snapshot = null,
    last_error: ?[]const u8 = null,
    transfer_save_problem: ?anyerror = null,
    draft_id: u64,
    dirty_fields: schema.FieldSet = .empty,
    raw_fields: [schema.fields.len]RawField = @splat(.{}),
    ai_fields: ai_draft.State = .{},
    save_operation: ?u64 = null,
    next_save_operation: u64 = 1,
    save_failed: bool = false,
    close_after_save: bool = false,
    close_ready: bool = false,
    search_query: []const u8 = "",
    search_return_page: ?usize = null,
    scroll_offsets: [8]f32 = @splat(0),
    folded_sections: u64 = std.math.maxInt(u64) & ~(@as(u64, 1) | (@as(u64, 1) << 3) | (@as(u64, 1) << 4) | (@as(u64, 1) << 8) | (@as(u64, 1) << 16) | (@as(u64, 1) << 48) | (@as(u64, 1) << 56)),
    plugin_page: plugins.State,
    background: material.Draft,
    theme_library: themes.LibraryState,
    next_theme_operation: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, value: config.Config) !Controller {
        const id = try allocateDraftId();
        const original = try runtime.Snapshot.init(allocator, value);
        return .{ .allocator = allocator, .draft_id = id, .original = original, .model = .{ .value = original.value, .original = original.value }, .plugin_page = plugins.State.init(@import("../host/plugin_registry.zig").Registry.builtins(), value.config_revision), .background = .{ .draft_id = id }, .theme_library = .{ .draft_id = id, .saved_theme_id = original.value.ui.theme, .draft_theme_id = original.value.ui.theme, .selected_id = original.value.ui.theme, .registry_revision = 0 } };
    }

    pub fn deinit(self: *Controller) void {
        self.clearRaw();
        self.ai_fields.deinit(self.allocator);
        if (self.search_query.len != 0) self.allocator.free(self.search_query);
        if (self.draft) |*draft| draft.deinit();
        self.original.deinit();
        self.background.deinit(self.allocator);
        self.theme_library.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn snapshot(self: Controller) !view.Snapshot {
        return view.snapshot(self.allocator, self.model);
    }

    /// All UI edits enter here instead of assigning borrowed Input slices
    /// directly to model.value. Validate and copy before releasing the old draft.
    pub fn setPluginPreference(self: *Controller, plugin_id: []const u8, key: []const u8, value: []const u8) !void {
        try self.ensureEditable();
        const manifest = self.plugin_page.registry_source.find(plugin_id) orelse return error.UnknownPlugin;
        const section = manifest.settings_section orelse return error.UnknownKey;
        var found = false;
        for (section.fields) |field| if (std.mem.eql(u8, field.key, key)) {
            found = true;
            switch (field.kind) {
                .boolean => if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidValue,
                .string => {},
                .choice => {
                    var matched = false;
                    for (field.options) |option| if (std.mem.eql(u8, option.value, value)) {
                        matched = true;
                        break;
                    };
                    if (!matched) return error.InvalidValue;
                },
            }
            break;
        };
        if (!found) return error.UnknownKey;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var candidate = self.model.value;
        try candidate.putPluginPreference(arena.allocator(), plugin_id, key, value);
        try candidate.validate();
        const owned = try runtime.Snapshot.init(self.allocator, candidate);
        if (self.draft) |*previous| previous.deinit();
        self.draft = owned;
        self.model.value = owned.value;
        self.last_error = null;
        self.refreshDirty();
    }

    pub fn editKey(self: *Controller, section: []const u8, key: []const u8, next: values.Value) !void {
        try self.ensureEditable();
        const background_path = std.mem.eql(u8, section, "ui.materials.background") and std.mem.eql(u8, key, "path");
        if (background_path and self.background.asset_revision == std.math.maxInt(u64)) return error.AssetRevisionExhausted;
        const index = schema.find(section, key) orelse return error.UnknownKey;
        const raw = switch (next) {
            .text => |text| try self.allocator.dupe(u8, text),
            .boolean => |boolean| try self.allocator.dupe(u8, if (boolean) "true" else "false"),
            .unsigned => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
            .decimal => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
        };
        self.replaceRaw(index, raw);
        self.last_error = null;
        const owned_next: values.Value = if (next == .text) .{ .text = raw } else next;
        self.applyEdit(section, key, owned_next) catch |err| {
            self.raw_fields[index].problem = err;
            self.last_error = @errorName(err);
            self.refreshDirty();
            return err;
        };
        self.refreshDirty();
        if (background_path) _ = try self.background.select(self.model.value.ui.materials.background.path);
    }

    /// Retains even an unparseable edit while typed_values/effective preview
    /// keep their last valid value. Navigation never creates a second draft.
    pub fn editRaw(self: *Controller, section: []const u8, key: []const u8, input: []const u8) !void {
        try self.ensureEditable();
        const background_path = std.mem.eql(u8, section, "ui.materials.background") and std.mem.eql(u8, key, "path");
        if (background_path and self.background.asset_revision == std.math.maxInt(u64)) return error.AssetRevisionExhausted;
        const index = schema.find(section, key) orelse return error.UnknownKey;
        const owned = try self.allocator.dupe(u8, input);
        self.replaceRaw(index, owned);
        const text = std.mem.trim(u8, owned, " \t");
        const current = values.read(self.model.value, section, key) orelse return error.UnknownKey;
        const next: values.Value = switch (current) {
            .text => .{ .text = owned },
            .boolean => .{ .boolean = if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else return self.invalidRaw(index, error.InvalidValue) },
            .unsigned => .{ .unsigned = std.fmt.parseInt(u32, text, 10) catch return self.invalidRaw(index, error.InvalidValue) },
            .decimal => .{ .decimal = std.fmt.parseFloat(f32, text) catch return self.invalidRaw(index, error.InvalidValue) },
        };
        self.applyEdit(section, key, next) catch |err| return self.invalidRaw(index, err);
        self.last_error = null;
        self.refreshDirty();
        if (background_path) _ = try self.background.select(self.model.value.ui.materials.background.path);
    }

    fn invalidRaw(self: *Controller, index: usize, err: anyerror) anyerror {
        self.raw_fields[index].problem = err;
        self.last_error = @errorName(err);
        self.refreshDirty();
        return err;
    }

    fn replaceRaw(self: *Controller, index: usize, owned: []u8) void {
        if (self.raw_fields[index].input) |old| self.allocator.free(old);
        self.raw_fields[index] = .{ .input = owned };
        if (transferPolicyField(index)) self.transfer_save_problem = null;
        self.save_failed = false;
    }

    fn clearRaw(self: *Controller) void {
        for (&self.raw_fields) |*field| {
            if (field.input) |input| self.allocator.free(input);
            field.* = .{};
        }
        self.ai_fields.clearRaw(self.allocator);
        self.transfer_save_problem = null;
    }

    fn ensureEditable(self: *Controller) !void {
        if (self.save_operation != null) return error.SettingsBusy;
    }

    pub fn refreshDirty(self: *Controller) void {
        self.dirty_fields = schema.changed(self.original.value, self.model.value);
        for (self.raw_fields, 0..) |field, index| if (field.problem != null) self.dirty_fields.set(index);
        if (self.ai_fields.invalid()) self.dirty_fields.set(schema.providers_index);
        self.model.dirty = self.dirty_fields.count() != 0;
        self.theme_library.saved_theme_id = self.original.value.ui.theme;
        self.theme_library.draft_theme_id = self.model.value.ui.theme;
        self.theme_library.selected_id = self.model.value.ui.theme;
    }

    pub fn state(self: *const Controller) State {
        if (self.save_operation != null) return .saving;
        for (self.raw_fields, 0..) |field, index| if (field.problem != null and self.fieldApplicable(index)) return .dirty_invalid;
        if (self.transferPolicyProblem() != null) return .dirty_invalid;
        if (self.ai_fields.invalid()) return .dirty_invalid;
        if (self.dirty_fields.isSet(schema.providers_index) or self.dirty_fields.isSet(schema.find("ai", "default_provider").?)) {
            ai_draft.validate(self.model.value.ai) catch return .dirty_invalid;
            ai_draft.validateDefault(self.model.value.ai, self.original.value.ai) catch return .dirty_invalid;
        }
        if (self.ai_fields.new_provider) |i| if (i >= self.model.value.ai.provider_count or !ai_draft.eligible(self.model.value.ai.providers[i])) return .dirty_invalid;
        if (self.ai_fields.new_model) |new| {
            if (new.provider >= self.model.value.ai.provider_count) return .dirty_invalid;
            const p = self.model.value.ai.providers[new.provider];
            if (new.model >= p.model_count or !ai_draft.modelValid(p.models[new.model])) return .dirty_invalid;
        }
        if (self.model.dirty and !self.background.canSave(self.model.value.ui.materials.background)) return .dirty_invalid;
        if (self.save_failed) return .save_failed;
        return if (self.model.dirty) .dirty_valid else .clean;
    }

    pub fn canSave(self: *const Controller) bool {
        return self.model.dirty and (self.state() == .dirty_valid or self.state() == .save_failed);
    }

    fn transferPolicyField(index: usize) bool {
        return index == schema.find("transfer", "chunk_kb").? or index == schema.find("transfer", "window_chunks").? or index == schema.find("transfer", "max_tasks").?;
    }

    fn transferPolicyChanged(self: *const Controller) bool {
        const saved = self.original.value.transfer;
        const draft = self.model.value.transfer;
        return saved.chunk_kb != draft.chunk_kb or saved.window_chunks != draft.window_chunks or saved.max_tasks != draft.max_tasks;
    }

    /// Existing policies remain loadable and do not block unrelated edits.
    /// Only an actual policy change opts this draft into the current budget.
    pub fn transferPolicyProblem(self: *const Controller) ?anyerror {
        if (!self.transferPolicyChanged()) return null;
        if (self.transfer_save_problem) |err| return err;
        const draft = self.model.value.transfer;
        window_policy.validateWindowPolicy(draft.chunk_kb, draft.window_chunks, draft.max_tasks) catch |err| return err;
        return null;
    }

    pub fn fieldProblem(self: *const Controller, index: usize) ?anyerror {
        if (index >= self.raw_fields.len) return null;
        if (self.raw_fields[index].problem) |err| return err;
        return if (transferPolicyField(index)) self.transferPolicyProblem() else null;
    }

    /// Disabled SSH dependencies retain raw and the last valid typed value,
    /// while their invalid draft cannot block a different applicable field.
    pub fn fieldApplicable(self: *const Controller, index: usize) bool {
        if (index >= schema.fields.len) return false;
        const field = schema.fields[index];
        if (!std.mem.eql(u8, field.section, "ssh")) return true;
        if (std.mem.eql(u8, field.key, "reconnect_max")) return self.model.value.ssh.auto_reconnect;
        if (std.mem.eql(u8, field.key, "reconnect_backoff") or std.mem.eql(u8, field.key, "buffer_input")) return self.model.value.ssh.auto_reconnect and self.model.value.ssh.reconnect_max > 0;
        return true;
    }

    /// Picker cancellation makes no call. Reading and decoding this owned
    /// request belongs to a worker, never this controller's event handler.
    pub fn requestBackground(self: *Controller, path: []const u8) !material.OwnedRequest {
        try self.ensureEditable();
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        return .{ .allocator = self.allocator, .request = try self.background.select(owned) };
    }

    pub fn selectTheme(self: *Controller, registry: *const themes.Registry, id: []const u8) !void {
        const record = registry.get(id) orelse return error.UnknownTheme;
        try self.editKey("ui", "theme", .{ .text = record.id });
        self.theme_library.registry_revision = registry.revision;
    }

    /// Capture before opening the picker. Cancellation leaves Config untouched.
    pub fn requestThemeImport(self: *Controller) !themes.ImportRequest {
        try self.ensureEditable();
        if (self.next_theme_operation == std.math.maxInt(u64)) return error.OperationIdExhausted;
        const request: themes.ImportRequest = .{ .draft_id = self.draft_id, .operation_id = self.next_theme_operation };
        self.next_theme_operation += 1;
        self.theme_library.import_operation = request;
        self.theme_library.problem = null;
        return request;
    }

    pub fn cancelThemeImport(self: *Controller, request: themes.ImportRequest) void {
        const current = self.theme_library.import_operation orelse return;
        if (current.draft_id == request.draft_id and current.operation_id == request.operation_id) self.theme_library.import_operation = null;
    }

    pub fn failThemeImport(self: *Controller, request: themes.ImportRequest, err: anyerror) bool {
        const current = self.theme_library.import_operation orelse return false;
        if (current.draft_id != request.draft_id or current.operation_id != request.operation_id) return false;
        self.theme_library.import_operation = null;
        self.theme_library.problem = err;
        return true;
    }

    /// Always consumes result with registry.allocator. Allocate the draft and
    /// raw value before the registry changes, so an OOM cannot half-select it.
    pub fn completeThemeImport(self: *Controller, registry: *themes.Registry, result: *themes.ImportResult) !bool {
        const active = if (self.save_operation == null) self.theme_library.import_operation else null;
        var consumed = false;
        defer if (!consumed) result.deinit(registry.allocator);
        if (active == null or active.?.draft_id != result.request.draft_id or active.?.operation_id != result.request.operation_id) {
            consumed = true;
            _ = try registry.completeImport(active, result);
            return false;
        }
        var next = self.model.value;
        next.ui.theme = result.record.id;
        var owned: ?runtime.Snapshot = try runtime.Snapshot.init(self.allocator, next);
        defer if (owned) |*prepared_draft| prepared_draft.deinit();
        const raw = try self.allocator.dupe(u8, result.record.id);
        var raw_owned = true;
        defer if (raw_owned) self.allocator.free(raw);
        consumed = true;
        _ = try registry.completeImport(active, result);
        if (self.draft) |*old| old.deinit();
        self.draft = owned;
        self.model.value = owned.?.value;
        owned = null;
        self.replaceRaw(schema.find("ui", "theme").?, raw);
        raw_owned = false;
        self.theme_library.import_operation = null;
        self.theme_library.registry_revision = registry.revision;
        self.theme_library.problem = null;
        self.refreshDirty();
        return true;
    }

    /// Always consumes asset, including stale/OOM callbacks. The typed path is
    /// changed only when the current load succeeded; failure retains its old
    /// identity, parameters and last valid preview.
    pub fn completeBackground(self: *Controller, asset: *material.Prepared) !bool {
        if (self.background.state != .loading or asset.draft_id != self.draft_id or asset.asset_revision != self.background.asset_revision) return self.background.complete(self.allocator, asset);
        errdefer {
            asset.deinit(self.allocator);
            self.background.state = .failed;
            self.background.problem = error.BackgroundApplyFailed;
        }
        try self.ensureEditable();
        const path = try self.allocator.dupe(u8, asset.path);
        errdefer self.allocator.free(path);
        try self.applyEdit("ui.materials.background", "path", .{ .text = path });
        self.replaceRaw(schema.find("ui.materials.background", "path").?, path);
        _ = self.background.complete(self.allocator, asset);
        self.refreshDirty();
        return true;
    }

    pub fn requestClose(self: *const Controller) CloseDecision {
        if (self.save_operation != null) return .blocked_saving;
        return if (self.model.dirty) .confirmation_required else .allow;
    }

    pub fn setSearch(self: *Controller, query: []const u8) !void {
        try self.ensureEditable();
        const owned = if (query.len == 0) "" else try self.allocator.dupe(u8, query);
        const was_empty = std.mem.trim(u8, self.search_query, " \t\r\n").len == 0;
        const is_empty = std.mem.trim(u8, query, " \t\r\n").len == 0;
        if (was_empty and !is_empty) self.search_return_page = self.model.page_index;
        if (is_empty) {
            if (self.search_return_page) |page| self.model.selectPage(page);
            self.search_return_page = null;
        }
        if (self.search_query.len != 0) self.allocator.free(self.search_query);
        self.search_query = owned;
    }

    fn applyEdit(self: *Controller, section: []const u8, key: []const u8, next: values.Value) !void {
        var candidate = self.model.value;
        try values.writeConfig(&candidate, section, key, next);
        const owned = try runtime.Snapshot.init(self.allocator, candidate);
        if (self.draft) |*draft| draft.deinit();
        self.draft = owned;
        self.model.value = owned.value;
    }

    /// Replace the complete recorded map as one owned draft transaction.
    pub fn editKeys(self: *Controller, map: config.keybindings.Map) !void {
        try self.ensureEditable();
        var buffer: [4096]u8 = undefined;
        _ = try config.keybindings.Map.parse(try map.format(&buffer));
        var candidate = self.model.value;
        candidate.keys = map;
        const owned = try runtime.Snapshot.init(self.allocator, candidate);
        if (self.draft) |*old| old.deinit();
        self.draft = owned;
        self.model.value = owned.value;
        self.refreshDirty();
        self.save_failed = false;
        self.last_error = null;
    }

    pub fn editProvider(self: *Controller, index: usize, next: config.AiProvider) !void {
        try self.ensureEditable();
        if (index >= self.model.value.ai.providers.len) return error.UnknownProvider;
        var candidate = self.model.value;
        candidate.ai.providers = try self.allocator.dupe(config.AiProvider, candidate.ai.providers);
        defer self.allocator.free(candidate.ai.providers);
        candidate.ai.providers[index] = next;
        try candidate.validate();
        const owned = try runtime.Snapshot.init(self.allocator, candidate);
        if (self.draft) |*old| old.deinit();
        self.draft = owned;
        self.model.value = owned.value;
        self.refreshDirty();
        self.save_failed = false;
        self.last_error = null;
    }

    pub fn selectProvider(self: *Controller, name: []const u8) !void {
        try self.editKey("ai", "default_provider", .{ .text = name });
    }

    pub fn editProviders(self: *Controller, ai: config.Ai) !void {
        try self.ensureEditable();
        var candidate = self.model.value;
        candidate.ai = ai;
        try candidate.validate();
        const owned = try runtime.Snapshot.init(self.allocator, candidate);
        if (self.draft) |*old| old.deinit();
        self.draft = owned;
        self.model.value = owned.value;
        self.refreshDirty();
        self.save_failed = false;
        self.last_error = null;
    }

    pub fn editAiRaw(self: *Controller, address: ai_draft.Address, text: []const u8) !void {
        try self.ensureEditable();
        const raw = try self.ai_fields.put(self.allocator, address, text);
        var owned = try runtime.Snapshot.init(self.allocator, self.model.value);
        defer owned.deinit();
        ai_draft.assign(&owned.value.ai, address, raw.input) catch |err| {
            raw.problem = err;
            self.last_error = @errorName(err);
            self.refreshDirty();
            return err;
        };
        self.editProviders(owned.value.ai) catch |err| {
            raw.problem = err;
            self.last_error = @errorName(err);
            self.refreshDirty();
            return err;
        };
    }

    pub fn cancelAiRaw(self: *Controller, address: ai_draft.Address) void {
        if (self.save_operation != null) return;
        self.ai_fields.remove(self.allocator, address);
        self.last_error = null;
        self.refreshDirty();
    }

    pub fn editSelected(self: *Controller, next: values.Value) !void {
        const key = self.model.selectedKey() orelse {
            self.last_error = "UnknownKey";
            return error.UnknownKey;
        };
        try self.editKey(key.section, key.key, next);
    }

    pub fn save(self: *Controller, io: std.Io, dir: std.Io.Dir, target: *runtime.RuntimeConfig) !void {
        try self.ensureEditable();
        self.refreshDirty();
        if (!self.model.dirty) return;
        self.last_error = null;
        var request = self.beginSave(target, false) catch |err| {
            self.last_error = @errorName(err);
            return err;
        };
        defer request.deinit();
        _ = try self.completeSave(io, dir, target, &request);
    }

    pub fn beginSave(self: *Controller, target: *runtime.RuntimeConfig, close_after_save: bool) !SaveRequest {
        try self.ensureEditable();
        self.refreshDirty();
        if (!self.canSave()) return error.InvalidDraft;
        errdefer {
            self.save_failed = true;
            self.close_ready = false;
        }
        if (self.next_save_operation == std.math.maxInt(u64)) return error.OperationIdExhausted;
        const merged = schema.merge(target.value, self.model.value, self.dirty_fields);
        if (self.transferPolicyChanged()) {
            const policy = merged.transfer;
            window_policy.validateWindowPolicy(policy.chunk_kb, policy.window_chunks, policy.max_tasks) catch |err| {
                self.transfer_save_problem = err;
                self.last_error = @errorName(err);
                return err;
            };
        }
        var prepared = target.prepare(merged) catch |err| {
            self.last_error = @errorName(err);
            return err;
        };
        errdefer prepared.deinit();
        if (merged.ui.materials.background.enabled) {
            const asset = if (self.background.last_good) |*good| good else return error.BackgroundNotPrepared;
            try prepared.confirmBackground(asset);
        }
        const baseline = runtime.Snapshot.init(self.allocator, prepared.owned.?.value) catch |err| {
            self.last_error = @errorName(err);
            return err;
        };
        const operation = self.next_save_operation;
        self.next_save_operation += 1;
        self.save_operation = operation;
        self.model.locked = true;
        self.close_after_save = close_after_save;
        self.close_ready = false;
        self.save_failed = false;
        self.last_error = null;
        return .{ .draft_id = self.draft_id, .operation_id = operation, .baseline_revision = self.original.value.config_revision, .close_after_save = close_after_save, .prepared = prepared, .baseline = baseline };
    }

    /// The matching callback is the only path that may commit and clear dirty.
    /// A stale/duplicate callback leaves runtime, input and the current request intact.
    pub fn completeSave(self: *Controller, io: std.Io, dir: std.Io.Dir, target: *runtime.RuntimeConfig, request: *SaveRequest) !bool {
        if (request.draft_id != self.draft_id or self.save_operation != request.operation_id) return false;
        const baseline = if (request.baseline) |*owned| owned else return error.AlreadyCommitted;
        // Prepare owned slots before committing so publishing actual refs cannot
        // fail or borrow the runtime snapshot's shorter-lived string storage.
        const reference_slots = baseline.arena.allocator().alloc([68]u8, baseline.value.ai.providers.len) catch |err| {
            _ = self.failSave(request, err);
            return err;
        };
        target.commitPrepared(io, dir, &request.prepared) catch |err| {
            _ = self.failSave(request, err);
            return err;
        };
        for (baseline.value.ai.providers, target.value.ai.providers, reference_slots) |*provider, saved, *slot| {
            provider.api_key_ref = if (saved.api_key_ref) |reference| blk: {
                @memcpy(slot, reference);
                break :blk slot;
            } else null;
        }
        if (self.draft) |*draft| draft.deinit();
        self.draft = null;
        self.original.deinit();
        self.original = request.baseline.?;
        request.baseline = null;
        self.clearRaw();
        self.save_operation = null;
        self.model.locked = false;
        self.model.setOriginal(self.original.value);
        self.plugin_page.settings_draft_revision = self.original.value.config_revision;
        self.dirty_fields = .empty;
        self.save_failed = false;
        self.last_error = null;
        self.close_ready = request.close_after_save;
        self.refreshDirty();
        return true;
    }

    pub fn failSave(self: *Controller, request: *const SaveRequest, err: anyerror) bool {
        if (request.draft_id != self.draft_id or self.save_operation != request.operation_id) return false;
        self.save_operation = null;
        self.model.locked = false;
        self.save_failed = true;
        self.close_after_save = false;
        self.close_ready = false;
        self.last_error = @errorName(err);
        return true;
    }

    /// Restoring defaults changes the draft only. It is independent of Discard
    /// and is persisted by the same Save action as all other edits.
    pub fn resetDefaults(self: *Controller) void {
        if (self.save_operation != null) return;
        self.clearRaw();
        self.model.resetDefaults();
        if (self.draft) |*draft| draft.deinit();
        self.draft = null;
        self.last_error = null;
        self.save_failed = false;
        self.cancelBackground();
        self.refreshDirty();
        self.theme_library.import_operation = null;
    }

    pub fn discard(self: *Controller) void {
        if (self.save_operation != null) return;
        self.clearRaw();
        self.model.discard();
        if (self.draft) |*draft| draft.deinit();
        self.draft = null;
        self.last_error = null;
        self.save_failed = false;
        self.close_ready = false;
        self.refreshDirty();
        self.cancelBackground();
        self.theme_library.import_operation = null;
    }

    /// Rebase Discard on the latest committed snapshot, including changes from
    /// commands or other windows made while this settings draft was open.
    pub fn discardLatest(self: *Controller, target: *const runtime.RuntimeConfig) !void {
        try self.ensureEditable();
        const baseline = try runtime.Snapshot.init(self.allocator, target.value);
        if (self.draft) |*draft| draft.deinit();
        self.draft = null;
        self.original.deinit();
        self.original = baseline;
        self.model.setOriginal(baseline.value);
        self.plugin_page.settings_draft_revision = baseline.value.config_revision;
        self.clearRaw();
        self.dirty_fields = .empty;
        self.last_error = null;
        self.save_failed = false;
        self.close_ready = false;
        self.cancelBackground();
        self.theme_library.import_operation = null;
        self.refreshDirty();
    }

    fn cancelBackground(self: *Controller) void {
        const revision = self.background.asset_revision +| 1;
        self.background.deinit(self.allocator);
        self.background = .{ .draft_id = self.draft_id, .asset_revision = revision };
    }

    pub fn failBackground(self: *Controller, request: material.Request, err: anyerror) bool {
        return self.background.fail(request, err);
    }

    /// A nine-anchor choice changes both axes as one owned draft edit. Other
    /// material raw errors remain intact if either allocation cannot complete.
    pub fn editBackgroundAlignment(self: *Controller, horizontal: material.Horizontal, vertical: material.Vertical) !void {
        try self.ensureEditable();
        const x = try self.allocator.dupe(u8, @tagName(horizontal));
        errdefer self.allocator.free(x);
        const y = try self.allocator.dupe(u8, @tagName(vertical));
        errdefer self.allocator.free(y);
        var next = self.model.value;
        next.ui.materials.background.alignment_x = horizontal;
        next.ui.materials.background.alignment_y = vertical;
        const prepared = try runtime.Snapshot.init(self.allocator, next);
        if (self.draft) |*old| old.deinit();
        self.draft = prepared;
        self.model.value = prepared.value;
        self.replaceRaw(schema.find("ui.materials.background", "alignment_x").?, x);
        self.replaceRaw(schema.find("ui.materials.background", "alignment_y").?, y);
        self.refreshDirty();
    }

    /// Restore this draft's material fields only, using the latest committed
    /// baseline. Other raw/dirty fields and library state remain untouched.
    pub fn restoreMaterials(self: *Controller, target: *const runtime.RuntimeConfig) !void {
        try self.ensureEditable();
        var next = self.model.value;
        next.ui.materials = target.value.ui.materials;
        const owned = try runtime.Snapshot.init(self.allocator, next);
        if (self.draft) |*old| old.deinit();
        self.draft = owned;
        self.model.value = owned.value;
        for (schema.fields, 0..) |field, i| {
            if (!std.mem.startsWith(u8, field.section, "ui.materials")) continue;
            if (self.raw_fields[i].input) |raw| self.allocator.free(raw);
            self.raw_fields[i] = .{};
        }
        self.cancelBackground();
        self.save_failed = false;
        self.refreshDirty();
    }
};

fn alignmentAllocationCase(allocator: std.mem.Allocator) !void {
    var controller = try Controller.init(allocator, .{});
    defer controller.deinit();
    controller.editRaw("ui.materials", "blur_px", "97") catch |err| if (err != error.OutOfRange) return err;
    controller.editBackgroundAlignment(.left, .top) catch |err| {
        try std.testing.expectEqual(.center, controller.model.value.ui.materials.background.alignment_x);
        try std.testing.expectEqual(.center, controller.model.value.ui.materials.background.alignment_y);
        try std.testing.expectEqualStrings("97", controller.raw_fields[schema.find("ui.materials", "blur_px").?].input.?);
        return err;
    };
    try std.testing.expectEqual(.left, controller.model.value.ui.materials.background.alignment_x);
    try std.testing.expectEqual(.top, controller.model.value.ui.materials.background.alignment_y);
    try std.testing.expectEqualStrings("97", controller.raw_fields[schema.find("ui.materials", "blur_px").?].input.?);
    try std.testing.expectEqual(@as(u8, 0), controller.model.value.ui.materials.blur_px);
    try std.testing.expect(!controller.canSave());
}
test "settings alignment axes change atomically and retain another invalid raw field" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, alignmentAllocationCase, .{});
}

test "settings controller tracks edit errors and discards to its owned baseline" {
    var initial_font = [_]u8{ 'M', 'o', 'n', 'o' };
    var initial: config.Config = .{};
    initial.ui.font_family = &initial_font;
    var controller = try Controller.init(std.testing.allocator, initial);
    defer controller.deinit();
    @memset(&initial_font, 'x');
    try controller.editKey("ui", "font_family", .{ .text = "Edited Mono" });
    try std.testing.expect(controller.model.dirty);
    controller.discard();
    try std.testing.expectEqualStrings("Mono", controller.model.value.ui.font_family);
    try std.testing.expect(!controller.model.dirty);
    try std.testing.expect(controller.last_error == null);
    try std.testing.expectError(error.OutOfRange, controller.editKey("ui", "font_size", .{ .unsigned = 2 }));
    try std.testing.expectEqualStrings("OutOfRange", controller.last_error.?);
    try std.testing.expectEqual(@as(u8, 14), controller.model.value.ui.font_size);
}

test "settings save uses runtime non-default path and reloads independently of controller" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "profile/settings.toml");
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    var controller_live = true;
    defer if (controller_live) controller.deinit();
    var edited_font = [_]u8{ 'I', 'n', 'p', 'u', 't', ' ', 'M', 'o', 'n', 'o' };
    try controller.editKey("ui", "font_family", .{ .text = &edited_font });
    @memset(&edited_font, 'x');
    try std.testing.expectEqualStrings("Input Mono", controller.model.value.ui.font_family);
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expect(!controller.model.dirty);
    try controller.editKey("ui", "font_family", .{ .text = "Unsaved Font" });
    controller.discard();
    try std.testing.expectEqualStrings("Input Mono", controller.model.value.ui.font_family);
    controller.deinit();
    controller_live = false;
    try std.testing.expectEqualStrings("Input Mono", target.value.ui.font_family);
    var restarted = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "profile/settings.toml");
    defer restarted.deinit();
    try std.testing.expectEqualStrings("Input Mono", restarted.value.ui.font_family);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "config.toml", .{}));
}

test "failed settings save preserves runtime baseline and edited draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "blocked/config.toml");
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    defer controller.deinit();
    try controller.editKey("ui", "font_family", .{ .text = "Edited Mono" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    try std.testing.expectError(error.NotDir, controller.save(std.testing.io, tmp.dir, &target));
    try std.testing.expectEqualStrings("Monaco", target.value.ui.font_family);
    try std.testing.expectEqualStrings("Monaco", controller.model.original.ui.font_family);
    try std.testing.expectEqualStrings("Edited Mono", controller.model.value.ui.font_family);
    try std.testing.expect(controller.model.dirty);
    try std.testing.expectEqualStrings("NotDir", controller.last_error.?);
    controller.discard();
    try std.testing.expectEqualStrings("Monaco", controller.model.value.ui.font_family);
}

test "settings user data path survives saving and restarting from another directory" {
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var unrelated = std.testing.tmpDir(.{});
    defer unrelated.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_length = try home.dir.realPath(std.testing.io, &home_buffer);
    var user_paths = try runtime.paths.Paths.fromHome(std.testing.allocator, home_buffer[0..home_length]);
    defer user_paths.deinit();

    // The production entry point supplies this absolute path, while settings
    // save supplies cwd. Neither save nor restart may follow the caller's dir.
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, home.dir, std.testing.allocator, user_paths.config);
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    defer controller.deinit();
    try controller.editKey("ui", "font_size", .{ .unsigned = 19 });
    try controller.save(std.testing.io, unrelated.dir, &target);

    var restarted = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, unrelated.dir, std.testing.allocator, user_paths.config);
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u8, 19), restarted.value.ui.font_size);
    try std.testing.expectEqualStrings(user_paths.config, restarted.path);
    try std.testing.expectError(error.FileNotFound, unrelated.dir.openFile(std.testing.io, "config.toml", .{}));
    try std.testing.expectError(error.FileNotFound, home.dir.openFile(std.testing.io, "config.toml", .{}));
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, user_paths.config, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "closing unsaved settings preserves persisted baseline across page switches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    defer controller.deinit();
    try controller.editKey("ui", "font_size", .{ .unsigned = 18 });
    try controller.save(std.testing.io, tmp.dir, &target);
    try controller.editKey("ui", "font_size", .{ .unsigned = 22 });
    controller.model.selectPage(2);
    try controller.editKey("transfer", "max_tasks", .{ .unsigned = 5 });
    controller.discard();
    try std.testing.expect(!controller.model.dirty);
    try std.testing.expectEqual(@as(u8, 18), controller.model.value.ui.font_size);
    try std.testing.expectEqual(target.value.transfer.max_tasks, controller.model.value.transfer.max_tasks);
    var restarted = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u8, 18), restarted.value.ui.font_size);
    try std.testing.expectEqual(target.value.transfer.max_tasks, restarted.value.transfer.max_tasks);
}

test "restore defaults can be discarded or saved and becomes the new baseline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var saved: config.Config = .{};
    saved.ui.font_size = 22;
    saved.ui.font_family = "Saved Mono";
    try @import("store.zig").save(std.testing.io, tmp.dir, "config.toml", saved);
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    defer controller.deinit();
    controller.resetDefaults();
    try std.testing.expectEqual(@as(u8, 14), controller.model.value.ui.font_size);
    try std.testing.expect(controller.model.dirty);
    try std.testing.expectEqual(@as(u8, 22), target.value.ui.font_size);
    controller.discard();
    try std.testing.expectEqual(@as(u8, 22), controller.model.value.ui.font_size);
    controller.resetDefaults();
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqual(@as(u8, 14), target.value.ui.font_size);
    try std.testing.expectEqualStrings("Monaco", target.value.ui.font_family);
    try std.testing.expectEqual(@as(f32, 1.5), target.value.ui.line_height);
    try std.testing.expectEqualStrings("bar", target.value.ui.cursor_style);
    try controller.editKey("ui", "font_size", .{ .unsigned = 30 });
    controller.discard();
    try std.testing.expectEqual(@as(u8, 14), controller.model.value.ui.font_size);
    var restarted = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u8, 14), restarted.value.ui.font_size);
}

test "recorded key map saves in config and default reset remains discardable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "app.toml");
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    defer controller.deinit();
    var map = controller.model.value.keys;
    try map.set(.search, .{ .key = .e });
    try controller.editKeys(map);
    controller.discard();
    try std.testing.expectEqual(config.keybindings.KeyCode.f, controller.model.value.keys.get(.search).key);
    try controller.editKeys(map);
    try controller.save(std.testing.io, tmp.dir, &target);
    var loaded = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "app.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(config.keybindings.KeyCode.e, loaded.value.keys.get(.search).key);
    controller.resetDefaults();
    try std.testing.expectEqual(config.keybindings.KeyCode.f, controller.model.value.keys.get(.search).key);
    controller.discard();
    try std.testing.expectEqual(config.keybindings.KeyCode.e, controller.model.value.keys.get(.search).key);
}

test "provider draft owns keys and models across cancel save and restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "provider.toml");
    defer target.deinit();
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    var key = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var id = [_]u8{ 'm', 'o', 'd', 'e', 'l' };
    var test_copy = try runtime.Snapshot.init(std.testing.allocator, c.model.value);
    defer test_copy.deinit();
    var ai = test_copy.value.ai;
    // The three legacy backing slots are not active Providers on a fresh install.
    ai.provider_count = 1;
    ai.providers = ai.providers[0..1];
    ai.providers[0].name = "test-provider";
    ai.providers[0].api_key = &key;
    var models = [_]config.AiModel{.{}};
    ai.providers[0].models = &models;
    ai.providers[0].model_count = 1;
    ai.providers[0].models[0] = .{ .id = &id, .context_window = 200000 };
    try c.editProviders(ai);
    @memset(&key, 'x');
    @memset(&id, 'x');
    try std.testing.expectEqualStrings("secret", c.model.value.ai.providers[0].api_key);
    c.discard();
    try std.testing.expectEqualStrings("", c.model.value.ai.providers[0].api_key);
    ai.providers[0].api_key = "saved-key";
    ai.providers[0].models[0].id = "saved-model";
    try c.editProviders(ai);
    try c.save(std.testing.io, tmp.dir, &target);
    var reload = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "provider.toml");
    defer reload.deinit();
    try std.testing.expectEqualStrings("saved-key", reload.value.ai.providers[0].api_key);
    try std.testing.expect(reload.value.ai.providers[0].api_key_ref != null);
    const persisted = try tmp.dir.readFileAlloc(std.testing.io, "provider.toml", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "saved-key") == null);
    try std.testing.expectEqualStrings("saved-model", reload.value.ai.providers[0].models[0].id);
}

test "invalid raw stays dirty with last valid preview and reverting becomes clean" {
    var c = try Controller.init(std.testing.allocator, .{});
    defer c.deinit();
    const index = schema.find("ui", "font_size").?;
    try std.testing.expectError(error.InvalidValue, c.editRaw("ui", "font_size", "fourteen"));
    try std.testing.expectEqualStrings("fourteen", c.raw_fields[index].input.?);
    try std.testing.expectEqual(@as(u8, 14), c.model.value.ui.font_size);
    try std.testing.expectEqual(State.dirty_invalid, c.state());
    try std.testing.expect(c.model.dirty);
    try std.testing.expect(!c.canSave());
    try c.setSearch("font");
    c.model.selectPage(5);
    c.scroll_offsets[5] = 120;
    try std.testing.expectEqualStrings("fourteen", c.raw_fields[index].input.?);
    try c.editRaw("ui", "font_size", "18");
    try std.testing.expectEqual(State.dirty_valid, c.state());
    try c.editRaw("ui", "font_size", "14");
    try std.testing.expectEqual(State.clean, c.state());
    try std.testing.expect(!c.model.dirty);
    try std.testing.expectEqualStrings("font", c.search_query);
    try std.testing.expectEqual(@as(f32, 120), c.scroll_offsets[5]);
    try std.testing.expectError(error.OutOfRange, c.editRaw("ui", "line_height", "nan"));
    try std.testing.expectEqual(@as(f32, 1.5), c.model.value.ui.line_height);
}

test "settings merges external commits by field and discard follows latest revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    try c.editKey("ui", "font_size", .{ .unsigned = 18 });
    try target.updateSetting(std.testing.io, tmp.dir, "ssh", "term", .{ .text = "vt100" });
    try target.updateSetting(std.testing.io, tmp.dir, "ui", "font_size", .{ .unsigned = 22 });
    try c.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqual(@as(u8, 18), target.value.ui.font_size);
    try std.testing.expectEqualStrings("vt100", target.value.ssh.term);
    try std.testing.expectEqual(target.value.config_revision, c.model.original.config_revision);
    try c.editKey("ui", "font_size", .{ .unsigned = 30 });
    try target.updateSetting(std.testing.io, tmp.dir, "ui", "theme", .{ .text = "dark-pro" });
    try c.discardLatest(&target);
    try std.testing.expectEqual(@as(u8, 18), c.model.value.ui.font_size);
    try std.testing.expectEqualStrings("dark-pro", c.model.value.ui.theme);
    try std.testing.expectEqual(State.clean, c.state());
}

test "saved sidebar width survives restart and an unrelated settings draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    try std.testing.expect(target.value.ui.sidebar_width == null);
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    try c.editKey("ui", "font_size", .{ .unsigned = 18 });
    var candidate = target.value;
    candidate.ui.sidebar_width = 312.5;
    try target.save(std.testing.io, tmp.dir, candidate);
    try c.save(std.testing.io, tmp.dir, &target);
    var restarted = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    try std.testing.expectEqual(@as(?f32, 312.5), restarted.value.ui.sidebar_width);
    try std.testing.expectEqual(@as(u8, 18), restarted.value.ui.font_size);
    candidate = target.value;
    candidate.ui.sidebar_width = 500;
    try std.testing.expectError(error.OutOfRange, target.save(std.testing.io, tmp.dir, candidate));
}

test "save locks draft and ignores old callbacks while retry commits once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    try c.editRaw("ui", "font_size", "18");
    c.scroll_offsets[0] = 80;
    var old = try c.beginSave(&target, true);
    defer old.deinit();
    try std.testing.expectEqual(State.saving, c.state());
    try std.testing.expectEqual(CloseDecision.blocked_saving, c.requestClose());
    try std.testing.expectError(error.SettingsBusy, c.editRaw("ui", "font_size", "20"));
    try std.testing.expectError(error.SettingsBusy, c.beginSave(&target, false));
    c.model.selectPage(4);
    c.resetDefaults();
    c.discard();
    try std.testing.expectEqual(@as(usize, 0), c.model.page_index);
    try std.testing.expectEqual(@as(u8, 18), c.model.value.ui.font_size);
    try std.testing.expect(c.failSave(&old, error.AccessDenied));
    try std.testing.expectEqual(State.save_failed, c.state());
    try std.testing.expectEqualStrings("18", c.raw_fields[schema.find("ui", "font_size").?].input.?);
    try std.testing.expectEqual(@as(f32, 80), c.scroll_offsets[0]);
    try std.testing.expect(!c.close_ready);
    var retry = try c.beginSave(&target, false);
    defer retry.deinit();
    try std.testing.expect(!try c.completeSave(std.testing.io, tmp.dir, &target, &old));
    try std.testing.expect(!c.failSave(&old, error.AccessDenied));
    try std.testing.expectEqual(@as(u64, 1), target.value.config_revision);
    try std.testing.expect(try c.completeSave(std.testing.io, tmp.dir, &target, &retry));
    try std.testing.expect(!try c.completeSave(std.testing.io, tmp.dir, &target, &retry));
    try std.testing.expectEqual(@as(u64, 2), target.value.config_revision);
    try std.testing.expect(!c.close_ready);
    try std.testing.expectEqual(State.clean, c.state());
    try c.editRaw("ui", "font_size", "20");
    var close = try c.beginSave(&target, true);
    defer close.deinit();
    try std.testing.expect(try c.completeSave(std.testing.io, tmp.dir, &target, &close));
    try std.testing.expect(c.close_ready);
}

test "external commit after save preparation rejects stale revision and retry merges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    try c.editRaw("ui", "font_size", "18");
    var request = try c.beginSave(&target, false);
    defer request.deinit();
    try target.updateSetting(std.testing.io, tmp.dir, "ssh", "term", .{ .text = "vt100" });
    try std.testing.expectError(error.StaleConfigRevision, c.completeSave(std.testing.io, tmp.dir, &target, &request));
    try std.testing.expectEqual(@as(u8, 14), target.value.ui.font_size);
    try std.testing.expectEqual(@as(u8, 18), c.model.value.ui.font_size);
    try c.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqualStrings("vt100", target.value.ssh.term);
    try std.testing.expectEqual(@as(u8, 18), target.value.ui.font_size);
}

test "empty provider registry and disabled incomplete models allow unrelated save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    var models = [_]config.AiModel{.{}};
    try c.editProvider(0, .{ .name = "disabled", .models = &models, .model_count = 1 });
    try std.testing.expectEqualStrings("", c.model.original.ai.providers[0].name);
    try c.editRaw("ui", "font_size", "18");
    try c.save(std.testing.io, tmp.dir, &target);
    var ai = c.model.value.ai;
    ai.provider_count = 0;
    ai.providers = &.{};
    try c.editProviders(ai);
    try c.save(std.testing.io, tmp.dir, &target);
    var loaded = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.value.ai.provider_count);
    try std.testing.expectEqual(@as(u8, 18), loaded.value.ui.font_size);
}

test "plugin preview validation and loading never dirty or block a real draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer target.deinit();
    var c = try Controller.init(std.testing.allocator, target.value);
    defer c.deinit();
    c.plugin_page.select(.{ .planned = .ftp_ftps });
    try c.plugin_page.showPreview(.validation);
    try std.testing.expectEqual(State.clean, c.state());
    try c.editRaw("ui", "font_size", "18");
    c.model.selectPage(5);
    try c.plugin_page.showPreview(.loading);
    try std.testing.expect(c.canSave());
    try c.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqual(State.clean, c.state());
    try std.testing.expectEqual(@as(u8, 18), target.value.ui.font_size);
    try std.testing.expectEqualStrings("0", c.plugin_page.validation_example_input);
    try std.testing.expectEqual(target.value.config_revision, c.plugin_page.settings_draft_revision);
}

test "plugin preferences share discard atomic save and restart with all settings" {
    const manifest_type = @import("../host/plugin_registry.zig").PluginManifest;
    const manifests = [_]manifest_type{.{ .id = "test.preferences", .display_name = "Preferences", .workspace_kind = "content", .content_renderer = "content", .settings_section = .{ .fields = &.{.{ .key = "show_grid", .label = "显示网格", .kind = .boolean, .default_value = "true" }} } }};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "plugins.toml");
    defer target.deinit();
    var controller = try Controller.init(std.testing.allocator, target.value);
    defer controller.deinit();
    controller.plugin_page.refreshRegistry(.{ .published = .{ .entries = &manifests, .renderers = &.{} } }, target.value.config_revision);
    try controller.setPluginPreference("test.preferences", "show_grid", "false");
    try std.testing.expect(controller.dirty_fields.isSet(schema.plugin_preferences_index));
    try std.testing.expectEqualStrings("false", controller.model.value.pluginPreference("test.preferences", "show_grid").?);
    try std.testing.expect(target.value.pluginPreference("test.preferences", "show_grid") == null);
    controller.discard();
    try std.testing.expect(!controller.model.dirty);
    try std.testing.expect(controller.model.value.pluginPreference("test.preferences", "show_grid") == null);
    try std.testing.expectError(error.InvalidValue, controller.setPluginPreference("test.preferences", "show_grid", "invalid"));
    try controller.setPluginPreference("test.preferences", "show_grid", "false");
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expect(!controller.model.dirty);
    try std.testing.expectEqualStrings("false", target.value.pluginPreference("test.preferences", "show_grid").?);
    var restarted = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "plugins.toml");
    defer restarted.deinit();
    try std.testing.expectEqualStrings("false", restarted.value.pluginPreference("test.preferences", "show_grid").?);
}
