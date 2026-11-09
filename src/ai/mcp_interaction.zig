//! Host-mediated MCP server requests. The server never gains local tool rights
//! or access to the surrounding conversation through a sampling request.
const std = @import("std");
const provider = @import("provider.zig");
const questions = @import("user_interaction.zig");
pub const Host = struct {
    context: *anyopaque,
    question: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const Option, bool, ?*provider.CancelToken) anyerror!questions.Answer,
    review: *const fn (*anyopaque, std.mem.Allocator, []const u8, std.json.Value, ?*provider.CancelToken) anyerror!void,
    sample: *const fn (*anyopaque, std.mem.Allocator, std.json.Value, ?*provider.CancelToken) anyerror![]u8,
    open: *const fn (*anyopaque, []const u8, ?*provider.CancelToken) anyerror!void,
};
pub const Option = struct { id: []const u8, label: []const u8 };
pub fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
pub fn handle(host: Host, a: std.mem.Allocator, server: @import("../config/ai_extensions.zig").Server, method: []const u8, params: std.json.Value, cancel: ?*provider.CancelToken) ![]u8 {
    if (params != .object) return error.InvalidMcpRequest;
    if (std.mem.eql(u8, method, "roots/list")) {
        const Root = struct { uri: []const u8 };
        const roots = try a.alloc(Root, server.roots.len);
        defer a.free(roots);
        for (server.roots, roots) |uri, *root| root.* = .{ .uri = uri };
        return std.json.Stringify.valueAlloc(a, .{ .roots = roots }, .{});
    }
    if (std.mem.eql(u8, method, "sampling/createMessage")) {
        if (params.object.get("tools") != null) return error.McpSamplingToolsNotNegotiated;
        try host.review(host.context, a, "sampling/createMessage · 请求模型生成", params, cancel);
        const reply = try host.sample(host.context, a, params, cancel);
        errdefer a.free(reply);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
        defer parsed.deinit();
        try host.review(host.context, a, "sampling/createMessage · 返回内容给服务", parsed.value, cancel);
        return reply;
    }
    if (!std.mem.eql(u8, method, "elicitation/create")) return error.McpMethodNotAllowed;
    const message = string(params, "message") orelse return error.InvalidMcpRequest;
    const mode = string(params, "mode") orelse "form";
    if (std.mem.eql(u8, mode, "url")) {
        const url = string(params, "url") orelse return error.InvalidMcpRequest;
        if (params.object.get("elicitationId")) |id| if (id != .string) return error.InvalidMcpRequest;
        // URL consent includes the exact destination, before opening a browser.
        host.review(host.context, a, "elicitation/create · 打开网页", params, cancel) catch |err| {
            if (err == error.ToolApprovalRejected) return action(a, "decline", null);
            return err;
        };
        try host.open(host.context, url, cancel);
        // URL-mode acceptance means consenting to visit the URL. Completion is
        // a separate server notification; secrets stay in the browser.
        return action(a, "accept", null);
    }
    if (!std.mem.eql(u8, mode, "form")) return error.InvalidMcpRequest;
    const schema = params.object.get("requestedSchema") orelse return error.InvalidMcpRequest;
    const schema_text = try std.json.Stringify.valueAlloc(a, schema, .{});
    defer a.free(schema_text);
    var validator: @import("mcp_schema.zig").Validator = .{};
    defer validator.deinit();
    try validator.validate(a, schema_text, null);
    const properties = if (schema == .object) schema.object.get("properties") orelse return error.InvalidMcpRequest else return error.InvalidMcpRequest;
    if (properties != .object) return error.InvalidMcpRequest;
    const heading = try std.fmt.allocPrint(a, "{s}\n{s}", .{ server.name, message });
    defer a.free(heading);
    const consent = try host.question(host.context, a, heading, &.{ .{ .id = "accept", .label = "填写" }, .{ .id = "decline", .label = "拒绝" }, .{ .id = "cancel", .label = "取消" } }, false, cancel);
    if (!std.mem.eql(u8, consent.option_id.?.text(), "accept")) return action(a, consent.option_id.?.text(), null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owned = arena.allocator();
    while (true) {
        var content: std.json.ObjectMap = .empty;
        var fields = properties.object.iterator();
        while (fields.next()) |field| {
            const name = field.key_ptr.*;
            const field_schema = field.value_ptr.*;
            if (field_schema != .object) return error.InvalidMcpRequest;
            const kind = string(field_schema, "type") orelse "string";
            const field_text = try std.json.Stringify.valueAlloc(owned, field_schema, .{});
            const question = try fieldQuestion(owned, server.name, name, field_schema);
            const required = required: {
                const names = schema.object.get("required") orelse break :required false;
                if (names == .array) for (names.array.items) |item| {
                    if (item == .string and std.mem.eql(u8, item.string, name)) break :required true;
                };
                break :required false;
            };
            var options: std.ArrayList(Option) = .empty;
            if (field_schema.object.get("default") != null) try options.append(owned, .{ .id = "default", .label = "使用默认值" });
            if (!required) try options.append(owned, .{ .id = "skip", .label = "跳过" });
            try options.append(owned, .{ .id = "cancel", .label = "取消填写" });
            var invalid = false;
            while (true) {
                const prompt = if (invalid) try std.fmt.allocPrint(owned, "输入不符合要求，请重试。\n{s}", .{question}) else question;
                const answer = try host.question(host.context, a, prompt, options.items, true, cancel);
                if (answer.option_id) |id| {
                    if (std.mem.eql(u8, id.text(), "cancel")) return action(a, "cancel", null);
                    if (std.mem.eql(u8, id.text(), "skip")) break;
                    try content.put(owned, name, field_schema.object.get("default").?);
                } else {
                    const value: std.json.Value = if (std.mem.eql(u8, kind, "string")) .{ .string = try owned.dupe(u8, answer.text.text()) } else parsed: {
                        if (std.mem.eql(u8, kind, "boolean")) {
                            if (std.mem.eql(u8, answer.text.text(), "是")) break :parsed .{ .bool = true };
                            if (std.mem.eql(u8, answer.text.text(), "否")) break :parsed .{ .bool = false };
                        }
                        if (std.mem.eql(u8, kind, "array")) {
                            var values: std.array_list.Managed(std.json.Value) = .init(owned);
                            var parts = std.mem.splitScalar(u8, answer.text.text(), ',');
                            while (parts.next()) |part| try values.append(.{ .string = try owned.dupe(u8, std.mem.trim(u8, part, " \t\r\n")) });
                            break :parsed .{ .array = values };
                        }
                        const value = std.json.parseFromSlice(std.json.Value, owned, answer.text.text(), .{ .allocate = .alloc_always }) catch {
                            invalid = true;
                            continue;
                        };
                        break :parsed value.value;
                    };
                    validator.validate(a, field_text, value) catch {
                        invalid = true;
                        continue;
                    };
                    try content.put(owned, name, value);
                }
                break;
            }
        }
        const value: std.json.Value = .{ .object = content };
        try validator.validate(a, schema_text, value);
        // The native approval shows all entered values. A rejection offers edit,
        // decline and cancel; nothing is sent until the user accepts the review.
        host.review(host.context, a, "elicitation/create · 提交表单", value, cancel) catch |err| {
            if (err != error.ToolApprovalRejected) return err;
            const decision = try host.question(host.context, a, "表单尚未发送。", &.{ .{ .id = "edit", .label = "重新填写" }, .{ .id = "decline", .label = "拒绝提供" }, .{ .id = "cancel", .label = "取消" } }, false, cancel);
            if (std.mem.eql(u8, decision.option_id.?.text(), "edit")) continue;
            return action(a, decision.option_id.?.text(), null);
        };
        return action(a, "accept", value);
    }
}
fn fieldQuestion(a: std.mem.Allocator, server: []const u8, name: []const u8, schema: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}\n{s}\n{s}", .{ server, string(schema, "title") orelse name, string(schema, "description") orelse "" });
    const kind = string(schema, "type") orelse "string";
    if (std.mem.eql(u8, kind, "boolean")) try out.writer.writeAll("\n请填写“是”或“否”。");
    if (std.mem.eql(u8, kind, "array")) try out.writer.writeAll("\n多个值用英文逗号分隔。");
    const target = schema.object.get("items") orelse schema;
    inline for (.{ "enum", "oneOf", "anyOf" }) |key| if (target == .object) if (target.object.get(key)) |choices| {
        if (choices == .array) {
            try out.writer.writeAll("\n可选：");
            for (choices.array.items, 0..) |item, i| {
                if (i != 0) try out.writer.writeAll("、");
                const value = if (item == .string) item.string else if (item == .object) string(item, "const") orelse "" else "";
                try out.writer.writeAll(value);
                if (string(item, "title")) |title| try out.writer.print("（{s}）", .{title});
            }
        }
    };
    inline for (.{ "default", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "format", "pattern" }, .{ "默认值", "最小值", "最大值", "最少字符", "最多字符", "最少选项", "最多选项", "格式", "格式要求" }) |key, label| if (schema.object.get(key)) |value| {
        try out.writer.print("\n{s}：", .{label});
        try std.json.Stringify.value(value, .{}, &out.writer);
    };
    return out.written();
}
fn action(a: std.mem.Allocator, decision: []const u8, content: ?std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .action = decision, .content = content }, .{ .emit_null_optional_fields = false });
}
pub fn invocation(a: std.mem.Allocator, original: @import("host_tools.zig").Invocation, tool: []const u8, args: anytype) !@import("host_tools.zig").Invocation {
    var result = original;
    result.tool_id = tool;
    result.arguments_json = try std.json.Stringify.valueAlloc(a, args, .{});
    result.arguments = (try std.json.parseFromSlice(std.json.Value, a, result.arguments_json, .{ .allocate = .alloc_always })).value;
    std.crypto.hash.sha2.Sha256.hash(result.arguments_json, &result.arguments_hash, .{});
    result.canonical_arguments_hash = try @import("canonical_arguments.zig").digest(a, result.arguments);
    result.approval_sequence = null;
    return result;
}

