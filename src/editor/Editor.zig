const std = @import("std");
const builtin = @import("builtin");
const icons = @import("icons");
const assets = @import("assets");
const known_folders = @import("known-folders");
const objc = @import("objc");
const sdl3 = @import("backend").c;

const cozette_ttf = assets.files.fonts.@"CozetteVector.ttf";
const cozette_bold_ttf = assets.files.fonts.@"CozetteVectorBold.ttf";

const comfortaa_ttf = assets.files.fonts.@"Comfortaa-Regular.ttf";
const comfortaa_bold_ttf = assets.files.fonts.@"Comfortaa-Bold.ttf";

const plus_jakarta_sans_ttf = assets.files.fonts.@"PlusJakartaSans-Regular.ttf";
const plus_jakarta_sans_bold_ttf = assets.files.fonts.@"PlusJakartaSans-Bold.ttf";

const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const update_notify = @import("../update_notify.zig");

const App = fizzy.App;
const Editor = @This();

pub const Colors = @import("Colors.zig");
pub const Project = @import("Project.zig");
pub const Recents = @import("Recents.zig");
pub const Settings = @import("Settings.zig");
pub const Tools = @import("Tools.zig");
pub const Dialogs = @import("dialogs/Dialogs.zig");

pub const Transform = @import("Transform.zig");
pub const Keybinds = @import("Keybinds.zig");

pub const Workspace = @import("Workspace.zig");
pub const Explorer = @import("explorer/Explorer.zig");
pub const IgnoreRules = @import("explorer/IgnoreRules.zig");
pub const Panel = @import("panel/Panel.zig");
pub const Sidebar = @import("Sidebar.zig");
pub const Infobar = @import("Infobar.zig");
pub const Menu = @import("Menu.zig");
pub const FileLoadJob = @import("FileLoadJob.zig");
pub const PackJob = @import("PackJob.zig");

/// This arena is for small per-frame editor allocations, such as path joins, null terminations and labels.
/// Do not free these allocations, instead, this allocator will be .reset(.retain_capacity) each frame
arena: std.heap.ArenaAllocator,

config_folder: []const u8,
palette_folder: []const u8,

atlas: fizzy.Internal.Atlas,

settings: Settings = undefined,
recents: Recents = undefined,

explorer: *Explorer,
panel: *Panel,

last_titlebar_color: dvui.Color,
dim_titlebar: bool = false,

/// Workspaces stored by their grouping ID
workspaces: std.AutoArrayHashMapUnmanaged(u64, Workspace) = .empty,
sidebar: Sidebar,
infobar: Infobar,

/// The root folder that will be searched for files and a .fizproject file
folder: ?[]const u8 = null,
project: ?Project = null,
/// From `.fizignore` (preferred) or `.gitignore` at the project root; used by the Files explorer.
ignore: IgnoreRules = .{},

themes: std.ArrayList(dvui.Theme) = .empty,

open_files: std.AutoArrayHashMapUnmanaged(u64, fizzy.Internal.File) = .empty,

/// Background file-load jobs in flight. Keyed by absolute path. Each job's worker thread runs
/// `Internal.File.fromPath` off the main thread; the main thread polls via `processLoadingJobs`
/// and moves completed results into `open_files`. The map owns its key strings via each job's
/// `path` allocation; the StringHashMap stores key slices that point into job memory.
loading_jobs: std.StringHashMapUnmanaged(*FileLoadJob) = .empty,

/// Background project-pack jobs. Each `startPackProject` cancels any predecessors and pushes a
/// new job; only the newest job's result is installed. Cancelled jobs are still kept here
/// until their worker observes the flag and publishes `done`, at which point
/// `processPackJob` reaps them. This way rapid Pack-Project clicks (or future per-save
/// repacks) coalesce: only the most recent request produces a visible atlas update.
pack_jobs: std.ArrayListUnmanaged(*PackJob) = .empty,
/// True iff a loading job should set its target file as the active file once it lands.
/// `setActiveFile`-on-completion respects the most recent open request — multiple in-flight
/// loads only auto-focus the most recently requested one.
last_load_request_path: ?[]const u8 = null,

// The actively focused workspace grouping ID
// This will contain tabs for all open files with a matching grouping ID
open_workspace_grouping: u64 = 0,

/// Files tree cross-workspace drag (`tab_drag`): heap copy of absolute path. See `files.zig`.
tab_drag_from_tree_path: ?[]u8 = null,
/// `drawFiles` data id for `removed_path`; clear after drop on workspace canvas.
file_tree_data_id: ?dvui.Id = null,

tools: Tools,
colors: Colors = .{},

grouping_id_counter: u64 = 0,
file_id_counter: u64 = 0,

sprite_clipboard: ?SpriteClipboard = null,

window_opacity: f32 = 1.0,

pending_native_menu_actions: [16]fizzy.backend.NativeMenuAction = undefined,
pending_native_menu_actions_len: u8 = 0,

/// When set, next `tick` runs `warmupDrawingComposites` on the active file (after open or drawing-tool select).
pending_composite_warmup: bool = false,

/// Filled from the async SDL save dialog callback, then applied inside `tick` (when `currentWindow` is valid).
pending_save_as_path: ?[]u8 = null,

/// After Save As from "Save and Close", close this file id once save completes.
pending_close_file_id: ?u64 = null,

/// "Save all and quit" walks these ids (see `advanceSaveAllQuit`). Non-empty ⇒ save-all quit in progress.
quit_save_all_ids: std.ArrayListUnmanaged(u64) = .empty,

/// True during save-all quit (nested Save As / flat-raster prompts).
quit_in_progress: bool = false,
/// Next frame: continue save-all quit (`advanceSaveAllQuit`).
pending_quit_continue: bool = false,
/// End this frame with `App.Result.close` (e.g. quit finished).
pending_app_close: bool = false,

/// Last serialized JSON written or captured at startup; avoids redundant writes.
settings_last_saved_json: ?[]u8 = null,
/// True after user-driven settings edits until successfully persisted or snapshot matches disk.
settings_dirty: bool = false,
/// Monotonic deadline (`perf.nanoTimestamp()`): autosave runs when dirty and `now >= deadline`.
settings_save_deadline_ns: i128 = 0,

pub const SpriteClipboard = struct {
    source: dvui.ImageSource,
    offset: dvui.Point,
};

const embedded_fonts: []const dvui.Font.Source = &.{
    .{
        .family = dvui.Font.array("CozetteVector"),
        .bytes = cozette_ttf,
    },
    .{
        .family = dvui.Font.array("CozetteVector"),
        .bytes = cozette_bold_ttf,
        .weight = .bold,
    },

    .{
        .family = dvui.Font.array("Comfortaa"),
        .bytes = comfortaa_ttf,
    },
    .{
        .family = dvui.Font.array("Comfortaa"),
        .bytes = comfortaa_bold_ttf,
        .weight = .bold,
    },
    .{
        .family = dvui.Font.array("PlusJakartaSans"),
        .bytes = plus_jakarta_sans_ttf,
    },
    .{
        .family = dvui.Font.array("PlusJakartaSans"),
        .bytes = plus_jakarta_sans_bold_ttf,
        .weight = .bold,
    },
};

pub fn init(
    app: *App,
) !Editor {
    const arena = dvui.currentWindow().arena();
    var environ_map = try fizzy.processEnviron().createMap(arena);
    defer environ_map.deinit();
    const config_root = try known_folders.getPath(dvui.io, arena, environ_map, .local_configuration) orelse app.root_path;
    const config_folder = std.fs.path.join(fizzy.app.allocator, &.{ config_root, "fizzy" }) catch app.root_path;

    // One-time migration: pre-rename builds used `Fizzy/` (capitalized).
    // On case-insensitive filesystems (Windows NTFS, macOS APFS) `fizzy/` already
    // resolves to that same directory, so the rename is a no-op and the
    // failure is ignored. On case-sensitive filesystems (most Linux) the legacy
    // dir is otherwise orphaned, so we move it across to preserve user settings.
    {
        const legacy = std.fs.path.join(arena, &.{ config_root, "Fizzy" }) catch null;
        if (legacy) |legacy_path| {
            // Only rename if the new path doesn't already have content.
            const new_exists = blk: {
                std.Io.Dir.accessAbsolute(dvui.io, config_folder, .{ .read = true }) catch break :blk false;
                break :blk true;
            };
            const legacy_exists = blk: {
                std.Io.Dir.accessAbsolute(dvui.io, legacy_path, .{ .read = true }) catch break :blk false;
                break :blk true;
            };
            if (legacy_exists and !new_exists) {
                std.Io.Dir.renameAbsolute(legacy_path, config_folder, dvui.io) catch |err| {
                    std.log.warn("legacy config folder migration ({s} -> {s}) failed: {s}", .{ legacy_path, config_folder, @errorName(err) });
                };
            }
        }
    }
    const palette_folder = std.fs.path.join(fizzy.app.allocator, &.{ config_folder, "Palettes" }) catch config_folder;

    var editor: Editor = .{
        .config_folder = config_folder,
        .palette_folder = palette_folder,
        .explorer = try app.allocator.create(Explorer),
        .panel = try app.allocator.create(Panel),
        .sidebar = try .init(),
        .infobar = try .init(),
        .arena = .init(std.heap.page_allocator),
        .last_titlebar_color = dvui.themeGet().color(.control, .fill),
        .atlas = .{
            .data = try .loadFromBytes(app.allocator, assets.files.@"fizzy.atlas"),
            .source = try fizzy.image.fromImageFileBytes("fizzy.png", assets.files.@"fizzy.png", .ptr),
        },
        .tools = try .init(app.allocator),
        .themes = .empty,
    };

    editor.settings = try Settings.load(app.allocator, try std.fs.path.join(app.allocator, &.{ editor.config_folder, "settings.json" }));

    { // Setup themes
        var fizzy_dark = dvui.themeGet();
        fizzy_dark.embedded_fonts = embedded_fonts;

        fizzy_dark.window = .{
            .fill = .{ .r = 28, .g = 29, .b = 36, .a = 255 },
            .border = .{ .r = 34, .g = 35, .b = 42, .a = 255 },
            .text = .{ .r = 206, .g = 163, .b = 127, .a = 255 },
        };

        fizzy_dark.control = .{
            .fill = .{ .r = 28, .g = 29, .b = 36, .a = 255 },
            .border = .{ .r = 34, .g = 35, .b = 42, .a = 255 },
            .text = .{ .r = 134, .g = 138, .b = 148, .a = 255 },
        };

        fizzy_dark.highlight = .{
            .fill = .{ .r = 47, .g = 179, .b = 135, .a = 255 },
            .border = .{ .r = 47, .g = 179, .b = 135, .a = 255 },
            .text = fizzy_dark.window.fill,
        };

        fizzy_dark.err = .{
            .fill = .{ .r = 109, .g = 35, .b = 54, .a = 255 },
        };

        // theme.content
        fizzy_dark.fill = .{ .r = 42, .g = 44, .b = 54, .a = 255 };
        fizzy_dark.text = fizzy_dark.window.text.?;
        fizzy_dark.focus = fizzy_dark.highlight.fill.?;

        fizzy_dark.dark = true;
        fizzy_dark.name = "Fizzy Dark";
        fizzy_dark.font_body = .find(.{ .family = "Comfortaa", .size = editor.settings.font_body_size });
        fizzy_dark.font_title = .find(.{ .family = "Comfortaa", .size = editor.settings.font_title_size, .weight = .bold });
        fizzy_dark.font_heading = .find(.{ .family = "PlusJakartaSans", .size = editor.settings.font_heading_size, .weight = .bold });
        fizzy_dark.font_mono = .find(.{ .family = "CozetteVector", .size = editor.settings.font_mono_size });

        var moi: dvui.Theme = fizzy_dark;
        moi.name = "Moi";
        moi.window = .{
            .fill = .{ .r = 84, .g = 12, .b = 26, .a = 255 },
            .border = .{ .r = 104, .g = 62, .b = 72, .a = 255 },
            .text = .{ .r = 255, .g = 190, .b = 190, .a = 240 },
        };

        moi.control = .{
            .fill = moi.window.fill.?.lighten(10),
            .border = .{ .r = 104, .g = 62, .b = 72, .a = 255 },
            .text = .{ .r = 255, .g = 235, .b = 235, .a = 200 },
        };
        moi.highlight = .{
            .fill = moi.window.fill.?.lighten(10),
        };

        moi.fill = moi.control.fill.?;
        moi.text = moi.window.text.?;
        moi.focus = moi.highlight.fill.?;

        var fizzy_light = fizzy_dark;
        fizzy_light.dark = false;
        fizzy_light.name = "Fizzy Light";

        fizzy_light.window = .{
            .fill = .{ .r = 240, .g = 240, .b = 245, .a = 255 },
            .border = dvui.Theme.builtin.adwaita_light.window.border,
            .text = .{ .r = 120, .g = 70, .b = 65, .a = 255 },
        };

        fizzy_light.control = dvui.Theme.builtin.adwaita_light.control;

        fizzy_light.highlight = .{
            .fill = .{ .r = 170, .g = 130, .b = 140, .a = 255 },
            .text = fizzy_light.window.fill,
        };

        fizzy_light.err = .{
            .fill = .{ .r = 109, .g = 35, .b = 54, .a = 255 },
        };

        // theme.content
        fizzy_light.fill = .{ .r = 200, .g = 200, .b = 205, .a = 255 };
        fizzy_light.text = .{ .r = 40, .g = 40, .b = 45, .a = 255 };
        fizzy_light.focus = fizzy_light.highlight.fill.?;

        appendUserThemes(app.allocator, &editor) catch |err| {
            dvui.log.err("Failed to prepare user themes folder: {s}", .{@errorName(err)});
        };

        editor.themes.append(app.allocator, fizzy_dark) catch {
            dvui.log.err("Failed to append theme", .{});
            return error.FailedToAppendTheme;
        };

        editor.themes.append(app.allocator, moi) catch {
            dvui.log.err("Failed to append moi theme", .{});
            return error.FailedToAppendMoiTheme;
        };

        editor.themes.append(app.allocator, fizzy_light) catch {
            dvui.log.err("Failed to append fizzy light theme", .{});
            return error.FailedToAppendFizzyLightTheme;
        };

        for (dvui.Theme.builtins) |b| {
            editor.themes.append(app.allocator, b) catch {
                dvui.log.err("Failed to append builtin theme", .{});
                return error.FailedToAppendBuiltinTheme;
            };
        }

        try editor.applySettingsTheme();
    }

    var valid_path: bool = true;
    if (std.fs.path.isAbsolute(editor.config_folder)) {
        std.Io.Dir.accessAbsolute(dvui.io, editor.config_folder, .{ .read = true }) catch {
            valid_path = false;
        };

        if (!valid_path) {
            std.Io.Dir.createDirAbsolute(dvui.io, editor.config_folder, .default_dir) catch |err| dvui.log.err("Failed to create config folder: {s}: {any}", .{ editor.config_folder, err });
        }
    }

    valid_path = true;
    if (std.fs.path.isAbsolute(editor.palette_folder)) {
        std.Io.Dir.accessAbsolute(dvui.io, editor.palette_folder, .{ .read = true }) catch {
            valid_path = false;
        };

        if (!valid_path) {
            std.Io.Dir.createDirAbsolute(dvui.io, editor.palette_folder, .default_dir) catch |err| dvui.log.err("Failed to create palette folder: {s}: {any}", .{ editor.palette_folder, err });
        }
    }

    fizzy.perf.console_logging_enabled = editor.settings.perf_logging;
    editor.recents = Recents.load(app.allocator, try std.fs.path.join(app.allocator, &.{ editor.config_folder, "recents.json" })) catch .{
        .folders = .init(app.allocator),
    };

    fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(if (dvui.themeGet().dark) editor.settings.window_opacity_dark else editor.settings.window_opacity_light));

    editor.explorer.* = .init();
    editor.panel.* = .init();
    editor.open_files = .empty;
    editor.workspaces = .empty;
    editor.workspaces.put(fizzy.app.allocator, 0, .init(0)) catch |err| {
        std.log.err("Failed to create workspace: {s}", .{@errorName(err)});
        return err;
    };

    editor.colors.file_tree_palette = fizzy.Internal.Palette.loadFromBytes(app.allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    editor.colors.palette = fizzy.Internal.Palette.loadFromBytes(app.allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;

    try Keybinds.register();

    // Collect the initial settings json
    editor.settings_last_saved_json = try std.json.Stringify.valueAlloc(fizzy.app.allocator, &editor.settings, .{});

    return editor;
}

/// Ensures `{config}/Themes` exists and scans `*.json` for future user themes (loaded entries are prepended before Fizzy themes).
fn appendUserThemes(gpa: std.mem.Allocator, editor: *Editor) !void {
    const themes_dir = try std.fs.path.join(gpa, &.{ editor.config_folder, "Themes" });

    if (!std.fs.path.isAbsolute(themes_dir)) {
        gpa.free(themes_dir);
        return;
    }
    defer gpa.free(themes_dir);

    std.Io.Dir.accessAbsolute(dvui.io, themes_dir, .{ .read = true }) catch {
        try std.Io.Dir.createDirAbsolute(dvui.io, themes_dir, .default_dir);
    };

    var dir = try std.Io.Dir.cwd().openDir(dvui.io, themes_dir, .{ .access_sub_paths = false, .iterate = true });
    defer dir.close(dvui.io);

    var iter = dir.iterate();
    while (try iter.next(dvui.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        // Future: parse Theme JSON and append before Fizzy themes so folder overrides builtins by list order.
    }
}

/// Clamp settings font sizes (6–20), apply those sizes to every registered theme (preserving each theme’s font families), and refresh the active DVUI theme.
pub fn applyFontSizesFromSettings(editor: *Editor) void {
    const clampFontSize = struct {
        fn f(sz: f32) f32 {
            return @floatCast(std.math.clamp(@round(sz), 6.0, 20.0));
        }
    }.f;

    const sb = clampFontSize(editor.settings.font_body_size);
    const st = clampFontSize(editor.settings.font_title_size);
    const sh = clampFontSize(editor.settings.font_heading_size);
    const sm = clampFontSize(editor.settings.font_mono_size);

    editor.settings.font_body_size = sb;
    editor.settings.font_title_size = st;
    editor.settings.font_heading_size = sh;
    editor.settings.font_mono_size = sm;

    for (editor.themes.items) |*t| {
        t.font_body = t.font_body.withSize(sb);
        t.font_title = t.font_title.withSize(st);
        t.font_heading = t.font_heading.withSize(sh);
        t.font_mono = t.font_mono.withSize(sm);
    }

    const active_name = dvui.themeGet().name;
    for (editor.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, active_name)) {
            dvui.themeSet(t.*);
            break;
        }
    }
}

