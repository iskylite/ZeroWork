/// FormOf(T), comptime generic form data + validation layer
///
/// Implements fine-grained form state management based on StoreOf(T):
/// - Each field has independent Signal (value + error + touched + dirty)
/// - Extracts T.rules at comptime, generates validation functions at compile-time
/// - Validation timing configurable (onChange / onBlur / onSubmit)
///
/// Usage:
/// ```zig
/// const LoginForm = struct {
///     email: []const u8,
///     password: []const u8,
///     pub const rules = .{
///         .email = struct {
///             fn validate(v: []const u8) ValidationResult {
///                 if (v.len == 0) return .{ .valid = false, .message = "required" };
///                 return .{ .valid = true };
///             }
///         }.validate,
///     };
/// };
///
/// const form = try FormOf(LoginForm).create(scope, .{ .email = "", .password = "" }, .{});
/// form.setValue(.email, "test@example.com");   // text field copies content
/// // field signal can be bound directly to component: W.Input(.{ .value = form.field(.email) })
/// form.touchField(.email);
/// if (form.validateAll()) { ... }
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Scope = core.Scope;
const Signal = core.Signal;
const Handler = core.Handler;
const StoreOf = @import("../../reactive/store.zig").StoreOf;

/// Validation timing
pub const ValidateTrigger = enum {
    /// Validate immediately on value change
    on_change,
    /// Validate on blur
    on_blur,
    /// Validate only on submit
    on_submit,
};

/// Validation rule return value
pub const ValidationResult = struct {
    valid: bool,
    message: ?[]const u8 = null,
};

/// Per-field metadata
pub const FieldMeta = struct {
    /// Error message (null = no error)
    error_sig: *Signal(?[]const u8),
    /// Whether touched (true after blur)
    touched_sig: *Signal(bool),
    /// Whether modified (value != initial)
    dirty_sig: *Signal(bool),
};

