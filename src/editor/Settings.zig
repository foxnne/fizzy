const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const std = @import("std");
const dvui = @import("dvui");

const Settings = @This();

pub const default_theme = "Fizzy Dark";

/// Duration after the last edit before autosave runs (during normal operation).
pub const autosave_timeout_ns: i128 = 500 * 1_000_000;

pub var parsed: ?std.json.Parsed(Settings) = null;

pub const InputScheme = enum { auto, mouse, trackpad };

/// Resolved zoom/pan control style after applying `auto` (`dvui.getMouseTypeHint`).
pub const ResolvedPanZoomScheme = enum {
    mouse,
    trackpad,
};
pub const FlipbookView = enum { sequential, grid };
pub const Compatibility = enum { none, ldtk };

/// How sprite-cell transparency (checkerboard) is tinted behind the canvas.
pub const TransparencyEffect = enum {
    /// Uniform default tone only (no hue gradient).
    none,
    /// Mouse-smoothed corner gradient (current default).
    rainbow,
    /// Per-cell tone shifted toward the animation’s palette color (when the sprite belongs to an animation).
    animation,
};

/// The ratio of the explorer to the artboard.
explorer_ratio: f32 = 0.35,

/// Height of the flipbook window.
panel_ratio: f32 = 0.25,

min_window_size: [2]f32 = .{ 640, 480 },

initial_window_size: [2]f32 = .{ 1280, 720 },

/// Zoom/pan control scheme (`auto` picks mouse vs trackpad gestures from `dvui.getMouseTypeHint` after scroll events).
/// Default chosen by platform: trackpad on macOS (most laptops use one by default),
/// mouse elsewhere. Users can switch to `.auto` or the other explicit value in settings.
input_scheme: InputScheme = if (builtin.os.tag == .macos) .trackpad else .mouse,

/// Whether or not to show rulers on each canvas.
show_rulers: bool = true,

/// When true, print frame/draw perf stats to the console (Debug / ReleaseSafe only for tick stats).
perf_logging: bool = false,

/// Pretend an app update is available (badge + launch toast). Restart after toggling.
debug_simulate_update_available: bool = false,

/// Padding to include in the size of the ruler outside of the font height.
ruler_padding: f32 = 4.0,

/// Setting to control overall zoom sensitivity
/// 0 - 1
zoom_sensitivity: f32 = 1.0,

/// Predetermined zoom steps, each is pixel perfect.
zoom_steps: [23]f32 = [_]f32{ 0.125, 0.167, 0.2, 0.25, 0.333, 0.5, 1, 2, 3, 4, 5, 6, 8, 12, 18, 28, 38, 50, 70, 90, 128, 256, 512 },

/// Maximum file size
max_file_size: [2]i32 = .{ 4096, 4096 },

/// Maximum number of recents before removing oldest
max_recents: usize = 10,

/// Last selected UI theme (`dvui.Theme.name`). Always allocator-owned after `load`; see `setThemeName` / `deinit`.
theme: []const u8 = default_theme,

/// Logical font sizes applied to body / title / heading / mono slots for every theme (families unchanged).
font_body_size: f32 = 9,
font_title_size: f32 = 9,
font_heading_size: f32 = 8,
font_mono_size: f32 = 10,

/// Color for the even squares of the checkerboard pattern
checker_color_even: [4]u8 = .{ 255, 255, 255, 255 },
/// Color for the odd squares of the checkerboard pattern
checker_color_odd: [4]u8 = .{ 175, 175, 175, 255 },

/// Opacity of the background window
/// CURRENTLY ONLY SUPPORTED ON MACOS and Windows
window_opacity_dark: f32 = 0.7,
window_opacity_light: f32 = 0.3,
content_opacity: f32 = 0.7,

/// Checkerboard / transparency tint behind sprites (grid cells).
transparency_effect: TransparencyEffect = .none,

titlebar_height: f32 = 26.0, // This is the height of the titlebar in pixels

/// Empty strip below the top window edge (non-macOS), above the main title row (in-window menu, etc.).
titlebar_top_buffer: f32 = 10.0,

pub fn resolvedPanZoomScheme(settings: *const Settings) ResolvedPanZoomScheme {
    return switch (settings.input_scheme) {
        .auto => switch (dvui.getMouseTypeHint()) {
            .unknown => if (builtin.os.tag == .macos) .trackpad else .mouse,
            .mouse => .mouse,
            .trackpad => .trackpad,
        },
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}

fn default(allocator: std.mem.Allocator) !Settings {
    return .{
        .theme = try allocator.dupe(u8, default_theme),
    };
}

pub fn setThemeName(settings: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, settings.theme, name)) return;
    const copy = try allocator.dupe(u8, name);
    allocator.free(settings.theme);
    settings.theme = copy;
}

/// Loads settings (`theme` is always heap-owned after successful return — see `setThemeName` / `deinit`).
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Settings {
    const maybe_data = fizzy.fs.read(allocator, dvui.io, path) catch null;
    const data = maybe_data orelse return default(allocator);
    defer allocator.free(data);

    const options = std.json.ParseOptions{
        .duplicate_field_behavior = .use_first,
        .ignore_unknown_fields = true,
    };
    const p = std.json.parseFromSlice(Settings, allocator, data, options) catch |err| {
        dvui.log.warn("Could not parse settings.json ({s}); using defaults.", .{@errorName(err)});
        parsed = null;
        return default(allocator);
    };

    parsed = p;
    var result = p.value;
    // Own theme independently of JSON parse arena (arena is freed in `deinit`).
    result.theme = try allocator.dupe(u8, p.value.theme);
    return result;
}

pub fn save(settings: *Settings, allocator: std.mem.Allocator, path: []const u8) !void {
    const str = try std.json.Stringify.valueAlloc(allocator, settings, .{});
    defer allocator.free(str);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = str });
}

pub fn deinit(settings: *Settings, allocator: std.mem.Allocator) void {
    allocator.free(settings.theme);
    defer parsed = null;
    if (parsed) |pr| pr.deinit();
}
