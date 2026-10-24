//! One settings resource job at a time. Only owned memory crosses the thread
//! boundary. The host holds busy() across registry writes, configuration Save
//! and immediate theme changes; the live Registry is never a worker target.
const std = @import("std");
const themes = @import("theme_registry.zig");
const background = @import("background_asset.zig");
const Controller = @import("settings_controller.zig").Controller;

pub const Kind = enum { load_library, theme, background, favorite, remove, installation, abort_installation };
pub const Poll = struct {
    kind: ?Kind = null,
    pending: bool = false,
    changed: bool = false,
    problem: ?anyerror = null,
};
pub const BackgroundPreflight = struct {
    context: *anyopaque,
    /// Main thread, current draft/revision only. Failure retains the old draft.
    prepare: *const fn (*anyopaque, *const background.Prepared) anyerror!void,
    /// Called exactly once after successful prepare, including Controller OOM.
    complete: *const fn (*anyopaque, bool) void,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    metadata_path: []u8,
    job: ?*Job = null,
    installation: ?themes.Installation = null,
    selected_path: []u8,
    picker_active: bool = false,
    last_error: ?anyerror = null,
    background_preflight: ?BackgroundPreflight = null,

    /// allocator must be thread safe and match Registry/Controller allocation.
    /// dir and io remain live until the final job has been polled.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, metadata_path: []const u8) !Worker {
        const path = try allocator.dupe(u8, metadata_path);
        errdefer allocator.free(path);
        return .{ .allocator = allocator, .io = io, .dir = dir, .metadata_path = path, .selected_path = try allocator.dupe(u8, "") };
    }
    /// Call after polling every job and taking/aborting its installation. There
    /// is deliberately no file cleanup hidden inside a UI-thread destructor.
    pub fn deinit(self: *Worker) void {
        std.debug.assert(self.job == null and self.installation == null and !self.picker_active);
        self.allocator.free(self.metadata_path);
        self.allocator.free(self.selected_path);
        self.* = undefined;
    }
    pub fn busy(self: *const Worker) bool {
        return self.job != null or self.picker_active;
    }
    pub fn selectedPath(self: *const Worker) []const u8 {
        return self.selected_path;
    }
    pub fn clearSelectedPath(self: *Worker) void {
        self.allocator.free(self.selected_path);
        self.selected_path = &.{};
    }
    fn create(self: *Worker, kind: Kind) !*Job {
        if (self.busy()) return error.AppearanceBusy;
        if (self.installation != null) return error.InstallationPending;
        const job = try self.allocator.create(Job);
        job.* = .{ .allocator = self.allocator, .io = self.io, .dir = self.dir, .kind = kind };
        return job;
    }
    fn launch(self: *Worker, job: *Job) !void {
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        self.last_error = null;
    }
    pub fn startThemeImport(self: *Worker, request: themes.ImportRequest, path: []const u8) !void {
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".itermcolors")) return error.UnsupportedThemeFile;
        const job = try self.create(.theme);
        errdefer job.destroy();
        job.import_request = request;
        job.path = try self.allocator.dupe(u8, path);
        try self.launch(job);
    }
    pub fn loadLibrary(self: *Worker, registry: *const themes.Registry) !void {
        const job = try self.create(.load_library);
        errdefer job.destroy();
        job.registry = try registry.clone();
        job.expected_revision = registry.revision;
        job.path = try self.allocator.dupe(u8, self.metadata_path);
        try self.launch(job);
    }
    /// Takes request only on success. No Controller or Input is borrowed.
    pub fn startBackground(self: *Worker, request: *background.OwnedRequest) !void {
        const job = try self.create(.background);
        errdefer job.destroy();
        const selected = try self.allocator.dupe(u8, request.request.path);
        errdefer self.allocator.free(selected);
        job.background_request = request.*;
        errdefer job.background_request = null;
        try self.launch(job);
        request.* = undefined;
        self.allocator.free(self.selected_path);
        self.selected_path = selected;
    }
    pub fn startFavorite(self: *Worker, registry: *const themes.Registry, id: []const u8, revision: u64, enabled: bool) !void {
        if (revision != registry.revision) return error.StaleRegistryRevision;
        _ = registry.get(id) orelse return error.UnknownTheme;
        const job = try self.create(.favorite);
        errdefer job.destroy();
        job.registry = try registry.clone();
        job.expected_revision = revision;
        job.id = try self.allocator.dupe(u8, id);
        job.path = try self.allocator.dupe(u8, self.metadata_path);
        job.favorite_enabled = enabled;
        try self.launch(job);
    }
    pub fn startRemove(self: *Worker, registry: *const themes.Registry, id: []const u8, revision: u64, references: themes.References) !void {
        try registry.checkRemove(id, revision, references);
        const job = try self.create(.remove);
        errdefer job.destroy();
        job.registry = try registry.clone();
        job.expected_revision = revision;
        job.id = try self.allocator.dupe(u8, id);
        job.saved_id = try self.allocator.dupe(u8, references.saved);
        job.draft_theme_id = try self.allocator.dupe(u8, references.draft);
        try self.launch(job);
    }
    pub fn prepareInstallation(self: *Worker, registry: *const themes.Registry, draft_id: u64) !void {
        const job = try self.create(.installation);
        errdefer job.destroy();
        job.registry = try registry.clone();
        job.expected_revision = registry.revision;
        job.receipt = try themes.Installation.init(registry, draft_id);
        try self.launch(job);
    }
    pub fn takeInstallation(self: *Worker) ?themes.Installation {
        const receipt = self.installation;
        self.installation = null;
        return receipt;
    }
    /// Takes receipt only on successful start. An abort failure returns the
    /// receipt through takeInstallation, preserving created-file ownership.
    pub fn abortInstallation(self: *Worker, receipt: *themes.Installation) !void {
        const job = try self.create(.abort_installation);
        errdefer job.destroy();
        job.receipt = receipt.*;
        errdefer job.receipt = null;
        try self.launch(job);
        receipt.* = undefined;
    }
    /// Invalidates draft resources. A completed global metadata transaction is
    /// still published; changing settings selection is never its side effect.
    pub fn cancel(self: *Worker) void {
        if (self.job) |job| job.cancelled.store(true, .release);
    }
    /// App teardown fallback. It waits for owned jobs, and sends any remaining
    /// file cleanup to a worker. Normal window close uses cancel/poll instead.
    /// An abort error retains its receipt for explicit reporting/retry.
    pub fn shutdown(self: *Worker, registry: *themes.Registry) !void {
        self.cancel();
        while (self.job) |job| {
            if (job.thread) |thread| thread.join();
            job.thread = null;
            _ = self.poll(null, registry, "");
        }
        if (self.takeInstallation()) |value| {
            var receipt = value;
            self.abortInstallation(&receipt) catch |err| {
                self.installation = receipt;
                return err;
            };
            const job = self.job.?;
            job.thread.?.join();
            job.thread = null;
            const result = self.poll(null, registry, "");
            if (result.problem) |problem| return problem;
        }
    }
    /// Main thread only. May replace the live registry after an atomic worker
    /// write. The host must not mutate that registry while busy() is true.
    /// The saved/draft references are rechecked before a removal is published.
    pub fn poll(self: *Worker, controller: ?*Controller, registry: *themes.Registry, saved_theme: []const u8) Poll {
        const job = self.job orelse return .{};
        if (!job.done.load(.acquire)) return .{ .kind = job.kind, .pending = true };
        if (job.thread) |thread| thread.join();
        self.job = null;
        defer job.destroy();
        var result: Poll = .{ .kind = job.kind, .problem = job.problem };
        const cancelled = job.cancelled.load(.acquire);
        switch (job.kind) {
            .theme => if (controller) |c| {
                if (job.import_result) |*import| {
                    if (cancelled) c.cancelThemeImport(job.import_request.?);
                    result.changed = c.completeThemeImport(registry, import) catch |err| failed: {
                        result.problem = err;
                        _ = c.failThemeImport(job.import_request.?, err);
                        break :failed false;
                    };
                    job.import_result = null; // completeThemeImport always consumes.
                } else if (job.problem) |err| {
                    result.changed = c.failThemeImport(job.import_request.?, err);
                } else if (cancelled) c.cancelThemeImport(job.import_request.?);
            },
            .background => if (controller) |c| {
                if (job.background_result) |*asset| {
                    if (!cancelled and c.background.state == .loading and c.draft_id == asset.draft_id and c.background.asset_revision == asset.asset_revision) attempt: {
                        if (self.background_preflight) |hook| hook.prepare(hook.context, asset) catch |err| {
                            result.problem = err;
                            result.changed = c.failBackground(job.background_request.?.request, err);
                            break :attempt;
                        };
                        result.changed = c.completeBackground(asset) catch |err| failed: {
                            result.problem = err;
                            break :failed false;
                        };
                        job.background_result = null; // completion always consumes.
                        if (self.background_preflight) |hook| hook.complete(hook.context, result.changed);
                    }
                } else if (!cancelled) if (job.problem) |err| {
                    result.changed = c.failBackground(job.background_request.?.request, err);
                };
            },
            .load_library, .favorite, .remove => if (job.problem == null) {
                if (registry.revision != job.expected_revision) {
                    result.problem = error.StaleRegistryRevision;
                } else if (job.kind == .remove and (controller == null or !std.mem.eql(u8, saved_theme, job.saved_id.?) or !std.mem.eql(u8, controller.?.model.value.ui.theme, job.draft_theme_id.?))) {
                    result.problem = error.StaleThemeReferences;
                } else {
                    var previous = registry.*;
                    registry.* = job.registry.?;
                    job.registry = null;
                    previous.deinit();
                    result.changed = true;
                }
            },
            .installation => if (job.receipt) |*receipt| {
                if (cancelled or controller == null or controller.?.draft_id != receipt.draft_id or registry.revision != job.expected_revision) {
                    self.abortInstallation(receipt) catch |err| {
                        self.installation = receipt.*;
                        result.problem = err;
                    };
                    job.receipt = null;
                    result.pending = self.busy();
                } else {
                    self.installation = receipt.*;
                    job.receipt = null;
                    result.changed = true;
                }
            },
            .abort_installation => if (job.problem != null) {
                self.installation = job.receipt;
                job.receipt = null;
            },
        }
        self.last_error = result.problem;
        return result;
    }
};

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    kind: Kind,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    problem: ?anyerror = null,
    path: ?[]u8 = null,
    id: ?[]u8 = null,
    saved_id: ?[]u8 = null,
    draft_theme_id: ?[]u8 = null,
    expected_revision: u64 = 0,
    favorite_enabled: bool = false,
    registry: ?themes.Registry = null,
    import_request: ?themes.ImportRequest = null,
    background_request: ?background.OwnedRequest = null,
    import_result: ?themes.ImportResult = null,
    background_result: ?background.Prepared = null,
    receipt: ?themes.Installation = null,

    fn work(self: *Job) !void {
        switch (self.kind) {
            .load_library => {
                try self.registry.?.loadInstalled(self.io, self.dir);
                try self.registry.?.loadFavorites(self.io, self.dir, self.path.?);
            },
            .theme => if (!self.cancelled.load(.acquire)) {
                self.import_result = try themes.Registry.readImport(self.io, self.dir, self.allocator, self.import_request.?, self.path.?);
            },
            .background => if (!self.cancelled.load(.acquire)) {
                self.background_result = try background.prepare(self.io, self.dir, self.allocator, self.background_request.?.request, .{});
            },
            .favorite => try self.registry.?.favorite(self.io, self.dir, self.path.?, self.id.?, self.expected_revision, self.favorite_enabled),
            .remove => try self.registry.?.remove(self.io, self.dir, self.id.?, self.expected_revision, .{ .saved = self.saved_id.?, .draft = self.draft_theme_id.? }),
            .installation => if (!self.cancelled.load(.acquire)) try self.receipt.?.prepare(self.io, self.dir, &self.registry.?),
            .abort_installation => try self.receipt.?.abort(self.io, self.dir),
        }
    }
    fn run(self: *Job) void {
        self.work() catch |err| {
            self.problem = err;
        };
        self.done.store(true, .release);
    }
    fn destroy(self: *Job) void {
        if (self.path) |value| self.allocator.free(value);
        if (self.id) |value| self.allocator.free(value);
        if (self.saved_id) |value| self.allocator.free(value);
        if (self.draft_theme_id) |value| self.allocator.free(value);
        if (self.registry) |*value| value.deinit();
        if (self.background_request) |*value| value.deinit();
        if (self.import_result) |*value| value.deinit(self.allocator);
        if (self.background_result) |*value| value.deinit(self.allocator);
        if (self.receipt) |*value| value.deinit();
        self.allocator.destroy(self);
    }
};
