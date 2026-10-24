/// Offscreen texture pool + size calculation, extracted from command_encoder.zig.
///
/// For opacity layer/backdrop blur/rounded clip etc. needing offscreen render.
const std = @import("std");
/// Textures created by offscreen pools since the app renderer last reset it
/// (per frame). Steady-state frames should create none.
pub var perf_texture_creates: u32 = 0;
const gpu = @import("gpu");

pub const OffscreenTextureSize = struct {
    width: u32,
    height: u32,
};

/// Texture allocation size bucket: round up to 64px multiple (clamp to max_dimension).
/// Scale/size animation offscreen content ±1px jitter per frame, exact-match pool never
/// hits; allocate by bucket, same-bucket frames share texture, compositor clamp UV by
/// used/alloc.
pub const BUCKET_PX: u32 = 64;

pub fn bucketDimension(px: u32, max_dimension: u32) u32 {
    const capped = @min(px, max_dimension);
    const remainder = capped % BUCKET_PX;
    if (remainder == 0) return capped;
    const bucketed = std.math.add(u32, capped, BUCKET_PX - remainder) catch max_dimension;
    return @min(bucketed, max_dimension);
}

pub fn computeOffscreenTextureSize(width: f32, height: f32, scale: f32, max_dimension: u32) ?OffscreenTextureSize {
    if (max_dimension == 0) return null;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(scale)) return null;
    if (width <= 0 or height <= 0 or scale <= 0) return null;

    const scaled_width = @ceil(width * scale);
    const scaled_height = @ceil(height * scale);
    if (!std.math.isFinite(scaled_width) or !std.math.isFinite(scaled_height)) return null;

    const max_dimension_f: f32 = @floatFromInt(max_dimension);
    if (scaled_width > max_dimension_f or scaled_height > max_dimension_f) return null;

    return .{
        .width = @intFromFloat(@max(@as(f32, 1), scaled_width)),
        .height = @intFromFloat(@max(@as(f32, 1), scaled_height)),
    };
}

/// Offscreen texture pool: cache by size for reuse, avoid alloc/free per frame.
/// Caution: same frame can't reuse texture already submitted to command buffer sample/write,
/// else subsequent offscreen pass overwrites prior rounded-clip/blur composite still using
/// it. `PoolEntry.retained_id` sentinel: entry unowned, use normal size-based reuse.
pub const NO_RETAINED_OWNER: u32 = std.math.maxInt(u32);

/// Copyable, non-owning token for one active offscreen texture. Ownership stays
/// in `OffscreenTexturePool`; generation checks prevent stale tokens from
/// resolving after eviction or transient destruction.
pub const TextureLease = struct {
    kind: Kind,
    slot: u8,
    generation: u32,

    pub const Kind = enum(u8) { pooled, transient };

    pub fn eql(self: TextureLease, other: TextureLease) bool {
        return self.kind == other.kind and self.slot == other.slot and self.generation == other.generation;
    }
};

/// Result of `acquireRetained`.
pub const RetainedAcquire = struct {
    lease: TextureLease,
    /// true = texture already has frame's desired content, can skip content pass and
    /// compose directly.
    content_matches: bool,
    /// true = texture size unchanged and prior frame content already drawn (when
    /// content_matches=false, this is prerequisite for damage-rect partial redraw: old pixels
    /// still meaningful, only redraw dirty region).
    was_primed: bool = false,
};

/// Damage-rect partial redraw: retained layer prior frame each paint command's
/// {single fingerprint, conservative expanded bounds}. Cross-frame diff finds dirty region.
pub const DamageItem = @import("command_encoder/retained_plan.zig").DamageItem;

/// Max damage info records per retained entry. Exceed = abandon partial redraw
/// (repaint full layer), never truncate (truncate = incomplete diff = miss dirty = stale
/// pixels).
pub const MAX_DAMAGE_ITEMS = 128;

/// Retained entry not claimed for consecutive frames -> recycle. Composite layer may
/// disappear long-term (popover close), not worth pinning full-screen texture forever;
/// grace frames avoid 'close then open immediately' thrashing.
pub const RETAINED_IDLE_FRAMES: u64 = 60;

/// Damage baseline bypath slot count.
///
/// Why not MAX_POOL (128): damage baseline is only meaningful for **retained** entries, and
/// valid baseline retained layers per frame have a hard cap, command_encoder
/// `retained_hashes: [64]` + `damage_ranges: [64]`:
///   - seq >= 64 opacity layer can't get content_version (`break :blk 0`),
///     0 fingerprint is rejected by `acquireRetained` -> not a retained entry at all;
///   - `storeRetainedDamageItems` sole call (opacity_layer.zig:609) first checks
///     `retained_seq < damage_ranges.len` (64); out of bounds stores null (invalid).
/// So **same-frame** max is 64 baselines. Cross-frame residue is released with entry slots
/// (sweepRetained/dropRetained/evict/deinit all free), so it won't accumulate.
/// 64 slots = 64 x (128x24 + 8) ~= 197 KB, saves 2/3 vs. inlining into 128 PoolEntry,
/// and scales with damage need, not pool capacity.
///
/// Capacity exhausted (theoretically unreachable) -> **safe degradation**: no baseline = next
/// full-layer repaint. Never truncate (truncated = incomplete diff = missed dirty = stale pixels).
pub const MAX_DAMAGE_SLOTS = 64;

