const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Editor = fizzy.Editor;
const settings = fizzy.settings;
const zstbi = @import("zstbi");
const builtin = @import("builtin");

pub var mouse_distance: f32 = std.math.floatMax(f32);

pub fn draw() !dvui.App.Result {
    const bg_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .color_fill = dvui.themeGet().color(.control, .fill) });
    defer bg_box.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    const current_highlight_style = dvui.themeGet().highlight;
    var theme = dvui.themeGet();
    theme.highlight.fill = theme.color(.control, .fill_hover);
    dvui.themeSet(theme);
    defer {
        theme.highlight = current_highlight_style;
        dvui.themeSet(theme);
    }

    if (menuItem(@src(), "File", .{ .submenu = true }, .{
        .expand = .horizontal,
        //.color_accent = dvui.themeGet().color(.window, .fill),
        .color_text = dvui.themeGet().color(.control, .text),
    })) |r| {
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{
            .expand = .both,
        });
        defer animator.deinit();

        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemWithHotkey(@src(), "Open Folder", dvui.currentWindow().keybinds.get("open_folder") orelse .{}, true, .{}, .{
            .expand = .horizontal,
            //.style = .control,
        }) != null) {
            if (try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{ .title = "Open Project Folder" })) |folder| {
                try fizzy.editor.setProjectFolder(folder);
            }
            fw.close();
        }

        if (menuItemWithHotkey(@src(), "New File…", dvui.currentWindow().keybinds.get("new_file") orelse .{}, true, .{}, .{
            .expand = .horizontal,
        }) != null) {
            fizzy.editor.requestNewFileDialog();
            fw.close();
        }

        if (menuItemWithHotkey(@src(), "Open Files", dvui.currentWindow().keybinds.get("open_files") orelse .{}, true, .{}, .{
            .expand = .horizontal,
            //.style = .control,
        }) != null) {
            if (try dvui.dialogNativeFileOpenMultiple(dvui.currentWindow().arena(), .{
                .title = "Open Files...",
                .filter_description = ".fiz, .pixi, .png, .jpg, .jpeg",
                .filters = &.{ "*.fiz", "*.pixi", "*.png", "*.jpg", "*.jpeg" },
            })) |files| {
                for (files) |file| {
                    _ = fizzy.editor.openFilePath(file, fizzy.editor.open_workspace_grouping) catch {
                        std.log.err("Failed to open file: {s}", .{file});
                    };
                }
            }
            fw.close();
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItemWithChevron(
            @src(),
            "Recent Folders",
            .{ .submenu = true },
            .{
                .expand = .horizontal,
                .color_text = dvui.themeGet().color(.window, .text),
                //.style = .control,
            },
        )) |recents_item| {
            var recents_anim = dvui.animate(@src(), .{
                .kind = .alpha,
                .duration = 250_000,
            }, .{
                .expand = .both,
            });
            defer recents_anim.deinit();

            var recents_fw = dvui.floatingMenu(@src(), .{ .from = recents_item }, .{});
            defer recents_fw.deinit();

            var vert_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .none,
            });
            defer vert_box.deinit();

            var i: usize = fizzy.editor.recents.folders.items.len;
            while (i > 0) : (i -= 1) {
                const folder = fizzy.editor.recents.folders.items[i - 1];
                if (menuItem(@src(), folder, .{}, .{
                    .expand = .horizontal,
                    .font = dvui.Font.theme(.mono).larger(-2.0),
                    .id_extra = i,
                    .margin = dvui.Rect.all(1),
                    .padding = dvui.Rect.all(2),
                })) |_| {
                    try fizzy.editor.setProjectFolder(folder);
                }
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItemWithHotkey(@src(), "Save", dvui.currentWindow().keybinds.get("save") orelse .{}, if (fizzy.editor.activeFile()) |file|
            (file.dirty() or !fizzy.Internal.File.hasRecognizedSaveExtension(file.path))
        else
            false, .{}, .{
            .expand = .horizontal,
            .color_text = dvui.themeGet().color(.window, .text),
        }) != null) {
            fizzy.editor.save() catch {
                std.log.err("Failed to save", .{});
            };
            fw.close();
        }

        if (menuItemWithHotkey(@src(), "Save As…", dvui.currentWindow().keybinds.get("save_as") orelse .{}, fizzy.editor.activeFile() != null, .{}, .{
            .expand = .horizontal,
            .color_text = dvui.themeGet().color(.window, .text),
        }) != null) {
            fizzy.editor.requestSaveAs();
            fw.close();
        }
    }

    if (menuItem(
        @src(),
        "Edit",
        .{ .submenu = true },
        .{
            .expand = .horizontal,
            .color_text = dvui.themeGet().color(.control, .text),
            //.style = .control,
        },
    )) |r| {
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{
            .expand = .both,
        });
        defer animator.deinit();

        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemWithHotkey(
            @src(),
            "Copy",
            dvui.currentWindow().keybinds.get("copy") orelse .{},
            if (fizzy.editor.activeFile() != null) true else false,
            .{},
            .{ .expand = .horizontal },
        ) != null) {
            if (fizzy.editor.activeFile() != null) {
                fizzy.editor.copy() catch {
                    std.log.err("Failed to copy", .{});
                };
                fw.close();
            }
        }

        if (menuItemWithHotkey(
            @src(),
            "Paste",
            dvui.currentWindow().keybinds.get("paste") orelse .{},
            if (fizzy.editor.activeFile() != null) true else false,
            .{},
            .{ .expand = .horizontal },
        ) != null) {
            if (fizzy.editor.activeFile() != null) {
                fizzy.editor.paste() catch {
                    std.log.err("Failed to paste", .{});
                };
                fw.close();
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItemWithHotkey(
            @src(),
            "Undo",
            dvui.currentWindow().keybinds.get("undo") orelse .{},
            if (fizzy.editor.activeFile()) |file| if (file.history.undo_stack.items.len > 0) true else false else false,
            .{},
            .{ .expand = .horizontal },
        ) != null) {
            if (fizzy.editor.activeFile()) |file| {
                file.history.undoRedo(file, .undo) catch {
                    std.log.err("Failed to undo", .{});
                };
            }
        }

        if (menuItemWithHotkey(
            @src(),
            "Redo",
            dvui.currentWindow().keybinds.get("redo") orelse .{},
            if (fizzy.editor.activeFile()) |file| if (file.history.redo_stack.items.len > 0) true else false else false,
            .{},
            .{ .expand = .horizontal },
        ) != null) {
            if (fizzy.editor.activeFile()) |file| {
                file.history.undoRedo(file, .redo) catch {
                    std.log.err("Failed to redo", .{});
                };
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItemWithHotkey(
            @src(),
            "Transform",
            dvui.currentWindow().keybinds.get("transform") orelse .{},
            if (fizzy.editor.activeFile() != null) true else false,
            .{},
            .{ .expand = .horizontal },
        ) != null) {
            if (fizzy.editor.activeFile() != null) {
                fizzy.editor.transform() catch {
                    std.log.err("Failed to transform", .{});
                };
                fw.close();
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItemWithHotkey(
            @src(),
            "Grid Layout…",
            dvui.currentWindow().keybinds.get("grid_layout") orelse .{},
            if (fizzy.editor.activeFile() != null) true else false,
            .{},
            .{ .expand = .horizontal },
        ) != null) {
            if (fizzy.editor.activeFile() != null) {
                fizzy.editor.requestGridLayoutDialog();
                fw.close();
            }
        }
    }

    if (menuItem(@src(), "View", .{ .submenu = true }, .{
        .expand = .horizontal,
        .color_text = dvui.themeGet().color(.control, .text),
    })) |r| {
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{
            .expand = .both,
        });
        defer animator.deinit();

        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItemWithHotkey(
            @src(),
            if (fizzy.editor.explorer.paned.split_ratio.* == 0.0) "Show Explorer" else "Hide Explorer",
            dvui.currentWindow().keybinds.get("explorer") orelse .{},
            true,
            .{},
            .{
                .expand = .horizontal,
            },
        ) != null) {
            if (fizzy.editor.explorer.paned.split_ratio.* == 0.0) {
                fizzy.editor.explorer.open();
            } else {
                fizzy.editor.explorer.close();
            }

            fw.close();
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItem(@src(), "Show DVUI Demo", .{}, .{ .expand = .horizontal }) != null) {
            dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
            fw.close();
        }
    }

    // Help — matches the macOS native Help menu so the two menubars stay congruent.
    if (menuItem(@src(), "Help", .{ .submenu = true }, .{
        .expand = .horizontal,
        .color_text = dvui.themeGet().color(.control, .text),
    })) |r| {
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{
            .expand = .both,
        });
        defer animator.deinit();

        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (menuItem(@src(), "Check for Updates…", .{}, .{ .expand = .horizontal }) != null) {
            // The AboutFizzy dialog hosts the actual update check + install controls.
            // macOS routes "About fizzy" to the same dialog via the native Help menu;
            // here we only expose the update entry to avoid duplicating it.
            fizzy.Editor.Dialogs.AboutFizzy.request();
            fw.close();
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (menuItem(@src(), "Report Bug…", .{}, .{ .expand = .horizontal }) != null) {
            _ = dvui.openURL(.{ .url = "https://github.com/foxnne/fizzy/issues" });
            fw.close();
        }
    }

    return .ok;
}

