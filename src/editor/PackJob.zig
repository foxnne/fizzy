//! Background project-pack job. Owns a worker thread that runs the full append-pack-blit pipeline
//! off the main thread so packing large projects doesn't stall the editor.
//!
//! Inputs are gathered on the main thread: open files are snapshotted into thread-isolated
//! `PackFile` values (deep copies of layer pixels + sprite/animation metadata); unopened files
//! are passed as paths and the worker loads them via `Internal.File.fromPath`. Either way the
//! worker only ever touches its own `PackFile` values plus the app allocator.
//!
//! The worker produces a finished `Internal.Atlas` (RGBA pixels + sprite/animation data). The
//! main thread swaps it into `fizzy.packer.atlas` via `Editor.processPackJob` once `done` is
//! published.
//!
//! Ownership / threading model:
//!   - `inputs` is owned by the job; each input owns its own buffers. Freed in `destroy()`.
//!   - `result_atlas` is written by the worker, read by the main thread only after
//!     `done.load(.acquire)`. On consume the main thread takes ownership of its allocations.
//!   - `phase` / `cancelled` are atomic; either side may read or write them.

const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const zstbi = @import("zstbi");
const perf = @import("../gfx/perf.zig");
const reduce_alg = @import("../algorithms/reduce.zig");

const PackJob = @This();

pub const Phase = enum(u8) {
    queued = 0,
    loading = 1,
    appending = 2,
    packing = 3,
    blitting = 4,
    ready = 5,
    failed = 6,
    cancelled = 7,
};

// ----------------------------------------------------------------------------
// Thread-safe snapshot of the pack-relevant data for a single file.
// ----------------------------------------------------------------------------

pub const PackLayer = struct {
    name: []u8,
    visible: bool,
    collapse: bool,
    width: u32,
    height: u32,
    pixels: [][4]u8,

    fn deinit(self: *PackLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.pixels);
    }
};

pub const PackSprite = struct {
    origin: [2]f32,
};

pub const PackAnimation = struct {
    name: []u8,
    frames: []fizzy.Animation.Frame,

    fn deinit(self: *PackAnimation, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.frames);
    }
};

pub const PackFile = struct {
    columns: u32,
    column_width: u32,
    row_height: u32,
    width: u32,
    height: u32,
    layers: []PackLayer,
    sprites: []PackSprite,
    animations: []PackAnimation,
    allocator: std.mem.Allocator,

    /// Deep-copy the pack-relevant fields of an in-memory file. Caller must run on the main
    /// thread (reads the file's pixel buffers, which the editor may otherwise mutate).
    pub fn fromOpenFile(allocator: std.mem.Allocator, file: *const fizzy.Internal.File) !PackFile {
        const src_layers = file.layers.slice();

        var layers = try allocator.alloc(PackLayer, src_layers.len);
        var layers_initialized: usize = 0;
        errdefer {
            for (layers[0..layers_initialized]) |*l| l.deinit(allocator);
            allocator.free(layers);
        }

        var i: usize = 0;
        while (i < src_layers.len) : (i += 1) {
            const layer = src_layers.get(i);
            const sz = dvui.imageSize(layer.source) catch dvui.Size{ .w = 0, .h = 0 };
            const layer_w: u32 = @intFromFloat(sz.w);
            const layer_h: u32 = @intFromFloat(sz.h);
            const src_pixels = fizzy.image.pixels(layer.source);

            const name_copy = try allocator.dupe(u8, layer.name);
            errdefer allocator.free(name_copy);

            const pixels_copy = try allocator.dupe([4]u8, src_pixels);

            layers[i] = .{
                .name = name_copy,
                .visible = layer.visible,
                .collapse = layer.collapse,
                .width = layer_w,
                .height = layer_h,
                .pixels = pixels_copy,
            };
            layers_initialized = i + 1;
        }

        const src_sprites = file.sprites.slice();
        const sprites = try allocator.alloc(PackSprite, src_sprites.len);
        errdefer allocator.free(sprites);
        for (sprites, 0..) |*dst, idx| {
            const s = src_sprites.get(idx);
            dst.* = .{ .origin = s.origin };
        }

        const src_anims = file.animations.slice();
        var anims = try allocator.alloc(PackAnimation, src_anims.len);
        var anims_initialized: usize = 0;
        errdefer {
            for (anims[0..anims_initialized]) |*a| a.deinit(allocator);
            allocator.free(anims);
        }
        var a: usize = 0;
        while (a < src_anims.len) : (a += 1) {
            const anim = src_anims.get(a);
            const name_copy = try allocator.dupe(u8, anim.name);
            errdefer allocator.free(name_copy);
            const frames_copy = try allocator.dupe(fizzy.Animation.Frame, anim.frames);
            anims[a] = .{ .name = name_copy, .frames = frames_copy };
            anims_initialized = a + 1;
        }

        return .{
            .columns = file.columns,
            .column_width = file.column_width,
            .row_height = file.row_height,
            .width = file.width(),
            .height = file.height(),
            .layers = layers,
            .sprites = sprites,
            .animations = anims,
            .allocator = allocator,
        };
    }

    /// Build a snapshot by loading the file from disk. Safe to call from any thread.
    pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) !?PackFile {
        const maybe_file = try fizzy.Internal.File.fromPath(path);
        var file = maybe_file orelse return null;
        defer file.deinit();
        return try PackFile.fromOpenFile(allocator, &file);
    }

    pub fn deinit(self: *PackFile) void {
        for (self.layers) |*l| l.deinit(self.allocator);
        self.allocator.free(self.layers);
        self.allocator.free(self.sprites);
        for (self.animations) |*anim| anim.deinit(self.allocator);
        self.allocator.free(self.animations);
    }
};