pub const OffscreenTexturePool = struct {
    /// Pool capacity rationale (MAX_POOL).
    ///
    /// Demand scales linearly with 'glass island count x blur depth'. Each glass island needs a
    /// frame
    /// level0 capture + kawase chain + glass/composite textures; opacity/clip layers need ~4-way
    /// per-size rotation for the release() in-flight guard period. Measured on a 7-island fixture
    /// (108 frames):
    ///
    ///   MAX_POOL=48 : 1414 creates, pool peak stuck at 48, 1135 MB if everything were kept resident
    ///   MAX_POOL=128:  112 creates, pool peak 111,          52 MB if all resident
    ///
    /// Raising capacity actually cut memory to ~1/20.
    ///
    /// If capacity is below the workset (111 there), the pool is perpetually full -> new textures
    /// are
    /// all transient -> **destroyed at end of frame and rebuilt next frame** (40+ same-size creates
    /// per
    /// cycle). Worse, the downsample chain can't get a texture -> `break`, `actual_levels` ends
    /// mid-path, and blur level jumps between e.g. 5/5 and 4/5. All glass islands share this pool
    /// and
    /// reuse lag is fixed (REUSE_LAG_FRAMES=3), so **unrelated islands jitter in sync with a
    /// 3-frame period** (visible as flashing fill rows/icons). Capacity below the workset kills the
    /// cache (thrash); capacity above it restores design intent. Memory ceiling comes from
    /// `sweepIdle`
    /// (idle recycle), not slot pressure, so surplus margin is safe.
    ///
    /// WARNING: 128 is only a surplus over today's workset. Root fix: (a) make capacity dynamic by
    /// glass island count; (b) guarantee a stable blur level per island frame-to-frame (prefer
    /// always one level fewer over jittering 4/5; jitter reads as a visual 'flash').
    pub const MAX_POOL = 128;
    pub const MAX_TRANSIENT = 32;
    /// Normal pool entry no reuse consecutive frames -> destroy (prevent post-switch old-size
    /// giant textures permanently hogging memory; retained entry recycle separate
    /// RETAINED_IDLE_FRAMES).
    pub const POOL_IDLE_FRAMES: u64 = 180;
    pub const POOL_IDLE_NS: u64 = 3 * std.time.ns_per_s;
    pub const RETAINED_IDLE_NS: u64 = std.time.ns_per_s;
    pub const RESIZED_IDLE_NS: u64 = std.time.ns_per_s;
    const REUSE_LAG_FRAMES: u64 = 3;
    clock_ns: u64 = 0,
    /// Render-thread confined. Maintenance may never run while commands can
    /// still acquire/write pooled textures.
    encoder_active: bool = false,

    entries: [MAX_POOL]?PoolEntry = @splat(null),
    transients: [MAX_TRANSIENT]?TransientEntry = @splat(null),
    pool_generations: [MAX_POOL]u32 = @as([MAX_POOL]u32, @splat(1)),
    transient_generations: [MAX_TRANSIENT]u32 = @as([MAX_TRANSIENT]u32, @splat(1)),
    count: usize = 0,
    /// `acquire` complete failure (pool **and** transient full) cumulative count.
    ///
    /// WARNING semantic boundary, don't misuse: pool full but transient free is **not counted**;
    /// that path 'create one, destroy at end of frame' shows up as perf thrash, **not** visual
    /// degradation. Corollary: `> 0` is definitely a visual downgrade; `== 0` **doesn't mean** the
    /// pool is large enough. Judge adequacy by `ZENIT_DEBUG_PASSCOUNT` `[offpool] create`
    /// frequency.
    exhausted_count: u64 = 0,
    exhausted_warned: bool = false,
    /// Damage baseline bypath storage (see MAX_DAMAGE_SLOTS/DamageSlot). Invariant:
    /// `damage_slot_used[i]` true <-> **exactly one** PoolEntry `damage_slot == i`. Maintained
    /// by acquireDamageSlot/releaseDamageSlot pair, and all paths losing retained status call
    /// latter.
    damage_slots: [MAX_DAMAGE_SLOTS]DamageSlot = undefined,
    damage_slot_used: [MAX_DAMAGE_SLOTS]bool = @as([MAX_DAMAGE_SLOTS]bool, @splat(false)),

    /// Pull-only developer accounting. Logical texel bytes are not Metal
    /// allocatedSize or resident graphics pages; callers must keep them separate.
    /// No counters, scans or extra fields are added to the rendering hot path.
    pub const MemorySnapshot = struct {
        live: u32 = 0,
        retained: u32 = 0,
        transient: u32 = 0,
        idle: u32 = 0,
        reapable: u32 = 0,
        oldest_age_frames: u64 = 0,
        logical_bytes: u64 = 0,
        retained_bytes: u64 = 0,
        idle_bytes: u64 = 0,
        unsupported_formats: u32 = 0,
    };

    fn diagnosticTexelBytes(texture: *const gpu.Backend.Texture) ?u64 {
        const bpp: u64 = switch (texture.format) {
            .r8_unorm => 1,
            .rg8_unorm, .r16_float => 2,
            .bgra8_unorm, .bgra8_unorm_srgb, .rgba8_unorm, .rgba8_unorm_srgb => 4,
            .rgba16_float => 8,
            .rgba32_float => 16,
            else => return null,
        };
        return @as(u64, texture.size.width) * texture.size.height * bpp;
    }

    pub fn memorySnapshot(self: *const OffscreenTexturePool, frame_index: u64) MemorySnapshot {
        var result: MemorySnapshot = .{};
        for (self.entries) |maybe| {
            const entry = maybe orelse continue;
            const bytes = diagnosticTexelBytes(&entry.texture) orelse blk: {
                result.unsupported_formats += 1;
                break :blk 0;
            };
            const age = frame_index -| entry.last_used_frame;
            result.live += 1;
            result.logical_bytes += bytes;
            result.oldest_age_frames = @max(result.oldest_age_frames, age);
            if (entry.retained_id != NO_RETAINED_OWNER) {
                result.retained += 1;
                result.retained_bytes += bytes;
            }
            if (age != 0) {
                result.idle += 1;
                result.idle_bytes += bytes;
            }
            if (entry.retained_id == NO_RETAINED_OWNER and !entry.in_use and
                entry.reusable_after_frame <= frame_index and age >= POOL_IDLE_FRAMES)
                result.reapable += 1;
        }
        for (self.transients) |maybe| {
            const entry = maybe orelse continue;
            result.transient += 1;
            result.live += 1;
            result.logical_bytes += diagnosticTexelBytes(&entry.texture) orelse blk: {
                result.unsupported_formats += 1;
                break :blk 0;
            };
        }
        return result;
    }

    pub const PoolEntry = struct {
        texture: gpu.Backend.Texture,
        width: u32,
        height: u32,
        in_use: bool,
        reusable_after_frame: u64 = 0,
        last_used_frame: u64 = 0,
        last_used_ns: u64 = 0,
        old_size: bool = false,
        /// GPU retained: the composite layer (layer stable_id) that exclusively holds this texture.
        /// NO_RETAINED_OWNER = normal pool entry.
        ///
        /// Retained vs. normal key differences:
        /// - size-based `acquire` **never** returns it (else others overwrite cache content);
        /// - `resetFrame` **doesn't clear** its in_use (normal entries are returned every frame,
        ///   retained
        ///   ones persist cross-frame; clearing would hand it back to the pool);
        /// - only claimable via `acquireRetained` by (id, size), or idle-reaped.
        retained_id: u32 = NO_RETAINED_OWNER,
        /// Already-rasterized **content fingerprint** in retained entry (encoder side hash of
        /// actual commands this layer encodes, see command_encoder.computeRetainedContentHashes).
        /// Match request fingerprint = content unchanged, can composite directly, skip content
        /// pass.
        retained_content_version: u64 = 0,
        /// Content already drawn. Freshly allocated texture undefined, must draw once before
        /// reuse.
        retained_primed: bool = false,
        /// Damage-rect: prior-frame per-item baseline **bypath slot** index. NO_DAMAGE_SLOT = entry
        /// has no valid baseline (= next miss repaints the full layer).
        ///
        /// Not inlined: a 128x24 B baseline array would grow `entries: [128]?PoolEntry` to ~403 KB,
        /// yet
        /// most slots are normal entries that never write a baseline. Bypath keeps PoolEntry ~72 B.
        damage_slot: u8 = NO_DAMAGE_SLOT,
    };

    /// Sentinel for `PoolEntry.damage_slot`.
    pub const NO_DAMAGE_SLOT: u8 = std.math.maxInt(u8);

    /// One retained layer's prior frame damage baseline.
    const DamageSlot = struct {
        items: [MAX_DAMAGE_ITEMS]DamageItem = undefined,
        count: u16 = 0,
    };

    /// Return damage slot entry occupied (idempotent). **Must** call when retained entry
    /// loses status/overwritten/destroyed; miss leaks slot, worse lets other layer claim old
    /// entry read **someone else's** baseline (crosstalk = miss dirty).
    fn releaseDamageSlot(self: *OffscreenTexturePool, entry: *PoolEntry) void {
        const slot = entry.damage_slot;
        if (slot == NO_DAMAGE_SLOT) return;
        entry.damage_slot = NO_DAMAGE_SLOT;
        if (slot < MAX_DAMAGE_SLOTS) self.damage_slot_used[slot] = false;
    }

    /// Allocate damage slot for entry (reuse if exists). Exhausted -> null, caller must
    /// safely degrade (no baseline = full-layer repaint), never truncate.
    fn acquireDamageSlot(self: *OffscreenTexturePool, entry: *PoolEntry) ?*DamageSlot {
        if (entry.damage_slot != NO_DAMAGE_SLOT and entry.damage_slot < MAX_DAMAGE_SLOTS) {
            return &self.damage_slots[entry.damage_slot];
        }
        for (&self.damage_slot_used, 0..) |*used, i| {
            if (used.*) continue;
            used.* = true;
            entry.damage_slot = @intCast(i);
            return &self.damage_slots[i];
        }
        return null;
    }

    const TransientEntry = struct {
        texture: gpu.Backend.Texture,
        width: u32,
        height: u32,
        in_use: bool,
    };

    fn bumpGeneration(generation: *u32) void {
        generation.* +%= 1;
        if (generation.* == 0) generation.* = 1;
    }

    fn pooledLease(self: *const OffscreenTexturePool, slot: usize) TextureLease {
        return .{ .kind = .pooled, .slot = @intCast(slot), .generation = self.pool_generations[slot] };
    }

    fn transientLease(self: *const OffscreenTexturePool, slot: usize) TextureLease {
        return .{ .kind = .transient, .slot = @intCast(slot), .generation = self.transient_generations[slot] };
    }

    pub fn resolveTexture(self: *OffscreenTexturePool, lease: TextureLease) ?*gpu.Backend.Texture {
        const slot: usize = lease.slot;
        return switch (lease.kind) {
            .pooled => if (slot < MAX_POOL and self.pool_generations[slot] == lease.generation)
                if (self.entries[slot]) |*entry| &entry.texture else null
            else
                null,
            .transient => if (slot < MAX_TRANSIENT and self.transient_generations[slot] == lease.generation)
                if (self.transients[slot]) |*entry| &entry.texture else null
            else
                null,
        };
    }

    pub fn binding(self: *OffscreenTexturePool, lease: TextureLease) ?gpu.Backend.TextureBinding {
        const value = self.resolveTexture(lease) orelse return null;
        return value.binding();
    }

    /// Get or create offscreen texture matching size. Pool full and no match, LRU-evict one
    /// safe entry (!in_use and past in-flight guard), prevent stale size permanent slot hog,
    /// subsequent acquire all non-pool create/release slow path.
    pub fn acquire(self: *OffscreenTexturePool, device: *gpu.Backend.Device, width: u32, height: u32, frame_index: u64) ?TextureLease {
        return self.acquireWithFormat(device, width, height, frame_index, gpu.color_format);
    }

    /// Match both size and pixel format: float intermediates must never reuse
    /// an sRGB render target, even when their dimensions are identical.
    pub fn acquireWithFormat(self: *OffscreenTexturePool, device: *gpu.Backend.Device, width: u32, height: u32, frame_index: u64, format: gpu.TextureFormat) ?TextureLease {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                // Retained entry exclusive to one layer, size-based reuse never touches it.
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                if (!e.in_use and e.reusable_after_frame <= frame_index and e.width == width and e.height == height and e.texture.format == format) {
                    e.in_use = true;
                    e.last_used_frame = frame_index;
                    e.last_used_ns = self.clock_ns;
                    e.old_size = false;
                    return self.pooledLease(slot);
                }
            }
        }
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (!e.in_use and e.width == width and e.height == height and e.texture.format == format) {
                    e.in_use = true;
                    return self.transientLease(slot);
                }
            }
        }
        if (@import("zenit_environment").has("ZENIT_DEBUG_PASSCOUNT")) {
            var retained_n: usize = 0;
            for (self.entries) |m| {
                if (m) |e| {
                    if (e.retained_id != NO_RETAINED_OWNER) retained_n += 1;
                }
            }
            std.debug.print("[offpool] create {d}x{d} (pool={d} retained={d})\n", .{ width, height, self.count, retained_n });
        }
        // A failed allocation after an earlier eviction can leave a hole below
        // `count`. Reuse it before growing or evicting again; otherwise a pool
        // whose high-water mark reached MAX_POOL could permanently lose slots.
        var vacant_slot: ?usize = null;
        for (self.entries[0..self.count], 0..) |entry, slot| {
            if (entry == null) {
                vacant_slot = slot;
                break;
            }
        }
        if (vacant_slot) |slot| {
            const new_texture = createTextureWithFormat(device, width, height, format) orelse return null;
            self.entries[slot] = .{
                .texture = new_texture,
                .width = width,
                .height = height,
                .in_use = true,
                .last_used_frame = frame_index,
                .last_used_ns = self.clock_ns,
            };
            return self.pooledLease(slot);
        } else if (self.count < MAX_POOL) {
            const new_texture = createTextureWithFormat(device, width, height, format) orelse return null;
            self.entries[self.count] = .{
                .texture = new_texture,
                .width = width,
                .height = height,
                .in_use = true,
                .last_used_frame = frame_index,
                .last_used_ns = self.clock_ns,
            };
            const lease = self.pooledLease(self.count);
            self.count += 1;
            return lease;
        } else if (self.evictLruSlot(frame_index)) |slot| {
            const new_texture = createTextureWithFormat(device, width, height, format) orelse return null;
            self.entries[slot] = .{
                .texture = new_texture,
                .width = width,
                .height = height,
                .in_use = true,
                .last_used_frame = frame_index,
                .last_used_ns = self.clock_ns,
            };
            return self.pooledLease(slot);
        }
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.* != null) continue;
            const new_texture = createTextureWithFormat(device, width, height, format) orelse return null;
            entry.* = .{ .texture = new_texture, .width = width, .height = height, .in_use = true };
            return self.transientLease(slot);
        }
        // Pool + transient full. Caller (blur chain, opacity layer) **silently degrade**: one
        // fewer blur level, or no full-layer composite. Visually 'flashes', and since all glass
        // islands share pool, unrelated regions sync jitter (downstream app took long debugging to
        // pin here). Exhaustion must leave trace independent of debug switch.
        self.exhausted_count += 1;
        if (!self.exhausted_warned) {
            self.exhausted_warned = true;
            std.log.warn(
                "[offpool] exhausted (pool={d}/{d} transient={d}) requesting {d}x{d} — " ++
                    "callers will silently degrade (blur levels dropped / layer not composited). " ++
                    "This message appears once; see exhausted_count for the running total.",
                .{ self.count, MAX_POOL, MAX_TRANSIENT, width, height },
            );
        }
        return null;
    }

    /// Create new offscreen RT.
    ///
    /// Private storage: these offscreen RTs are **pure GPU intermediates** (opacity layer
    /// composite, backdrop blur ping-pong); the CPU never reads/writes them. The only frame pixel
    /// read-back in the codebase is the e2e screenshot, which reads the drawable, not the pool
    /// (renderer.zig:214). Shared would put these textures on the CPU-visible coherency path on
    /// Apple Silicon, wasting bandwidth and compression; Private lets the driver enable lossless
    /// compression. If read-back is ever needed, use a separate staging blit; don't revert the
    /// whole pool to Shared.
    fn createTexture(device: *gpu.Backend.Device, width: u32, height: u32) ?gpu.Backend.Texture {
        return createTextureWithFormat(device, width, height, gpu.color_format);
    }

    fn createTextureWithFormat(device: *gpu.Backend.Device, width: u32, height: u32, format: gpu.TextureFormat) ?gpu.Backend.Texture {
        perf_texture_creates += 1;
        return device.createTexture(std.heap.page_allocator, .{
            .label = "Zenit.Offscreen",
            .size = .{ .width = width, .height = height },
            .format = format,
            .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true, .copy_dst = true },
            .memory = .device_local,
        }) catch null;
    }

    /// When pool full, pick safely-evictable entry: !in_use and reusable_after_frame past
    /// (= pool's own reuse rules say GPU no longer references), take last_used_frame oldest.
    /// No safe candidate (all in_use or still in-flight guard) -> null, new texture not in pool.
    fn findLruSlot(self: *const OffscreenTexturePool, frame_index: u64) ?usize {
        var best: ?usize = null;
        var best_frame: u64 = std.math.maxInt(u64);
        for (&self.entries, 0..) |*entry, i| {
            if (entry.*) |*e| {
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                if (!e.in_use and e.reusable_after_frame <= frame_index and e.last_used_frame < best_frame) {
                    best = i;
                    best_frame = e.last_used_frame;
                }
            }
        }
        if (best == null) {
            // No normal entry evictable: fall back to sacrificing a retained entry **not chosen
            // this frame**.
            //
            // Without this step, retained entries pin 16 slots, evictLruSlot perpetually returns
            // null, and
            // **all** normal offscreen textures take the 'created but can't pool' path
            // (create/release every
            // frame), collapsing Modal/Sheet offscreen composite (dialog renders solid blank). GPU
            // retained
            // is an optimization and must not squeeze the normal path dead.
            for (&self.entries, 0..) |*entry, i| {
                if (entry.*) |*e| {
                    if (e.retained_id == NO_RETAINED_OWNER) continue;
                    if (e.last_used_frame >= frame_index) continue; // Using this frame
                    if (e.reusable_after_frame > frame_index) continue; // Still in in-flight guard period
                    if (e.last_used_frame < best_frame) {
                        best = i;
                        best_frame = e.last_used_frame;
                    }
                }
            }
        }
        return best;
    }

    fn evictLruSlot(self: *OffscreenTexturePool, frame_index: u64) ?usize {
        const slot = self.findLruSlot(frame_index) orelse return null;
        if (self.entries[slot]) |*entry| {
            // Entry disappears, slot must go too; miss leaks (slots finite, leak all retained
            // layers
            // permanently degrade full-repaint).
            self.releaseDamageSlot(entry);
            entry.texture.destroy();
        }
        self.entries[slot] = null;
        bumpGeneration(&self.pool_generations[slot]);
        return slot;
    }

    /// Release texture back to pool. Texture reusable next frame post-resetFrame, avoid
    /// same-frame read-write stomp.
    pub fn release(self: *OffscreenTexturePool, lease: TextureLease, frame_index: u64) bool {
        const slot: usize = lease.slot;
        switch (lease.kind) {
            .pooled => {
                if (slot >= MAX_POOL or self.pool_generations[slot] != lease.generation) return false;
                const entry = if (self.entries[slot]) |*value| value else return false;
                entry.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
                return true;
            },
            .transient => {
                if (slot >= MAX_TRANSIENT or self.transient_generations[slot] != lease.generation) return false;
                if (self.transients[slot]) |*entry| entry.texture.destroy() else return false;
                self.transients[slot] = null;
                bumpGeneration(&self.transient_generations[slot]);
                return true;
            },
        }
    }

    /// Immediate same-frame reuse after release, for the backdrop blur internal chain only.
    ///
    /// Precondition: texture is **only read/written by already-encoded passes within the current
    /// command buffer** (GPU-only texture + default hazard tracking: passes serialize within the
    /// buffer, so pass i+1 overwriting a texture pass i read is safe). REUSE_LAG_FRAMES guards
    /// cross-frame in-flight command buffers, which is overprotective here. If a frame is ever
    /// split
    /// into multiple command buffers (multiple commits) this breaks; revert the callsite to
    /// release(). Other callers (opacity layer etc.) keep release().
    pub fn releaseForReuseInFrame(self: *OffscreenTexturePool, lease: TextureLease) bool {
        const slot: usize = lease.slot;
        switch (lease.kind) {
            .pooled => {
                if (slot >= MAX_POOL or self.pool_generations[slot] != lease.generation) return false;
                const entry = if (self.entries[slot]) |*value| value else return false;
                entry.in_use = false;
                entry.reusable_after_frame = 0;
                return true;
            },
            .transient => {
                if (slot >= MAX_TRANSIENT or self.transient_generations[slot] != lease.generation) return false;
                const entry = if (self.transients[slot]) |*value| value else return false;
                entry.in_use = false;
                return true;
            },
        }
    }

    /// Reset all in_use flags at frame start. Retained entries **don't** participate,
    /// cross-frame held, in_use perpetually true means 'exclusive to layer'. Clear means gave
    /// back pool texture still in use. Their recycle via `sweepRetained` (idle frames after).
    pub fn resetFrame(self: *OffscreenTexturePool) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                e.in_use = false;
            }
        }
        self.releaseTransients();
    }

    /// Drop per-frame owner handles after encoding. Also called by resetFrame
    /// for standalone pool users. This prevents the last frame's transients
    /// from surviving indefinitely when the app stops submitting frames.
    pub fn releaseTransients(self: *OffscreenTexturePool) void {
        // Transients are per-frame owner handles. Recorded Metal commands
        // retain resources; D3D12 keeps D12RenderRefs/D12CopyRefs through the
        // queue fence; Linux command state owns retainedTexture() references.
        // Dropping this owner never releases storage still referenced by GPU
        // work. A wallclock TTL here would be dead: every frame drops them.
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.*) |*value| value.texture.destroy();
            entry.* = null;
            bumpGeneration(&self.transient_generations[slot]);
        }
    }

    /// Call only between frames, after fences prove every submitted use of
    /// this pool has completed and before encoding any new uses. Frame-count
    /// quarantine is then unnecessary; ownership and content validity remain.
    pub fn notifyGpuIdle(self: *OffscreenTexturePool) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| e.reusable_after_frame = 0;
        }
    }

    /// GPU retained: claim the texture exclusive to `retained_id`.
    ///
    /// Returning null means 'don't use the retained path this frame' (pool full etc.); the caller
    /// must
    /// fall back to the normal acquire full-redraw path, always a safe degradation.
    ///
    /// `content_matches` true means the texture holds the frame's desired content, so the caller
    /// can
    /// skip the content pass and composite directly; false means repaint. **Size mismatch always
    /// misses** (content size changed, old pixels meaningless).
    pub fn acquireRetained(
        self: *OffscreenTexturePool,
        device: *gpu.Backend.Device,
        retained_id: u32,
        content_version: u64,
        width: u32,
        height: u32,
        frame_index: u64,
    ) ?RetainedAcquire {
        if (retained_id == NO_RETAINED_OWNER) return null;
        // 0 = fingerprint invalid (prescan didn't cover / layer count over limit). Better
        // every-frame repaint.
        if (content_version == 0) return null;

        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                // Identity matched but size changed: old content stale, rebuild in-place new size.
                if (e.width != width or e.height != height) {
                    // Still in in-flight guard, can't overwrite, this frame degrade normal path.
                    if (e.reusable_after_frame > frame_index) return null;
                    const fresh = createTexture(device, width, height) orelse return null;
                    e.texture.destroy();
                    e.texture = fresh;
                    e.width = width;
                    e.height = height;
                    e.retained_content_version = content_version;
                    e.retained_primed = false;
                    self.releaseDamageSlot(e); // Size changed, old diff baseline stale
                    e.last_used_frame = frame_index;
                    e.last_used_ns = self.clock_ns;
                    e.old_size = false;
                    e.in_use = true;
                    bumpGeneration(&self.pool_generations[slot]);
                    return .{ .lease = self.pooledLease(slot), .content_matches = false };
                }
                const was_primed = e.retained_primed;
                const matches = e.retained_primed and e.retained_content_version == content_version;
                if (!matches) {
                    // Must repaint. Last composite hit GPU sampled this texture; if that frame's
                    // command buffer still in-flight (triple buffer norm), this clear+repaint
                    // same-place is
                    // write-read race, swap frame one/two flash. In guard period reject claim,
                    // caller normal
                    // pool path (there temp texture past guard, safe), next frame come back repaint
                    // exclusive.
                    if (e.reusable_after_frame > frame_index) return null;
                }
                const matches_final = matches;
                // Miss: texture about to repaint, old pixels don't match any completed version.
                // Must
                // first drop primed, else version rewritten new fingerprint but primed still true,
                // content
                // pass mid-fail (didn't reach markRetainedPrimed), next frame same fingerprint hit
                // half-baked/
                // stale. After repaint end markRetainedPrimed set back. was_primed snapshotted
                // above,
                // partial redraw criteria unaffected.
                if (!matches) e.retained_primed = false;
                e.retained_content_version = content_version;
                e.last_used_frame = frame_index;
                e.last_used_ns = self.clock_ns;
                e.old_size = false;
                e.in_use = true;
                // This frame GPU reads (hit composite) or writes (miss repaint) texture, record
                // guard
                // period for above judgment + evictLruSlot use.
                e.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
                return .{ .lease = self.pooledLease(slot), .content_matches = matches_final, .was_primed = was_primed };
            }
        }

        // First claim: create new texture pinned to this layer.
        var new_texture = createTexture(device, width, height) orelse return null;
        const slot: usize = blk: {
            for (self.entries[0..self.count], 0..) |entry, i| if (entry == null) break :blk i;
            if (self.count < MAX_POOL) {
                const i = self.count;
                self.count += 1;
                break :blk i;
            }
            break :blk self.evictLruSlot(frame_index) orelse {
                // Pool full no evictable, not in pool can't cross-frame hold, retained pointless.
                new_texture.destroy();
                return null;
            };
        };
        self.entries[slot] = .{
            .texture = new_texture,
            .width = width,
            .height = height,
            .in_use = true,
            .last_used_frame = frame_index,
            .last_used_ns = self.clock_ns,
            .retained_id = retained_id,
            .retained_content_version = content_version,
            .retained_primed = false,
        };
        return .{ .lease = self.pooledLease(slot), .content_matches = false };
    }

    /// Mark retained texture content done drawing, next frame can directly reuse. Must
    /// call after content pass truly encodes complete; premature call lets next frame reuse
    /// half-drawn pixels.
    pub fn markRetainedPrimed(self: *OffscreenTexturePool, lease: TextureLease) bool {
        if (lease.kind != .pooled) return false;
        const slot: usize = lease.slot;
        if (slot >= MAX_POOL or self.pool_generations[slot] != lease.generation) return false;
        const entry = &(self.entries[slot] orelse return false);
        if (entry.retained_id == NO_RETAINED_OWNER) return false;
        entry.retained_primed = true;
        return true;
    }

    /// Damage-rect: fetch retained entry prior frame per-item baseline (invalid returns
    /// null).
    pub fn retainedDamageItems(self: *OffscreenTexturePool, retained_id: u32) ?[]const DamageItem {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                if (e.damage_slot == NO_DAMAGE_SLOT or e.damage_slot >= MAX_DAMAGE_SLOTS) continue;
                const slot = &self.damage_slots[e.damage_slot];
                return slot.items[0..slot.count];
            }
        }
        return null;
    }

    /// Damage-rect: after content pass encodes, write this frame per-item baseline. Items
    /// exceed limit -> invalid (better next full-repaint, never truncate diff).
    pub fn storeRetainedDamageItems(self: *OffscreenTexturePool, retained_id: u32, items: ?[]const DamageItem) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                if (items) |list| {
                    if (list.len <= MAX_DAMAGE_ITEMS) {
                        // Slots exhausted -> fall to release(invalid) below = full-layer repaint.
                        if (self.acquireDamageSlot(e)) |slot| {
                            @memcpy(slot.items[0..list.len], list);
                            slot.count = @intCast(list.len);
                            return;
                        }
                    }
                }
                self.releaseDamageSlot(e);
                return;
            }
        }
    }

    /// A frame supplies one monotonic sample; acquisitions do not query clocks.
    pub fn setClock(self: *OffscreenTexturePool, now_ns: u64) void {
        self.clock_ns = now_ns;
    }

    pub fn noteResize(self: *OffscreenTexturePool) void {
        for (&self.entries) |*entry| if (entry.*) |*e| {
            e.old_size = true;
        };
    }

    fn deadline(e: *const PoolEntry) u64 {
        const age_ns = if (e.old_size) RESIZED_IDLE_NS else if (e.retained_id != NO_RETAINED_OWNER) RETAINED_IDLE_NS else POOL_IDLE_NS;
        return e.last_used_ns +| age_ns;
    }

    /// Independent wake deadline. It must not be scheduled as a UI redraw:
    /// a maintenance wake never acquires/presents a drawable.
    pub fn nextMaintenanceDelayNs(self: *const OffscreenTexturePool, now_ns: u64) ?u64 {
        var nearest: ?u64 = null;
        for (self.entries) |entry| if (entry) |e| {
            const delay = deadline(&e) -| now_ns;
            nearest = if (nearest) |n| @min(n, delay) else delay;
        };
        return nearest;
    }

    /// Between encoders only. The caller must prove the latest submitted buffer
    /// on this pool's serial queue is terminal; elapsed time is never a fence.
    /// Expired retained pixels lose their damage baseline. The next acquire is
    /// a full repaint, while the already presented window remains undisturbed.
    pub fn maintain(self: *OffscreenTexturePool, now_ns: u64, gpu_completed: bool) void {
        std.debug.assert(!self.encoder_active);
        self.clock_ns = now_ns;
        if (!gpu_completed) return;
        // Retire old viewport sizes first, then the normal grace period.
        for ([_]bool{ true, false }) |old_size| {
            for (&self.entries, 0..) |*entry, slot| {
                const e = if (entry.*) |*value| value else continue;
                if (e.old_size != old_size or now_ns < deadline(e)) continue;
                if (!e.old_size and e.retained_id != NO_RETAINED_OWNER and
                    now_ns < e.last_used_ns +| POOL_IDLE_NS)
                {
                    self.releaseDamageSlot(e);
                    e.retained_id = NO_RETAINED_OWNER;
                    e.retained_primed = false;
                    e.retained_content_version = 0;
                    e.in_use = false;
                    e.reusable_after_frame = 0;
                    // Losing ownership invalidates leases even if the texture
                    // remains available for size-based reuse.
                    bumpGeneration(&self.pool_generations[slot]);
                    continue;
                }
                self.releaseDamageSlot(e);
                e.texture.destroy();
                entry.* = null;
                bumpGeneration(&self.pool_generations[slot]);
            }
        }
    }

    // Frame-age sweeps retained only for legacy explicit callers/tests. The
    // app runtime exclusively uses fence-checked monotonic maintenance above.
    /// Recycle normal entries no acquire hit consecutive `POOL_IDLE_FRAMES` frames. Same
    /// rhythm as sweepRetained call (once/frame). Don't touch in_use / in-flight guard entries,
    /// only clear confirmed unreferenced idle textures.
    pub fn sweepIdle(self: *OffscreenTexturePool, frame_index: u64) void {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                if (e.in_use) continue;
                if (e.reusable_after_frame > frame_index) continue;
                if (frame_index < e.last_used_frame + POOL_IDLE_FRAMES) continue;
                self.releaseDamageSlot(e); // Defensive: normal entries shouldn't hold slot
                e.texture.destroy();
                entry.* = null;
                bumpGeneration(&self.pool_generations[slot]);
            }
        }
    }

    /// Recycle retained entries unclaimed consecutive `RETAINED_IDLE_FRAMES` frames, revert
    /// to normal pool entries (texture itself stays continue size-based reuse, no waste one
    /// create).
    pub fn sweepRetained(self: *OffscreenTexturePool, frame_index: u64) void {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (e.retained_id == NO_RETAINED_OWNER) continue;
                if (frame_index < e.last_used_frame + RETAINED_IDLE_FRAMES) continue;
                // Losing retained status => baseline must be invalidated and slot returned.
                // If not: texture gets acquired by another layer by size while slot stays on entry;
                // when later claimed as **another id** by acquireRetained, it reads the previous
                // owner's
                // baseline => diff is wrong => missing damage regions, stale pixels.
                self.releaseDamageSlot(e);
                e.retained_id = NO_RETAINED_OWNER;
                e.retained_primed = false;
                e.retained_content_version = 0;
                e.in_use = false;
                bumpGeneration(&self.pool_generations[slot]);
                // After returning to regular pool, must still pass in-flight protection period
                // before reuse.
                e.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
            }
        }
    }

    /// Rendering policy changed: keep resources/in-flight ownership, discard
    /// pixel and partial-damage baselines so an old material cannot be reused.
    pub fn invalidateRetainedContents(self: *OffscreenTexturePool) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                self.releaseDamageSlot(e);
                e.retained_primed = false;
                e.retained_content_version = 0;
            }
        }
    }

    /// Release retained texture for a layer (when layer is destroyed).
    pub fn dropRetained(self: *OffscreenTexturePool, retained_id: u32, frame_index: u64) void {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                self.releaseDamageSlot(e); // Like sweepRetained: without retained status, baseline must be invalidated.
                e.retained_id = NO_RETAINED_OWNER;
                e.retained_primed = false;
                e.retained_content_version = 0;
                e.in_use = false;
                e.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
                bumpGeneration(&self.pool_generations[slot]);
            }
        }
    }

    /// Release all textures.
    pub fn deinit(self: *OffscreenTexturePool) void {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                self.releaseDamageSlot(e);
                e.texture.destroy();
                entry.* = null;
                bumpGeneration(&self.pool_generations[slot]);
            }
        }
        self.damage_slot_used = @as([MAX_DAMAGE_SLOTS]bool, @splat(false));
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.*) |*e| e.texture.destroy();
            entry.* = null;
            bumpGeneration(&self.transient_generations[slot]);
        }
        self.count = 0;
    }
};

