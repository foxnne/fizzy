//! Single-instance support for fizzy. Wraps `dvui-singleton-app`:
//!
//!   * `acquireLock` is called from `AppInit` before any fizzy globals exist.
//!     If another fizzy process already owns the lock, our argv has been
//!     forwarded to it and we exit(0).
//!   * `registerWindow` captures the dvui window pointer (so the listener
//!     thread can call `dvui.refresh`) and queues any paths from our own
//!     argv.
//!   * `drainPending` is called from the top of each frame to open queued
//!     paths in the editor.
//!
//! Path dispatch: directories → `editor.setProjectFolder`, files → `editor.openFilePath`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const singleton_app = @import("singleton_app");
const fizzy = @import("fizzy.zig");

const log = std.log.scoped(.singleton);

pub const app_id = "dev.foxnne.fizzy";

const PendingOpen = struct { path: []u8 };

const State = struct {
    instance: ?singleton_app.SingletonApp = null,
    /// Captured at `acquireLock` time; used by the listener thread to
    /// allocate queued path copies before `fizzy.app` may exist.
    allocator: std.mem.Allocator = undefined,
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayListUnmanaged(PendingOpen) = .empty,
    window: ?*dvui.Window = null,
};

var state: State = .{};

/// Acquire the single-instance lock. If we are the secondary instance, the
/// supplied `argv` has been forwarded to the primary and this function
/// calls `std.process.exit(0)`. Caller should pass argv with file paths
/// already resolved to absolute (so the primary doesn't need to know the
/// secondary's working directory).
pub fn acquireLock(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    state.allocator = gpa;

    var socket_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const socket_dir = pickUnixSocketDir(&socket_dir_buf);

    state.instance = try singleton_app.SingletonApp.init(.{
        .app_id = app_id,
        .allocator = gpa,
        .io = dvui.io,
        .unix_socket_dir = socket_dir,
        .on_second_instance = onSecondInstance,
    });

    switch (try state.instance.?.requestSingleInstanceLock(argv)) {
        .acquired => {},
        .already_running => {
            state.instance.?.deinit();
            state.instance = null;
            std.process.exit(0);
        },
    }
}

/// Hand the dvui window to the listener thread and queue any paths from
/// our own argv so the first frame opens them.
pub fn registerWindow(win: *dvui.Window, argv: []const []const u8) void {
    state.window = win;
    queueArgvPaths(argv);
}

pub fn deinit() void {
    if (state.instance != null) {
        state.instance.?.deinit();
        state.instance = null;
    }
    state.mutex.lockUncancelable(dvui.io);
    defer state.mutex.unlock(dvui.io);
    for (state.pending.items) |item| state.allocator.free(item.path);
    state.pending.deinit(state.allocator);
    state.window = null;
}

/// Open any paths queued by `onSecondInstance` or `registerWindow`.
pub fn drainPending() void {
    var to_open: []PendingOpen = &.{};
    {
        state.mutex.lockUncancelable(dvui.io);
        defer state.mutex.unlock(dvui.io);
        if (state.pending.items.len == 0) return;
        to_open = state.pending.toOwnedSlice(state.allocator) catch return;
    }
    defer state.allocator.free(to_open);

    for (to_open) |item| {
        defer state.allocator.free(item.path);
        dispatchPath(item.path) catch |err| {
            log.err("failed to open '{s}': {t}", .{ item.path, err });
        };
    }
}

/// Runs on the singleton listener thread. Just queue and wake the GUI.
fn onSecondInstance(argv: []const []const u8, _: ?*anyopaque) void {
    queueArgvPaths(argv);
    if (state.window) |w| dvui.refresh(w, @src(), null);
}

/// Queue a single absolute path to be opened on the next frame. Safe to
/// call from any thread, including SDL event-watch callbacks. No-ops if
/// the singleton hasn't been initialized yet.
pub fn queuePath(path: []const u8) void {
    if (path.len == 0) return;
    if (state.instance == null) return;
    const dup = state.allocator.dupe(u8, path) catch return;
    {
        state.mutex.lockUncancelable(dvui.io);
        defer state.mutex.unlock(dvui.io);
        state.pending.append(state.allocator, .{ .path = dup }) catch {
            state.allocator.free(dup);
            return;
        };
    }
    if (state.window) |w| dvui.refresh(w, @src(), null);
}