pub const PackInput = union(enum) {
    open: PackFile,
    /// Owned path string. Worker loads from disk and converts.
    path: []u8,

    pub fn deinit(self: *PackInput, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .open => |*pf| pf.deinit(),
            .path => |p| allocator.free(p),
        }
    }
};

// ----------------------------------------------------------------------------
// Job state
// ----------------------------------------------------------------------------

allocator: std.mem.Allocator,

/// All inputs to pack, in deterministic order. Owned.
inputs: []PackInput,

/// Captured at create time on the GUI thread; the worker uses it to wake the main loop on
/// completion via `dvui.refresh(window, ...)` so small projects don't sit completed-but-
/// unconsumed waiting for an unrelated input event.
window: *dvui.Window,

started_at_ns: i128,

phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.queued)),

/// Worker reports `(done_inputs, total_inputs)` while in the `loading` / `appending` phases.
progress_num: std.atomic.Value(u32) = .init(0),
progress_den: std.atomic.Value(u32) = .init(0),

cancelled: std.atomic.Value(bool) = .init(false),

/// Worker → main publish flag. `release` on write, `acquire` on read.
done: std.atomic.Value(bool) = .init(false),

/// Worker output. Read only after `done.load(.acquire)`. The main thread takes ownership of
/// the inner allocations when it consumes the job; subsequent `destroy()` will leave the
/// fields alone.
result_atlas: ?fizzy.Internal.Atlas = null,

/// Set to `true` once the main thread has consumed `result_atlas` (so `destroy()` knows not
/// to free the moved-out atlas allocations).
result_consumed: bool = false,

err: ?anyerror = null,

pub fn create(allocator: std.mem.Allocator, inputs: []PackInput) !*PackJob {
    const job = try allocator.create(PackJob);
    job.* = .{
        .allocator = allocator,
        .inputs = inputs,
        .window = dvui.currentWindow(),
        .started_at_ns = perf.nanoTimestamp(),
    };
    return job;
}