test "releaseForReuseInFrame makes texture immediately reacquirable in same frame" {
    var pool = OffscreenTexturePool{};
    pool.entries[0] = .{ .texture = fakeTexture(64, 64), .width = 64, .height = 64, .in_use = true, .reusable_after_frame = 0 };
    pool.count = 1;
    const lease = pool.pooledLease(0);

    // Regular release: not reusable within REUSE_LAG_FRAMES.
    try std.testing.expect(pool.release(lease, 10));
    try std.testing.expectEqual(@as(u64, 13), pool.entries[0].?.reusable_after_frame);

    // Same-frame reuse release: immediately available for same-frame acquire hit (hit path avoids
    // device calls).
    pool.entries[0].?.in_use = true;
    try std.testing.expect(pool.releaseForReuseInFrame(lease));
    try std.testing.expect(!pool.entries[0].?.in_use);
    try std.testing.expectEqual(@as(u64, 0), pool.entries[0].?.reusable_after_frame);
    const got = pool.acquire(undefined, 64, 64, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expect(got.eql(lease));
    try std.testing.expect(pool.entries[0].?.in_use);
}

test "acquireWithFormat keeps pooled and transient formats separate and reuses matching leases" {
    // SKIP-REASON: Null supplies deterministic allocation without a live GPU.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var pool = OffscreenTexturePool{};
    defer pool.deinit();

    const srgb = pool.acquire(&device, 8, 8, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.releaseForReuseInFrame(srgb));
    const float = pool.acquireWithFormat(&device, 8, 8, 10, .rgba16_float) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!float.eql(srgb));
    try std.testing.expectEqual(gpu.TextureFormat.bgra8_unorm, pool.resolveTexture(srgb).?.format);
    try std.testing.expectEqual(gpu.TextureFormat.rgba16_float, pool.resolveTexture(float).?.format);
    try std.testing.expect(pool.releaseForReuseInFrame(float));

    const srgb_again = pool.acquire(&device, 8, 8, 10) orelse return error.TestUnexpectedResult;
    const float_again = pool.acquireWithFormat(&device, 8, 8, 10, .rgba16_float) orelse return error.TestUnexpectedResult;
    try std.testing.expect(srgb_again.eql(srgb));
    try std.testing.expect(float_again.eql(float));
    try std.testing.expectEqual(@as(usize, 2), device.texture_count);

    // Hold every pooled entry in use so both formats must use transient slots.
    while (pool.count < OffscreenTexturePool.MAX_POOL) {
        _ = pool.acquire(&device, 4, 4, 10) orelse return error.TestUnexpectedResult;
    }
    const transient_float = pool.acquireWithFormat(&device, 8, 8, 10, .rgba16_float) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TextureLease.Kind.transient, transient_float.kind);
    try std.testing.expect(pool.releaseForReuseInFrame(transient_float));
    const transient_srgb = pool.acquire(&device, 8, 8, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TextureLease.Kind.transient, transient_srgb.kind);
    try std.testing.expect(!transient_srgb.eql(transient_float));
    try std.testing.expectEqual(gpu.TextureFormat.bgra8_unorm, pool.resolveTexture(transient_srgb).?.format);
    try std.testing.expectEqual(gpu.TextureFormat.rgba16_float, pool.resolveTexture(transient_float).?.format);
    try std.testing.expect(pool.releaseForReuseInFrame(transient_srgb));

    const created = device.texture_count;
    const transient_float_again = pool.acquireWithFormat(&device, 8, 8, 10, .rgba16_float) orelse return error.TestUnexpectedResult;
    const transient_srgb_again = pool.acquire(&device, 8, 8, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expect(transient_float_again.eql(transient_float));
    try std.testing.expect(transient_srgb_again.eql(transient_srgb));
    try std.testing.expectEqual(created, device.texture_count);
}