fn queueArgvPaths(argv: []const []const u8) void {
    if (argv.len < 2) return;
    for (argv[1..]) |arg| {
        if (arg.len == 0) continue;
        // Skip flags so we don't try to open them as files.
        if (arg[0] == '-') continue;
        const path = state.allocator.dupe(u8, arg) catch continue;
        state.mutex.lockUncancelable(dvui.io);
        defer state.mutex.unlock(dvui.io);
        state.pending.append(state.allocator, .{ .path = path }) catch {
            state.allocator.free(path);
        };
    }
}

fn dispatchPath(path: []const u8) !void {
    const io = dvui.io;
    // Try as directory first: openDirAbsolute succeeds → it's a folder.
    if (std.Io.Dir.openDirAbsolute(io, path, .{})) |dir| {
        var d = dir;
        d.close(io);
        try fizzy.editor.setProjectFolder(path);
        return;
    } else |_| {}
    // Otherwise try as file.
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        log.warn("open '{s}' failed: {t}", .{ path, err });
        return err;
    };
    file.close(io);
    _ = try fizzy.editor.openFilePath(path, fizzy.editor.open_workspace_grouping);
}

/// Walk `argv` once via this zig's `Args.Iterator` API and return a slice
/// `[argv[0], abs_path_1, abs_path_2, …]` owned by `gpa`. Flags (entries
/// starting with `-`) pass through unchanged; everything else is resolved
/// to an absolute path so the singleton primary doesn't need to know the
/// secondary's working directory. Resolution failures pass the original
/// string through with a warning.
pub fn collectAndResolveArgv(
    gpa: std.mem.Allocator,
    main_init_opt: ?std.process.Init,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }

    const main_init = main_init_opt orelse {
        const exe = try gpa.dupe(u8, "fizzy");
        try out.append(gpa, exe);
        return out.toOwnedSlice(gpa);
    };

    var iter = try std.process.Args.Iterator.initAllocator(main_init.minimal.args, gpa);
    defer iter.deinit();

    // Capture cwd up-front so relative paths can be resolved before fizzy
    // chdirs to the exe directory.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(main_init.io, &cwd_buf) catch 0;
    const cwd: []const u8 = if (cwd_len > 0) cwd_buf[0..cwd_len] else &.{};

    var first = true;
    while (iter.next()) |arg| {
        if (first) {
            first = false;
            try out.append(gpa, try gpa.dupe(u8, arg));
            continue;
        }
        if (arg.len == 0 or arg[0] == '-') {
            try out.append(gpa, try gpa.dupe(u8, arg));
            continue;
        }
        const abs = resolveAbsolute(gpa, cwd, arg) catch |err| {
            log.warn("could not resolve '{s}': {t}; passing through", .{ arg, err });
            try out.append(gpa, try gpa.dupe(u8, arg));
            continue;
        };
        try out.append(gpa, abs);
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeResolvedArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| gpa.free(s);
    gpa.free(argv);
}

fn resolveAbsolute(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    if (cwd.len == 0) return error.NoCwd;
    return std.fs.path.join(gpa, &.{ cwd, path });
}

fn pickUnixSocketDir(buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (builtin.os.tag == .windows) return "."; // unused on Windows
    // Prefer TMPDIR (macOS sets it per-user) → /tmp fallback.
    // Use the libc env to avoid plumbing `process.Environ` here.
    if (std.c.getenv("TMPDIR")) |env_ptr| {
        const len = std.mem.len(env_ptr);
        if (len > 0 and len < buf.len) {
            @memcpy(buf[0..len], env_ptr[0..len]);
            return buf[0..len];
        }
    }
    if (builtin.os.tag == .linux) {
        if (std.c.getenv("XDG_RUNTIME_DIR")) |env_ptr| {
            const len = std.mem.len(env_ptr);
            if (len > 0 and len < buf.len) {
                @memcpy(buf[0..len], env_ptr[0..len]);
                return buf[0..len];
            }
        }
    }
    return "/tmp";
}
