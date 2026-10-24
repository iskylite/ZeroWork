//! Shared Linux renderer contracts; instantiated with the native driver.
pub fn For(comptime Driver: type, comptime manifest: type, comptime prefix: []const u8) type {
    return struct {
        //! Linux GPU renderer shader adapter: resolves renderer shader-source tokens onto
        //! the pre-compiled, validated SPIR-V entries of the generated
        //! `vulkan_ui_shaders` manifest (scripts/compile_vulkan_ui_shaders.py).
        //!
        //! Contract, pinned by tools/linux_vulkan_pipeline_probe.zig:
        //!   * `initFromSource` accepts exactly `zenit-vulkan:<program>` where
        //!     `<program>` names one program of the manifest. Whitespace, suffixes,
        //!     empty tokens, missing prefixes and unknown programs are rejected.
        //!   * The stored `program` slice is the manifest's own static string, never
        //!     caller memory: callers may overwrite their source buffer immediately
        //!     after a successful call. Nothing here compiles, allocates or frees
        //!     SPIR-V; the manifest already holds validated code and reflection.
        //!   * `getFunction` resolves entries only within this module's program, so
        //!     cross-program names are `ShaderFunctionNotFound`. The returned entry is
        //!     the manifest value by copy, preserving code alignment, stage and
        //!     bindings.
        //!   * The device is borrowed: no native GPU object is created or destroyed.
        //!     An inactive module is the canonical `program == ""` state, and shader
        //!     functions stay valid after `ShaderModule.deinit` because manifest data
        //!     is static and the device lifetime is independent.
        const std = @import("std");
        const vk = Driver;

        /// Token prefix shared by every exported program constant.
        const token_prefix = prefix;

        pub const blur: []const u8 = token_prefix ++ "blur";
        pub const composite: []const u8 = token_prefix ++ "composite";
        pub const path: []const u8 = token_prefix ++ "path";
        pub const image: []const u8 = token_prefix ++ "image";
        pub const damage_clear: []const u8 = token_prefix ++ "damage_clear";
        pub const icon: []const u8 = token_prefix ++ "icon";
        pub const text: []const u8 = token_prefix ++ "text";
        pub const sdf: []const u8 = token_prefix ++ "sdf_primitives";
        pub const glass: []const u8 = token_prefix ++ "glass";

        // Every exported token must select a program in the generated manifest.
        comptime {
            @setEvalBranchQuota(10000);
            for ([_][]const u8{ blur, composite, path, image, damage_clear, icon, text, sdf, glass }) |token| {
                if (!programExists(token[token_prefix.len..])) {
                    @compileError(std.fmt.comptimePrint("Linux GPU shader token '{s}' selects no program of the generated shader manifest", .{token}));
                }
            }
        }

        fn programExists(program: []const u8) bool {
            for (manifest.entries) |entry| {
                if (std.mem.eql(u8, entry.program, program)) return true;
            }
            return false;
        }

        /// Strip the token prefix, rejecting empty programs. Exactness of the
        /// remaining program is decided by manifest comparison, never by trimming.
        fn tokenProgram(source: []const u8) ?[]const u8 {
            if (!std.mem.startsWith(u8, source, token_prefix)) return null;
            const program = source[token_prefix.len..];
            return if (program.len == 0) null else program;
        }

        /// Zero-length SPIR-V with the manifest's `code` alignment, for the inactive
        /// function state. `Stage` has no inactive tag; empty borrowed slices are the
        /// inactive discriminant.
        const no_code: [0]u8 align(4) = .{};

        /// Canonical inactive entry: borrows no manifest data and frees nothing.
        const inactive_entry: manifest.Entry = if (@hasField(manifest.Entry, "texture_units")) .{ .program = "", .name = "", .stage = .vertex, .code = "", .bindings = &.{}, .texture_units = &.{}, .first_instance_uniform = null } else .{
            .program = "",
            .name = "",
            .stage = .vertex,
            .code = if (@hasField(manifest.Entry, "texture_units")) "" else &no_code,
            .bindings = &.{},
        };

        pub const ShaderFunction = struct {
            device: *vk.Device,
            entry: manifest.Entry,

            /// Borrows only: the manifest entry is static and the device is owned
            /// elsewhere, so there is nothing to release. Idempotent.
            pub fn deinit(self: *ShaderFunction) void {
                self.entry = inactive_entry;
            }
        };

        pub const ShaderModule = struct {
            device: *vk.Device,
            /// Manifest's own static program name; `""` once deinited.
            program: []const u8,

            pub fn initFromSource(device: *vk.Device, source: []const u8) !ShaderModule {
                // Device liveness is checked before the token: a dead device with a
                // valid token is a device error, not a source error.
                if (device.handle == null) return error.InvalidDescriptor;
                const program = tokenProgram(source) orelse return error.InvalidShaderProgram;
                for (manifest.entries) |entry| {
                    if (!std.mem.eql(u8, entry.program, program)) continue;
                    // Store the manifest slice, not `source`: the caller's buffer may
                    // be reused or overwritten as soon as this returns.
                    return .{ .device = device, .program = entry.program };
                }
                return error.InvalidShaderProgram;
            }

            pub fn getFunction(self: *const ShaderModule, name: []const u8) !ShaderFunction {
                if (self.program.len == 0) return error.InvalidShaderProgram;
                if (self.device.handle == null) return error.InvalidDescriptor;
                for (manifest.entries) |entry| {
                    if (!std.mem.eql(u8, entry.program, self.program)) continue;
                    if (!std.mem.eql(u8, entry.name, name)) continue;
                    return .{ .device = self.device, .entry = entry };
                }
                // Unknown names and names from other programs are indistinguishable
                // here by contract: both are plain lookup misses.
                return error.ShaderFunctionNotFound;
            }

            /// Idempotent. Borrows only; the static program string is not freed and
            /// previously returned functions remain usable.
            pub fn deinit(self: *ShaderModule) void {
                self.program = "";
            }
        };
    };
}