test "v0.4 extensions elicitation validates input and lets users edit before sending" {
    const Fake = struct {
        questions_seen: usize = 0,
        reviews: usize = 0,
        fn question(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const Option, _: bool, _: ?*provider.CancelToken) !questions.Answer {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const answers = [_][]const u8{ "accept", "0", "3", "edit", "4" };
            const value = answers[self.questions_seen];
            self.questions_seen += 1;
            return .{ .option_id = if (std.mem.eql(u8, value, "accept") or std.mem.eql(u8, value, "edit")) try questions.Text(64).init(value) else null, .text = try questions.Text(4096).init(value) };
        }
        fn review(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, value: std.json.Value, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reviews += 1;
            if (self.reviews == 1) {
                try std.testing.expectEqual(@as(i64, 3), value.object.get("count").?.integer);
                return error.ToolApprovalRejected;
            }
            try std.testing.expectEqual(@as(i64, 4), value.object.get("count").?.integer);
        }
        fn sample(_: *anyopaque, _: std.mem.Allocator, _: std.json.Value, _: ?*provider.CancelToken) ![]u8 {
            return error.UnexpectedSampling;
        }
        fn open(_: *anyopaque, _: []const u8, _: ?*provider.CancelToken) !void {
            return error.UnexpectedBrowser;
        }
    };
    var fake: Fake = .{};
    const input = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"message\":\"Count\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"count\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":5}},\"required\":[\"count\"]}}", .{});
    defer input.deinit();
    const body = try handle(.{ .context = &fake, .question = Fake.question, .review = Fake.review, .sample = Fake.sample, .open = Fake.open }, std.testing.allocator, .{ .id = "form", .name = "Form", .program = "/usr/bin/true" }, "elicitation/create", input.value, null);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"action\":\"accept\",\"content\":{\"count\":4}}", body);
    try std.testing.expectEqual(@as(usize, 5), fake.questions_seen);
    try std.testing.expectEqual(@as(usize, 2), fake.reviews);
}

