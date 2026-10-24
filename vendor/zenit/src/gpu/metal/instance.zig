/// Metal Instance implementation
///
/// Metal has no explicit Instance object, mainly for device enumeration
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const Adapter = @import("adapter.zig").Adapter;

pub const Instance = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, desc: gpu.InstanceDescriptor) !Instance {
        _ = desc;
        return Instance{
            .allocator = allocator,
        };
    }

    pub fn enumerateAdapters(self: *Instance) ![]Adapter {
        // Use autorelease pool to prevent memory spikes
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // First query device count
        var count: usize = 0;
        _ = mtl.metal_copy_all_devices(&count, null, 0);

        if (count == 0) {
            // If no devices, try to get system default device
            const default_device = mtl.createSystemDefaultDevice() orelse {
                return error.NoMetalDevices;
            };

            const adapters = try self.allocator.alloc(Adapter, 1);
            adapters[0] = Adapter{
                .device = default_device,
            };
            return adapters;
        }

        // Allocate device pointer array
        const devices = try self.allocator.alloc(?*anyopaque, count);
        defer self.allocator.free(devices);

        // Get all devices. Count may change between calls (hot-swap eGPU/wake discrete GPU):
        // bridge clamps writes by capacity, trust actual count not first query's count
        var total: usize = 0;
        const written = mtl.metal_copy_all_devices(&total, devices.ptr, devices.len);
        if (written == 0) return error.NoMetalDevices;

        const adapters = try self.allocator.alloc(Adapter, written);

        for (0..written) |i| {
            const device: *mtl.MTLDevice = @ptrCast(devices[i].?);
            // Note: metal_copy_all_devices already retained, no need to retain again
            adapters[i] = Adapter{
                .device = device,
            };
        }

        return adapters;
    }

    pub fn deinit(self: *Instance) void {
        _ = self;
    }
};
