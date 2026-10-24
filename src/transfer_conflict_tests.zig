const std = @import("std");
const C = @import("transfer/conflict.zig");
const identity = @import("host/identity.zig");
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 9 };
const resource: identity.ResourceOwner = .{ .session = owner };
const seeds = [_]C.EntrySeed{
    .{ .job = 41, .attempt = 2, .source_path = "/source/release.tar.gz", .target_path = "/target/release.tar.gz", .source_metadata = .{ .kind = .file, .size = 128, .modified_at = 10 } },
    .{ .job = 42, .attempt = 3, .source_path = "/source/b.tar.gz", .target_path = "/target/b.tar.gz", .source_metadata = .{ .kind = .file, .size = 256, .modified_at = 11 } },
    .{ .job = 43, .attempt = 1, .source_path = "/source/c.tar.gz", .target_path = "/target/c.tar.gz", .source_metadata = .{ .kind = .file, .size = 512, .modified_at = 12 } },
    .{ .job = 44, .attempt = 1, .source_path = "/source/d.tar.gz", .target_path = "/target/d.tar.gz", .source_metadata = .{ .kind = .file, .size = 1024, .modified_at = 13 } },
};
fn intent(id: u64, direction: @FieldType(C.Intent, "direction")) C.Intent {
    const local: C.Endpoint = .{ .local_fs = .{ .binding_id = 11, .binding_generation = 7 } };
    const remote: C.Endpoint = .{ .sftp = .{ .binding_id = 12, .binding_generation = 3, .resource_owner = resource, .origin_session = owner, .connection_snapshot_id = 91 } };
    return .{ .id = id, .original_owner = owner, .resource_owner = resource, .direction = direction, .source_endpoint = if (direction == .upload) local else remote, .target_endpoint = if (direction == .upload) remote else local, .entries = &seeds };
}
fn version(revision: u64) C.TargetVersion {
    return .{ .revision = revision, .metadata = .{ .kind = .file, .size = 124, .modified_at = revision + 20 } };
}
fn current() C.Observation {
    return .{ .present = version(1) };
}
fn revalidate(model: *C.Model, key: C.Key) !C.Next {
    const request = (try model.next(key)).target_revalidate;
    return model.observe(request, current());
}

test "transfer conflict starts unapproved and freezes exact owner endpoints attempt and raw paths" {
    const source = try std.testing.allocator.dupe(u8, "/original/source.txt");
    defer std.testing.allocator.free(source);
    var original = intent(1, .upload);
    var seed = seeds[0];
    seed.source_path = source;
    original.entries = &.{seed};
    var model = try C.Model.init(std.testing.allocator, original);
    defer model.deinit();
    @memset(source, 'x');
    const prompt = try model.offer(0, version(1));
    try std.testing.expect(prompt.selection.choice == null);
    try std.testing.expectError(error.NoSelection, model.next(prompt.key));
    try std.testing.expectEqualStrings("/original/source.txt", prompt.source_path);
    try std.testing.expectEqualStrings("/target/release.tar.gz", prompt.target_path);
    try std.testing.expectEqual(owner, prompt.key.original_owner);
    try std.testing.expectEqual(@as(u32, 2), prompt.key.attempt);
    try model.select(prompt.key, .{ .choice = .skip });
    const check = (try model.next(prompt.key)).target_revalidate;
    try std.testing.expectEqual(@as(u64, 12), check.endpoint.sftp.binding_id);
    try std.testing.expectEqual(@as(u64, 3), check.endpoint.sftp.binding_generation);
    var wrong = check;
    wrong.endpoint.sftp.binding_generation += 1;
    try std.testing.expectError(error.StaleCheck, model.observe(wrong, current()));
    wrong = check;
    wrong.path = "/another/target";
    try std.testing.expectError(error.StaleCheck, model.observe(wrong, current()));
    var stale = prompt.key;
    stale.attempt += 1;
    try std.testing.expectError(error.StaleConflict, model.select(stale, .{ .choice = .overwrite }));
    stale = prompt.key;
    stale.owner.session.generation += 1;
    try std.testing.expectError(error.StaleConflict, model.next(stale));
    const done = (try model.observe(check, current())).completed;
    try std.testing.expectEqual(.skipped, done.kind);
    try std.testing.expectEqual(@as(usize, 1), model.skippedCount());
}

test "transfer conflict skip policy is only current Intent remaining entries and never reports transferred bytes" {
    var model = try C.Model.init(std.testing.allocator, intent(2, .upload));
    defer model.deinit();
    const first = try model.offer(0, version(1));
    try model.select(first.key, .{ .choice = .skip });
    try std.testing.expectEqual(.skipped, (try revalidate(&model, first.key)).completed.kind);
    const second = try model.offer(1, version(1));
    try model.select(second.key, .{ .choice = .skip, .apply_to_remaining = true });
    _ = try revalidate(&model, second.key);
    const third = try model.offer(2, version(1));
    try std.testing.expectEqual(C.Choice.skip, third.selection.choice.?);
    try std.testing.expectEqual(.skipped, (try revalidate(&model, third.key)).completed.kind);
    try std.testing.expectEqual(@as(usize, 3), model.skippedCount());
    try std.testing.expectEqual(first.key, (try model.snapshot(0)).key);
    var later = try C.Model.init(std.testing.allocator, intent(3, .upload));
    defer later.deinit();
    const independent = try later.offer(0, version(1));
    try std.testing.expect(independent.selection.choice == null);
    try std.testing.expectError(error.NoSelection, later.next(independent.key));
    try std.testing.expectError(error.StaleConflict, later.next(third.key));
}