pub fn destroy(job: *PackJob) void {
    const a = job.allocator;
    for (job.inputs) |*input| input.deinit(a);
    a.free(job.inputs);

    // Free any unconsumed result. `result_consumed` is set by the main thread when it moves
    // the atlas into `fizzy.packer.atlas`; in that case the new owner is responsible for the
    // allocations and we must not double-free.
    if (job.result_atlas != null and !job.result_consumed) {
        const atlas = job.result_atlas.?;
        a.free(fizzy.image.bytes(atlas.source));
        for (atlas.data.animations) |*anim| a.free(anim.name);
        a.free(atlas.data.animations);
        a.free(atlas.data.sprites);
    }
    a.destroy(job);
}

pub fn elapsedExceeds(job: *const PackJob, threshold_ms: i64) bool {
    const elapsed_ns = perf.nanoTimestamp() - job.started_at_ns;
    return @divTrunc(elapsed_ns, std.time.ns_per_ms) >= threshold_ms;
}

pub fn currentPhase(job: *const PackJob) Phase {
    const raw = job.phase.load(.acquire);
    return switch (raw) {
        0 => .queued,
        1 => .loading,
        2 => .appending,
        3 => .packing,
        4 => .blitting,
        5 => .ready,
        6 => .failed,
        7 => .cancelled,
        else => .queued,
    };
}

pub fn phaseLabel(phase: Phase) []const u8 {
    return switch (phase) {
        .queued => "Queued",
        .loading => "Loading",
        .appending => "Reducing",
        .packing => "Packing",
        .blitting => "Compositing",
        .ready => "Done",
        .failed => "Failed",
        .cancelled => "Cancelled",
    };
}

// ----------------------------------------------------------------------------
// Worker
// ----------------------------------------------------------------------------

/// Worker entry point. Spawn with `std.Thread.spawn(.{}, PackJob.workerMain, .{job})`.
pub fn workerMain(job: *PackJob) void {
    defer {
        job.done.store(true, .release);
        dvui.refresh(job.window, @src(), null);
    }

    // Worker-local scratch. The final atlas allocations are made through `fizzy.app.allocator`
    // so they outlive the job; everything else (sprite refs, frames, animations, any
    // `.path`-loaded `PackFile`s, collapse carry-overs) lives in `ws` and is freed below.
    const work = WorkerState.init(fizzy.app.allocator) catch |e| {
        job.err = e;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };
    var ws = work;
    defer ws.deinit();

    // Resolve and append each input. Both `.open` snapshots and `.path` loads must outlive
    // the append phase, because the sprite list stores borrowed pointers into their pixel
    // buffers and `buildAtlas` blits straight from those pointers. `.open` inputs are owned
    // by `job.inputs` for the job's full lifetime; `.path`-loaded files are parked in
    // `ws.loaded_files` (freed with `ws.deinit`).
    job.phase.store(@intFromEnum(Phase.loading), .release);
    job.progress_den.store(@intCast(job.inputs.len), .monotonic);

    for (job.inputs, 0..) |*input, idx| {
        if (job.cancelled.load(.monotonic)) {
            job.phase.store(@intFromEnum(Phase.cancelled), .release);
            return;
        }

        switch (input.*) {
            .open => |*pf| {
                job.phase.store(@intFromEnum(Phase.appending), .release);
                ws.appendPackFile(pf) catch |e| {
                    job.err = e;
                    job.phase.store(@intFromEnum(Phase.failed), .release);
                    return;
                };
            },
            .path => |path| {
                job.phase.store(@intFromEnum(Phase.loading), .release);
                const maybe_pf = PackFile.fromPath(fizzy.app.allocator, path) catch |e| {
                    job.err = e;
                    job.phase.store(@intFromEnum(Phase.failed), .release);
                    return;
                };
                if (maybe_pf) |pf_val| {
                    ws.loaded_files.append(pf_val) catch |e| {
                        var tmp = pf_val;
                        tmp.deinit();
                        job.err = e;
                        job.phase.store(@intFromEnum(Phase.failed), .release);
                        return;
                    };
                    job.phase.store(@intFromEnum(Phase.appending), .release);
                    const ref = &ws.loaded_files.items[ws.loaded_files.items.len - 1];
                    ws.appendPackFile(ref) catch |e| {
                        job.err = e;
                        job.phase.store(@intFromEnum(Phase.failed), .release);
                        return;
                    };
                }
            },
        }
        job.progress_num.store(@intCast(idx + 1), .monotonic);
    }

    if (ws.frames.items.len == 0) {
        // Nothing to pack — keep `result_atlas == null`, surface as `ready`. The main thread
        // treats null-result the same as the old `packAndClear` early-out: leave the existing
        // atlas in place.
        job.phase.store(@intFromEnum(Phase.ready), .release);
        return;
    }

    // Try increasing texture sizes until everything fits.
    job.phase.store(@intFromEnum(Phase.packing), .release);
    const tex_size = ws.packRects() catch |e| {
        job.err = e;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    } orelse {
        job.err = error.PackFailed;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };

    if (job.cancelled.load(.monotonic)) {
        job.phase.store(@intFromEnum(Phase.cancelled), .release);
        return;
    }

    // Blit each emitted sprite into a fresh atlas pixel buffer at the location chosen by
    // `packRects`, then assemble the `Internal.Atlas` value that the main thread will install.
    job.phase.store(@intFromEnum(Phase.blitting), .release);
    const atlas = ws.buildAtlas(tex_size) catch |e| {
        job.err = e;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };

    if (job.cancelled.load(.monotonic)) {
        // Free the atlas we just built since the consumer won't take it.
        fizzy.app.allocator.free(fizzy.image.bytes(atlas.source));
        for (atlas.data.animations) |*anim| fizzy.app.allocator.free(anim.name);
        fizzy.app.allocator.free(atlas.data.animations);
        fizzy.app.allocator.free(atlas.data.sprites);
        job.phase.store(@intFromEnum(Phase.cancelled), .release);
        return;
    }

    job.result_atlas = atlas;
    job.phase.store(@intFromEnum(Phase.ready), .release);
}