pub fn menuItemWithHotkey(src: std.builtin.SourceLocation, label_str: []const u8, hotkey: dvui.enums.Keybind, enabled: bool, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    fizzy.dvui.labelWithKeybind(label_str, hotkey, enabled, opts, opts);

    mi.deinit();

    return ret;
}

pub fn menuItem(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);

    if (fizzy.dvui.hovered(mi.data())) {
        label_opts.color_text = dvui.themeGet().color(.window, .text);
    }

    dvui.labelNoFmt(@src(), label_str, .{}, label_opts);

    // Register top-level menu items as interactive rects on Windows so clicks land on the item
    // instead of dragging the window. We only push items that overlap the title bar strip — submenu
    // items rendered inside floatingMenu are below the strip and don't need registering.
    if (builtin.os.tag == .windows) {
        const r = mi.data().rectScale().r;
        const strip_h = (fizzy.editor.settings.titlebar_top_buffer + fizzy.editor.settings.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    mi.deinit();

    return ret;
}

pub fn menuItemWithChevron(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);

    if (fizzy.dvui.hovered(mi.data())) {
        label_opts.color_text = dvui.themeGet().color(.window, .text);
    }

    dvui.labelNoFmt(@src(), label_str, .{}, label_opts);

    dvui.icon(@src(), "chevron_right", dvui.entypo.chevron_small_right, .{
        .stroke_color = dvui.themeGet().color(.control, .text).opacity(0.5),
        .fill_color = dvui.themeGet().color(.control, .text).opacity(0.5),
    }, .{
        .expand = .none,
        .gravity_x = 1.0,
        .gravity_y = 0.5,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });

    mi.deinit();

    return ret;
}