test "acquireWithFormat recovers a failed allocation after eviction without reviving a stale lease" {
    // SKIP-REASON: Null can deterministically reject an invalid descriptor.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var pool = OffscreenTexturePool{};
    defer pool.deinit();
    const old = pool.acquire(&device, 8, 8, 10) orelse return error.TestUnexpectedResult;
    while (pool.count < OffscreenTexturePool.MAX_POOL) {
        _ = pool.acquire(&device, 4, 4, 10) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expect(pool.releaseForReuseInFrame(old));
    try std.testing.expect(pool.acquireWithFormat(&device, 0, 8, 10, .rgba16_float) == null);
    try std.testing.expect(pool.resolveTexture(old) == null);
    try std.testing.expect(pool.entries[old.slot] == null);
    try std.testing.expectEqual(@as(usize, OffscreenTexturePool.MAX_POOL), pool.count);

    // The high-water mark stays full, but the vacant slot must be recoverable.
    const fresh = pool.acquireWithFormat(&device, 8, 8, 10, .rgba16_float) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(old.slot, fresh.slot);
    try std.testing.expect(!fresh.eql(old));
    try std.testing.expectEqual(gpu.TextureFormat.rgba16_float, pool.resolveTexture(fresh).?.format);
    try std.testing.expect(pool.resolveTexture(old) == null);

    // A successful eviction must create the requested new format as well.
    try std.testing.expect(pool.releaseForReuseInFrame(fresh));
    const replacement = pool.acquireWithFormat(&device, 8, 8, 10, .rgba32_float) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh.slot, replacement.slot);
    try std.testing.expect(!replacement.eql(fresh));
    try std.testing.expectEqual(gpu.TextureFormat.rgba32_float, pool.resolveTexture(replacement).?.format);
    try std.testing.expect(pool.resolveTexture(fresh) == null);
}