/// comptime generic form
pub fn FormOf(comptime T: type) type {
    const field_count = @import("zenit_reflection").fields(T).len;
    const has_rules = @hasDecl(T, "rules");

    return struct {
        const Self = @This();
        pub const FieldEnum = std.meta.FieldEnum(T);

        store: StoreOf(T),
        metas: [field_count]FieldMeta,
        scope: *Scope,
        trigger: ValidateTrigger,
        /// Reset initial values; text fields are form's own copies (freed on destroy)
        initial_values: T,
        initial_text: [field_count]?[]u8 = @as([field_count]?[]u8, @splat(null)),

        /// Validated submission: snapshot of values (text slices valid only during callback)
        on_submit: ?Handler(T),

        /// Create Form instance
        pub fn create(
            scope: *Scope,
            initial: T,
            config: struct {
                trigger: ValidateTrigger = .on_blur,
                on_submit: ?Handler(T) = null,
            },
        ) !*Self {
            const form_scope = try scope.childScope();
            errdefer form_scope.dispose();
            const store = try StoreOf(T).create(form_scope, initial);

            var metas: [field_count]FieldMeta = undefined;
            inline for (0..field_count) |i| {
                metas[i] = .{
                    .error_sig = try form_scope.createSignal(?[]const u8, null),
                    .touched_sig = try form_scope.createSignal(bool, false),
                    .dirty_sig = try form_scope.createSignal(bool, false),
                };
            }

            const self = try form_scope.allocator.create(Self);
            self.* = .{
                .store = store,
                .metas = metas,
                .scope = form_scope,
                .trigger = config.trigger,
                .initial_values = initial,
                .on_submit = config.on_submit,
            };
            // On adopt failure, destroy self immediately (initial_text all empty at this point)
            try form_scope.adoptResource(@ptrCast(self), struct {
                fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                    const s: *Self = @ptrCast(@alignCast(ptr));
                    for (s.initial_text) |buf| if (buf) |b| alloc.free(b);
                    alloc.destroy(s);
                }
            }.destroy);
            // Copy text initial values: caller may pass temp buffer, needed for reset
            inline for (@import("zenit_reflection").fields(T), 0..) |f, i| {
                if (f.type == []const u8) {
                    const copy = try form_scope.allocator.dupe(u8, @field(initial, f.name));
                    self.initial_text[i] = copy;
                    @field(self.initial_values, f.name) = copy;
                }
            }

            return self;
        }

        /// Get field value (auto-track dependencies)
        pub fn get(self: *const Self, comptime fe: FieldEnum) FieldType(fe) {
            return self.store.get(fe);
        }

        /// Set field value + mark dirty + validate per strategy
        pub fn setValue(self: *Self, comptime fe: FieldEnum, value: FieldType(fe)) void {
            self.store.set(fe, value);
            const idx = @backingInt(fe);
            self.metas[idx].dirty_sig.set(true);
            if (self.trigger == .on_change) {
                self.validateField(fe);
            }
        }

        /// Field signal (owned text / regular value), can bind directly to component
        pub fn field(self: *const Self, comptime f: FieldEnum) *Signal(FieldType(f)) {
            return self.store.field(f);
        }

        /// Mark field touched (called on blur)
        pub fn touchField(self: *Self, comptime fe: FieldEnum) void {
            const idx = @backingInt(fe);
            self.metas[idx].touched_sig.set(true);
            if (self.trigger == .on_blur) {
                self.validateField(fe);
            }
        }

        /// Validate single field (extract rules at comptime)
        pub fn validateField(self: *Self, comptime fe: FieldEnum) void {
            const idx = @backingInt(fe);
            if (has_rules) {
                const field_name = @import("zenit_reflection").fields(T)[idx].name;
                const RulesType = @TypeOf(T.rules);
                if (@hasField(RulesType, field_name)) {
                    const rule_fn = @field(T.rules, field_name);
                    const value = self.store.get(fe);
                    const result = rule_fn(value);
                    self.metas[idx].error_sig.set(result.message);
                    return;
                }
            }
            // No rules -> clear error
            self.metas[idx].error_sig.set(null);
        }

        /// Validate all fields
        pub fn validateAll(self: *Self) bool {
            var all_valid = true;
            const values = self.store.snapshot(); // Peek all fields, no dependency tracking
            inline for (@import("zenit_reflection").fields(T), 0..) |f, i| {
                self.metas[i].touched_sig.set(true);
                if (has_rules) {
                    const RulesType = @TypeOf(T.rules);
                    if (@hasField(RulesType, f.name)) {
                        const rule_fn = @field(T.rules, f.name);
                        const value = @field(values, f.name);
                        const result = rule_fn(value);
                        self.metas[i].error_sig.set(result.message);
                        if (!result.valid) all_valid = false;
                    }
                }
            }
            return all_valid;
        }

        /// Submit handler: full validation -> on success call callback
        pub fn handleSubmit(self: *Self) void {
            if (!self.validateAll()) return;
            if (self.on_submit) |h| h.call(self.store.snapshot());
        }

        /// Handler for submit button: `.on_click = form.submitHandler()`
        pub fn submitHandler(self: *Self) Handler(void) {
            return core.Cx.simpleHandler(submitThunk, self);
        }

        fn submitThunk(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.handleSubmit();
        }

        /// Reset to initial values, clear all meta
        pub fn reset(self: *Self) void {
            inline for (@import("zenit_reflection").fields(T), 0..) |f, i| {
                const field_enum: FieldEnum = @fromBackingInt(@intCast(i));
                self.store.set(field_enum, @field(self.initial_values, f.name));
                self.metas[i].error_sig.set(null);
                self.metas[i].touched_sig.set(false);
                self.metas[i].dirty_sig.set(false);
            }
        }

        /// Get field FieldMeta (for FormField use)
        pub fn meta(self: *Self, comptime fe: FieldEnum) *FieldMeta {
            return &self.metas[@backingInt(fe)];
        }

        /// Does entire form have errors
        pub fn hasErrors(self: *Self) bool {
            for (&self.metas) |*m| {
                if (m.error_sig.peek() != null) return true;
            }
            return false;
        }

        /// Is entire form dirty
        pub fn isDirty(self: *Self) bool {
            for (&self.metas) |*m| {
                if (m.dirty_sig.peek()) return true;
            }
            return false;
        }

        /// Get field type
        fn FieldType(comptime fe: FieldEnum) type {
            return std.meta.fieldInfo(T, fe).type;
        }
    };
}

