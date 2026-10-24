//! Backend interface contract: compile-time check that a backend implements every symbol the
//! renderer depends on.
//!
//! ## Why needed
//!
//! With `gpu.Backend` as a plain alias of `@import("metal/backend.zig")`, the abstraction is never
//! falsified: with one implementation there is no way to know whether `gpu.Backend.*` signatures
//! are backend-neutral or accidentally welded to Metal semantics.
//!
//! Here "what a backend must provide" is a **compile-time assertion**: a missing symbol or a wrong
//! kind (type vs function) fails `zig build` immediately, not when some `@import` path is
//! instantiated.
//!
//! ## Why these symbols
//! The roster is every `gpu.Backend.<Symbol>` referenced in `src/render`, `src/ui`,
//! `src/zenit_app`. The contract locks that **depended-on subset**; extra symbols are allowed,
//! missing ones are not.
const std = @import("std");

/// Type symbols actually depended on by render layer.
///
/// Order by measured reference frequency (Buffer highest); purely for reading hotspots first.
pub const required_types = [_][]const u8{
    "Instance",
    "Adapter",
    "Device",
    "Queue",
    "Buffer",
    "Texture",
    "TextureBinding",
    "TextureView",
    "Sampler",
    "Surface",
    "SurfaceTexture",
    "SurfaceConfiguration",
    "CommandEncoder",
    "CommandBuffer",
    "RenderPass",
    "ShaderModule",
    "ShaderFunction",
    "RenderPipeline",
    "RenderPipelineDescriptor",
    "VertexBufferLayoutDescriptor",
    "VertexAttributeDescriptor",
    "BlendState",
    "FrameSync",
};

/// Free function symbols actually depended on by render layer.
pub const required_functions = [_][]const u8{
    "createRenderPipeline",
    "writePngRgba",
};

/// Compile-time validation: does `BackendType` satisfy the contract?
///
/// Call once at `gpu.zig` top level on the selected backend. Failure gives **specific missing
/// symbol** compile error, far better to locate than indirect "undefined" errors.
pub fn verify(comptime BackendType: type, comptime backend_name: []const u8) void {
    comptime {
        for (required_types) |name| {
            if (!@hasDecl(BackendType, name)) {
                @compileError("GPU backend '" ++ backend_name ++
                    "' is missing required type '" ++ name ++
                    "' (see src/gpu/backend_contract.zig)");
            }
            const decl = @field(BackendType, name);
            if (@TypeOf(decl) != type) {
                @compileError("GPU backend '" ++ backend_name ++ "' declares '" ++ name ++
                    "' but it is not a type (see src/gpu/backend_contract.zig)");
            }
        }
        for (required_functions) |name| {
            if (!@hasDecl(BackendType, name)) {
                @compileError("GPU backend '" ++ backend_name ++
                    "' is missing required function '" ++ name ++
                    "' (see src/gpu/backend_contract.zig)");
            }
            const info = @typeInfo(@TypeOf(@field(BackendType, name)));
            if (info != .@"fn") {
                @compileError("GPU backend '" ++ backend_name ++ "' declares '" ++ name ++
                    "' but it is not a function (see src/gpu/backend_contract.zig)");
            }
        }
    }
}

test "contract accepts a backend that declares every required symbol" {
    // Minimal compliant backend: symbols **exist and correct type**, no need to actually run.
    const Ok = struct {
        pub const Instance = struct {};
        pub const Adapter = struct {};
        pub const Device = struct {};
        pub const Queue = struct {};
        pub const Buffer = struct {};
        pub const Texture = struct {};
        pub const TextureBinding = struct {};
        pub const TextureView = struct {};
        pub const Sampler = struct {};
        pub const Surface = struct {};
        pub const SurfaceTexture = struct {};
        pub const SurfaceConfiguration = struct {};
        pub const CommandEncoder = struct {};
        pub const CommandBuffer = struct {};
        pub const RenderPass = struct {};
        pub const ShaderModule = struct {};
        pub const ShaderFunction = struct {};
        pub const RenderPipeline = struct {};
        pub const RenderPipelineDescriptor = struct {};
        pub const VertexBufferLayoutDescriptor = struct {};
        pub const VertexAttributeDescriptor = struct {};
        pub const BlendState = struct {};
        pub const FrameSync = struct {};
        pub fn createRenderPipeline() void {}
        pub fn writePngRgba() void {}
    };
    verify(Ok, "test-ok");
}

test "contract lists stay in sync with themselves" {
    // Typo prevention: neither list can be empty, no duplicates (duplicates repeat "missing symbol"
    // error, imply copy-paste accidents).
    try std.testing.expect(required_types.len > 0);
    try std.testing.expect(required_functions.len > 0);
    for (required_types, 0..) |a, i| {
        for (required_types[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
    for (required_functions, 0..) |a, i| {
        for (required_functions[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}