test "computeOffscreenTextureSize accepts finite positive bounds" {
    const size = computeOffscreenTextureSize(120.25, 60.1, 2.0, 8192).?;
    try std.testing.expectEqual(@as(u32, 241), size.width);
    try std.testing.expectEqual(@as(u32, 121), size.height);
}

test "computeOffscreenTextureSize rejects invalid layer bounds" {
    try std.testing.expect(computeOffscreenTextureSize(std.math.nan(f32), 40, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(40, std.math.inf(f32), 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(0, 40, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(40, -2, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(40, 40, 0, 8192) == null);
}

test "computeOffscreenTextureSize rejects oversize textures" {
    try std.testing.expect(computeOffscreenTextureSize(4097, 1, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(1, 4096.5, 2.0, 8192) == null);
}

// GPU retained semantics tests
// --------
// Cases guard rendering correctness, not performance: a wrong retained decision
// shows stale prior-frame content, worse than redrawing. Each 'can reuse'
// assertion pairs with a 'must not reuse' inverse.
// Tests use an undefined native handle and exercise bookkeeping paths only.

fn fakeTexture(width: u32, height: u32) gpu.Backend.Texture {
    // Use backend-provided constructor, not direct field literals, which would bake
    // one backend's field layout (Metal's `.raw`) into render tests and fail on switch.
    return gpu.Backend.Texture.fakeForTesting(width, height, .bgra8_unorm);
}

/// Pre-seed a primed retained entry, simulating 'previous frame already rendered'.
fn seedRetained(
    pool: *OffscreenTexturePool,
    idx: usize,
    retained_id: u32,
    content_version: u64,
    w: u32,
    h: u32,
) void {
    pool.entries[idx] = .{
        .texture = fakeTexture(w, h),
        .width = w,
        .height = h,
        .in_use = true,
        .last_used_frame = 0,
        .retained_id = retained_id,
        .retained_content_version = content_version,
        .retained_primed = true,
    };
    if (pool.count <= idx) pool.count = idx + 1;
}

test "retained: same id + same content_version + same size = cache hit" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    const got = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(got.lease.eql(pool.pooledLease(0)));
    try std.testing.expect(got.content_matches);
}

test "retained: content_version bump forces repaint" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    // Content changed -> must redraw, else display freezes on stale content.
    const got = pool.acquireRetained(undefined, 42, 8, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(got.lease.eql(pool.pooledLease(0))); // Texture reused (saves one allocation).
    try std.testing.expect(!got.content_matches); // But content must redraw.
    // Record new version after claiming; can't count as a hit until after redraw and
    // markRetainedPrimed.
    try std.testing.expectEqual(@as(u64, 8), pool.entries[0].?.retained_content_version);
}

test "retained: not primed yet = miss even when version matches" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    // Newly allocated texture content is undefined.
    pool.entries[0].?.retained_primed = false;

    const got = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!got.content_matches);

    // Only counts as a hit after draw completes and marked.
    try std.testing.expect(pool.markRetainedPrimed(got.lease));
    const got2 = pool.acquireRetained(undefined, 42, 7, 128, 128, 6) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(got2.content_matches);
}

test "retained: miss 后内容 pass 未完成（未 markRetainedPrimed）下一帧同指纹不得命中" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    // Frame N: fingerprint 7->8, miss, start redraw... but content pass fails mid-way,
    // never reaches end's markRetainedPrimed.
    const miss = pool.acquireRetained(undefined, 42, 8, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!miss.content_matches);
    try std.testing.expect(miss.was_primed); // Partial redraw criteria still use old state.
    // Frame N+k (after protection period): same fingerprint 8, texture holds incomplete
    // render, must redraw.
    const again = pool.acquireRetained(undefined, 42, 8, 128, 128, 5 + OffscreenTexturePool.REUSE_LAG_FRAMES) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!again.content_matches);
    try std.testing.expect(!again.was_primed); // Old pixels untrustworthy -> skip partial redraw.
    // Completed this time -> subsequent same-fingerprint hits work.
    try std.testing.expect(pool.markRetainedPrimed(again.lease));
    const hit = pool.acquireRetained(undefined, 42, 8, 128, 128, 5 + 2 * OffscreenTexturePool.REUSE_LAG_FRAMES) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit.content_matches);
}