fn themeFilenameToName(trimmed: []const u8) ?[]const u8 {
    const pairs = [_]struct { stub: []const u8, canonical: []const u8 }{
        .{ .stub = "fizzy_dark.json", .canonical = "Fizzy Dark" },
        .{ .stub = "fizzy_light.json", .canonical = "Fizzy Light" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, trimmed, p.stub)) return p.canonical;
    }
    return null;
}

/// Select a theme from `editor.themes` matching `settings.theme`: trim, legacy file-name aliases, then exact and case-insensitive name match. Falls back to `Settings.default_theme`, then the first entry, and logs if the stored value did not match anything.
fn resolveSettingsTheme(editor: *Editor) *dvui.Theme {
    const trimmed = std.mem.trim(u8, editor.settings.theme, &std.ascii.whitespace);
    const candidate = themeFilenameToName(trimmed) orelse trimmed;

    for (editor.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, candidate)) return t;
    }
    for (editor.themes.items) |*t| {
        if (std.ascii.eqlIgnoreCase(t.name, candidate)) return t;
    }
    dvui.log.warn(
        "Saved theme \"{s}\" did not match any known theme; falling back to \"{s}\".",
        .{ trimmed, Settings.default_theme },
    );
    for (editor.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, Settings.default_theme)) return t;
    }
    std.debug.assert(editor.themes.items.len > 0);
    return &editor.themes.items[0];
}

pub fn applySettingsTheme(editor: *Editor) !void {
    const t = resolveSettingsTheme(editor);
    if (!std.mem.eql(u8, editor.settings.theme, t.name)) {
        try Settings.setThemeName(&editor.settings, fizzy.app.allocator, t.name);
    }
    dvui.themeSet(t.*);
    editor.applyFontSizesFromSettings();

    // TEMP diagnostic: dump every Source registered in the font database, plus
    // the active theme's heading/title font specs. Helps confirm whether the
    // Comfortaa-Bold entry actually made it in and what weight font_heading asks for.
    {
        const cw = dvui.currentWindow();
        dvui.log.info("[font-debug] active theme: {s}", .{cw.theme.name});
        dvui.log.info("[font-debug]   font_heading: family={s} weight={s} size={d}", .{
            cw.theme.font_heading.familyName(),
            @tagName(cw.theme.font_heading.weight),
            cw.theme.font_heading.size,
        });
        dvui.log.info("[font-debug]   font_title:   family={s} weight={s} size={d}", .{
            cw.theme.font_title.familyName(),
            @tagName(cw.theme.font_title.weight),
            cw.theme.font_title.size,
        });
        for (cw.fonts.database.items, 0..) |src, i| {
            dvui.log.info("[font-debug]   db[{d}]: family={s} weight={s} bytes.ptr={x}", .{
                i,
                src.familyName(),
                @tagName(src.weight),
                @intFromPtr(src.bytes.ptr),
            });
        }
    }
}

pub fn currentGroupingID(editor: *Editor) u64 {
    return editor.open_workspace_grouping;
}

pub fn newGroupingID(editor: *Editor) u64 {
    editor.grouping_id_counter += 1;
    return editor.grouping_id_counter;
}

pub fn newFileID(editor: *Editor) u64 {
    editor.file_id_counter += 1;
    return editor.file_id_counter;
}

pub fn markSettingsDirty(editor: *Editor) void {
    editor.settings_dirty = true;
    editor.settings_save_deadline_ns = fizzy.perf.nanoTimestamp() + Settings.autosave_timeout_ns;
}

fn activelyDrawing(editor: *Editor) bool {
    for (editor.open_files.values()) |*file| {
        if (file.editor.active_drawing) return true;
    }
    return false;
}

/// Debounced autosave (defers while a canvas stroke is active).
fn saveSettingsGuarded(editor: *Editor) !void {
    if (!editor.settings_dirty) return;

    const now = fizzy.perf.nanoTimestamp();
    if (now < editor.settings_save_deadline_ns) return;

    if (editor.activelyDrawing())
        return;

    const serialized = try std.json.Stringify.valueAlloc(fizzy.app.allocator, &editor.settings, .{});
    defer fizzy.app.allocator.free(serialized);

    if (editor.settings_last_saved_json) |old| {
        if (std.mem.eql(u8, old, serialized)) {
            editor.settings_dirty = false;
            return;
        }
    }

    const settings_path = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "settings.json" });
    defer fizzy.app.allocator.free(settings_path);

    try Settings.save(&editor.settings, fizzy.app.allocator, settings_path);

    if (editor.settings_last_saved_json) |blob| {
        fizzy.app.allocator.free(blob);
        editor.settings_last_saved_json = null;
    }
    editor.settings_last_saved_json = try fizzy.app.allocator.dupe(u8, serialized);
    editor.settings_dirty = false;
}

/// Flush to disk regardless of idle/drawing deferral — used during shutdown only.
fn saveSettingsRaw(editor: *Editor) !void {
    const serialized = try std.json.Stringify.valueAlloc(fizzy.app.allocator, &editor.settings, .{});
    defer fizzy.app.allocator.free(serialized);

    const need_disk = blk: {
        if (editor.settings_last_saved_json) |old| {
            if (std.mem.eql(u8, old, serialized)) break :blk false;
        }
        break :blk true;
    };

    const settings_path = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "settings.json" });
    defer fizzy.app.allocator.free(settings_path);

    if (need_disk)
        try Settings.save(&editor.settings, fizzy.app.allocator, settings_path);

    if (need_disk) {
        if (editor.settings_last_saved_json) |blob| {
            fizzy.app.allocator.free(blob);
            editor.settings_last_saved_json = null;
        }
        editor.settings_last_saved_json = try fizzy.app.allocator.dupe(u8, serialized);
    }
    editor.settings_dirty = false;
}

const handle_size = 10;
const handle_dist = 60;

