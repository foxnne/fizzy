//! Windows named pipe primary implementation.
//!
//! The pipe is created with FILE_FLAG_FIRST_PIPE_INSTANCE; if another
//! process already owns it, CreateNamedPipeW fails with
//! ERROR_ACCESS_DENIED and we send our argv as a secondary instead.

const std = @import("std");
const root = @import("root.zig");
const w = std.os.windows;

const Running = std.atomic.Value(u8);

const log = std.log.scoped(.singleton_app);

// ----------------------------------------------------------------------------
// Win32 declarations missing from std.os.windows.kernel32 in 0.15.
// ----------------------------------------------------------------------------

const FILE_FLAG_FIRST_PIPE_INSTANCE: w.DWORD = 0x00080000;
const PIPE_ACCESS_INBOUND: w.DWORD = 0x00000001;
const PIPE_ACCESS_DUPLEX: w.DWORD = 0x00000003;
const PIPE_TYPE_BYTE: w.DWORD = 0x00000000;
const PIPE_READMODE_BYTE: w.DWORD = 0x00000000;
const PIPE_WAIT: w.DWORD = 0x00000000;
const PIPE_REJECT_REMOTE_CLIENTS: w.DWORD = 0x00000008;
const PIPE_UNLIMITED_INSTANCES: w.DWORD = 255;

const GENERIC_READ: w.DWORD = 0x80000000;
const GENERIC_WRITE: w.DWORD = 0x40000000;
const OPEN_EXISTING: w.DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: w.DWORD = 0x80;

const NMPWAIT_USE_DEFAULT_WAIT: w.DWORD = 0x00000000;

const ERROR_FILE_NOT_FOUND = @as(w.Win32Error, @enumFromInt(2));
const ERROR_ACCESS_DENIED = @as(w.Win32Error, @enumFromInt(5));
const ERROR_PIPE_BUSY = @as(w.Win32Error, @enumFromInt(231));
const ERROR_PIPE_CONNECTED = @as(w.Win32Error, @enumFromInt(535));
const ERROR_BROKEN_PIPE = @as(w.Win32Error, @enumFromInt(109));

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: w.HANDLE,
    lpOverlapped: ?*w.OVERLAPPED,
) callconv(.winapi) w.BOOL;

extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: w.HANDLE,
) callconv(.winapi) w.BOOL;

extern "kernel32" fn WaitNamedPipeW(
    lpNamedPipeName: w.LPCWSTR,
    nTimeOut: w.DWORD,
) callconv(.winapi) w.BOOL;

// ----------------------------------------------------------------------------

pub const AcquireArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app_id: []const u8,
    unix_socket_dir: []const u8, // ignored on Windows
    callback: ?root.SecondInstanceFn,
    user_data: ?*anyopaque,
    argv: []const []const u8,
};

