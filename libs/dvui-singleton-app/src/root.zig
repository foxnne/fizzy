//! Single-instance application support, modeled after Electron's
//! `app.requestSingleInstanceLock`.
//!
//! The first process to call `requestSingleInstanceLock` for a given
//! `app_id` becomes the *primary* and starts a background listener. Later
//! processes that call it become *secondaries*: their argv is forwarded to
//! the primary and the call returns `.already_running`, signalling that
//! the caller should exit.
//!
//! Usage:
//! ```
//! const singleton_app = @import("singleton_app");
//!
//! fn onSecondInstance(argv: []const []const u8, user_data: ?*anyopaque) void {
//!     _ = user_data;
//!     // Bring window to front, open the file, etc.
//!     // NOTE: this runs on a background listener thread; if the work
//!     // touches GUI state, hand it off to the main thread.
//!     std.log.info("second instance argv: {any}", .{argv});
//! }
//!
//! pub fn main() !void {
//!     const allocator = std.heap.page_allocator;
//!     var app = try singleton_app.SingletonApp.init(.{
//!         .app_id = "com.example.myapp",
//!         .allocator = allocator,
//!         .io = io,
//!         .on_second_instance = onSecondInstance,
//!     });
//!     defer app.deinit();
//!
//!     // Caller-supplied argv slice (resolve relative paths before passing).
//!     switch (try app.requestSingleInstanceLock(argv)) {
//!         .already_running => return,
//!         .acquired => {}, // run app
//!     }
//! }
//! ```
//!
//! Implementation:
//!   * Linux/macOS - Unix domain socket placed under `unix_socket_dir`,
//!     with the user's UID mixed into the path to keep different users
//!     from colliding.
//!   * Windows - named pipe at \\.\pipe\<app_id>, created with
//!     FILE_FLAG_FIRST_PIPE_INSTANCE so the first call wins.

const std = @import("std");
const builtin = @import("builtin");

pub const SecondInstanceFn = *const fn (
    argv: []const []const u8,
    user_data: ?*anyopaque,
) void;

pub const Options = struct {
    /// Stable, per-application identifier. Must be 1..64 chars and contain
    /// only ASCII letters, digits, '-', '_' or '.'. Used to derive the
    /// socket / pipe name.
    app_id: []const u8,

    allocator: std.mem.Allocator,

    /// `Io` implementation used for sockets and pipes. Must be thread-safe
    /// (the listener thread shares it with the caller's main thread).
    io: std.Io,

    /// Unix only: directory the socket file is placed under (e.g. "/tmp",
    /// or $XDG_RUNTIME_DIR / $TMPDIR computed by the caller). Must not
    /// contain a trailing slash. Ignored on Windows.
    unix_socket_dir: []const u8 = "/tmp",

    /// Invoked on a background listener thread each time a secondary
    /// instance forwards its argv. The callback owns the argv only for
    /// the duration of the call; the bytes are freed afterwards. The
    /// callback may be invoked concurrently with the rest of the
    /// application, so synchronize accordingly (e.g., post an event onto
    /// the GUI's event queue).
    on_second_instance: ?SecondInstanceFn = null,

    /// Opaque pointer forwarded to `on_second_instance`.
    user_data: ?*anyopaque = null,
};

pub const LockResult = enum {
    /// This call established the lock; we are the primary instance.
    acquired,
    /// Another process holds the lock; our argv was delivered to it.
    already_running,
};

pub const Error = error{
    InvalidAppId,
    AlreadyCalled,
    TooManyArgs,
    ArgTooLong,
    PayloadTooLarge,
    PathTooLong,
    UnexpectedEof,
    LockUnavailable,
};

pub const max_args: u32 = 4096;
pub const max_arg_bytes: u32 = 1 << 20; // 1 MiB per arg
pub const max_total_bytes: u64 = 32 << 20; // 32 MiB per message

const Primary = if (builtin.os.tag == .windows)
    @import("windows_impl.zig").Primary
else
    @import("unix_impl.zig").Primary;