pub fn tick(editor: *Editor) !dvui.App.Result {
    editor.window_opacity = if (dvui.themeGet().dark) editor.settings.window_opacity_dark else editor.settings.window_opacity_light;

    if (editor.pending_quit_continue) {
        editor.pending_quit_continue = false;
        editor.advanceSaveAllQuit();
    }

    const wd = dvui.currentWindow().data();
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (!dvui.eventMatchSimple(e, wd)) continue;
        const want_quit = (e.evt == .window and e.evt.window.action == .close) or
            (e.evt == .app and e.evt.app.action == .quit);
        if (!want_quit) continue;

        var dirty_n: usize = 0;
        for (editor.open_files.values()) |f| {
            if (f.dirty()) dirty_n += 1;
        }
        if (dirty_n == 0) continue;

        e.handle(@src(), wd);
        if (!Dialogs.AppQuitUnsaved.active(dvui.currentWindow()) and editor.quit_save_all_ids.items.len == 0) {
            Dialogs.AppQuitUnsaved.request();
        }
    }

    if (fizzy.backend.pollPendingNativeMenuAction()) |action| {
        editor.queueNativeMenuAction(action);
    }

    defer editor.dim_titlebar = false;
    editor.setTitlebarColor();
    editor.setWindowStyle();

    fizzy.render.frame_index +%= 1;
    if (fizzy.perf.record) fizzy.perf.beginFrame();
    defer if (fizzy.perf.record) fizzy.perf.endFrameAndMaybeLog();

    // Reap completed background file loads. Must run BEFORE `pending_composite_warmup` and any
    // workspace/file iteration so that a just-loaded file is visible to the rest of this frame.
    editor.processLoadingJobs();
    editor.processPackJob();

    // Build workspaces AFTER reaping load jobs so a freshly-loaded file with a new grouping
    // (e.g. "Open to the side") gets its workspace created on the same frame it lands.
    // Otherwise the new pane only appears on the next frame, which won't happen until some
    // unrelated event (mouse move, key) wakes the loop.
    editor.rebuildWorkspaces() catch {
        dvui.log.err("Failed to rebuild workspaces", .{});
    };

    if (editor.pending_composite_warmup) {
        editor.pending_composite_warmup = false;
        if (editor.activeFile()) |file| {
            const w = file.width();
            const h = file.height();
            if (w > 0 and h > 0) {
                const area = @as(u64, w) * @as(u64, h);
                // Skip tiny canvases; large docs benefit most from moving split-target work off the first stroke.
                if (area >= 512 * 512) {
                    fizzy.render.warmupDrawingComposites(file) catch |err| {
                        dvui.log.err("Composite warmup failed: {any}", .{err});
                    };
                }
            }
        }
    }

    {
        var any_drawing = false;
        fizzy.perf.draw_stroke_buf_count = 0; // no active stroke → 0; else first active file's map size
        for (editor.open_files.values()) |*file| {
            if (file.editor.active_drawing) {
                any_drawing = true;
                fizzy.perf.draw_stroke_buf_count = file.buffers.stroke.pixels.count();
                break;
            }
        }
        fizzy.perf.drawFrameBegin(any_drawing);
    }
    defer fizzy.perf.drawFrameEnd();

    // TODO: Does this need to be here for touchscreen zooming? Or does that belong in canvas?
    // var scaler = dvui.scale(
    //     @src(),
    //     .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
    //     .{ .expand = .both },
    // );
    // defer scaler.deinit();

    {

        // First, window color is set to the opaque color.
        var window_color = dvui.themeGet().color(.content, .fill);

        switch (builtin.os.tag) {
            .macos => {
                window_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) window_color.opacity(editor.window_opacity).lighten((1.0 - editor.window_opacity) * 4.0) else window_color;
            },
            .windows => {
                window_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) window_color.opacity(editor.window_opacity).lighten((1.0 - editor.window_opacity) * 4.0) else window_color;
            },
            else => {},
        }

        var overall_box = dvui.box(
            @src(),
            .{ .dir = .vertical },
            .{
                .expand = .both,
                .background = true,
                .color_fill = window_color,
            },
        );
        defer overall_box.deinit();

        // Non-macOS: a thin strip below the top edge so the in-window title row (menu, etc.) is not flush
        // against the window border (complements the system caption area on Windows 11).
        if (builtin.os.tag != .macos) {
            var top_inset = dvui.box(
                @src(),
                .{ .dir = .horizontal },
                .{
                    .expand = .horizontal,
                    .background = false,
                    .min_size_content = .{ .w = 1, .h = fizzy.editor.settings.titlebar_top_buffer },
                    .max_size_content = .{ .w = std.math.floatMax(f32), .h = fizzy.editor.settings.titlebar_top_buffer },
                },
            );
            defer top_inset.deinit();
        }

        // Title bar handling:
        //  - macOS (not maximized): render an empty horizontal strip so AppKit's traffic lights have visual
        //    breathing room at the top-left. AppKit handles dragging natively.
        //  - Windows: the main UI (sidebar, menu) starts below `titlebar_top_buffer`. A floating overlay
        //    at the top-right corner (y=0) hosts the min/max/close buttons; a drag rect is pushed across the top so
        //    empty space (gaps between widgets) drags the window. Menu items and sidebar buttons push
        //    themselves as interactive rects so clicks on them still reach DVUI.
        if (builtin.os.tag == .windows) {
            fizzy.backend.resetTitleBarHints();

            const window_rect_natural = dvui.windowRect();
            const scale = dvui.windowNaturalScale();
            const title_strip_h = fizzy.editor.settings.titlebar_top_buffer + fizzy.editor.settings.titlebar_height;
            // Backend derives the drag strip's width live from GetClientRect; we only cache its height
            // and the client width as it stood this frame so right-anchored caption buttons survive
            // a one-frame staleness window after a resize.
            fizzy.backend.setTitleBarStrip(
                title_strip_h * scale,
                @intFromFloat(window_rect_natural.w * scale),
            );
        } else if (builtin.os.tag == .macos and !fizzy.backend.isMaximized(dvui.currentWindow())) {
            var titlebar_box = dvui.box(
                @src(),
                .{ .dir = .horizontal },
                .{
                    .expand = .horizontal,
                    .background = false,
                    .min_size_content = .{ .w = 1, .h = fizzy.editor.settings.titlebar_height },
                    .max_size_content = .{ .w = std.math.floatMax(f32), .h = fizzy.editor.settings.titlebar_height },
                },
            );
            defer titlebar_box.deinit();
        }

        // Windows-only top-right overlay: minimize / maximize / close. Lives in a FloatingWidget
        // (a subwindow) so it doesn't take any space in the vertical overall_box layout — the main
        // UI below fills the entire window. Caption-button rects are pushed to the backend so
        // WM_NCHITTEST returns HTMINBUTTON/HTMAXBUTTON/HTCLOSE for them (snap-layouts + click).
        if (builtin.os.tag == .windows) {
            const button_w: f32 = 46;
            const button_h = fizzy.editor.settings.titlebar_height;
            const overlay_w: f32 = button_w * 3;
            const win_rect = dvui.windowRect();

            var fw: dvui.FloatingWidget = undefined;
            fw.init(@src(), .{ .mouse_events = true }, .{
                .rect = .{ .x = win_rect.w - overlay_w, .y = 0, .w = overlay_w, .h = button_h },
            });
            defer fw.deinit();

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer row.deinit();

            const hovered = fizzy.backend.getHoveredTitleBarButton();
            const stroke = dvui.themeGet().color(.control, .text);
            const hover_fill = dvui.themeGet().color(.control, .fill_hover).lighten(if (dvui.themeGet().dark) 3 else -3);
            const close_hover_fill = dvui.Color{ .r = 232, .g = 17, .b = 35, .a = 255 };
            const close_hover_stroke = dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

            // minimize
            {
                const is_hover = hovered == .minimize;
                var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = button_w, .h = button_h },
                    .expand = .vertical,
                    .background = is_hover,
                    .color_fill = hover_fill,
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.minimize, b.data().rectScale().r);
                dvui.icon(@src(), "win_min", icons.tvg.feather.minus, .{ .stroke_color = stroke }, .{
                    .expand = .ratio,
                    .padding = .all(7),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
            // maximize / restore
            {
                const is_hover = hovered == .maximize;
                var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = button_w, .h = button_h },
                    .expand = .vertical,
                    .background = is_hover,
                    .color_fill = hover_fill,
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.maximize, b.data().rectScale().r);
                dvui.icon(@src(), "win_max", icons.tvg.lucide.square, .{ .stroke_color = stroke }, .{
                    .expand = .ratio,
                    .padding = .all(9),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
            // close
            {
                const is_hover = hovered == .close;
                var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = button_w, .h = button_h },
                    .expand = .vertical,
                    .background = is_hover,
                    .color_fill = close_hover_fill.opacity(0.5),
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.close, b.data().rectScale().r);
                dvui.icon(@src(), "win_close", icons.tvg.heroicons.outline.@"x-mark", .{
                    .stroke_color = if (is_hover) close_hover_stroke else stroke,
                }, .{
                    .expand = .ratio,
                    .padding = .all(5),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
        }

        var base_box = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                .expand = .both,
            },
        );
        defer base_box.deinit();

        // Advance the animation frame if we are in play mode
        if (editor.activeFile()) |file| {
            if (file.editor.playing) {
                if (file.selected_animation_index) |index| {
                    const animation = file.animations.get(index);

                    if (animation.frames.len > 0) {
                        if (dvui.timerDoneOrNone(base_box.data().id)) {
                            if (file.selected_animation_frame_index >= animation.frames.len - 1) {
                                file.selected_animation_frame_index = 0;
                            } else {
                                file.selected_animation_frame_index += 1;
                            }
                            const millis_per_frame = animation.frames[file.selected_animation_frame_index].ms;

                            dvui.timer(base_box.data().id, @intCast(millis_per_frame * 1000));
                        }
                    }
                }
            }
        }

        // Always reset the peek layer index back, but we need to do this outside of the file widget so
        // other editor windows can use it
        defer for (editor.open_files.values()) |*file| {
            if (file.editor.isolate_layer) {
                file.peek_layer_index = file.selected_layer_index;
            } else {
                file.peek_layer_index = null;
            }
        };

        // Sidebar area
        // Since sidebar is drawn before the explorer, and we want to allow expanding the explorer
        // from clicking a sidebar option, we need to check if the sidebar was pressed
        const sidebar_pressed = editor.sidebar.draw() catch {
            dvui.log.err("Failed to draw sidebar", .{});
            return false;
        };

        var explorer_paned_box = dvui.box(
            @src(),
            .{ .dir = .vertical },
            .{
                .expand = .both,
                .background = false,
            },
        );
        defer explorer_paned_box.deinit();

        // Draw the infobar, but draw it at the bottom of the paned box (gravity_y = 1.0)
        {
            editor.infobar.draw() catch {
                dvui.log.err("Failed to draw infobar", .{});
            };
        }

        // Draw the explorer paned widget, which will recursively draw the workspaces in the second pane
        editor.explorer.paned = fizzy.dvui.paned(@src(), .{
            .direction = .horizontal,
            .collapsed_size = fizzy.editor.settings.min_window_size[0] + 1,
            .handle_size = handle_size,
            .handle_dynamic = .{
                .handle_size_max = handle_size,
                .distance_max = handle_dist,
            },
            .uncollapse_ratio = fizzy.editor.settings.explorer_ratio,
        }, .{
            .expand = .both,
            .background = false,
        });
        defer editor.explorer.paned.deinit();

        editor.flushQueuedNativeMenuActions();
        editor.processPendingSaveAs();

        if (dvui.firstFrame(editor.explorer.paned.wd.id)) {
            editor.explorer.paned.split_ratio.* = 0.0;
            editor.explorer.paned.animateSplit(fizzy.editor.settings.explorer_ratio, dvui.easing.outBack);

            if (fizzy.editor.settings.explorer_ratio < 0.01) {
                editor.explorer.closed = true;
            }
        } else if (editor.explorer.paned.dragging) {
            editor.settings.explorer_ratio = editor.explorer.paned.split_ratio.*;
            editor.markSettingsDirty();
        }

        if (sidebar_pressed) {
            editor.explorer.open();
        }

        if (editor.explorer.paned.showFirst()) {

            // Explorer area
            {
                const result = try editor.explorer.draw();
                if (result != .ok) {
                    return result;
                }
            }
        }

        if (editor.explorer.paned.showSecond()) {
            const bg_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer bg_box.deinit();

            // On macOS, the menu is handled natively, so we don't need to draw it here
            if (builtin.os.tag != .macos) {
                const result = try Menu.draw();
                if (result != .ok) {
                    return result;
                }
            }

            const workspace_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false, .padding = .{ .w = handle_size } });
            defer workspace_vbox.deinit();

            editor.panel.paned = fizzy.dvui.paned(@src(), .{
                .direction = .vertical,
                .collapsed_size = fizzy.editor.settings.min_window_size[1] + 1,
                .handle_size = handle_size,
                .handle_dynamic = .{ .handle_size_max = handle_size, .distance_max = handle_dist },
                .uncollapse_ratio = 1.0,
            }, .{
                .expand = .both,
                .background = false,
            });
            defer editor.panel.paned.deinit();

            if (!editor.panel.paned.dragging) {
                if (editor.activeFile()) |_| {
                    if ((editor.panel.paned.split_ratio.* == 1.0 and !editor.panel.paned.collapsed()) and fizzy.editor.settings.panel_ratio > 0.0) {
                        editor.panel.paned.animateSplit(1.0 - fizzy.editor.settings.panel_ratio, dvui.easing.outQuint);
                    }
                } else {
                    if (!editor.panel.paned.animating and editor.panel.paned.split_ratio.* < 1.0) {
                        editor.panel.paned.animateSplit(1.0, dvui.easing.outQuint);
                    }
                }
            } else {
                fizzy.editor.settings.panel_ratio = 1.0 - editor.panel.paned.split_ratio.*;
                fizzy.editor.markSettingsDirty();
            }

            if (editor.panel.paned.showSecond()) {
                const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .expand = .both,
                    .background = false,
                    .gravity_y = 0.0,
                });
                defer vbox.deinit();

                const result = try editor.panel.draw();
                if (result != .ok) {
                    return result;
                }
            }

            if (editor.panel.paned.showFirst()) {
                const result = try editor.drawWorkspaces(0);
                if (result != .ok) {
                    return result;
                }
            }
        }

        { // Radial Menu

            Keybinds.tick() catch {
                dvui.log.err("Failed to tick hotkeys", .{});
            };

            for (dvui.events()) |*e| {
                switch (e.evt) {
                    .mouse => |me| {
                        editor.tools.radial_menu.mouse_position = me.p;
                    },
                    else => {},
                }
            }

            if (editor.tools.radial_menu.visible) {
                editor.drawRadialMenu() catch {
                    dvui.log.err("Failed to draw radial menu", .{});
                };
            }
        }

        // Arms the launch update toast once the background check reports a newer
        // version, then renders it in a custom rect anchored just above the infobar.
        // (We use a non-null subwindow_id on the toast so DVUI's default `toastsShow`
        // in Window.end skips it — see `update_notify.drawAbove`.)
        update_notify.tick();
        if (Infobar.last_top_y_physical) |infobar_y_physical| {
            // Bottom-flush against the infobar's top edge. `last_top_y_physical`
            // is in screen-space pixels so it matches FloatingWidget's `from`
            // coordinate system; `drawAbove` self-sizes the pill so the bottom
            // sits exactly at this y.
            update_notify.drawAbove(infobar_y_physical, 4.0);
        }
    }

    // look at demo() for examples of dvui widgets, shows in a floating window
    dvui.Examples.demo(.full);

    // Render a centered loading overlay for any background file-load job that has been
    // running long enough to warrant UI feedback. Small files complete before the threshold
    // and never flash this. Non-modal — user can keep working in other tabs while loading.
    editor.drawLoadingOverlay();
    // Render any save-complete toasts in the same centered, content-fill-styled card system.
    // The dvui toast queue holds them with a 2.5s timeout; each toast's display function fades
    // out and removes itself when the timer expires.
    editor.drawSaveToasts();

    editor.saveSettingsGuarded() catch |err| {
        dvui.log.err("Failed to autosave settings ({s})", .{@errorName(err)});
    };

    _ = editor.arena.reset(.retain_capacity);

    if (editor.pending_app_close) {
        editor.pending_app_close = false;
        return .close;
    }

    return .ok;
}