pub const Primary = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pipe_name_w: [:0]u16,
    callback: ?root.SecondInstanceFn,
    user_data: ?*anyopaque,
    thread: std.Thread,
    running: Running,

    pub fn acquire(args: AcquireArgs) !?*Primary {
        const pipe_name_w = try buildPipeNameW(args.allocator, args.app_id);
        var name_owner: ?[:0]u16 = pipe_name_w;
        defer if (name_owner) |n| args.allocator.free(n);

        // Try to claim the lock by creating the first pipe instance.
        const handle = createPipeInstance(pipe_name_w, true);
        if (handle == w.INVALID_HANDLE_VALUE) {
            const last = w.GetLastError();
            if (last == ERROR_ACCESS_DENIED) {
                // Another process already owns the pipe; act as secondary.
                try sendArgv(args.io, pipe_name_w, args.argv);
                return null;
            }
            log.warn("CreateNamedPipeW failed: {t}", .{last});
            return root.Error.LockUnavailable;
        }

        const primary = try args.allocator.create(Primary);
        errdefer args.allocator.destroy(primary);
        primary.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .pipe_name_w = pipe_name_w,
            .callback = args.callback,
            .user_data = args.user_data,
            .thread = undefined,
            .running = Running.init(1),
        };
        name_owner = null;

        primary.thread = std.Thread.spawn(.{}, acceptLoop, .{ primary, handle }) catch |err| {
            w.CloseHandle(handle);
            return err;
        };
        return primary;
    }

    pub fn shutdown(self: *Primary) void {
        self.running.store(0, .release);
        // Wake up ConnectNamedPipe by connecting to ourselves as a
        // sentinel client. Retry briefly in case the loop is between
        // pipe instances.
        var attempts: u8 = 0;
        while (attempts < 100) : (attempts += 1) {
            const h = w.kernel32.CreateFileW(
                self.pipe_name_w.ptr,
                GENERIC_READ | GENERIC_WRITE,
                0,
                null,
                OPEN_EXISTING,
                0,
                null,
            );
            if (h != w.INVALID_HANDLE_VALUE) {
                w.CloseHandle(h);
                break;
            }
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
        self.thread.join();
        self.allocator.free(self.pipe_name_w);
    }

    fn acceptLoop(self: *Primary, initial: w.HANDLE) void {
        var current = initial;
        while (true) {
            if (self.running.load(.acquire) == 0) {
                _ = DisconnectNamedPipe(current);
                w.CloseHandle(current);
                return;
            }

            const ok = ConnectNamedPipe(current, null);
            const err = if (ok == 0) w.GetLastError() else @as(w.Win32Error, @enumFromInt(0));
            if (ok == 0 and err != ERROR_PIPE_CONNECTED) {
                log.warn("ConnectNamedPipe failed: {t}", .{err});
                w.CloseHandle(current);
                return;
            }

            if (self.running.load(.acquire) == 0) {
                _ = DisconnectNamedPipe(current);
                w.CloseHandle(current);
                return;
            }

            const file = std.Io.File{ .handle = current };
            var rbuf: [4096]u8 = undefined;
            var fr = file.reader(self.io, &rbuf);
            const argv = root.readArgvIo(self.allocator, &fr.interface) catch |e| blk: {
                if (e != root.Error.UnexpectedEof) {
                    log.warn("read argv failed: {t}", .{e});
                }
                break :blk null;
            };
            if (argv) |a| {
                defer root.freeArgv(self.allocator, a);
                if (self.callback) |cb| cb(a, self.user_data);
            }

            _ = DisconnectNamedPipe(current);
            w.CloseHandle(current);

            if (self.running.load(.acquire) == 0) return;

            current = createPipeInstance(self.pipe_name_w, false);
            if (current == w.INVALID_HANDLE_VALUE) {
                log.warn("CreateNamedPipeW (next) failed: {t}", .{w.GetLastError()});
                return;
            }
        }
    }
};

fn createPipeInstance(pipe_name: [:0]const u16, first: bool) w.HANDLE {
    const open_mode: w.DWORD = PIPE_ACCESS_DUPLEX |
        (if (first) FILE_FLAG_FIRST_PIPE_INSTANCE else @as(w.DWORD, 0));
    const pipe_mode: w.DWORD = PIPE_TYPE_BYTE | PIPE_READMODE_BYTE |
        PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS;
    return w.kernel32.CreateNamedPipeW(
        pipe_name.ptr,
        open_mode,
        pipe_mode,
        PIPE_UNLIMITED_INSTANCES,
        64 * 1024,
        64 * 1024,
        0,
        null,
    );
}

fn sendArgv(io: std.Io, pipe_name: [:0]const u16, argv: []const []const u8) !void {
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        const h = w.kernel32.CreateFileW(
            pipe_name.ptr,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (h != w.INVALID_HANDLE_VALUE) {
            defer w.CloseHandle(h);
            const file = std.Io.File{ .handle = h };
            var wbuf: [4096]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try root.writeArgvIo(&fw.interface, argv);
            fw.interface.flush() catch {};
            // Make sure the server reads the data before we close.
            _ = w.kernel32.FlushFileBuffers(h);
            return;
        }
        const err = w.GetLastError();
        if (err == ERROR_PIPE_BUSY) {
            _ = WaitNamedPipeW(pipe_name.ptr, 5000);
            continue;
        }
        return root.Error.LockUnavailable;
    }
    return root.Error.LockUnavailable;
}

fn buildPipeNameW(allocator: std.mem.Allocator, app_id: []const u8) ![:0]u16 {
    const prefix = "\\\\.\\pipe\\";
    const utf8_len = prefix.len + app_id.len;
    const utf8 = try allocator.alloc(u8, utf8_len);
    defer allocator.free(utf8);
    @memcpy(utf8[0..prefix.len], prefix);
    @memcpy(utf8[prefix.len..], app_id);
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, utf8);
}