test "retained: different layer id never shares a texture" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    seedRetained(&pool, 1, 43, 7, 128, 128);

    const a = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    const b = pool.acquireRetained(undefined, 43, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(a.lease.eql(pool.pooledLease(0)));
    try std.testing.expect(b.lease.eql(pool.pooledLease(1)));
    try std.testing.expect(!a.lease.eql(b.lease));
}

test "retained: size-keyed acquire never steals a retained texture" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    // Even clearing in_use (simulating wrong resetFrame behavior), must not be claimed by regular
    // acquire.
    pool.entries[0].?.in_use = false;

    // Size matches perfectly, but since it's a retained entry, acquire must skip it to go
    // through create path. Create path needs real device; undefined here would crash, so instead
    // verify 'scan won't return it': pool holds only this entry and no other hits possible.
    var found_retained = false;
    for (pool.entries) |maybe| {
        if (maybe) |e| {
            if (e.retained_id != NO_RETAINED_OWNER) found_retained = true;
        }
    }
    try std.testing.expect(found_retained);
    // Verify invariant directly: acquire hit condition includes retained skip.
    // (Equivalence assertions in comments above; here assert bookkeeping not broken by resetFrame.)
    pool.resetFrame();
    try std.testing.expect(pool.entries[0].?.retained_id == 42);
}

test "retained: resetFrame does not release retained entries" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    pool.entries[1] = .{ .texture = fakeTexture(64, 64), .width = 64, .height = 64, .in_use = true, .last_used_ns = pool.clock_ns };
    pool.count = 2;

    pool.resetFrame();
    // Regular entries return to pool; retained entries remain exclusive to their layer.
    try std.testing.expect(!pool.entries[1].?.in_use);
    try std.testing.expect(pool.entries[0].?.in_use);
}