// ========== Tests ==========

test "FormOf: create and get/set" {
    const TestForm = struct {
        name: []const u8,
        age: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice", .age = 25 }, .{});

    // Read initial value
    try std.testing.expectEqualStrings("Alice", form.get(.name));
    try std.testing.expectEqual(@as(i32, 25), form.get(.age));

    // Set value
    form.setValue(.name, "Bob");
    try std.testing.expectEqualStrings("Bob", form.get(.name));

    // dirty should auto-mark
    try std.testing.expect(form.meta(.name).dirty_sig.peek());
    try std.testing.expect(!form.meta(.age).dirty_sig.peek());
}

test "FormOf: validation rules" {
    const TestForm = struct {
        email: []const u8,
        name: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "", .name = "Alice" }, .{});

    // Empty email should error
    form.validateField(.email);
    try std.testing.expectEqualStrings("Required", form.meta(.email).error_sig.peek().?);

    // After filling should pass
    form.setValue(.email, "test@example.com");
    form.validateField(.email);
    try std.testing.expect(form.meta(.email).error_sig.peek() == null);

    // name has no rules, validateField should not error
    form.validateField(.name);
    try std.testing.expect(form.meta(.name).error_sig.peek() == null);
}

test "FormOf: on_change trigger auto-validates" {
    const TestForm = struct {
        email: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{
        .trigger = .on_change,
    });

    // Set empty value -> auto-validate error
    form.setValue(.email, "");
    try std.testing.expectEqualStrings("Required", form.meta(.email).error_sig.peek().?);

    // Set valid value -> auto-clear error
    form.setValue(.email, "a@b.com");
    try std.testing.expect(form.meta(.email).error_sig.peek() == null);
}

test "FormOf: on_blur trigger" {
    const TestForm = struct {
        email: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{
        .trigger = .on_blur,
    });

    // setValue does not trigger validation (on_blur mode)
    form.setValue(.email, "");
    try std.testing.expect(form.meta(.email).error_sig.peek() == null);

    // touchField triggers validation
    form.touchField(.email);
    try std.testing.expectEqualStrings("Required", form.meta(.email).error_sig.peek().?);
    try std.testing.expect(form.meta(.email).touched_sig.peek());
}

test "FormOf: validateAll and hasErrors" {
    const TestForm = struct {
        email: []const u8,
        password: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Email required" };
                    return .{ .valid = true };
                }
            }.validate,
            .password = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len < 6) return .{ .valid = false, .message = "Min 6 chars" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "", .password = "123" }, .{});

    // validateAll should return false
    try std.testing.expect(!form.validateAll());
    try std.testing.expect(form.hasErrors());

    // Both fields should have errors
    try std.testing.expectEqualStrings("Email required", form.meta(.email).error_sig.peek().?);
    try std.testing.expectEqualStrings("Min 6 chars", form.meta(.password).error_sig.peek().?);

    // All fields should be marked touched
    try std.testing.expect(form.meta(.email).touched_sig.peek());
    try std.testing.expect(form.meta(.password).touched_sig.peek());

    // After fix should all pass
    form.setValue(.email, "a@b.com");
    form.setValue(.password, "123456");
    try std.testing.expect(form.validateAll());
    try std.testing.expect(!form.hasErrors());
}