fn queueNativeMenuAction(editor: *Editor, action: fizzy.backend.NativeMenuAction) void {
    if (editor.pending_native_menu_actions_len >= editor.pending_native_menu_actions.len) {
        // If we ever overflow, drop the action rather than crashing.
        return;
    }
    editor.pending_native_menu_actions[editor.pending_native_menu_actions_len] = action;
    editor.pending_native_menu_actions_len += 1;
}

fn flushQueuedNativeMenuActions(editor: *Editor) void {
    if (editor.pending_native_menu_actions_len == 0) return;
    const len: usize = editor.pending_native_menu_actions_len;
    editor.pending_native_menu_actions_len = 0;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        editor.handleNativeMenuAction(editor.pending_native_menu_actions[i]) catch |err| {
            dvui.log.err("Native menu action failed: {any}", .{err});
        };
    }
}

pub fn handleNativeMenuAction(editor: *Editor, action: fizzy.backend.NativeMenuAction) !void {
    switch (action) {
        .open_folder => {
            if (try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{ .title = "Open Project Folder" })) |folder| {
                try editor.setProjectFolder(folder);
            }
        },
        .open_files => {
            if (try dvui.dialogNativeFileOpenMultiple(dvui.currentWindow().arena(), .{
                .title = "Open Files...",
                .filter_description = ".fiz, .pixi, .png, .jpg, .jpeg",
                .filters = &.{ "*.fiz", "*.pixi", "*.png", "*.jpg", "*.jpeg" },
            })) |files| {
                for (files) |file| {
                    _ = editor.openFilePath(file, editor.open_workspace_grouping) catch {
                        std.log.err("Failed to open file: {s}", .{file});
                    };
                }
            }
        },
        .save => {
            editor.save() catch {
                std.log.err("Failed to save", .{});
            };
        },
        .new_file => {
            editor.requestNewFileDialog();
        },
        .save_as => {
            editor.requestSaveAs();
        },
        .copy => {
            if (editor.activeFile() != null) {
                editor.copy() catch {
                    std.log.err("Failed to copy", .{});
                };
            }
        },
        .paste => {
            if (editor.activeFile() != null) {
                editor.paste() catch {
                    std.log.err("Failed to paste", .{});
                };
            }
        },
        .undo => {
            if (editor.activeFile()) |file| {
                file.history.undoRedo(file, .undo) catch {
                    std.log.err("Failed to undo", .{});
                };
            }
        },
        .redo => {
            if (editor.activeFile()) |file| {
                file.history.undoRedo(file, .redo) catch {
                    std.log.err("Failed to redo", .{});
                };
            }
        },
        .transform => {
            if (editor.activeFile() != null) {
                editor.transform() catch {
                    std.log.err("Failed to transform", .{});
                };
            }
        },
        .grid_layout => {
            if (editor.activeFile() != null) {
                editor.requestGridLayoutDialog();
            }
        },
        .toggle_explorer => {
            // Use .closed, not paned.split_ratio — split_ratio is only valid during draw
            if (editor.explorer.closed) {
                editor.explorer.open();
            } else {
                editor.explorer.close();
            }
            // Native menu does not go through SDL events; request a frame so the paned animates immediately.
            dvui.refresh(null, @src(), dvui.currentWindow().data().id);
        },
        .show_dvui_demo => {
            dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
        },
        .about, .check_for_updates => {
            // Mirror the infobar fizzy button: the About dialog displays version, current
            // update status, and a Check-for-Updates / Install button. Both menu items land
            // here so the macOS Help → "Check for Updates…" path is congruent with the in-app affordance.
            Dialogs.AboutFizzy.request();
        },
        .report_bug => {
            _ = dvui.openURL(.{ .url = "https://github.com/foxnne/fizzy/issues" });
        },
    }
}

pub fn setTitlebarColor(editor: *Editor) void {
    const color = if (editor.dim_titlebar) dvui.themeGet().color(.control, .fill).lerp(.black, if (dvui.themeGet().dark) 60.0 / 255.0 else 80.0 / 255.0) else dvui.themeGet().color(.control, .fill);

    if (!std.mem.eql(u8, &editor.last_titlebar_color.toRGBA(), &color.toRGBA())) {
        editor.last_titlebar_color = color;
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), color.opacity(if (dvui.themeGet().dark) editor.settings.window_opacity_dark else editor.settings.window_opacity_light));
    }
}

pub fn setWindowStyle(_: *Editor) void {
    fizzy.backend.setWindowStyle(dvui.currentWindow());
}

pub fn drawRadialMenu(editor: *Editor) !void {
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .cast(dvui.windowRect()),
    });
    defer fw.deinit();

    const menu_color = dvui.themeGet().color(.content, .fill).lighten(4.0);

    if (dvui.firstFrame(fw.data().id)) {
        editor.tools.radial_menu.center = editor.tools.radial_menu.mouse_position;
    }

    const center = fw.data().rectScale().pointFromPhysical(editor.tools.radial_menu.center);

    const tool_count: usize = std.meta.fields(Editor.Tools.Tool).len;

    const radius: f32 = 50.0;
    const width: f32 = radius * 2.0;
    const height: f32 = radius * 2.0;
    const step: f32 = (2.0 * std.math.pi) / @as(f32, @floatFromInt(tool_count));

    var angle: f32 = 180.0;

    var outer_anim = dvui.animate(@src(), .{ .duration = 400_000, .kind = .horizontal, .easing = dvui.easing.outBack }, .{});

    const temp_radius: f32 = 3.0 * radius * (outer_anim.val orelse 1.0);

    var outer_rect = dvui.Rect.fromPoint(center);
    outer_rect.w = temp_radius;
    outer_rect.h = temp_radius;
    outer_rect.x -= outer_rect.w / 2.0;
    outer_rect.y -= outer_rect.h / 2.0;

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .rect = outer_rect,
        .expand = .none,
        .background = true,
        .corner_radius = dvui.Rect.all(100000),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -4.0, .y = 4.0 },
            .fade = 8.0,
            .alpha = 0.35,
        },
        .color_fill = menu_color.opacity(0.75),
        .border = dvui.Rect.all(0.0),
    });

    box.deinit();

    outer_anim.deinit();

    for (0..tool_count) |i| {
        var anim = dvui.animate(@src(), .{ .duration = 100_000 + 50_000 * @as(i32, @intCast(i)), .kind = .alpha, .easing = dvui.easing.linear }, .{
            .id_extra = i,
        });
        defer anim.deinit();

        if (anim.val) |val| {
            angle += ((1 - val) * 100.0) * 0.015;
        }

        var color = dvui.themeGet().color(.control, .fill_hover);
        if (fizzy.editor.colors.file_tree_palette) |*palette| {
            color = palette.getDVUIColor(i);
        }

        const x: f32 = std.math.round(width / 2.0 + radius * std.math.cos(angle) - width / 2.0);
        const y: f32 = std.math.round(height / 2.0 + radius * std.math.sin(angle) - height / 2.0);

        const new_center = center.plus(.{ .x = x, .y = y });

        { // Draw line along pie slice
            // const line_x: f32 = std.math.round(width / 2.0 + radius * std.math.cos(angle + step / 2.0) - width / 2.0);
            // const line_y: f32 = std.math.round(height / 2.0 + radius * std.math.sin(angle + step / 2.0) - height / 2.0);

            // const new_line_center = center.plus((dvui.Point{ .x = line_x, .y = line_y }).normalize().scale(radius * 1.5, dvui.Point));

            // dvui.Path.stroke(.{ .points = &.{ center.scale(scale, dvui.Point.Physical), new_line_center.scale(scale, dvui.Point.Physical) } }, .{
            //     .color = dvui.themeGet().color(.control, .text),
            //     .thickness = 1.0,
            // });
        }

        var rect = dvui.Rect.fromPoint(new_center);

        rect.w = 40.0;
        rect.h = 40.0;
        rect.x -= rect.w / 2.0;
        rect.y -= rect.h / 2.0;

        const tool = @as(Editor.Tools.Tool, @enumFromInt(i));

        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .rect = rect,
            .id_extra = i,
            .corner_radius = dvui.Rect.all(1000.0),
            .color_fill = if (tool == editor.tools.current) dvui.themeGet().color(.content, .fill) else .transparent,
            .box_shadow = if (tool == editor.tools.current) .{
                .color = .black,
                .offset = .{ .x = -2.5, .y = 2.5 },
                .fade = 4.0,
                .alpha = 0.25,
                .corner_radius = dvui.Rect.all(1000),
            } else null,
            .padding = .all(0),
            .margin = .all(0),
        });

        {
            editor.tools.drawTooltip(tool, button.data().rectScale().r, i) catch {};
        }

        const selection_sprite = switch (editor.tools.selection_mode) {
            .box => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.box_selection_default],
            .pixel => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pixel_selection_default],
            .color => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.color_selection_default],
        };

        const sprite = switch (@as(Editor.Tools.Tool, @enumFromInt(i))) {
            .pointer => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.cursor_default],
            .pencil => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pencil_default],
            .eraser => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.eraser_default],
            .bucket => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.bucket_default],
            .selection => selection_sprite,
        };
        const size: dvui.Size = dvui.imageSize(fizzy.editor.atlas.source) catch .{ .w = 0, .h = 0 };

        const uv = dvui.Rect{
            .x = @as(f32, @floatFromInt(sprite.source[0])) / size.w,
            .y = @as(f32, @floatFromInt(sprite.source[1])) / size.h,
            .w = @as(f32, @floatFromInt(sprite.source[2])) / size.w,
            .h = @as(f32, @floatFromInt(sprite.source[3])) / size.h,
        };

        button.processEvents();
        button.drawBackground();

        var rs = button.data().contentRectScale();

        const w = @as(f32, @floatFromInt(sprite.source[2])) * rs.s;
        const h = @as(f32, @floatFromInt(sprite.source[3])) * rs.s;

        rs.r.x += (rs.r.w - w) / 2.0;
        rs.r.y += (rs.r.h - h) / 2.0;
        rs.r.w = w;
        rs.r.h = h;

        dvui.renderImage(fizzy.editor.atlas.source, rs, .{
            .uv = uv,
            .fade = 0.0,
        }) catch {
            std.log.err("Failed to render image", .{});
        };
        angle += step;

        if (button.clicked() or button.hovered()) {
            editor.tools.set(tool);
        }

        button.deinit();
    }

    { // Center play/pause button

        var anim = dvui.animate(@src(), .{ .duration = 100_000, .kind = .alpha, .easing = dvui.easing.linear }, .{
            .id_extra = tool_count + 1,
        });
        defer anim.deinit();

        var rect = dvui.Rect.fromPoint(center);

        rect.w = 40.0;
        rect.h = 40.0;
        rect.x -= rect.w / 2.0;
        rect.y -= rect.h / 2.0;

        {
            if (editor.activeFile()) |file| {
                if (dvui.buttonIcon(@src(), "Play", if (file.editor.playing) icons.tvg.entypo.pause else icons.tvg.entypo.play, .{}, .{}, .{
                    .expand = .none,
                    .corner_radius = dvui.Rect.all(1000),
                    .box_shadow = .{
                        .color = .black,
                        .offset = .{ .x = -2.5, .y = 2.5 },
                        .fade = 4.0,
                        .alpha = 0.25,
                        .corner_radius = dvui.Rect.all(1000),
                    },
                    .color_fill = dvui.themeGet().color(.control, .fill_hover),
                    .rect = rect,
                })) {
                    file.editor.playing = !file.editor.playing;
                }
            }
        }
    }
}