test "v0.4 extensions URL elicitation accepts navigation separately from completion and can decline" {
    const Fake = struct {
        decline: bool = false,
        opened: usize = 0,
        fn question(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const Option, _: bool, _: ?*provider.CancelToken) !questions.Answer {
            return error.UnexpectedQuestion;
        }
        fn review(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: std.json.Value, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.decline) return error.ToolApprovalRejected;
        }
        fn sample(_: *anyopaque, _: std.mem.Allocator, _: std.json.Value, _: ?*provider.CancelToken) ![]u8 {
            return error.UnexpectedSampling;
        }
        fn open(raw: *anyopaque, url: []const u8, _: ?*provider.CancelToken) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("https://example.test/interaction", url);
            self.opened += 1;
        }
    };
    const input = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"mode\":\"url\",\"message\":\"Visit the service\",\"url\":\"https://example.test/interaction\",\"elicitationId\":\"one\"}", .{});
    defer input.deinit();
    var fake: Fake = .{};
    const callbacks: Host = .{ .context = &fake, .question = Fake.question, .review = Fake.review, .sample = Fake.sample, .open = Fake.open };
    const server: @import("../config/ai_extensions.zig").Server = .{ .id = "url", .name = "URL", .program = "/usr/bin/true" };
    const accepted = try handle(callbacks, std.testing.allocator, server, "elicitation/create", input.value, null);
    defer std.testing.allocator.free(accepted);
    try std.testing.expectEqualStrings("{\"action\":\"accept\"}", accepted);
    try std.testing.expectEqual(@as(usize, 1), fake.opened);
    fake.decline = true;
    const declined = try handle(callbacks, std.testing.allocator, server, "elicitation/create", input.value, null);
    defer std.testing.allocator.free(declined);
    try std.testing.expectEqualStrings("{\"action\":\"decline\"}", declined);
    try std.testing.expectEqual(@as(usize, 1), fake.opened);
}