test "FormOf: reset" {
    const TestForm = struct {
        name: []const u8,
        age: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice", .age = 25 }, .{});

    // Modify and mark dirty
    form.setValue(.name, "Bob");
    form.touchField(.name);
    form.meta(.name).error_sig.set("some error");

    try std.testing.expect(form.meta(.name).dirty_sig.peek());
    try std.testing.expect(form.meta(.name).touched_sig.peek());
    try std.testing.expect(form.meta(.name).error_sig.peek() != null);

    // Reset
    form.reset();
    try std.testing.expectEqualStrings("Alice", form.get(.name));
    try std.testing.expectEqual(@as(i32, 25), form.get(.age));
    try std.testing.expect(!form.meta(.name).dirty_sig.peek());
    try std.testing.expect(!form.meta(.name).touched_sig.peek());
    try std.testing.expect(form.meta(.name).error_sig.peek() == null);
}

test "FormOf: handleSubmit" {
    const TestForm = struct {
        email: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const CallbackState = struct {
        submitted: bool = false,
        submitted_email: []const u8 = "",
    };
    var cb_state = CallbackState{};

    const Recv = struct {
        fn submit(state: *CallbackState, values: TestForm) void {
            state.submitted = true;
            state.submitted_email = values.email;
        }
    };
    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{
        .on_submit = @import("../../reactive.zig").Callback(TestForm).from(CallbackState, &cb_state, Recv.submit),
    });

    // Empty email -> validation fail -> not submit
    form.handleSubmit();
    try std.testing.expect(!cb_state.submitted);

    // Fill valid value -> submit via submitHandler (button use)
    form.setValue(.email, "a@b.com");
    form.submitHandler().invoke();
    try std.testing.expect(cb_state.submitted);
    try std.testing.expectEqualStrings("a@b.com", cb_state.submitted_email);
}

test "FormOf: 文本字段与初值都是 form 自己的副本（临时缓冲改了不影响值与 reset）" {
    const TestForm = struct { name: []const u8 };
    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();
    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    var init_buf = "Alice".*;
    const form = try FormOf(TestForm).create(scope, .{ .name = &init_buf }, .{});
    init_buf[0] = 'X';
    var typed = "Bob".*;
    form.setValue(.name, &typed);
    typed[0] = 'Y';
    try std.testing.expectEqualStrings("Bob", form.get(.name));
    try std.testing.expect(form.field(.name) == form.store.field(.name));
    form.reset();
    try std.testing.expectEqualStrings("Alice", form.get(.name));
}

test "form: create 在任意分配点失败时不泄漏" {
    const TestForm = struct { name: []const u8, age: i32 };
    var k: usize = 0;
    while (true) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = k });
        const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
        var owner = SignalOwner.init(failing.allocator()) catch continue;
        defer owner.deinit();
        const scope = Scope.init(failing.allocator(), null, owner) catch continue;
        defer scope.dispose();
        const before = scope.children.items.len;
        if (FormOf(TestForm).create(scope, .{ .name = "a", .age = 1 }, .{})) |_| break else |_| {}
        // Failed create cannot leave half-built child scope under parent (waits for parent scope
        // release)
        try std.testing.expectEqual(before, scope.children.items.len);
        try std.testing.expect(k < 200);
    }
}

test "FormOf: isDirty" {
    const TestForm = struct {
        name: []const u8,
        age: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice", .age = 25 }, .{});

    try std.testing.expect(!form.isDirty());

    form.setValue(.name, "Bob");
    try std.testing.expect(form.isDirty());

    form.reset();
    try std.testing.expect(!form.isDirty());
}

test "FormOf: no rules struct" {
    const SimpleForm = struct {
        text: []const u8,
        count: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(SimpleForm).create(scope, .{ .text = "hello", .count = 0 }, .{});

    // No rules -> validateAll should return true
    try std.testing.expect(form.validateAll());
    try std.testing.expect(!form.hasErrors());

    form.setValue(.text, "world");
    try std.testing.expectEqualStrings("world", form.get(.text));
}