pub fn rebuildWorkspaces(editor: *Editor) !void {

    // Create workspaces for each grouping ID
    for (editor.open_files.values()) |*file| {
        if (!editor.workspaces.contains(file.editor.grouping)) {
            var workspace: fizzy.Editor.Workspace = .init(file.editor.grouping);
            for (editor.open_files.values()) |*f| {
                if (f.editor.grouping == file.editor.grouping) {
                    workspace.open_file_index = editor.open_files.getIndex(f.id) orelse 0;
                }
            }

            editor.workspaces.put(fizzy.app.allocator, file.editor.grouping, workspace) catch |err| {
                std.log.err("Failed to create workspace: {s}", .{@errorName(err)});
                return err;
            };
        }
    }

    // Remove workspaces that are no longer needed
    for (editor.workspaces.values()) |*workspace| {
        if (editor.workspaces.count() == 1) {
            break;
        }

        var contains: bool = false;
        for (editor.open_files.values()) |*file| {
            if (file.editor.grouping == workspace.grouping) {
                contains = true;
                break;
            }
        }

        if (!contains) {
            if (editor.open_workspace_grouping == workspace.grouping) {
                for (editor.workspaces.values()) |*w| {
                    if (w.grouping != workspace.grouping) {
                        editor.open_workspace_grouping = w.grouping;
                        break;
                    }
                }
            }

            _ = editor.workspaces.orderedRemove(workspace.grouping);
            break;
        }
    }

    // Ensure the selected file for each workspace is still valid
    for (editor.workspaces.values()) |*workspace| {
        if (editor.getFile(workspace.open_file_index)) |file| {
            if (file.editor.grouping == workspace.grouping) {
                continue;
            }
        }

        var i: usize = editor.open_files.count();
        while (i > 0) {
            i -= 1;

            if (editor.getFile(i)) |file| {
                if (file.editor.grouping == workspace.grouping) {
                    workspace.open_file_index = i;
                    break;
                }
            }
        }
    }
}

pub fn drawWorkspaces(editor: *Editor, index: usize) !dvui.App.Result {
    if (index >= editor.workspaces.count()) return .ok;

    var s = fizzy.dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = if (index == editor.workspaces.count() - 1) std.math.floatMax(f32) else 0,
        .handle_size = handle_size,
        .handle_dynamic = .{ .handle_size_max = handle_size, .distance_max = handle_dist },
    }, .{
        .expand = .both,
        .background = false,
    });
    defer s.deinit();

    const dragging = editor.panel.paned.dragging or s.dragging;

    if (!dragging) {
        if (index + 1 < editor.workspaces.count()) {
            editor.workspaces.values()[index + 1].center = (s.animating and s.split_ratio.* < 1.0) or (editor.panel.paned.animating and editor.panel.paned.split_ratio.* < 1.0);
        } else if (editor.workspaces.count() == 1) {
            editor.workspaces.values()[index].center = (editor.panel.paned.animating and editor.panel.paned.split_ratio.* < 1.0);
        }
    }

    // Ens
    if (s.collapsing and s.split_ratio.* < 0.5) {
        s.animateSplit(1.0, dvui.easing.outBack);
    }

    if (!s.dragging and !s.animating and !s.collapsing and !s.collapsed_state) {
        if (index == editor.workspaces.count() - 1) {
            if (s.split_ratio.* != 1.0) {
                s.animateSplit(1.0, dvui.easing.outBack);
            }
        } else {
            if (dvui.firstFrame(s.wd.id)) {
                s.split_ratio.* = 1.0;
                s.animateSplit(0.5, dvui.easing.outBack);
            }
        }
    }

    if (s.showFirst()) {
        const result = try editor.workspaces.values()[index].draw();
        if (result != .ok) {
            return result;
        }
    }

    if (s.showSecond()) {
        const result = try drawWorkspaces(editor, index + 1);
        if (result != .ok) {
            return result;
        }
    }

    return .ok;
}

pub fn abortSaveAllQuit(editor: *Editor) void {
    Dialogs.FlatRasterSaveWarning.pending_from_save_all_quit = false;
    editor.quit_save_all_ids.clearAndFree(fizzy.app.allocator);
    editor.quit_in_progress = false;
    editor.pending_close_file_id = null;
    editor.pending_quit_continue = false;
}

pub fn advanceSaveAllQuit(editor: *Editor) void {
    if (editor.quit_save_all_ids.items.len == 0) return;

    while (editor.quit_save_all_ids.items.len > 0) {
        const id = editor.quit_save_all_ids.items[0];
        const file_ptr = editor.open_files.getPtr(id) orelse {
            _ = editor.quit_save_all_ids.swapRemove(0);
            continue;
        };
        if (!file_ptr.dirty()) {
            _ = editor.quit_save_all_ids.swapRemove(0);
            continue;
        }

        if (editor.open_files.getIndex(id)) |idx| {
            editor.setActiveFile(idx);
        }

        if (!fizzy.Internal.File.hasRecognizedSaveExtension(file_ptr.path)) {
            editor.pending_close_file_id = id;
            editor.quit_in_progress = true;
            editor.requestSaveAs();
            return;
        }
        if (file_ptr.shouldConfirmFlatRasterSave()) {
            Dialogs.FlatRasterSaveWarning.pending_from_save_all_quit = true;
            Dialogs.FlatRasterSaveWarning.request(id, .save_and_close);
            return;
        }
        Dialogs.UnsavedClose.saveSynchronously(file_ptr) catch |err| {
            dvui.log.err("Save all quit: {s}", .{@errorName(err)});
            editor.abortSaveAllQuit();
            return;
        };
        editor.rawCloseFileID(id) catch |err| {
            dvui.log.err("Save all quit close: {s}", .{@errorName(err)});
            editor.abortSaveAllQuit();
            return;
        };
        _ = editor.quit_save_all_ids.swapRemove(0);
    }

    editor.quit_save_all_ids.clearRetainingCapacity();
    editor.quit_in_progress = false;
    editor.pending_app_close = true;
}

pub fn close(app: *App, editor: *Editor) void {
    _ = app;
    if (editor.open_files.count() == 0) {
        editor.pending_app_close = true;
        return;
    }
    var dirty_n: usize = 0;
    for (editor.open_files.values()) |f| {
        if (f.dirty()) dirty_n += 1;
    }
    if (dirty_n > 0) {
        Dialogs.AppQuitUnsaved.request();
    } else {
        editor.pending_app_close = true;
    }
}

pub fn setProjectFolder(editor: *Editor, path: []const u8) !void {
    if (editor.folder) |folder| {
        editor.ignore.deinit(fizzy.app.allocator);
        if (editor.project) |*project| {
            project.save() catch {
                dvui.log.err("Failed to save project", .{});
            };
        }
        fizzy.app.allocator.free(folder);
    }
    editor.folder = try fizzy.app.allocator.dupe(u8, path);
    try editor.recents.appendFolder(try fizzy.app.allocator.dupe(u8, path));
    editor.explorer.pane = .files;

    editor.project = Project.load(fizzy.app.allocator) catch null;
    editor.ignore = try IgnoreRules.load(fizzy.app.allocator, path);
}

pub fn saving(editor: *Editor) bool {
    for (editor.open_files.values()) |file| {
        if (file.saving) return true;
    }
    return false;
}

/// Returns true if a new file was opened.
/// The editor doesn't care what type of file is being opened,
/// File.fromPath will handle the file type
/// Open `path` if needed, set its grouping, focus it, and return its index in `open_files`.
/// If the file at `path` is already open, reassigns its grouping and returns its `open_files`
/// index. If it's not open, queues an async load with `grouping` as the target and returns
/// `null` — callers must NOT treat that case as if the file is already present, since the
/// worker hasn't landed it yet and there is no valid `open_files` index to act on. The async
/// load will auto-focus once the worker completes (see `processLoadingJobs`).
pub fn openOrFocusFileAtGrouping(editor: *Editor, path: []const u8, grouping: u64) !?usize {
    if (editor.getFileFromPath(path)) |file| {
        const idx = editor.open_files.getIndex(file.id) orelse return error.Unexpected;
        editor.open_files.values()[idx].editor.grouping = grouping;
        editor.setActiveFile(idx);
        return idx;
    }
    _ = try editor.openFilePath(path, grouping);
    return null;
}

/// After a workspace drop from the Files tree or when `tab_drag` ends; frees path and clears tree reorder stash.
pub fn clearFileTreeTabDragDropState(editor: *Editor) void {
    if (editor.tab_drag_from_tree_path) |p| {
        fizzy.app.allocator.free(p);
        editor.tab_drag_from_tree_path = null;
    }
    if (editor.file_tree_data_id) |id| {
        dvui.dataRemove(null, id, "removed_path");
    }
    // `file_tree_data_id` is reassigned each `drawFiles` frame; do not clear the id here so
    // multiple workspace `processTabDrag` calls in one frame do not race.
}

pub fn openFilePath(editor: *Editor, path: []const u8, grouping: u64) !bool {
    // Already open? Just focus it.
    for (editor.open_files.values(), 0..) |*file, i| {
        if (std.mem.eql(u8, file.path, path)) {
            editor.setActiveFile(i);
            return false;
        }
    }

    // Already loading? Mark this as the most-recent request so it gets focused on completion.
    if (editor.loading_jobs.getKey(path)) |existing_key| {
        editor.last_load_request_path = existing_key;
        return false;
    }

    // Spawn a worker. The job owns the path string we'll key the map by.
    const job = try FileLoadJob.create(fizzy.app.allocator, path, grouping);
    errdefer job.destroy();

    try editor.loading_jobs.put(fizzy.app.allocator, job.path, job);
    editor.last_load_request_path = job.path;

    const thread = std.Thread.spawn(.{}, FileLoadJob.workerMain, .{job}) catch |err| {
        _ = editor.loading_jobs.remove(job.path);
        job.destroy();
        return err;
    };
    thread.detach();

    return true;
}

/// Per-frame sweep called from `tick`. Moves completed load jobs into `open_files`, cleans up
/// failed/cancelled jobs, and focuses the most-recently-requested file as it completes.
pub fn processLoadingJobs(editor: *Editor) void {
    if (editor.loading_jobs.count() == 0) return;

    // Snapshot the job pointers because we'll be mutating the map during iteration.
    var to_remove: std.ArrayListUnmanaged(*FileLoadJob) = .empty;
    defer to_remove.deinit(fizzy.app.allocator);

    var it = editor.loading_jobs.valueIterator();
    while (it.next()) |job_ptr| {
        const job = job_ptr.*;
        if (!job.done.load(.acquire)) continue;
        to_remove.append(fizzy.app.allocator, job) catch continue;
    }

    for (to_remove.items) |job| {
        _ = editor.loading_jobs.remove(job.path);

        const phase = job.currentPhase();
        switch (phase) {
            .ready => {
                if (job.result) |result| {
                    var file = result;
                    file.editor.grouping = job.target_grouping;

                    editor.open_files.put(fizzy.app.allocator, file.id, file) catch {
                        dvui.log.err("Failed to insert loaded file into open_files: {s}", .{job.path});
                        // We still own `file` here — clean it up.
                        var f = file;
                        f.deinit();
                        job.destroy();
                        continue;
                    };

                    // Focus this file iff it's the most recently requested load. Multiple
                    // simultaneous loads only auto-focus the latest; others land silently.
                    const should_focus = editor.last_load_request_path != null and
                        std.mem.eql(u8, editor.last_load_request_path.?, job.path);
                    if (should_focus) {
                        if (editor.open_files.getIndex(file.id)) |idx| {
                            editor.setActiveFile(idx);
                            editor.last_load_request_path = null;
                        }
                        editor.pending_composite_warmup = true;
                    }
                } else {
                    dvui.log.err("Load job reported ready but result was null: {s}", .{job.path});
                }
            },
            .failed => {
                dvui.log.err("Failed to open file: {s} ({any})", .{ job.path, job.err });
            },
            .cancelled => {
                // No-op: result already discarded by the worker.
            },
            else => {
                dvui.log.err("Load job finished in unexpected phase {s}: {s}", .{ @tagName(phase), job.path });
            },
        }

        job.destroy();
    }
}

/// Kick off an async project-pack. Walks the project directory once on the main thread to
/// gather inputs: open files contribute a thread-isolated snapshot (so unsaved edits make it
/// into the pack); unopened files just contribute their paths and the worker reads them. Once
/// inputs are gathered the heavy work — pixel reduction, rect packing, atlas blit — runs on a
/// worker thread.
///
/// Rapid re-triggers (e.g. save-all-then-repack, or rapid button clicks) coalesce: any
/// in-flight jobs are cancelled before the new one spawns. The cancelled workers continue
/// running long enough to observe the flag and exit cleanly; their results are discarded by
/// `processPackJob`. Only the most recently-started job's result is installed.
pub fn startPackProject(editor: *Editor) !void {
    const root = fizzy.editor.folder orelse return;

    var inputs: std.ArrayListUnmanaged(PackJob.PackInput) = .empty;
    errdefer {
        for (inputs.items) |*input| input.deinit(fizzy.app.allocator);
        inputs.deinit(fizzy.app.allocator);
    }

    // Recurse the project directory and gather one PackInput per fizzy-extension file. Open
    // files get snapshotted now so their in-memory (possibly-dirty) state is what we pack.
    try gatherPackInputs(editor, &inputs, root);

    if (inputs.items.len == 0) return;

    // `owned_inputs` is nulled out once ownership transfers into the job, so the errdefer
    // below is a no-op on the success path and avoids the double-free of letting both this
    // and `job.destroy()` reclaim the same allocations.
    var owned_inputs: ?[]PackJob.PackInput = try inputs.toOwnedSlice(fizzy.app.allocator);
    errdefer if (owned_inputs) |o| {
        for (o) |*input| input.deinit(fizzy.app.allocator);
        fizzy.app.allocator.free(o);
    };

    // Cancel every predecessor BEFORE appending the new job. This avoids a race where a
    // predecessor publishes `done` between append and cancel: `processPackJob` walks the list
    // newest-first and would otherwise see an old non-cancelled ready job and install its
    // (stale) atlas. Cancelled predecessors are skipped during install selection.
    for (editor.pack_jobs.items) |old| {
        old.cancelled.store(true, .monotonic);
    }

    const job = try PackJob.create(fizzy.app.allocator, owned_inputs.?);
    owned_inputs = null;
    errdefer job.destroy();

    try editor.pack_jobs.append(fizzy.app.allocator, job);
    errdefer _ = editor.pack_jobs.pop();

    const thread = try std.Thread.spawn(.{}, PackJob.workerMain, .{job});
    thread.detach();
}