// ----------------------------------------------------------------------------
// Worker-side state. Mirrors the layout the synchronous `Packer` built up across `append` and
// `packAndClear`, but is wholly owned by the worker thread.
// ----------------------------------------------------------------------------

/// Borrowed view of a sprite's reduced pixel region inside its source buffer (a `PackLayer`'s
/// pixels, or a carry-over buffer for collapse chains). `buildAtlas` blits directly from
/// `source` using `stride`; no intermediate per-sprite allocation. The referenced buffer
/// must outlive the worker state — see `loaded_files` / `carry_overs` in `WorkerState`.
const WorkerSpriteRef = struct {
    source: [*]const [4]u8,
    src_x: u32,
    src_y: u32,
    w: u32,
    h: u32,
    stride: u32,
};

const WorkerSprite = struct {
    image: ?WorkerSpriteRef = null,
    origin: [2]f32 = .{ 0, 0 },
};

const WorkerAnimation = struct {
    name: []u8,
    frames: []fizzy.Animation.Frame,

    fn deinit(self: *WorkerAnimation, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.frames);
    }
};

const WorkerState = struct {
    allocator: std.mem.Allocator,
    frames: std.array_list.Managed(zstbi.Rect),
    sprites: std.array_list.Managed(WorkerSprite),
    animations: std.array_list.Managed(WorkerAnimation),

    /// `.path`-loaded `PackFile`s held alive for the worker's lifetime so the sprite refs
    /// recorded during append remain valid through `buildAtlas`. `.open` snapshots already
    /// live in `job.inputs` until the job is destroyed.
    loaded_files: std.array_list.Managed(PackFile),

    /// Per-collapse-chain carry-over buffers (file-sized RGBA grids). Retained for the same
    /// reason as `loaded_files`: sprite refs point into these.
    carry_overs: std.array_list.Managed([][4]u8),

    id_counter: u32 = 0,

    fn init(allocator: std.mem.Allocator) !WorkerState {
        return .{
            .allocator = allocator,
            .frames = std.array_list.Managed(zstbi.Rect).init(allocator),
            .sprites = std.array_list.Managed(WorkerSprite).init(allocator),
            .animations = std.array_list.Managed(WorkerAnimation).init(allocator),
            .loaded_files = std.array_list.Managed(PackFile).init(allocator),
            .carry_overs = std.array_list.Managed([][4]u8).init(allocator),
        };
    }

    fn deinit(self: *WorkerState) void {
        for (self.animations.items) |*anim| anim.deinit(self.allocator);
        for (self.loaded_files.items) |*pf| pf.deinit();
        for (self.carry_overs.items) |buf| self.allocator.free(buf);
        self.frames.deinit();
        self.sprites.deinit();
        self.animations.deinit();
        self.loaded_files.deinit();
        self.carry_overs.deinit();
    }

    fn newId(self: *WorkerState) u32 {
        const i = self.id_counter;
        self.id_counter += 1;
        return i;
    }

    /// Mirrors `Packer.append`: walks the layer stack, honours collapse / visibility, and
    /// emits sprite refs (borrowed pointers into either the layer's own pixel buffer or a
    /// chain-local carry-over buffer) + animation entries into the worker state. Allocates
    /// only the carry-over buffer per collapse chain — sprite pixels themselves are never
    /// copied here; `buildAtlas` blits straight from the borrowed source.
    fn appendPackFile(self: *WorkerState, pf: *const PackFile) !void {
        const layers = pf.layers;

        // Carry-over pixel buffer for the current collapse chain. Sized to the full file
        // canvas, matching the temporary `Layer.init(..., file.width(), file.height(), ...)`
        // the synchronous Packer used. `null` until a collapse chain starts; when the chain
        // ends the buffer moves into `self.carry_overs` so the sprite refs that point into it
        // stay valid through `buildAtlas`.
        var carry_over: ?[][4]u8 = null;
        var carry_w: u32 = 0;
        var carry_h: u32 = 0;
        errdefer if (carry_over) |buf| self.allocator.free(buf);

        var index: usize = 0;
        while (index < layers.len) : (index += 1) {
            const layer = &layers[index];
            if (!layer.visible) continue;

            const last_item = index == layers.len - 1;
            const prev_collapses = index != 0 and layers[index - 1].collapse;

            // True if we're inside (or just exited) a collapse chain involving `layer`.
            const in_chain = (layer.collapse and !last_item) or prev_collapses;
            if (in_chain) {
                if (carry_over == null) {
                    const buf = try self.allocator.alloc([4]u8, pf.width * pf.height);
                    @memset(buf, .{ 0, 0, 0, 0 });
                    carry_over = buf;
                    carry_w = pf.width;
                    carry_h = pf.height;
                }
                const dst_pixels = carry_over.?;
                for (layer.pixels, dst_pixels) |src, *dst| {
                    if (src[3] != 0 and dst[3] == 0) dst.* = src;
                }
                if (layer.collapse and !last_item) continue;
            }

            // Which pixels feed sprite reduction this iteration: the carry-over (if active)
            // or the layer itself. Either way the buffer must outlive `buildAtlas` (see
            // `loaded_files` / `carry_overs`).
            const cur_pixels: [][4]u8 = if (carry_over) |buf| buf else layer.pixels;
            const cur_w: u32 = if (carry_over != null) carry_w else layer.width;
            const cur_h: u32 = if (carry_over != null) carry_h else layer.height;

            // Same sprite count as `File.spriteCount`: columns * rows.
            const rows: u32 = if (pf.row_height == 0) 0 else pf.height / pf.row_height;
            const total_sprites: usize = @as(usize, pf.columns) * @as(usize, rows);

            var sprite_index: usize = 0;
            while (sprite_index < total_sprites) : (sprite_index += 1) {
                const column = @as(u32, @intCast(sprite_index)) % pf.columns;
                const row = @as(u32, @intCast(sprite_index)) / pf.columns;
                const src_x: u32 = @min(column * pf.column_width, pf.width);
                const src_y: u32 = @min(row * pf.row_height, pf.height);

                const src_rect: reduce_alg.Rect = .{
                    .x = src_x,
                    .y = src_y,
                    .w = pf.column_width,
                    .h = pf.row_height,
                };

                if (reduce_alg.reduce(cur_pixels, cur_w, cur_h, src_rect)) |r| {
                    const offset_x = r.x - src_x;
                    const offset_y = r.y - src_y;

                    const orig_x: f32 = if (sprite_index < pf.sprites.len) pf.sprites[sprite_index].origin[0] else 0;
                    const orig_y: f32 = if (sprite_index < pf.sprites.len) pf.sprites[sprite_index].origin[1] else 0;

                    try self.sprites.append(.{
                        .image = .{
                            .source = cur_pixels.ptr,
                            .src_x = r.x,
                            .src_y = r.y,
                            .w = r.w,
                            .h = r.h,
                            .stride = cur_w,
                        },
                        .origin = .{ orig_x - @as(f32, @floatFromInt(offset_x)), orig_y - @as(f32, @floatFromInt(offset_y)) },
                    });
                    try self.frames.append(.{
                        .id = self.newId(),
                        .w = @intCast(r.w),
                        .h = @intCast(r.h),
                    });

                    const new_sprite_index = self.sprites.items.len - 1;
                    for (pf.animations) |anim| {
                        if (anim.frames.len == 0) continue;
                        if (anim.frames[0].sprite_index != sprite_index) continue;

                        const frames = try self.allocator.alloc(fizzy.Animation.Frame, anim.frames.len);
                        for (frames, anim.frames, 0..) |*current_frame, src_frame, i| {
                            current_frame.* = .{
                                .sprite_index = new_sprite_index + i,
                                .ms = src_frame.ms,
                            };
                        }
                        const merged_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ anim.name, layer.name });
                        try self.animations.append(.{ .name = merged_name, .frames = frames });
                    }
                } else {
                    // Empty reduced region — but the sprite may still appear in an animation,
                    // in which case we must emit a placeholder to keep frame indices stable.
                    for (pf.animations) |anim| {
                        for (anim.frames) |frame| {
                            if (frame.sprite_index != sprite_index) continue;
                            try self.sprites.append(.{ .image = null, .origin = .{ 0, 0 } });
                            try self.frames.append(.{
                                .id = self.newId(),
                                .w = 2,
                                .h = 2,
                            });
                        }
                    }
                }
            }

            // End of a collapse chain. Move the carry-over into the worker's retained list so
            // any sprite refs that point into it stay valid past this iteration.
            if (carry_over) |buf| {
                try self.carry_overs.append(buf);
                carry_over = null;
            }
        }

        // If the file's last layer was still part of an unclosed chain (only happens when
        // every visible layer up to the last had `collapse = true`), move that buffer too.
        if (carry_over) |buf| {
            try self.carry_overs.append(buf);
            carry_over = null;
        }
    }

    fn packRects(self: *WorkerState) !?[2]u16 {
        if (self.frames.items.len == 0) return null;

        var ctx: zstbi.Context = undefined;
        const node_count = 4096 * 2;
        var nodes: [node_count]zstbi.Node = undefined;

        const texture_sizes = [_][2]u32{
            .{ 256, 256 },   .{ 512, 256 },   .{ 256, 512 },
            .{ 512, 512 },   .{ 1024, 512 },  .{ 512, 1024 },
            .{ 1024, 1024 }, .{ 2048, 1024 }, .{ 1024, 2048 },
            .{ 2048, 2048 }, .{ 4096, 2048 }, .{ 2048, 4096 },
            .{ 4096, 4096 }, .{ 8192, 4096 }, .{ 4096, 8192 },
        };

        for (texture_sizes) |tex_size| {
            zstbi.initTarget(&ctx, tex_size[0], tex_size[1], &nodes);
            zstbi.setupHeuristic(&ctx, zstbi.Heuristic.skyline_bl_sort_height);
            if (zstbi.packRects(&ctx, self.frames.items) == 1) {
                return .{ @intCast(tex_size[0]), @intCast(tex_size[1]) };
            }
        }

        return null;
    }

    /// Allocate the final atlas pixels and metadata, blit each emitted sprite into its packed
    /// slot, and return an `Internal.Atlas` that owns all of its allocations through the app
    /// allocator (so it survives past the job's lifetime).
    ///
    /// IMPORTANT: this runs on the worker thread, so we cannot use `Layer.blit` — it calls
    /// `invalidate()` → `dvui.textureInvalidateCache`, which dereferences `currentWindow()`
    /// and panics off the main thread. Build the atlas as a plain pixel buffer + raw
    /// `pixelsPMA` ImageSource directly; first use of the source on the main thread will pick
    /// up a fresh texture-cache key because `.invalidation = .ptr` keys on the pixel pointer.
    fn buildAtlas(self: *WorkerState, tex_size: [2]u16) !fizzy.Internal.Atlas {
        const num_pixels: usize = @as(usize, tex_size[0]) * @as(usize, tex_size[1]);
        const pixels = try fizzy.app.allocator.alloc([4]u8, num_pixels);
        errdefer fizzy.app.allocator.free(pixels);
        @memset(pixels, .{ 0, 0, 0, 0 });

        const tex_w: usize = tex_size[0];
        for (self.frames.items, self.sprites.items) |frame, sprite| {
            if (sprite.image) |ref| {
                const slice = frame.slice();
                const dst_x: usize = slice[0];
                const dst_y: usize = slice[1];
                const w: usize = @intCast(ref.w);
                const h: usize = @intCast(ref.h);
                const stride: usize = @intCast(ref.stride);
                const src_x: usize = @intCast(ref.src_x);
                const src_y: usize = @intCast(ref.src_y);
                // Blit straight from the borrowed source buffer (a layer or carry-over) into
                // the atlas — no intermediate per-sprite copy, just one pass per pixel.
                var row: usize = 0;
                while (row < h) : (row += 1) {
                    const src_row_start = (src_y + row) * stride + src_x;
                    const src_row = ref.source[src_row_start .. src_row_start + w];
                    const dst_row_start = (dst_y + row) * tex_w + dst_x;
                    const dst_row = pixels[dst_row_start .. dst_row_start + w];
                    @memcpy(dst_row, src_row);
                }
            }
        }

        const sprites_out = try fizzy.app.allocator.alloc(fizzy.Atlas.Sprite, self.sprites.items.len);
        errdefer fizzy.app.allocator.free(sprites_out);
        for (sprites_out, self.sprites.items, self.frames.items) |*dst, src, src_rect| {
            dst.source = .{ src_rect.x, src_rect.y, src_rect.w, src_rect.h };
            dst.origin = src.origin;
        }

        const animations_out = try fizzy.app.allocator.alloc(fizzy.Animation, self.animations.items.len);
        var anims_initialized: usize = 0;
        errdefer {
            for (animations_out[0..anims_initialized]) |*anim| fizzy.app.allocator.free(anim.name);
            fizzy.app.allocator.free(animations_out);
        }
        for (animations_out, self.animations.items) |*dst, src| {
            dst.name = try fizzy.app.allocator.dupe(u8, src.name);
            errdefer fizzy.app.allocator.free(dst.name);
            dst.frames = try fizzy.app.allocator.dupe(fizzy.Animation.Frame, src.frames);
            anims_initialized += 1;
        }

        return .{
            .source = .{
                .pixelsPMA = .{
                    .rgba = @ptrCast(pixels),
                    .width = tex_size[0],
                    .height = tex_size[1],
                    .interpolation = .nearest,
                    .invalidation = .ptr,
                },
            },
            .data = .{
                .sprites = sprites_out,
                .animations = animations_out,
            },
        };
    }
};
