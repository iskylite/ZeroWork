//! D3DCompiler Shader Model 5 modules. Entry points compile eagerly and own DXBC.
const std = @import("std");
const gpu = @import("../gpu.zig");
const NativeShader = opaque {};
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern fn zenit_d12_shader_compile([*]const u8, usize, [*:0]const u8, u32, *?*NativeShader, *?[*]u8, *usize) c_int;
extern fn zenit_d12_shader_retain(*NativeShader) void;
extern fn zenit_d12_shader_release(*NativeShader) void;
extern fn zenit_d12_shader_data(*NativeShader) [*]const u8;
extern fn zenit_d12_shader_size(*NativeShader) usize;
extern fn zenit_d12_shader_atomic_switch(*NativeShader, *?*NativeShader) c_int;
extern fn zenit_d12_shader_non_uniform_buffer_atomics(*NativeShader) c_int;
extern fn zenit_d12_shader_diagnostic_free([*]u8) void;
pub const ResourceBinding = extern struct { group: u32, binding: u32, kind: u32, count: u32, dimension: u32, sample_type: u32, sampler_type: u32, stride: u32, min_size: u64 };
extern fn zenit_d12_shader_bindings(*NativeShader, ?[*]ResourceBinding, u32, *u32) c_int;
const Entry = struct { name: []u8, stage: gpu.ShaderStage, raw: *NativeShader };
pub const ShaderModule = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    /// Initialize diagnostic to null. Caller owns any returned diagnostic, on
    /// both success and failure. It contains the last compiler message received.
    pub fn compileWithDiagnostics(allocator: std.mem.Allocator, source: gpu.HlslSource, diagnostic: *?[]u8) !ShaderModule {
        if (diagnostic.* != null) return error.DiagnosticAlreadyOwned;
        if (source.code.len == 0 or std.mem.indexOfScalar(u8, source.code, 0) != null or source.entry_points.len == 0) return error.InvalidShaderDescriptor;
        for (source.entry_points, 0..) |entry, i| {
            if (entry.name.len == 0 or std.mem.indexOfScalar(u8, entry.name, 0) != null) return error.InvalidShaderDescriptor;
            for (source.entry_points[0..i]) |previous| if (std.mem.eql(u8, entry.name, previous.name)) return error.DuplicateShaderEntry;
        }
        const entries = try allocator.alloc(Entry, source.entry_points.len);
        var created: usize = 0;
        errdefer {
            for (entries[0..created]) |entry| {
                zenit_d12_shader_release(entry.raw);
                allocator.free(entry.name);
            }
            allocator.free(entries);
        }
        for (source.entry_points, entries) |entry, *output| {
            const name = try allocator.dupeSentinel(u8, entry.name, 0);
            defer allocator.free(name);
            var raw: ?*NativeShader = null;
            var message: ?[*]u8 = null;
            var message_size: usize = 0;
            const compile_start = GetTickCount64();
            const status = zenit_d12_shader_compile(source.code.ptr, source.code.len, name.ptr, switch (entry.stage) {
                .vertex => 1,
                .fragment => 2,
                .compute => 3,
            }, &raw, &message, &message_size);
            // A cache hit returns in well under a millisecond; a real D3DCompile
            // of the larger sources takes hundreds of ms to seconds. Report the
            // slow ones so a slow first frame can be attributed.
            const compile_ms = GetTickCount64() -% compile_start;
            if (compile_ms >= 100) std.log.info("[{s}] HLSL compile {s} took {d} ms", .{ @tagName(gpu.backend_kind), entry.name, compile_ms });
            defer if (message) |bytes| zenit_d12_shader_diagnostic_free(bytes);
            errdefer if (raw) |shader| zenit_d12_shader_release(shader);
            if (message) |bytes| {
                const copy = try allocator.dupe(u8, bytes[0..message_size]);
                if (diagnostic.*) |old| allocator.free(old);
                diagnostic.* = copy;
            }
            switch (status) {
                0 => {},
                1 => return error.InvalidShaderDescriptor,
                3 => return error.ShaderCompilationFailed,
                else => return error.ShaderCompilerFailure,
            }
            output.* = .{ .name = try allocator.dupe(u8, entry.name), .stage = entry.stage, .raw = raw.? };
            created += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }
    pub fn getFunction(self: *const ShaderModule, name: []const u8) !ShaderFunction {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.name, name)) {
            zenit_d12_shader_retain(entry.raw);
            return .{ .raw = entry.raw, .stage = entry.stage };
        };
        return error.FunctionNotFound;
    }
    pub fn deinit(self: *ShaderModule) void {
        for (self.entries) |entry| {
            zenit_d12_shader_release(entry.raw);
            self.allocator.free(entry.name);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};
pub const ShaderFunction = struct {
    raw: *NativeShader,
    stage: gpu.ShaderStage,
    /// Borrowed, valid until this function's deinit; independent of its module.
    /// Owned reflection snapshot; free with the supplied allocator.
    pub fn resourceBindings(self: *const ShaderFunction, allocator: std.mem.Allocator) ![]ResourceBinding {
        var count: u32 = 0;
        if (zenit_d12_shader_bindings(self.raw, null, 0, &count) != 0) return error.ShaderReflectionFailed;
        const bindings = try allocator.alloc(ResourceBinding, count);
        errdefer allocator.free(bindings);
        if (count != 0) switch (zenit_d12_shader_bindings(self.raw, bindings.ptr, count, &count)) {
            0 => {},
            3 => return error.UnsupportedShaderResource,
            else => return error.ShaderReflectionFailed,
        };
        return bindings;
    }
    pub fn requiresNonUniformUavBufferArrayAtomics(self: *const ShaderFunction) !bool {
        if (gpu.backend_kind != .d3d12) return false;
        return switch (zenit_d12_shader_non_uniform_buffer_atomics(self.raw)) {
            0 => false,
            1 => true,
            else => error.InvalidShaderBytecode,
        };
    }
    pub fn retained(self: *const ShaderFunction) ShaderFunction {
        zenit_d12_shader_retain(self.raw);
        return self.*;
    }
    pub fn withAtomicSwitch(self: *const ShaderFunction) !ShaderFunction {
        var raw: ?*NativeShader = null;
        if (zenit_d12_shader_atomic_switch(self.raw, &raw) != 0)
            return error.UnsupportedNonUniformUavBufferArrayAtomics;
        return .{ .raw = raw.?, .stage = self.stage };
    }
    pub fn bytecode(self: *const ShaderFunction) []const u8 {
        return zenit_d12_shader_data(self.raw)[0..zenit_d12_shader_size(self.raw)];
    }
    pub fn deinit(self: *ShaderFunction) void {
        zenit_d12_shader_release(self.raw);
        self.* = undefined;
    }
};