/// True iff there is a non-cancelled pack job in flight. Drives the explorer button's spinner
/// state without coupling the UI to the internal pack-job list.
pub fn isPackingActive(editor: *const Editor) bool {
    for (editor.pack_jobs.items) |job| {
        if (!job.cancelled.load(.monotonic) and !job.done.load(.acquire)) return true;
    }
    return false;
}

fn gatherPackInputs(
    editor: *Editor,
    inputs: *std.ArrayListUnmanaged(PackJob.PackInput),
    directory: []const u8,
) !void {
    const io = dvui.io;
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (!fizzy.Internal.File.isFizzyExtension(ext)) continue;

            const abs_path = try std.fs.path.joinZ(fizzy.app.allocator, &.{ directory, entry.name });
            // Determine whether this file is currently open. If so, snapshot it now; the
            // returned `PackFile` owns its allocations. Otherwise the worker will read it
            // from disk, so we pass the path along (transferring ownership to the input).
            if (editor.getFileFromPath(abs_path)) |open_file| {
                defer fizzy.app.allocator.free(abs_path);
                const snapshot = try PackJob.PackFile.fromOpenFile(fizzy.app.allocator, open_file);
                try inputs.append(fizzy.app.allocator, .{ .open = snapshot });
            } else {
                // Transfer ownership of the path into the input; the input deinit will free it.
                // `joinZ` produced a null-terminated slice but we only need the non-sentinel
                // bytes for `File.fromPath`; copy into a plain `[]u8` so deinit is symmetric.
                const owned_path = try fizzy.app.allocator.dupe(u8, abs_path);
                fizzy.app.allocator.free(abs_path);
                try inputs.append(fizzy.app.allocator, .{ .path = owned_path });
            }
        } else if (entry.kind == .directory) {
            const abs_path = try std.fs.path.join(fizzy.app.allocator, &.{ directory, entry.name });
            defer fizzy.app.allocator.free(abs_path);
            try gatherPackInputs(editor, inputs, abs_path);
        }
    }
}

/// Per-frame sweep called from `tick`. Reaps any pack jobs whose worker has published `done`,
/// installs the result of the newest non-cancelled job (and only that one), and discards the
/// rest. Older or cancelled jobs' results — even successful ones — are freed without affecting
/// `fizzy.packer.atlas` so coalesced re-triggers can't briefly flicker stale atlases.
pub fn processPackJob(editor: *Editor) void {
    if (editor.pack_jobs.items.len == 0) return;

    // Identify the newest (last appended) job that finished with a `.ready` result and was
    // not cancelled. Only its result is installed; older successful results are stale and
    // get discarded along with cancelled / failed ones.
    var install_index: ?usize = null;
    {
        var i = editor.pack_jobs.items.len;
        while (i > 0) {
            i -= 1;
            const job = editor.pack_jobs.items[i];
            if (!job.done.load(.acquire)) continue;
            if (job.cancelled.load(.monotonic)) continue;
            if (job.currentPhase() == .ready and job.result_atlas != null) {
                install_index = i;
                break;
            }
        }
    }

    if (install_index) |idx| {
        const job = editor.pack_jobs.items[idx];
        const new_atlas = job.result_atlas.?;
        // Free the previously-installed atlas's allocations so the new one can take its
        // place — matches the synchronous `packAndClear` cleanup ordering.
        if (fizzy.packer.atlas) |*current_atlas| {
            for (current_atlas.data.animations) |*anim| fizzy.app.allocator.free(anim.name);
            fizzy.app.allocator.free(current_atlas.data.sprites);
            fizzy.app.allocator.free(current_atlas.data.animations);
            fizzy.app.allocator.free(fizzy.image.bytes(current_atlas.source));

            current_atlas.source = new_atlas.source;
            current_atlas.data = new_atlas.data;
        } else {
            fizzy.packer.atlas = new_atlas;
        }
        job.result_consumed = true;
    }

    // Reap everything that has published `done`. Successful-but-superseded jobs leave their
    // `result_atlas` un-consumed; `destroy()` frees those allocations for us.
    var write: usize = 0;
    for (editor.pack_jobs.items) |job| {
        if (!job.done.load(.acquire)) {
            editor.pack_jobs.items[write] = job;
            write += 1;
            continue;
        }
        const phase = job.currentPhase();
        switch (phase) {
            .ready, .cancelled => {},
            .failed => dvui.log.err("Pack project failed: {any}", .{job.err}),
            else => dvui.log.err("Pack job finished in unexpected phase {s}", .{@tagName(phase)}),
        }
        job.destroy();
    }
    editor.pack_jobs.shrinkRetainingCapacity(write);
}

/// Returns the active workspace's canvas content rect (physical pixels) captured from the
/// previous frame's draw, if available. Falls back to `null` before the first workspace draw.
/// Used by `drawLoadingOverlay` / `drawSaveToasts` to center their cards over the canvas area
/// the user is currently looking at, instead of the raw OS window rect.
pub fn activeWorkspaceCanvasRectPhysical(editor: *Editor) ?dvui.Rect.Physical {
    const workspace = editor.workspaces.getPtr(editor.open_workspace_grouping) orelse return null;
    return workspace.canvas_rect_physical;
}

/// Cancel every in-flight load. Workers exit at the next cancellation checkpoint (after
/// `fromPath` returns) and discard their results. Used on app quit.
pub fn cancelAllLoadingJobs(editor: *Editor) void {
    var it = editor.loading_jobs.valueIterator();
    while (it.next()) |job_ptr| {
        job_ptr.*.cancelled.store(true, .monotonic);
    }
}

/// Iterates the save-complete toast subwindow (`fizzy.dvui.save_toast_subwindow_id`) and
/// renders each toast inside a self-sized floating column anchored to the bottom-center of
/// the viewport, so back-to-back saves stack vertically rather than overlapping. Each toast's
/// display function (`saveCompleteToastDisplay`) builds its own card body + fade-out animator
/// + self-remove on timer expiry.
pub fn drawSaveToasts(editor: *Editor) void {
    if (dvui.toastsFor(fizzy.dvui.save_toast_subwindow_id) == null) return;

    // Anchor at the center of the active workspace's canvas rect (in physical pixels). Using
    // `from` + `from_gravity = 0.5,0.5` lets the FloatingWidget self-size to the toast column
    // and centers it around the anchor. Falls back to the window center if no workspace has
    // rendered yet.
    const anchor_physical: dvui.Point.Physical = if (editor.activeWorkspaceCanvasRectPhysical()) |r| .{
        .x = r.x + r.w * 0.5,
        .y = r.y + r.h * 0.5,
    } else blk: {
        const win_pix = dvui.windowRectPixels();
        break :blk .{
            .x = win_pix.x + win_pix.w * 0.5,
            .y = win_pix.y + win_pix.h * 0.5,
        };
    };

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{
        .mouse_events = false,
        .from = anchor_physical,
        .from_gravity_x = 0.5,
        .from_gravity_y = 0.5,
    }, .{});
    defer fw.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .none });
    defer col.deinit();

    var it = dvui.toastsFor(fizzy.dvui.save_toast_subwindow_id) orelse return;
    while (it.next()) |t| {
        t.display(t.id) catch |err| {
            dvui.log.err("save toast display: {any}", .{err});
        };
    }
}

/// Centered floating card listing in-flight file loads that have been running long enough to
/// warrant UI feedback. Non-modal: the user can keep interacting with the rest of the editor.
/// Called once per frame from `tick`.
pub fn drawLoadingOverlay(editor: *Editor) void {
    if (editor.loading_jobs.count() == 0) return;

    // Skip jobs that completed in under `toast_threshold_ms` to avoid flashing the UI for
    // small files. If every in-flight job is still under the threshold, render nothing.
    const toast_threshold_ms: i64 = 150;
    var visible_count: usize = 0;
    var earliest_pending_start_ns: ?i128 = null;
    var it_count = editor.loading_jobs.valueIterator();
    while (it_count.next()) |job_ptr| {
        if (job_ptr.*.elapsedExceeds(toast_threshold_ms)) {
            visible_count += 1;
        } else {
            const start = job_ptr.*.started_at_ns;
            if (earliest_pending_start_ns == null or start < earliest_pending_start_ns.?) {
                earliest_pending_start_ns = start;
            }
        }
    }
    // If we have pending jobs that haven't crossed the threshold yet, the app would otherwise
    // sleep on the click event that started them and the overlay would never appear until some
    // unrelated input (mouse move, etc.) ticks a frame. Schedule a wakeup at the threshold
    // boundary so the overlay shows on time even with the cursor parked.
    if (earliest_pending_start_ns) |start_ns| {
        const elapsed_ms = @divTrunc(@import("../gfx/perf.zig").nanoTimestamp() - start_ns, std.time.ns_per_ms);
        const remaining_ms: i64 = toast_threshold_ms - @as(i64, @intCast(elapsed_ms));
        if (remaining_ms > 0) {
            dvui.timer(dvui.currentWindow().data().id, @intCast(remaining_ms * std.time.us_per_ms));
        } else {
            dvui.refresh(null, @src(), dvui.currentWindow().data().id);
        }
    }
    if (visible_count == 0) return;

    // Prefer centering over the active workspace's canvas rect so the toast appears where the
    // user is looking. Fall back to the OS window rect on the very first frame before any
    // workspace has drawn, or if there's no active workspace (e.g., empty app state).
    //
    // Single-line rows keep multi-file loads compact: spinner + "<basename> — <phase>…" on one
    // baseline. `row_h` is the natural-pixel height each row contributes to the card; the
    // header band adds a fixed amount on top.
    const card_w: f32 = 320;
    const row_h: f32 = 26;
    const header_h: f32 = 32;
    const card_h: f32 = header_h + @as(f32, @floatFromInt(visible_count)) * row_h;
    const card_rect: dvui.Rect = blk: {
        if (editor.activeWorkspaceCanvasRectPhysical()) |rs_phys| {
            const rs_natural = rs_phys.toNatural();
            break :blk .{
                .x = rs_natural.x + (rs_natural.w - card_w) * 0.5,
                .y = rs_natural.y + (rs_natural.h - card_h) * 0.5,
                .w = card_w,
                .h = card_h,
            };
        }
        const window_rect = dvui.windowRect();
        break :blk .{
            .x = (window_rect.w - card_w) * 0.5,
            .y = (window_rect.h - card_h) * 0.5,
            .w = card_w,
            .h = card_h,
        };
    };

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = card_rect,
        .background = true,
        // Content-fill @ 0.85 matches the look of the other dialog-style popups in the editor.
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.85),
        .corner_radius = dvui.Rect.all(8),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 12.0,
            .alpha = 0.35,
            .corner_radius = dvui.Rect.all(8),
        },
    });
    defer fw.deinit();

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer outer.deinit();

    dvui.labelNoFmt(@src(), "Loading…", .{}, .{
        .font = dvui.Font.theme(.heading),
        .color_text = dvui.themeGet().color(.content, .text),
        .padding = .{ .h = 2 },
    });

    var key_it = editor.loading_jobs.iterator();
    var entry_idx: usize = 0;
    while (key_it.next()) |entry| : (entry_idx += 1) {
        const job = entry.value_ptr.*;
        if (!job.elapsedExceeds(toast_threshold_ms)) continue;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = entry_idx,
            .expand = .horizontal,
            .padding = .{ .y = 1, .h = 1 },
        });
        defer row.deinit();

        // Single-line layout: small bubble spinner + "<basename> — <phase>…" on one baseline.
        // Keeps multi-file load lists compact (each row ~26 nat-px tall) while still showing
        // both the file identity and what's currently happening to it.
        fizzy.dvui.bubbleSpinner(@src(), .{
            .min_size_content = .{ .w = 18, .h = 18 },
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.content, .text),
            .padding = .{ .w = 8 },
        });

        const basename = std.fs.path.basename(job.path);
        const phase = job.currentPhase();
        dvui.label(@src(), "{s} — {s}…", .{ basename, FileLoadJob.phaseLabel(phase) }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.content, .text),
        });
    }
}

pub fn requestCompositeWarmup(editor: *Editor) void {
    editor.pending_composite_warmup = true;
}