test "transfer conflict save as preserves invalid input checks actual duplicate and does not copy batch literal" {
    var model = try C.Model.init(std.testing.allocator, intent(4, .download));
    defer model.deinit();
    const prompt = try model.offer(0, version(1));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b", "\xff" }) |bad| {
        try model.select(prompt.key, .{ .choice = .save_as, .rename = bad });
        try std.testing.expectError(error.InvalidName, model.next(prompt.key));
        try std.testing.expectEqualStrings(bad, (try model.snapshot(0)).selection.rename);
    }
    try model.select(prompt.key, .{ .choice = .save_as, .rename = "release-new.tar.gz", .apply_to_remaining = true });
    const collision_probe = (try revalidate(&model, prompt.key)).candidate_stat;
    try std.testing.expectEqualStrings("/target/release-new.tar.gz", collision_probe.path);
    const collision = (try model.observe(collision_probe, current())).waiting;
    try std.testing.expectEqual(C.Issue.name_exists, collision.issue.?);
    try std.testing.expectEqualStrings("release-new.tar.gz", collision.selection.rename);
    const probe = (try revalidate(&model, prompt.key)).candidate_stat;
    const action = (try model.observe(probe, .absent)).execute;
    try std.testing.expectEqual(.exclusive_create, std.meta.activeTag(action.action));
    try std.testing.expectEqualStrings(seeds[0].source_path, action.source_path);
    try std.testing.expectEqual(C.Phase.executing, (try model.snapshot(0)).phase);
    try std.testing.expectError(error.ExecutionPending, model.next(prompt.key));
    try std.testing.expectError(error.ResultTargetMismatch, model.finish(action.ticket, .{ .created = "/target/unrelated" }));
    const done = (try model.finish(action.ticket, .{ .created = action.target_path })).completed;
    try std.testing.expectEqual(.created, done.kind);
    try std.testing.expectEqualStrings("/target/release-new.tar.gz", done.actual_target_path);
    try std.testing.expectError(error.StaleExecution, model.finish(action.ticket, .{ .created = action.target_path }));
    const remaining = try model.offer(1, version(1));
    try std.testing.expectEqual(C.Choice.save_as, remaining.selection.choice.?);
    try std.testing.expectEqualStrings("", remaining.selection.rename);
    try std.testing.expectError(error.InvalidName, model.next(remaining.key));
}

test "transfer conflict keep both preserves tar gz and handles stat and exclusive create races with actual receipt" {
    var model = try C.Model.init(std.testing.allocator, intent(5, .upload));
    defer model.deinit();
    const prompt = try model.offer(0, version(1));
    try model.select(prompt.key, .{ .choice = .keep_both });
    const first = (try revalidate(&model, prompt.key)).candidate_stat;
    try std.testing.expectEqualStrings("/target/release (1).tar.gz", first.path);
    const second = (try model.observe(first, current())).candidate_stat;
    try std.testing.expectEqualStrings("/target/release (2).tar.gz", second.path);
    const raced = (try model.observe(second, .absent)).execute;
    try std.testing.expectEqual(.exclusive_create, std.meta.activeTag(raced.action));
    const third = (try model.finish(raced.ticket, .name_exists)).candidate_stat;
    try std.testing.expectEqualStrings("/target/release (3).tar.gz", third.path);
    const created = (try model.observe(third, .absent)).execute;
    try std.testing.expectEqual(C.Phase.executing, (try model.snapshot(0)).phase);
    const done = (try model.finish(created.ticket, .{ .created = created.target_path })).completed;
    try std.testing.expectEqualStrings("/target/release (3).tar.gz", done.actual_target_path);
    try std.testing.expectEqualStrings(seeds[0].target_path, (try model.snapshot(0)).target_path);
    try std.testing.expectEqual(@as(usize, 0), model.skippedCount());
}