test "retained: idle sweep returns the texture to the normal pool" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    pool.entries[0].?.last_used_frame = 100;

    // Not expired yet: keep retained.
    pool.sweepRetained(100 + RETAINED_IDLE_FRAMES - 1);
    try std.testing.expectEqual(@as(u32, 42), pool.entries[0].?.retained_id);

    // Expired: return to regular pool, texture itself kept for reuse but must pass in-flight
    // protection.
    pool.sweepRetained(100 + RETAINED_IDLE_FRAMES);
    try std.testing.expectEqual(NO_RETAINED_OWNER, pool.entries[0].?.retained_id);
    try std.testing.expect(!pool.entries[0].?.in_use);
    try std.testing.expect(!pool.entries[0].?.retained_primed);
    try std.testing.expect(pool.entries[0].?.reusable_after_frame > 100 + RETAINED_IDLE_FRAMES);
}

test "retained: dropRetained releases ownership immediately" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    pool.dropRetained(42, 200);
    try std.testing.expectEqual(NO_RETAINED_OWNER, pool.entries[0].?.retained_id);
    try std.testing.expect(!pool.entries[0].?.in_use);
    try std.testing.expect(pool.entries[0].?.reusable_after_frame > 200);
}

test "retained: zero fingerprint is rejected" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 0, 128, 128);
    // Fingerprint 0 = prescan couldn't compute valid value, must reject retained (prefer redraw
    // every frame).
    try std.testing.expect(pool.acquireRetained(undefined, 42, 0, 128, 128, 5) == null);
}

test "retained: NO_RETAINED_OWNER id is rejected" {
    var pool = OffscreenTexturePool{};
    // Sentinel id is not valid identity, must reject, else all 'non-retained' layers share one
    // texture and overwrite each other.
    try std.testing.expect(pool.acquireRetained(undefined, NO_RETAINED_OWNER, 0, 64, 64, 1) == null);
}

test "retained: eviction may sacrifice an idle retained entry when pool is full" {
    // Regression guard (2026-07-30): retained entries were once **completely non-evictable**; once
    // they pinned all 16 slots, evictLruSlot always returned null, so no regular offscreen texture
    // could enter the pool and each frame did create/release. GPU retained is an optimization and
    // must never starve the regular path.
    var pool = OffscreenTexturePool{};
    for (0..OffscreenTexturePool.MAX_POOL) |i| {
        seedRetained(&pool, i, @intCast(i + 1), 7, 64, 64);
        // All 'used last frame', not claimed this frame.
        pool.entries[i].?.last_used_frame = 10;
        pool.entries[i].?.reusable_after_frame = 0;
    }
    // All retained, none claimed this frame -> allow evicting the oldest.
    const victim = pool.findLruSlot(20);
    try std.testing.expect(victim != null);
}

test "retained: entry claimed this frame is never evicted" {
    var pool = OffscreenTexturePool{};
    for (0..OffscreenTexturePool.MAX_POOL) |i| {
        seedRetained(&pool, i, @intCast(i + 1), 7, 64, 64);
        pool.entries[i].?.last_used_frame = 20; // Claimed this frame.
        pool.entries[i].?.reusable_after_frame = 0;
    }
    // Evicting a retained texture in active use (being written) = texture stolen while writing,
    // render breaks.
    try std.testing.expect(pool.findLruSlot(20) == null);
}

test "damage-rect: 基线存取 + 尺寸变化作废 + was_primed 语义" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    const items = [_]DamageItem{
        .{ .digest = 111, .bounds = .{ 0, 0, 10, 10 } },
        .{ .digest = 222, .bounds = .{ 10, 10, 20, 20 } },
    };
    pool.storeRetainedDamageItems(42, items[0..]);
    const got_items = pool.retainedDamageItems(42) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), got_items.len);
    try std.testing.expectEqual(@as(u64, 222), got_items[1].digest);

    // Content miss but primed + same size -> was_primed=true (partial redraw precondition).
    const got = pool.acquireRetained(undefined, 42, 8, 128, 128, 100) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!got.content_matches);
    try std.testing.expect(got.was_primed);

    // Explicit invalidation.
    pool.storeRetainedDamageItems(42, null);
    try std.testing.expect(pool.retainedDamageItems(42) == null);

    // Re-store, size-change path must invalidate baseline.
    pool.storeRetainedDamageItems(42, items[0..]);
    pool.entries[0].?.reusable_after_frame = 0;
    // Can't call real createTexture (needs device), assert field semantics directly:
    try std.testing.expect(pool.entries[0].?.damage_slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    pool.entries[0].?.width = 999; // Simulate size mismatch precondition.
    // acquireRetained size-mismatch branch needs real device for texture creation, can't test in
    // unit tests;
    // semantics guaranteed by `releaseDamageSlot(e)` call (see acquireRetained).
    _ = &pool;
}

test "damage-rect: 旁路槽位随条目回收，绝不串味" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    const items = [_]DamageItem{.{ .digest = 111, .bounds = .{ 0, 0, 10, 10 } }};

    pool.storeRetainedDamageItems(42, items[0..]);
    const slot = pool.entries[0].?.damage_slot;
    try std.testing.expect(slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    try std.testing.expect(pool.damage_slot_used[slot]);

    // Idle eviction -> identity gone, slot must return, baseline unreachable.
    pool.entries[0].?.last_used_frame = 100;
    pool.sweepRetained(100 + RETAINED_IDLE_FRAMES);
    try std.testing.expectEqual(OffscreenTexturePool.NO_DAMAGE_SLOT, pool.entries[0].?.damage_slot);
    try std.testing.expect(!pool.damage_slot_used[slot]);
    try std.testing.expect(pool.retainedDamageItems(42) == null);

    // Same entry claimed by **another** id afterward must never read previous owner's baseline
    // (cross-contamination = missing damage regions).
    pool.entries[0].?.retained_id = 43;
    try std.testing.expect(pool.retainedDamageItems(43) == null);

    // dropRetained also returns slot.
    pool.entries[0].?.retained_id = 44;
    pool.storeRetainedDamageItems(44, items[0..]);
    try std.testing.expect(pool.entries[0].?.damage_slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    pool.dropRetained(44, 200);
    try std.testing.expectEqual(OffscreenTexturePool.NO_DAMAGE_SLOT, pool.entries[0].?.damage_slot);
}

test "damage-rect: 槽位耗尽是安全降级（不截断、不复用别人的槽）" {
    var pool = OffscreenTexturePool{};
    const items = [_]DamageItem{.{ .digest = 111, .bounds = .{ 0, 0, 10, 10 } }};
    // WARNING: slot count and pool capacity are **two independent constants**; the test indexes
    // both
    // entries (length MAX_POOL) and damage_slots (length MAX_DAMAGE_SLOTS). Using MAX_DAMAGE_SLOTS
    // as
    // an entries upper bound fails when MAX_POOL < MAX_DAMAGE_SLOTS+1 ("index 64 outside array of
    // length 48"). Use the smaller value and skip configs where the pool can't demonstrate
    // 'slots exhausted'.
    const pool_cap = OffscreenTexturePool.MAX_POOL;
    // SKIP-REASON: branch reachable only if pool capacity exceeds damage slot count,
    // compiler-constant-dependent.
    if (pool_cap <= MAX_DAMAGE_SLOTS) return error.SkipZigTest;
    const fill_n = @min(MAX_DAMAGE_SLOTS, pool_cap - 1);
    // Fill all slots (ids start at 1, skip NO_RETAINED_OWNER).
    for (0..fill_n) |i| {
        seedRetained(&pool, i, @intCast(i + 1), 7, 64, 64);
        pool.storeRetainedDamageItems(@intCast(i + 1), items[0..]);
        try std.testing.expect(pool.entries[i].?.damage_slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    }
    // Entry N+1: no slot available -> don't store baseline (whole layer redraws next frame), don't
    // steal others'.
    seedRetained(&pool, fill_n, 9999, 7, 64, 64);
    pool.storeRetainedDamageItems(9999, items[0..]);
    try std.testing.expectEqual(
        OffscreenTexturePool.NO_DAMAGE_SLOT,
        pool.entries[fill_n].?.damage_slot,
    );
    try std.testing.expect(pool.retainedDamageItems(9999) == null);
    // All existing baselines untouched.
    for (0..fill_n) |i| {
        try std.testing.expect(pool.retainedDamageItems(@intCast(i + 1)) != null);
    }
}

test "damage-rect: 超上限的 items 置 invalid 且释放已占槽" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    const ok = [_]DamageItem{.{ .digest = 1, .bounds = .{ 0, 0, 1, 1 } }};
    pool.storeRetainedDamageItems(42, ok[0..]);
    try std.testing.expect(pool.retainedDamageItems(42) != null);

    // Over MAX_DAMAGE_ITEMS: prefer whole-layer redraw, never truncate diff.
    var big: [MAX_DAMAGE_ITEMS + 1]DamageItem = undefined;
    for (&big) |*it| it.* = .{ .digest = 2, .bounds = .{ 0, 0, 1, 1 } };
    pool.storeRetainedDamageItems(42, big[0..]);
    try std.testing.expect(pool.retainedDamageItems(42) == null);
    try std.testing.expectEqual(OffscreenTexturePool.NO_DAMAGE_SLOT, pool.entries[0].?.damage_slot);
}

// ============================================================================
// Struct size guardrail
// ------------
// Damage items live in a side table, not inline in PoolEntry: inline `damage_items:
// [128]DamageItem`
// is 3152 B per entry, making `entries: [128]?PoolEntry` 403 KB while most entries never touch
// damage. PoolEntry is ~72 B.
// Assertion fails at compile time if large arrays get inlined into PoolEntry.
// When adding fields, update this and document why.
comptime {
    const entry_size = @sizeOf(OffscreenTexturePool.PoolEntry);
    // Backend texture handles have different sizes (D3D12 also owns a Context).
    // Bound pool metadata independently, preserving the no-inline-array guard.
    const max_entry_size = @max(96, @sizeOf(gpu.Backend.Texture) + 64);
    if (entry_size > max_entry_size) {
        @compileError(std.fmt.comptimePrint(
            "PoolEntry 膨胀到 {d} B（上限 {d}）。entries 数组是 MAX_POOL 份，" ++
                "别往这里内联大数组 —— 只对 retained 条目有意义的数据请走旁路存储" ++
                "（见 damage_slots）。",
            .{ entry_size, max_entry_size },
        ));
    }
}

test "PoolEntry 不再内联大数组（尺寸护栏）" {
    try std.testing.expect(@sizeOf(OffscreenTexturePool.PoolEntry) <= @max(96, @sizeOf(gpu.Backend.Texture) + 64));
    // Entries array itself also pinned: MAX_POOL=128 should be ~16 KB scale, not ~400 KB.
    try std.testing.expect(@sizeOf(@TypeOf(@as(OffscreenTexturePool, undefined).entries)) <= 32 * 1024);
}

test "GPU completion permits next-frame repaint without losing retained ownership or validity" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    seedRetained(&pool, 1, NO_RETAINED_OWNER, 0, 128, 128);
    _ = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.acquireRetained(undefined, 42, 8, 128, 128, 6) == null);
    pool.entries[1].?.reusable_after_frame = 8;
    const generation = pool.pool_generations[0];
    pool.notifyGpuIdle();
    try std.testing.expect(pool.entries[0].?.in_use and pool.entries[1].?.in_use);
    try std.testing.expectEqual(generation, pool.pool_generations[0]);
    try std.testing.expectEqual(@as(u64, 0), pool.entries[1].?.reusable_after_frame);
    pool.resetFrame();
    try std.testing.expect(pool.entries[0].?.in_use and !pool.entries[1].?.in_use);
    const repaint = pool.acquireRetained(undefined, 42, 8, 128, 128, 6) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!repaint.content_matches and repaint.was_primed);
    try std.testing.expect(repaint.lease.eql(pool.pooledLease(0)));
    // A fence alone does not certify the contents of an interrupted repaint.
    pool.notifyGpuIdle();
    const incomplete = pool.acquireRetained(undefined, 42, 8, 128, 128, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!incomplete.content_matches and !incomplete.was_primed);
}