pub fn newFile(editor: *Editor, path: []const u8, options: fizzy.Internal.File.InitOptions) !*fizzy.Internal.File {
    if (editor.getFileFromPath(path)) |_| {
        return error.FileAlreadyExists;
    }

    const file = fizzy.Internal.File.init(path, options) catch {
        dvui.log.err("Failed to create file: {s}", .{path});
        return error.FailedToCreateFile;
    };

    try editor.open_files.put(fizzy.app.allocator, file.id, file);
    editor.setActiveFile(editor.open_files.count() - 1);
    editor.pending_composite_warmup = true;

    return editor.open_files.getPtr(file.id) orelse return error.FailedToCreateFile;
}

/// Heap-owned path like `untitled-1`, unique among `open_files` basenames.
pub fn allocNextUntitledPath(editor: *Editor) ![]u8 {
    var max_n: u32 = 0;
    for (editor.open_files.values()) |f| {
        const base = std.fs.path.basename(f.path);
        if (std.mem.startsWith(u8, base, "untitled-")) {
            const suffix = base["untitled-".len..];
            const n = std.fmt.parseUnsigned(u32, suffix, 10) catch continue;
            max_n = @max(max_n, n);
        } else if (std.mem.eql(u8, base, "untitled")) {
            max_n = @max(max_n, 1);
        }
    }
    return std.fmt.allocPrint(fizzy.app.allocator, "untitled-{d}", .{max_n + 1});
}

/// Opens the Grid Layout dialog for the active file. Uses a custom `windowFn` that matches
/// `dialogWindow`'s open animation while capping the window to half the main window size; the
/// dialog can still be resized afterward.
/// The dialog rebinds the active file via the `_grid_layout_file_id` data slot so the form and
/// preview can survive frames where `fizzy.editor.activeFile()` momentarily returns null.
pub fn requestGridLayoutDialog(editor: *Editor) void {
    const file = editor.activeFile() orelse return;

    Dialogs.GridLayout.presetFromFile(file);

    var mutex = fizzy.dvui.dialog(@src(), .{
        .displayFn = Dialogs.GridLayout.dialog,
        .callafterFn = Dialogs.GridLayout.callAfter,
        .windowFn = Dialogs.GridLayout.windowFn,
        .title = "Grid Layout...",
        .ok_label = "Apply",
        .cancel_label = "Cancel",
        .resizeable = true,
        .header_kind = .info,
        .default = .ok,
    });
    dvui.dataSet(null, mutex.id, "_grid_layout_file_id", file.id);
    // Let `GridLayout.windowFn` run `autoSize` only until the open animation finishes; otherwise
    // `auto_size` stays true every frame and the shell snaps back to content min (user resize breaks).
    dvui.dataSet(null, mutex.id, "_grid_dialog_open_done", false);
    mutex.mutex.unlock(dvui.io);
}

/// Opens the New File dimensions dialog; on confirm, creates an in-memory `untitled-n` document (or on-disk from explorer when `_parent_path` is set).
pub fn requestNewFileDialog(_: *Editor) void {
    var mutex = fizzy.dvui.dialog(@src(), .{
        .displayFn = Dialogs.NewFile.dialog,
        .callafterFn = Dialogs.NewFile.callAfter,
        .title = "New File...",
        .ok_label = "Create",
        .cancel_label = "Cancel",
        .resizeable = false,
        .header_kind = .info,
        .default = .ok,
    });
    mutex.mutex.unlock(dvui.io);
}

pub fn setActiveFile(editor: *Editor, index: usize) void {
    if (index >= editor.open_files.values().len) return;
    const file = editor.open_files.values()[index];
    const grouping = file.editor.grouping;

    if (editor.workspaces.getPtr(grouping)) |workspace| {
        editor.open_workspace_grouping = grouping;
        workspace.open_file_index = index;
    }
}

/// Returns the actively focused file, through workspace grouping.
pub fn activeFile(editor: *Editor) ?*fizzy.Internal.File {
    if (editor.workspaces.get(editor.open_workspace_grouping)) |workspace| {
        return editor.getFile(workspace.open_file_index);
    }

    return null;
}

pub fn getFile(editor: *Editor, index: usize) ?*fizzy.Internal.File {
    if (editor.open_files.values().len == 0) return null;
    if (index >= editor.open_files.values().len) return null;

    return &editor.open_files.values()[index];
}

pub fn getFileFromPath(editor: *Editor, path: []const u8) ?*fizzy.Internal.File {
    if (editor.open_files.values().len == 0) return null;

    for (editor.open_files.values()) |*file| {
        if (std.mem.eql(u8, file.path, path)) {
            return file;
        }
    }

    return null;
}

pub fn forceCloseFile(editor: *Editor, index: usize) !void {
    if (editor.getFile(index) != null) {
        return editor.rawCloseFile(index);
    }
}

pub fn accept(editor: *Editor) !void {
    if (editor.activeFile()) |file| {
        if (file.editor.transform) |*t| {
            t.accept();
        }
    }
}

pub fn cancel(editor: *Editor) !void {
    if (editor.activeFile()) |file| {
        if (file.editor.transform) |*t| {
            t.cancel();
        }

        if (file.editor.selected_sprites.count() > 0) {
            file.clearSelectedSprites();
        }

        if (file.selected_animation_index != null) {
            file.selected_animation_index = null;
        }
    }
}

pub fn copy(editor: *Editor) !void {
    if (editor.activeFile()) |file| {
        if (file.editor.transform != null) return;

        if (editor.sprite_clipboard) |*clipboard| {
            fizzy.app.allocator.free(fizzy.image.bytes(clipboard.source));
            editor.sprite_clipboard = null;
        }

        file.editor.transform_layer.clear();

        var selected_layer = file.layers.get(file.selected_layer_index);
        switch (editor.tools.current) {
            .selection => {
                // We are in the selection tool, so we should assume that the user has painted a selection
                // into the selection layer mask, we need to copy the pixels into the transform layer itself for reducing
                var pixel_iterator = file.editor.selection_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
                while (pixel_iterator.next()) |pixel_index| {
                    @memcpy(&file.editor.transform_layer.pixels()[pixel_index], &selected_layer.pixels()[pixel_index]);
                    file.editor.transform_layer.mask.set(pixel_index);
                }
            },
            else => {
                if (file.editor.selected_sprites.count() > 0) {
                    var sprite_iterator = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                    while (sprite_iterator.next()) |index| {
                        const source_rect = file.spriteRect(index);
                        if (selected_layer.pixelsFromRect(
                            dvui.currentWindow().arena(),
                            source_rect,
                        )) |source_pixels| {
                            file.editor.transform_layer.blit(
                                source_pixels,
                                source_rect,
                                .{ .transparent = true, .mask = true },
                            );
                        }
                    }
                } else {
                    if (file.editor.canvas.hovered) {
                        if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt))) |sprite_index| {
                            const rect = file.spriteRect(sprite_index);
                            if (selected_layer.pixelsFromRect(
                                dvui.currentWindow().arena(),
                                rect,
                            )) |source_pixels| {
                                file.editor.transform_layer.blit(
                                    source_pixels,
                                    rect,
                                    .{ .transparent = true, .mask = true },
                                );
                            }
                        }
                    } else if (file.selected_animation_index) |animation_index| {
                        const animation = file.animations.get(animation_index);
                        if (file.selected_animation_frame_index < animation.frames.len) {
                            const rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
                            if (selected_layer.pixelsFromRect(
                                dvui.currentWindow().arena(),
                                rect,
                            )) |source_pixels| {
                                file.editor.transform_layer.blit(
                                    source_pixels,
                                    rect,
                                    .{ .transparent = true, .mask = true },
                                );
                            }
                        }
                    }
                }
            },
        }

        const source_rect = dvui.Rect.fromSize(file.editor.transform_layer.size());
        if (file.editor.transform_layer.reduce(source_rect)) |reduced_data_rect| {
            const sprite_tl = file.spritePoint(reduced_data_rect.topLeft());

            editor.sprite_clipboard = .{
                .source = fizzy.image.fromPixelsPMA(
                    @ptrCast(file.editor.transform_layer.pixelsFromRect(fizzy.app.allocator, reduced_data_rect)),
                    @intFromFloat(reduced_data_rect.w),
                    @intFromFloat(reduced_data_rect.h),
                    .ptr,
                ) catch return error.MemoryAllocationFailed,
                .offset = reduced_data_rect.topLeft().diff(sprite_tl),
            };

            // Show a toast so its evident a copy action was completed
            {
                const id_mutex = dvui.toastAdd(dvui.currentWindow(), @src(), 0, file.editor.canvas.id, fizzy.dvui.toastDisplay, 2_000_000);
                const id = id_mutex.id;
                const message = std.fmt.allocPrint(dvui.currentWindow().arena(), "Copied selection", .{}) catch "Copied selection.";
                dvui.dataSetSlice(dvui.currentWindow(), id, "_message", message);
                id_mutex.mutex.unlock(dvui.io);
            }
        }
    }
}

pub fn paste(editor: *Editor) !void {
    if (editor.sprite_clipboard) |*clipboard| {
        if (editor.activeFile()) |file| {
            const active_layer = file.layers.get(file.selected_layer_index);

            var dst_rect: dvui.Rect = .fromSize(fizzy.image.size(clipboard.source));

            var sprite_iterator = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
            while (sprite_iterator.next()) |sprite_index| {
                const sprite_rect = file.spriteRect(sprite_index);

                dst_rect.x = sprite_rect.x + clipboard.offset.x;
                dst_rect.y = sprite_rect.y + clipboard.offset.y;

                file.editor.transform = .{
                    .target_texture = dvui.textureCreateTarget(file.width(), file.height(), .nearest, .rgba_8_8_8_8) catch {
                        dvui.log.err("Failed to create target texture", .{});
                        return;
                    },
                    .file_id = file.id,
                    .layer_id = active_layer.id,
                    .data_points = .{
                        dst_rect.topLeft(),
                        dst_rect.topRight(),
                        dst_rect.bottomRight(),
                        dst_rect.bottomLeft(),
                        dst_rect.center(),
                        dst_rect.center(),
                    },
                    .source = clipboard.source,
                };

                for (file.editor.transform.?.data_points[0..4]) |*point| {
                    const d = point.diff(file.editor.transform.?.point(.pivot).*);
                    if (d.length() > file.editor.transform.?.radius) {
                        file.editor.transform.?.radius = d.length() + 4;
                    }
                }

                return;
            }

            dst_rect.x = clipboard.offset.x;
            dst_rect.y = clipboard.offset.y;

            if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt))) |sprite_index| {
                const rect = file.spriteRect(sprite_index);
                dst_rect.x = rect.x + clipboard.offset.x;
                dst_rect.y = rect.y + clipboard.offset.y;
            } else if (file.selected_animation_index) |animation_index| {
                const animation = file.animations.get(animation_index);

                if (file.selected_animation_frame_index < animation.frames.len) {
                    const rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
                    dst_rect.x = rect.x + clipboard.offset.x;
                    dst_rect.y = rect.y + clipboard.offset.y;

                    file.editor.transform = .{
                        .target_texture = dvui.textureCreateTarget(file.width(), file.height(), .nearest, .rgba_8_8_8_8) catch {
                            dvui.log.err("Failed to create target texture", .{});
                            return;
                        },
                        .file_id = file.id,
                        .layer_id = active_layer.id,
                        .data_points = .{
                            dst_rect.topLeft(),
                            dst_rect.topRight(),
                            dst_rect.bottomRight(),
                            dst_rect.bottomLeft(),
                            dst_rect.center(),
                            dst_rect.center(),
                        },
                        .source = clipboard.source,
                    };

                    for (file.editor.transform.?.data_points[0..4]) |*point| {
                        const d = point.diff(file.editor.transform.?.point(.pivot).*);
                        if (d.length() > file.editor.transform.?.radius) {
                            file.editor.transform.?.radius = d.length() + 4;
                        }
                    }

                    return;
                }
            }

            file.editor.transform = .{
                .target_texture = dvui.textureCreateTarget(file.width(), file.height(), .nearest, .rgba_8_8_8_8) catch {
                    dvui.log.err("Failed to create target texture", .{});
                    return;
                },
                .file_id = file.id,
                .layer_id = active_layer.id,
                .data_points = .{
                    dst_rect.topLeft(),
                    dst_rect.topRight(),
                    dst_rect.bottomRight(),
                    dst_rect.bottomLeft(),
                    dst_rect.center(),
                    dst_rect.center(),
                },
                .source = clipboard.source,
            };

            for (file.editor.transform.?.data_points[0..4]) |*point| {
                const d = point.diff(file.editor.transform.?.point(.pivot).*);
                if (d.length() > file.editor.transform.?.radius) {
                    file.editor.transform.?.radius = d.length() + 4;
                }
            }
        }
    }
}

pub fn deleteSelectedContents(editor: *Editor) void {
    if (editor.activeFile()) |file| {
        file.deleteSelectedContents();
    }
}

