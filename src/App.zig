const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const build_opts = @import("build_opts");

const assets = @import("assets");

const icon = assets.files.@"icon.png";

const fizzy = @import("fizzy.zig");
const auto_update = @import("auto_update.zig");
const update_notify = @import("update_notify.zig");

const App = @This();
const Editor = fizzy.Editor;
const Packer = fizzy.Packer;
//const Assets = fizzy.Assets;

// App fields
allocator: std.mem.Allocator = undefined,

//delta_time: f32 = 0.0,

root_path: [:0]const u8 = undefined,
should_close: bool = false,
window: *dvui.Window = undefined,

var gpa: std.heap.DebugAllocator(.{}) = .init;

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1200.0, .h = 800.0 },
            .min_size = .{ .w = 640.0, .h = 480.0 },
            .title = "fizzy",
            .icon = icon,
            .transparent = if (builtin.os.tag == .macos or builtin.os.tag == .windows) true else false,
            // macOS: Cancel-leading dialog/footer order; other platforms: OK-leading (matches dialog header close vs icon).
            .window_init_options = .{
                .button_order = if (builtin.os.tag.isDarwin()) .cancel_ok else .ok_cancel,
            },
        },
    },
    .frameFn = AppFrame,
    .initFn = AppInit,
    .deinitFn = AppDeinit,
};

pub fn main(main_init: std.process.Init) !u8 {
    std.log.info("Fizzy version {s}", .{build_opts.app_version});

    if (comptime auto_update.impl) {
        // appRunHook handles Velopack's install/uninstall/firstrun CLI flags and
        // does not touch the network. Update checks are user-initiated from the
        // About dialog — startup must not block on connectivity.
        auto_update.appRunHook();
    }

    if (@hasDecl(dvui.backend, "main")) {
        return dvui.App.main(main_init);
    }
    try dvui.App.main();
    return 0;
}

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

// Runs before the first frame, after backend and dvui.Window.init()
pub fn AppInit(win: *dvui.Window) !void {
    const allocator = gpa.allocator();

    // Run from the directory where the executable is located so relative assets can be found.
    var buffer: [1024]u8 = undefined;
    const exe_dir_len = std.process.executableDirPath(dvui.io, buffer[0..]) catch 0;
    const path: []const u8 = if (exe_dir_len > 0) buffer[0..exe_dir_len] else ".";
    {
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        if (path.len < path_buf.len) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            _ = std.posix.system.chdir(@ptrCast(&path_buf));
        }
    }

    fizzy.app = try allocator.create(App);
    fizzy.app.* = .{
        .allocator = allocator,
        .window = win,
        .root_path = allocator.dupeZ(u8, path) catch ".",
    };

    fizzy.editor = try allocator.create(Editor);
    fizzy.editor.* = Editor.init(fizzy.app) catch unreachable;

    fizzy.packer = try allocator.create(Packer);
    fizzy.packer.* = Packer.init(allocator) catch unreachable;

    // Override DVUI's default SDL metadata ("DVUI App Example") so the macOS
    // app menu reads "About fizzy" / "Hide fizzy" / "Quit fizzy" and process
    // listings show the real product name + version. `build_opts.app_version`
    // is a non-sentinel slice, so allocate a null-terminated copy for SDL.
    const version_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{build_opts.app_version}, 0) catch "0.0.0";
    fizzy.backend.setSdlAppMetadata("fizzy", version_z, "com.foxnne.fizzy");

    fizzy.backend.setupMacOSMenuBar();

    update_notify.startLaunchCheck(dvui.io, fizzy.editor.settings.debug_simulate_update_available);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
    fizzy.editor.deinit() catch unreachable;
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    return try fizzy.editor.tick();
}