pub const SingletonApp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app_id: []u8,
    unix_socket_dir: []u8,
    callback: ?SecondInstanceFn,
    user_data: ?*anyopaque,
    primary: ?*Primary,

    pub fn init(options: Options) !SingletonApp {
        try validateAppId(options.app_id);
        const id_owned = try options.allocator.dupe(u8, options.app_id);
        errdefer options.allocator.free(id_owned);
        const dir_owned = try options.allocator.dupe(u8, options.unix_socket_dir);
        return .{
            .allocator = options.allocator,
            .io = options.io,
            .app_id = id_owned,
            .unix_socket_dir = dir_owned,
            .callback = options.on_second_instance,
            .user_data = options.user_data,
            .primary = null,
        };
    }

    pub fn deinit(self: *SingletonApp) void {
        if (self.primary) |p| {
            p.shutdown();
            self.allocator.destroy(p);
            self.primary = null;
        }
        self.allocator.free(self.app_id);
        self.allocator.free(self.unix_socket_dir);
    }

    pub fn requestSingleInstanceLock(
        self: *SingletonApp,
        argv: []const []const u8,
    ) !LockResult {
        if (self.primary != null) return Error.AlreadyCalled;
        const primary = try Primary.acquire(.{
            .allocator = self.allocator,
            .io = self.io,
            .app_id = self.app_id,
            .unix_socket_dir = self.unix_socket_dir,
            .callback = self.callback,
            .user_data = self.user_data,
            .argv = argv,
        });
        if (primary) |p| {
            self.primary = p;
            return .acquired;
        }
        return .already_running;
    }
};

fn validateAppId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > 64) return Error.InvalidAppId;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.';
        if (!ok) return Error.InvalidAppId;
    }
}

// ----------------------------------------------------------------------------
// Wire format (shared across platforms).
//
//   u32 LE argc
//   for each arg:
//       u32 LE arg_len
//       arg_len bytes
// ----------------------------------------------------------------------------

pub fn writeArgvIo(w: *std.Io.Writer, argv: []const []const u8) !void {
    if (argv.len > max_args) return Error.TooManyArgs;
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(argv.len), .little);
    try w.writeAll(&hdr);
    var total: u64 = 4;
    for (argv) |arg| {
        if (arg.len > max_arg_bytes) return Error.ArgTooLong;
        total += 4 + @as(u64, arg.len);
        if (total > max_total_bytes) return Error.PayloadTooLarge;
        std.mem.writeInt(u32, &hdr, @intCast(arg.len), .little);
        try w.writeAll(&hdr);
        if (arg.len > 0) try w.writeAll(arg);
    }
}

/// Read argv from `r`. Returned slice and its strings are owned by `allocator`.
pub fn readArgvIo(allocator: std.mem.Allocator, r: *std.Io.Reader) ![][]const u8 {
    var hdr_buf: [4]u8 = undefined;
    r.readSliceAll(&hdr_buf) catch return Error.UnexpectedEof;
    const argc = std.mem.readInt(u32, &hdr_buf, .little);
    if (argc > max_args) return Error.TooManyArgs;

    const argv = try allocator.alloc([]const u8, argc);
    var produced: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < produced) : (j += 1) allocator.free(argv[j]);
        allocator.free(argv);
    }
    var total: u64 = 4;
    while (produced < argc) {
        r.readSliceAll(&hdr_buf) catch return Error.UnexpectedEof;
        const len = std.mem.readInt(u32, &hdr_buf, .little);
        if (len > max_arg_bytes) return Error.ArgTooLong;
        total += 4 + @as(u64, len);
        if (total > max_total_bytes) return Error.PayloadTooLarge;
        const buf = try allocator.alloc(u8, len);
        var ok = false;
        errdefer if (!ok) allocator.free(buf);
        if (len > 0) {
            r.readSliceAll(buf) catch return Error.UnexpectedEof;
        }
        ok = true;
        argv[produced] = buf;
        produced += 1;
    }
    return argv;
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

test "validateAppId" {
    try validateAppId("ok");
    try validateAppId("com.example.app");
    try validateAppId("a-_.0123456789");
    try std.testing.expectError(Error.InvalidAppId, validateAppId(""));
    try std.testing.expectError(Error.InvalidAppId, validateAppId("has space"));
    try std.testing.expectError(Error.InvalidAppId, validateAppId("slash/no"));
    try std.testing.expectError(Error.InvalidAppId, validateAppId("\\back"));
}