/// Begins a transform operation on the currently active file.
pub fn transform(editor: *Editor) !void {
    if (editor.activeFile()) |file| {
        if (file.editor.transform) |*t| {
            t.cancel();
        }

        var selected_layer = file.layers.get(file.selected_layer_index);

        switch (editor.tools.current) {
            .selection => {
                file.editor.transform_layer.clear();
                // We are in the selection tool, so we should assume that the user has painted a selection
                // into the selection layer mask, we need to copy the pixels into the transform layer itself for reducing
                var pixel_iterator = file.editor.selection_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
                while (pixel_iterator.next()) |pixel_index| {
                    @memcpy(&file.editor.transform_layer.pixels()[pixel_index], &selected_layer.pixels()[pixel_index]);
                    selected_layer.pixels()[pixel_index] = .{ 0, 0, 0, 0 };
                    file.editor.transform_layer.mask.set(pixel_index);
                }
                selected_layer.invalidate();
            },
            else => {
                // Current tool is the pointer, so we potentially have a sprite selection in
                // selected sprites that we need to copy to the selection layer.
                file.editor.transform_layer.clear();

                if (file.editor.selected_sprites.count() > 0) {
                    var sprite_iterator = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });

                    while (sprite_iterator.next()) |index| {
                        const source_rect = file.spriteRect(index);
                        if (selected_layer.pixelsFromRect(
                            dvui.currentWindow().arena(),
                            source_rect,
                        )) |source_pixels| {
                            file.editor.transform_layer.blit(
                                source_pixels,
                                source_rect,
                                .{ .transparent = true, .mask = true },
                            );
                            selected_layer.clearRect(source_rect);
                        }
                    }
                } else {
                    if (file.editor.canvas.hovered) {
                        if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt))) |sprite_index| {
                            const rect = file.spriteRect(sprite_index);
                            if (selected_layer.pixelsFromRect(
                                dvui.currentWindow().arena(),
                                rect,
                            )) |source_pixels| {
                                file.editor.transform_layer.blit(
                                    source_pixels,
                                    rect,
                                    .{ .transparent = true, .mask = true },
                                );
                                selected_layer.clearRect(rect);
                            }
                        }
                    } else if (file.selected_animation_index) |animation_index| {
                        const animation = file.animations.get(animation_index);
                        if (file.selected_animation_frame_index < animation.frames.len) {
                            const source_rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
                            if (selected_layer.pixelsFromRect(
                                dvui.currentWindow().arena(),
                                source_rect,
                            )) |source_pixels| {
                                file.editor.transform_layer.blit(
                                    source_pixels,
                                    source_rect,
                                    .{ .transparent = true, .mask = true },
                                );
                                selected_layer.clearRect(source_rect);
                            }
                        }
                    }
                }
            },
        }

        // We now have a transform layer that contains:
        // 1. the unaltered colored pixels of the active transform
        // 2. a mask containing bits for the pixels of the selection being transformed
        const source_rect = dvui.Rect.fromSize(file.editor.transform_layer.size());
        if (file.editor.transform_layer.reduce(source_rect)) |reduced_data_rect| {
            defer file.editor.selection_layer.clearMask();
            file.editor.transform = .{
                .target_texture = dvui.textureCreateTarget(file.width(), file.height(), .nearest, .rgba_8_8_8_8) catch {
                    dvui.log.err("Failed to create target texture", .{});
                    return;
                },
                .file_id = file.id,
                .layer_id = selected_layer.id,
                .data_points = .{
                    reduced_data_rect.topLeft(),
                    reduced_data_rect.topRight(),
                    reduced_data_rect.bottomRight(),
                    reduced_data_rect.bottomLeft(),
                    reduced_data_rect.center(),
                    reduced_data_rect.center(), // This point constantly moves
                },
                .source = fizzy.image.fromPixelsPMA(
                    @ptrCast(file.editor.transform_layer.pixelsFromRect(fizzy.app.allocator, reduced_data_rect)),
                    @intFromFloat(reduced_data_rect.w),
                    @intFromFloat(reduced_data_rect.h),
                    .ptr,
                ) catch return error.MemoryAllocationFailed,
            };

            for (file.editor.transform.?.data_points[0..4]) |*point| {
                const d = point.diff(file.editor.transform.?.point(.pivot).*);
                if (d.length() > file.editor.transform.?.radius) {
                    file.editor.transform.?.radius = d.length() + 4;
                }
            }
        }
    }
}

/// Performs a save operation on the currently open file.
/// Paths without a recognized on-disk extension (e.g. in-memory `untitled-n`) open Save As instead.
pub fn save(editor: *Editor) !void {
    const file = editor.activeFile() orelse return;
    if (!fizzy.Internal.File.hasRecognizedSaveExtension(file.path)) {
        editor.requestSaveAs();
        return;
    }
    if (file.shouldConfirmFlatRasterSave()) {
        Dialogs.FlatRasterSaveWarning.request(file.id, .editor_save);
        return;
    }
    try file.saveAsync();
}

const save_as_dialog_filters: [3]sdl3.SDL_DialogFileFilter = .{
    .{ .name = "fizzy", .pattern = "fiz;pixi" },
    .{ .name = "PNG", .pattern = "png" },
    .{ .name = "JPEG", .pattern = "jpg;jpeg" },
};

/// Opens a Save As dialog: `.fiz` (all layers; `.pixi` also accepted for legacy) or flat `.png` / `.jpg` / `.jpeg` (visible layers composited).
pub fn requestSaveAs(_: *Editor) void {
    const active = fizzy.editor.activeFile() orelse return;
    const def = fizzy.Internal.File.defaultSaveAsFilename(fizzy.app.allocator, active.path) catch {
        std.log.err("Failed to build default save-as name", .{});
        return;
    };
    defer fizzy.app.allocator.free(def);
    const current_file_dir: ?[]const u8 = std.fs.path.dirname(active.path);
    fizzy.backend.showSaveFileDialog(saveAsDialogCallback, &save_as_dialog_filters, def, current_file_dir);
}

/// Save dialog may invoke this from AppKit outside `Window.begin` / `end`; do not use `currentWindow` here.
pub fn saveAsDialogCallback(paths: ?[][:0]const u8) void {
    if (paths == null) {
        if (fizzy.editor.pending_close_file_id) |_| {
            fizzy.editor.pending_close_file_id = null;
            if (fizzy.editor.quit_save_all_ids.items.len > 0) {
                fizzy.editor.abortSaveAllQuit();
            }
        }
        return;
    }
    const p = paths.?;
    if (p.len == 0) return;
    const path0 = p[0];
    if (path0.len == 0) return;
    if (fizzy.editor.pending_save_as_path) |old| {
        fizzy.app.allocator.free(old);
    }
    fizzy.editor.pending_save_as_path = fizzy.app.allocator.dupe(u8, path0[0..path0.len]) catch {
        dvui.log.err("Save As: out of memory queuing path", .{});
        return;
    };
}

fn processPendingSaveAs(editor: *Editor) void {
    const path = editor.pending_save_as_path orelse return;
    editor.pending_save_as_path = null;
    defer fizzy.app.allocator.free(path);

    const ext = std.fs.path.extension(path);
    const file = editor.activeFile() orelse {
        editor.pending_close_file_id = null;
        return;
    };

    const saved: bool = blk: {
        if (fizzy.Internal.File.isFizzyExtension(ext)) {
            file.saveAsFizzy(path, dvui.currentWindow()) catch |err| {
                dvui.log.err("Save As: {any}", .{err});
                break :blk false;
            };
        } else if (std.mem.eql(u8, ext, ".png") or
            std.mem.eql(u8, ext, ".jpg") or
            std.mem.eql(u8, ext, ".jpeg"))
        {
            file.saveAsFlattened(path, dvui.currentWindow()) catch |err| {
                dvui.log.err("Save As: {any}", .{err});
                break :blk false;
            };
        } else {
            dvui.log.err("Save As: choose extension .fiz, .png, .jpg, or .jpeg (got {s})", .{ext});
            break :blk false;
        }
        break :blk true;
    };
    if (!saved) return;

    if (editor.pending_close_file_id) |cid| {
        if (file.id == cid) {
            editor.pending_close_file_id = null;
            editor.rawCloseFileID(cid) catch |err| {
                dvui.log.err("Failed to close file after Save As: {s}", .{@errorName(err)});
            };
            if (editor.quit_save_all_ids.items.len > 0) {
                if (std.mem.indexOfScalar(u64, editor.quit_save_all_ids.items, cid)) |ix| {
                    _ = editor.quit_save_all_ids.swapRemove(ix);
                }
                editor.pending_quit_continue = true;
            }
        }
    }
}

pub fn undo(editor: *Editor) !void {
    if (editor.activeFile()) |file| {
        try file.history.undoRedo(file, .undo);
    }
}

pub fn redo(editor: *Editor) !void {
    if (editor.activeFile()) |file| {
        try file.history.undoRedo(file, .redo);
    }
}

pub fn openInFileBrowser(_: *Editor, path: []const u8) !void {
    const cmd = if (builtin.os.tag == .macos) "open" else if (builtin.os.tag == .linux) "xdg-open" else "start";
    _ = std.process.run(fizzy.app.allocator, dvui.io, .{ .argv = &.{ cmd, path } }) catch {
        dvui.log.err("Failed to open file browser", .{});
        return;
    };
}

pub fn closeFileID(editor: *Editor, id: u64) !void {
    if (editor.open_files.get(id)) |file| {
        if (file.dirty()) {
            Dialogs.UnsavedClose.request(id);
            return;
        }
        try editor.rawCloseFileID(id);
    }
}

pub fn closeFile(editor: *Editor, index: usize) !void {
    const file = editor.open_files.values()[index];
    try editor.closeFileID(file.id);
}

pub fn rawCloseFile(editor: *Editor, index: usize) !void {
    //editor.open_file_index = 0;
    var file = editor.open_files.values()[index];

    if (editor.workspaces.getPtr(file.editor.grouping)) |workspace| {
        if (workspace.open_file_index == fizzy.editor.open_files.getIndex(file.id)) {
            for (fizzy.editor.open_files.values(), 0..) |f, i| {
                if (f.grouping == workspace.grouping and f.id != file.id) {
                    workspace.open_file_index = i;
                    break;
                }
            }
        }
    }

    file.deinit();
    editor.open_files.orderedRemoveAt(index);
}

pub fn rawCloseFileID(editor: *Editor, id: u64) !void {
    if (editor.open_files.getPtr(id)) |file| {

        //editor.open_file_index = 0;
        if (editor.workspaces.getPtr(file.editor.grouping)) |workspace| {
            if (workspace.open_file_index == fizzy.editor.open_files.getIndex(file.id)) {
                for (fizzy.editor.open_files.values(), 0..) |f, i| {
                    if (f.editor.grouping == workspace.grouping and f.id != file.id) {
                        workspace.open_file_index = i;
                        break;
                    }
                }
            }
        }
        file.deinit();
        _ = editor.open_files.orderedRemove(id);
    }
}

pub fn closeReference(editor: *Editor, index: usize) !void {
    editor.open_reference_index = 0;
    var reference: fizzy.Internal.Reference = editor.open_references.orderedRemove(index);
    reference.deinit();
}

pub fn deinit(editor: *Editor) !void {
    // Signal cancel to any in-flight load workers. They check the flag after `fromPath` returns
    // and discard the result; we can't synchronously join them without blocking quit, so we
    // accept a brief window where a worker may still be running with a discardable result.
    // The detached threads' allocations are short-lived (heap file structs); leaking them on
    // hard quit is acceptable here.
    editor.cancelAllLoadingJobs();
    // Drop our bookkeeping for the jobs. Worker threads still own their result memory until
    // they observe the cancellation and discard it; the process is exiting anyway.
    {
        var it = editor.loading_jobs.valueIterator();
        while (it.next()) |job_ptr| {
            // Detached worker still references the job. Leak the FileLoadJob struct on quit
            // — better than a use-after-free if the worker hasn't yet observed cancellation.
            _ = job_ptr;
        }
        editor.loading_jobs.deinit(fizzy.app.allocator);
    }

    for (editor.pack_jobs.items) |job| {
        // Detached workers still reference each job. Signal cancellation and leak the structs
        // on hard quit — better than a use-after-free if a worker hasn't yet observed it.
        job.cancelled.store(true, .monotonic);
    }
    editor.pack_jobs.deinit(fizzy.app.allocator);

    if (editor.tab_drag_from_tree_path) |p| {
        fizzy.app.allocator.free(p);
        editor.tab_drag_from_tree_path = null;
    }

    if (editor.pending_save_as_path) |p| {
        fizzy.app.allocator.free(p);
        editor.pending_save_as_path = null;
    }

    editor.quit_save_all_ids.deinit(fizzy.app.allocator);

    if (editor.colors.palette) |*palette| palette.deinit();
    if (editor.colors.file_tree_palette) |*palette| palette.deinit();

    editor.recents.save(fizzy.app.allocator, try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "recents.json" })) catch {
        dvui.log.err("Failed to save recents", .{});
    };
    editor.recents.deinit(fizzy.app.allocator);

    try saveSettingsRaw(editor);
    if (editor.settings_last_saved_json) |blob| {
        fizzy.app.allocator.free(blob);
        editor.settings_last_saved_json = null;
    }
    editor.settings.deinit(fizzy.app.allocator);

    if (editor.project) |*project| {
        project.save() catch {
            dvui.log.err("Failed to save project file", .{});
        };
        project.deinit(fizzy.app.allocator);
    }

    editor.explorer.deinit();

    editor.tools.deinit(fizzy.app.allocator);

    editor.ignore.deinit(fizzy.app.allocator);

    if (editor.folder) |folder| fizzy.app.allocator.free(folder);
    editor.arena.deinit();
}