test "transfer conflict overwrite requires second confirmation fresh target and one shot approval in both directions" {
    inline for (.{ .upload, .download }) |direction| {
        var model = try C.Model.init(std.testing.allocator, intent(6, direction));
        defer model.deinit();
        const prompt = try model.offer(0, version(1));
        try model.select(prompt.key, .{ .choice = .overwrite });
        const first = (try revalidate(&model, prompt.key)).overwrite_confirmation;
        try std.testing.expectEqual(direction, first.direction);
        try std.testing.expectEqual(owner, first.original_owner);
        try std.testing.expectEqualStrings(seeds[0].target_path, first.targets[0].path);
        try std.testing.expectEqual(@as(usize, 1), first.targets.len);
        _ = try model.returnToChoice(first.ticket);
        try std.testing.expectEqual(C.Phase.waiting, (try model.snapshot(0)).phase);
        try std.testing.expectError(error.StaleConfirmation, model.confirmOverwrite(first.ticket));
        const confirmation = (try revalidate(&model, prompt.key)).overwrite_confirmation;
        var wrong = confirmation.ticket;
        wrong.owner.session.generation += 1;
        try std.testing.expectError(error.StaleConfirmation, model.confirmOverwrite(wrong));
        try model.confirmOverwrite(confirmation.ticket);
        const fresh_stat = (try model.next(prompt.key)).target_revalidate;
        const changed = (try model.observe(fresh_stat, .{ .present = version(2) })).waiting;
        try std.testing.expectEqual(C.Issue.target_changed, changed.issue.?);
        try std.testing.expect(changed.selection.choice == null);
        try std.testing.expect(changed.key.revision > prompt.key.revision);
        try std.testing.expectError(error.StaleConflict, model.next(prompt.key));
        try std.testing.expectError(error.NoSelection, model.next(changed.key));
        try model.select(changed.key, .{ .choice = .overwrite });
        const c2 = (try model.observe((try model.next(changed.key)).target_revalidate, .{ .present = version(2) })).overwrite_confirmation;
        try model.confirmOverwrite(c2.ticket);
        const execution = (try model.observe((try model.next(changed.key)).target_revalidate, .{ .present = version(2) })).execute;
        try std.testing.expectEqual(version(2), execution.action.replace_verified);
        _ = try model.finish(execution.ticket, .failed);
        // An accepted operation consumes approval, even if actual IO then fails.
        const again = try model.observe((try model.next(changed.key)).target_revalidate, .{ .present = version(2) });
        try std.testing.expectEqual(.overwrite_confirmation, std.meta.activeTag(again));
        try model.confirmOverwrite(again.overwrite_confirmation.ticket);
        const final = (try model.observe((try model.next(changed.key)).target_revalidate, .{ .present = version(2) })).execute;
        try std.testing.expectEqual(.replaced, (try model.finish(final.ticket, .replaced)).completed.kind);
    }
}

test "transfer conflict batch overwrite freezes known remaining versions and excludes processed or later targets" {
    var model = try C.Model.init(std.testing.allocator, intent(7, .upload));
    defer model.deinit();
    const processed = try model.offer(0, version(1));
    try model.select(processed.key, .{ .choice = .skip });
    _ = try revalidate(&model, processed.key);
    const current_prompt = try model.offer(1, version(1));
    const remaining = try model.offer(2, version(1));
    try model.select(current_prompt.key, .{ .choice = .overwrite, .apply_to_remaining = true });
    const batch = (try revalidate(&model, current_prompt.key)).overwrite_confirmation;
    try std.testing.expectEqual(@as(usize, 2), batch.targets.len);
    try std.testing.expectEqual(current_prompt.key, batch.targets[0].key);
    try std.testing.expectEqual(remaining.key, batch.targets[1].key);
    _ = try model.offer(2, version(2));
    try std.testing.expectError(error.StaleConfirmation, model.confirmOverwrite(batch.ticket));
    const reviewed_again = (try revalidate(&model, current_prompt.key)).overwrite_confirmation;
    try std.testing.expectEqual(version(2), reviewed_again.targets[1].version);
    try model.confirmOverwrite(reviewed_again.ticket);
    const changed = try model.offer(2, version(3));
    try std.testing.expect(changed.selection.choice == null);
    const actual = (try revalidate(&model, current_prompt.key)).execute;
    try std.testing.expectEqual(.replace_verified, std.meta.activeTag(actual.action));
    const later = try model.offer(3, version(1));
    try std.testing.expectEqual(C.Choice.overwrite, later.selection.choice.?);
    const extra = (try revalidate(&model, later.key)).overwrite_confirmation;
    try std.testing.expectEqual(@as(usize, 1), extra.targets.len);
    try std.testing.expectEqual(later.key, extra.targets[0].key);
    try std.testing.expectEqual(C.Phase.completed, (try model.snapshot(0)).phase);
    try std.testing.expectEqual(@as(usize, 1), model.skippedCount());
}

test "transfer conflict postpone returns only original pause and invalidates pending check" {
    var model = try C.Model.init(std.testing.allocator, intent(8, .download));
    defer model.deinit();
    const prompt = try model.offer(0, version(1));
    try model.select(prompt.key, .{ .choice = .keep_both });
    const check = (try model.next(prompt.key)).target_revalidate;
    try std.testing.expectEqual(prompt.key, (try model.deferConflict(prompt.key)).pause);
    try std.testing.expectEqual(C.Phase.deferred, (try model.snapshot(0)).phase);
    try std.testing.expectError(error.StaleCheck, model.observe(check, current()));
    try std.testing.expectEqual(.pause, std.meta.activeTag(try model.next(prompt.key)));
    try std.testing.expectEqual(@as(usize, 0), model.skippedCount());
}
