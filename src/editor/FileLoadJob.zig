//! Background file-load job. Owns a worker thread that runs `Internal.File.fromPath` off the
//! main thread so large files don't stall the editor. The main thread polls `done` each frame
//! via `Editor.processLoadingJobs`; once true, the result is moved into `editor.open_files`.
//!
//! Cancellation is best-effort: `Internal.File.fromPath` is monolithic, so we can only
//! observe cancellation AFTER it returns. The worker checks the flag, frees the loaded file
//! if cancelled, and exits.
//!
//! Ownership / threading model:
//!   - `path` is owned by the job, freed in `destroy()`.
//!   - `result` is written by the worker, read by the main thread only after `done.load(.acquire)`.
//!   - `phase` / `cancelled` are written by either side, read by either side.
//!   - The job pointer itself is owned by `Editor.loading_jobs`. Worker holds a borrowed pointer
//!     but only writes through atomic fields + the worker-only `result`/`err`/`canvas_target_grouping` fields.

const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const perf = @import("../gfx/perf.zig");

const FileLoadJob = @This();

pub const Phase = enum(u8) {
    queued = 0,
    reading = 1,
    ready = 2,
    failed = 3,
    cancelled = 4,
};

allocator: std.mem.Allocator,

/// Absolute path. Owned by this job.
path: []u8,

/// Workspace grouping the file should land in once loaded.
target_grouping: u64,

/// Captured at create time on the GUI thread. The worker uses this to wake the main loop
/// (`dvui.refresh(window, ...)`) the instant the load finishes, so small files don't sit
/// completed-but-unconsumed waiting for an unrelated input event to tick the editor.
window: *dvui.Window,

/// Monotonic timestamp (boot clock, nanos) captured on the main thread at job creation.
/// Compared against the main thread's current `perf.nanoTimestamp` to gate the 150ms toast
/// threshold. Only read on the main thread.
started_at_ns: i128,

/// Atomic phase, written by worker, read by main. Cast through `Phase`.
phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.queued)),

/// Optional progress hint, written by worker. `den == 0` means indeterminate.
progress_num: std.atomic.Value(u32) = .init(0),
progress_den: std.atomic.Value(u32) = .init(0),

/// Main thread sets true on close-while-loading / quit. Worker checks after `fromPath` returns
/// and discards the result instead of publishing.
cancelled: std.atomic.Value(bool) = .init(false),

/// Worker → main publish flag. `release` on write, `acquire` on read.
done: std.atomic.Value(bool) = .init(false),

/// Filled by worker iff load succeeds AND wasn't cancelled. Safe to read after `done.load(.acquire)`.
result: ?fizzy.Internal.File = null,

/// Filled by worker iff load failed. Safe to read after `done.load(.acquire)`.
err: ?anyerror = null,

pub fn create(allocator: std.mem.Allocator, path: []const u8, target_grouping: u64) !*FileLoadJob {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);

    const job = try allocator.create(FileLoadJob);
    job.* = .{
        .allocator = allocator,
        .path = path_copy,
        .target_grouping = target_grouping,
        .window = dvui.currentWindow(),
        .started_at_ns = perf.nanoTimestamp(),
    };
    return job;
}

pub fn destroy(job: *FileLoadJob) void {
    const a = job.allocator;
    a.free(job.path);
    a.destroy(job);
}

/// Worker entry point. Spawn with `std.Thread.spawn(.{}, FileLoadJob.workerMain, .{job})`.
pub fn workerMain(job: *FileLoadJob) void {
    defer {
        // Publish before waking the GUI thread so `done.load(.acquire)` on the consumer side
        // sees `result` / `err` / `phase` already in place.
        job.done.store(true, .release);
        // Wake the GUI thread from this thread. `dvui.refresh` with a non-null Window pointer
        // is the documented thread-safe entry — it goes through the backend to interrupt the
        // event-driven idle loop, so the editor processes our completion immediately instead
        // of waiting for the next unrelated input event.
        dvui.refresh(job.window, @src(), null);
    }

    if (job.cancelled.load(.monotonic)) {
        job.phase.store(@intFromEnum(Phase.cancelled), .release);
        return;
    }

    job.phase.store(@intFromEnum(Phase.reading), .release);

    const maybe_file = fizzy.Internal.File.fromPath(job.path) catch |e| {
        job.err = e;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };

    const file = maybe_file orelse {
        job.err = error.InvalidFile;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };

    // Cancellation check post-load: if the user closed the tab / quit while we were loading,
    // discard the file rather than publishing it.
    if (job.cancelled.load(.monotonic)) {
        var f = file;
        f.deinit();
        job.phase.store(@intFromEnum(Phase.cancelled), .release);
        return;
    }

    job.result = file;
    job.phase.store(@intFromEnum(Phase.ready), .release);
}

/// True iff at least `threshold_ms` of wall-clock time has elapsed since job creation. Used
/// to delay the toast appearance so sub-threshold loads don't flash a UI element. Must be
/// called from the main thread (uses `dvui.io` via `perf.nanoTimestamp`).
pub fn elapsedExceeds(job: *const FileLoadJob, threshold_ms: i64) bool {
    const elapsed_ns = perf.nanoTimestamp() - job.started_at_ns;
    return @divTrunc(elapsed_ns, std.time.ns_per_ms) >= threshold_ms;
}

pub fn currentPhase(job: *const FileLoadJob) Phase {
    const raw = job.phase.load(.acquire);
    return switch (raw) {
        0 => .queued,
        1 => .reading,
        2 => .ready,
        3 => .failed,
        4 => .cancelled,
        else => .queued,
    };
}

pub fn phaseLabel(phase: Phase) []const u8 {
    return switch (phase) {
        .queued => "Queued",
        .reading => "Reading",
        .ready => "Done",
        .failed => "Failed",
        .cancelled => "Cancelled",
    };
}
