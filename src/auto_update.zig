const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_opts");

pub const impl: bool = build_opts.velopack_enabled and builtin.os.tag != .wasi;

const Vpk = if (impl)
    @cImport({
        @cInclude("Velopack.h");
    })
else
    struct {};

pub fn logVpkError(prefix: []const u8) void {
    if (!impl) return;
    var err_buf: [512]u8 = undefined;
    const msg = lastErrorSlice(&err_buf);
    std.log.err("{s}: {s}", .{ prefix, msg });
}

pub fn lastErrorSlice(buf: []u8) []const u8 {
    if (!impl) return "";
    const n = Vpk.vpkc_get_last_error(buf.ptr, buf.len);
    if (n > 0 and n <= buf.len)
        return buf[0 .. n - 1];
    return "(unknown)";
}

fn castManager(m: *anyopaque) *Vpk.vpkc_update_manager_t {
    return @ptrCast(@alignCast(m));
}

/// Velopack's macOS locator expects the process image under `*.app/Contents/MacOS/*`.
/// Loose binaries from `zig build` / `zig-out/.../fizzy` are not supported — skip the C API
/// so we don't spam logs or Velopack errors on every frame.
pub fn installLayoutSupported(io: std.Io) bool {
    if (!impl) return false;
    if (builtin.os.tag != .macos) return true;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return false;
    return std.mem.indexOf(u8, buf[0..n], ".app/") != null;
}

/// Create an update manager using `FIZZY_AUTOUPDATE_URL` or the build-time repo URL.
pub fn openUpdateManager(io: std.Io, allocator: std.mem.Allocator) error{OutOfMemory}!?*anyopaque {
    if (!impl) return null;
    if (!installLayoutSupported(io)) return null;

    if (std.c.getenv("FIZZY_AUTOUPDATE_URL")) |raw| {
        const update_url = std.mem.span(raw);
        if (update_url.len == 0) return null;
        const update_url_z = try allocator.dupeZ(u8, update_url);
        defer allocator.free(update_url_z);
        var manager: ?*Vpk.vpkc_update_manager_t = null;
        if (!Vpk.vpkc_new_update_manager(update_url_z.ptr, null, null, &manager)) {
            logVpkError("fizzy autoupdate: vpkc_new_update_manager failed");
            return null;
        }
        return @ptrCast(manager.?);
    }

    if (build_opts.app_repo_url.len == 0) return null;

    const repo_url_z = try allocator.dupeZ(u8, build_opts.app_repo_url);
    defer allocator.free(repo_url_z);

    const source: ?*Vpk.vpkc_update_source_t = Vpk.vpkc_new_source_github(repo_url_z.ptr, null, false);
    if (source == null) {
        logVpkError("fizzy autoupdate: vpkc_new_source_github failed");
        return null;
    }

    var manager: ?*Vpk.vpkc_update_manager_t = null;
    if (!Vpk.vpkc_new_update_manager_with_source(source, null, null, &manager)) {
        Vpk.vpkc_free_source(source);
        logVpkError("fizzy autoupdate: vpkc_new_update_manager_with_source failed");
        return null;
    }
    return @ptrCast(manager.?);
}

pub fn freeUpdateManager(m: ?*anyopaque) void {
    if (!impl) return;
    if (m == null) return;
    Vpk.vpkc_free_update_manager(castManager(m.?));
}

pub fn appRunHook() void {
    if (!impl) return;
    Vpk.vpkc_app_run(null);
}

/// Startup path: check remote feed and apply+exit when an update is available.
pub fn checkAndMaybeApplyAtStartup(io: std.Io, allocator: std.mem.Allocator) !void {
    if (!impl) return;
    if (!installLayoutSupported(io)) return;

    const mgr = (try openUpdateManager(io, allocator)) orelse return;
    defer freeUpdateManager(mgr);

    var update_info: ?*Vpk.vpkc_update_info_t = null;
    const result = Vpk.vpkc_check_for_updates(castManager(mgr), &update_info);

    switch (result) {
        Vpk.UPDATE_AVAILABLE => {
            const u = update_info.?;
            defer Vpk.vpkc_free_update_info(u);

            std.log.info("fizzy autoupdate: update available, downloading", .{});
            if (!Vpk.vpkc_download_updates(castManager(mgr), u, null, null)) {
                logVpkError("fizzy autoupdate: download failed");
                return error.UpdateDownloadFailed;
            }

            std.log.info("fizzy autoupdate: applying update and restarting", .{});
            const target_asset = u.TargetFullRelease;
            // args: manager, asset, silent=true, restart=true (relaunch after apply), restartArgs=null, restartArgsLen=0
            _ = Vpk.vpkc_wait_exit_then_apply_updates(castManager(mgr), target_asset, true, true, null, 0);
            if (builtin.os.tag == .windows) {
                const win32 = @import("win32");
                win32.system.threading.Sleep(2000);
            } else {
                const ts: std.c.timespec = .{ .sec = 2, .nsec = 0 };
                _ = std.c.nanosleep(&ts, null);
            }
            std.process.exit(0);
        },
        Vpk.NO_UPDATE_AVAILABLE => {
            std.log.info("fizzy autoupdate: no update available", .{});
        },
        Vpk.REMOTE_IS_EMPTY => {
            std.log.info("fizzy autoupdate: remote feed empty", .{});
        },
        Vpk.UPDATE_ERROR => {
            logVpkError("fizzy autoupdate: check failed");
            return error.UpdateCheckFailed;
        },
        else => |i| {
            std.log.err("fizzy autoupdate unknown status: {d}", .{i});
            return error.UpdateCheckUnknown;
        },
    }
}