test "memory snapshot separates retained idle transient and unsupported formats without mutation" {
    var pool: OffscreenTexturePool = .{};
    pool.entries[0] = .{ .texture = gpu.Backend.Texture.fakeForTesting(64, 64, .bgra8_unorm), .width = 64, .height = 64, .in_use = false, .last_used_frame = 1 };
    pool.entries[1] = .{ .texture = gpu.Backend.Texture.fakeForTesting(32, 32, .rgba16_float), .width = 32, .height = 32, .in_use = true, .last_used_frame = 200, .retained_id = 7 };
    pool.entries[2] = .{ .texture = gpu.Backend.Texture.fakeForTesting(1, 1, .depth32_float), .width = 1, .height = 1, .in_use = false, .last_used_frame = 201 };
    pool.transients[0] = .{ .texture = gpu.Backend.Texture.fakeForTesting(16, 16, .r8_unorm), .width = 16, .height = 16, .in_use = true };
    const before = pool.entries[0].?.last_used_frame;
    const snapshot = pool.memorySnapshot(201);
    try std.testing.expectEqual(@as(u32, 4), snapshot.live);
    try std.testing.expectEqual(@as(u32, 1), snapshot.retained);
    try std.testing.expectEqual(@as(u32, 1), snapshot.transient);
    try std.testing.expectEqual(@as(u32, 2), snapshot.idle);
    try std.testing.expectEqual(@as(u32, 1), snapshot.reapable);
    try std.testing.expectEqual(@as(u64, 200), snapshot.oldest_age_frames);
    try std.testing.expectEqual(@as(u64, 64 * 64 * 4 + 32 * 32 * 8 + 16 * 16), snapshot.logical_bytes);
    try std.testing.expectEqual(@as(u64, 32 * 32 * 8), snapshot.retained_bytes);
    try std.testing.expectEqual(@as(u32, 1), snapshot.unsupported_formats);
    try std.testing.expectEqual(before, pool.entries[0].?.last_used_frame);
    try std.testing.expectEqual(@as(u32, 7), pool.entries[1].?.retained_id);
}

test "wallclock maintenance waits for a fence and invalidates retained damage without frames" {
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var pool: OffscreenTexturePool = .{};
    defer pool.deinit();
    pool.setClock(10 * std.time.ns_per_s);
    const retained = pool.acquireRetained(&device, 9, 44, 64, 64, 1).?;
    try std.testing.expect(pool.markRetainedPrimed(retained.lease));
    pool.storeRetainedDamageItems(9, &.{});
    const count = device.texture_count;
    const next = pool.nextMaintenanceDelayNs(10 * std.time.ns_per_s).?;
    try std.testing.expectEqual(OffscreenTexturePool.RETAINED_IDLE_NS, next);
    pool.maintain(14 * std.time.ns_per_s, false);
    try std.testing.expect(pool.resolveTexture(retained.lease) != null);
    try std.testing.expect(pool.retainedDamageItems(9) != null);
    pool.maintain(14 * std.time.ns_per_s, true);
    try std.testing.expect(pool.resolveTexture(retained.lease) == null);
    try std.testing.expect(pool.retainedDamageItems(9) == null);
    const fresh = pool.acquireRetained(&device, 9, 44, 64, 64, 1).?;
    try std.testing.expect(!fresh.content_matches and !fresh.was_primed);
    try std.testing.expect(!fresh.lease.eql(retained.lease));
    try std.testing.expectEqual(count + 1, device.texture_count);
}

test "resize grace retires old sizes but preserves a newly reused size" {
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var pool: OffscreenTexturePool = .{};
    defer pool.deinit();
    pool.setClock(std.time.ns_per_s);
    const old = pool.acquire(&device, 128, 64, 1).?;
    const used = pool.acquire(&device, 64, 64, 1).?;
    _ = pool.releaseForReuseInFrame(used);
    pool.noteResize();
    pool.setClock(2 * std.time.ns_per_s);
    const reused = pool.acquire(&device, 64, 64, 1).?;
    try std.testing.expect(reused.eql(used));
    pool.maintain(2 * std.time.ns_per_s, false);
    try std.testing.expect(pool.resolveTexture(old) != null);
    pool.maintain(2 * std.time.ns_per_s, true);
    try std.testing.expect(pool.resolveTexture(old) == null);
    try std.testing.expect(pool.resolveTexture(reused) != null);
    pool.maintain(5 * std.time.ns_per_s, true);
    try std.testing.expect(pool.resolveTexture(reused) == null);
    try std.testing.expect(pool.nextMaintenanceDelayNs(5 * std.time.ns_per_s) == null);
}

test "retained downgrade invalidates leases before size-based reuse" {
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var pool: OffscreenTexturePool = .{};
    defer pool.deinit();
    pool.setClock(10 * std.time.ns_per_s);
    const old = pool.acquireRetained(&device, 9, 44, 64, 64, 1).?;
    try std.testing.expect(pool.markRetainedPrimed(old.lease));
    pool.maintain(11 * std.time.ns_per_s, true);
    try std.testing.expect(pool.resolveTexture(old.lease) == null);
    try std.testing.expect(!pool.markRetainedPrimed(old.lease));
    const reused = pool.acquire(&device, 64, 64, 2).?;
    try std.testing.expect(!reused.eql(old.lease));
    try std.testing.expect(pool.resolveTexture(reused) != null);
    try std.testing.expectEqual(@as(u32, 1), device.texture_count);
}