pub fn getCurrentVersionInto(manager: *anyopaque, buf: []u8) []const u8 {
    if (!impl) return "";
    const n = Vpk.vpkc_get_current_version(castManager(manager), buf.ptr, buf.len);
    if (n > 0 and n <= buf.len)
        return buf[0 .. n - 1];
    return "";
}

pub const CheckSummary = union(enum) {
    unavailable: void,
    no_feed: void,
    /// macOS: not running inside a packaged `.app` (e.g. zig-out binary).
    install_layout_unsupported: void,
    failed: void,
    no_update: void,
    remote_empty: void,
    /// Sub-slice of the `ver_buf` passed to [`checkRemoteVersionSummary`].
    available: []const u8,
};

/// Checks the remote feed and copies the available version string into `ver_buf` (if any).
pub fn checkRemoteVersionSummary(io: std.Io, allocator: std.mem.Allocator, ver_buf: []u8) error{OutOfMemory}!CheckSummary {
    if (!impl) return .{ .unavailable = {} };
    if (ver_buf.len == 0) return .{ .failed = {} };
    if (!installLayoutSupported(io)) return .{ .install_layout_unsupported = {} };

    const mgr = (try openUpdateManager(io, allocator)) orelse return .{ .no_feed = {} };
    defer freeUpdateManager(mgr);

    var update_info: ?*Vpk.vpkc_update_info_t = null;
    const result = Vpk.vpkc_check_for_updates(castManager(mgr), &update_info);

    switch (result) {
        Vpk.UPDATE_AVAILABLE => {
            const info = update_info.?;
            defer Vpk.vpkc_free_update_info(info);
            const rel: *Vpk.vpkc_asset_t = @ptrCast(info.TargetFullRelease);
            const ver_c = rel.Version orelse return .{ .failed = {} };
            const ver = std.mem.span(ver_c);
            const n = @min(ver.len, ver_buf.len);
            @memcpy(ver_buf[0..n], ver[0..n]);
            return .{ .available = ver_buf[0..n] };
        },
        Vpk.NO_UPDATE_AVAILABLE => return .{ .no_update = {} },
        Vpk.REMOTE_IS_EMPTY => return .{ .remote_empty = {} },
        Vpk.UPDATE_ERROR => return .{ .failed = {} },
        else => return .{ .failed = {} },
    }
}

/// Re-checks the feed, downloads, applies, and exits (same behaviour as the silent startup update).
pub fn checkDownloadApplyAndExit(io: std.Io, allocator: std.mem.Allocator) UpdateInstallError!void {
    if (!impl) return;
    if (!installLayoutSupported(io)) return error.InstallLayoutUnsupported;

    const mgr = (try openUpdateManager(io, allocator)) orelse return error.NoFeed;
    defer freeUpdateManager(mgr);

    var update_info: ?*Vpk.vpkc_update_info_t = null;
    const result = Vpk.vpkc_check_for_updates(castManager(mgr), &update_info);

    switch (result) {
        Vpk.UPDATE_AVAILABLE => {
            const u = update_info.?;
            defer Vpk.vpkc_free_update_info(u);

            if (!Vpk.vpkc_download_updates(castManager(mgr), u, null, null)) {
                logVpkError("fizzy autoupdate: download failed");
                return error.DownloadFailed;
            }
            const target_asset = u.TargetFullRelease;
            // args: manager, asset, silent=true, restart=true (relaunch after apply), restartArgs=null, restartArgsLen=0
            _ = Vpk.vpkc_wait_exit_then_apply_updates(castManager(mgr), target_asset, true, true, null, 0);
            if (builtin.os.tag == .windows) {
                const win32 = @import("win32");
                win32.system.threading.Sleep(2000);
            } else {
                const ts: std.c.timespec = .{ .sec = 2, .nsec = 0 };
                _ = std.c.nanosleep(&ts, null);
            }
            std.process.exit(0);
        },
        Vpk.NO_UPDATE_AVAILABLE => return error.NoUpdateToInstall,
        Vpk.REMOTE_IS_EMPTY => return error.NoUpdateToInstall,
        Vpk.UPDATE_ERROR => return error.CheckFailed,
        else => return error.CheckFailed,
    }
}

pub const UpdateInstallError = error{
    NoFeed,
    NoUpdateToInstall,
    InstallLayoutUnsupported,
    CheckFailed,
    DownloadFailed,
    OutOfMemory,
};
