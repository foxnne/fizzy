const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const Editor = fizzy.Editor;
const builtin = @import("builtin");

const icons = @import("icons");

const nfd = @import("nfd");
const zstbi = @import("zstbi");

pub var tree_removed_path: ?[]const u8 = null;
pub var selected_id: ?usize = null;
pub var edit_id: ?usize = null;

/// Multi-selection for the file tree. Maps `id_extra` (hash of absolute path) to the heap-owned
/// absolute path string. The primary `selected_id` is always a key here when set. Paths are
/// allocated from `fizzy.app.allocator` so they outlive the dvui arena used during draw.
pub var selected_paths: std.AutoArrayHashMapUnmanaged(usize, []u8) = .empty;
pub var selection_anchor: ?usize = null;

/// Visible file/folder rows in depth-first tree order for the current frame (shift-range selection).
const FileVisRow = struct { id: usize, path: []const u8 };
var visible_file_rows_order: std.ArrayListUnmanaged(FileVisRow) = .empty;

/// Shift-range uses row order built incrementally during draw; applying mid-traverse misses the anchor
/// when it appears later in DFS than the clicked row. Flush after the tree pass completes.
var pending_file_shift_range: ?struct {
    anchor_id: usize,
    clicked_id: usize,
    clicked_path: []const u8,
} = null;

/// Set from New File dialog when creating on disk; tree uses this to expand parents, focus rename, and set `new_file_close_rect`.
pub var new_file_path: ?[]const u8 = null;
/// When set, the dialog animates into this rect (explorer row) then closes.
pub var new_file_close_rect: ?dvui.Rect.Physical = null;

const open_message = if (builtin.os.tag == .macos) "Reveal in Finder" else "Reveal in File Browser";

pub const Extension = enum {
    unsupported,
    hidden,
    fizzy,
    atlas,
    png,
    jpg,
    pdf,
    psd,
    aseprite,
    pyxel,
    json,
    zig,
    txt,
    zip,
    _7z,
    tar,
    gif,
};

pub fn draw() !void {
    // `tab_drag` matches workspace tab strips so file rows can drop on the canvas like tabs (DVUI reorder_tree cross-widget pattern).
    var tree = fizzy.dvui.TreeWidget.tree(@src(), .{ .enable_reordering = true, .drag_name = "tab_drag" }, .{ .background = false, .expand = .both });
    defer tree.deinit();

    // Same as tools pane header: first frame after open (or after Files wasn't drawn last frame)
    // lacks published min sizes; clip until layout settles.
    const files_tree_settling = dvui.firstFrame(tree.data().id);
    const prev_clip: ?dvui.Rect.Physical = if (files_tree_settling)
        dvui.clip(.{ .x = 0, .y = 0, .w = 0, .h = 0 })
    else
        null;
    defer if (prev_clip) |p| dvui.clipSet(p);

    // Multi-drag uses this id list; descendants are omitted when a selected parent folder is dragged too.
    // Safe as long as `selected_paths` isn't mutated between now and `tree.deinit`.
    tree.selected_branch_ids = selectionBranchIdsForMultiDrag(dvui.currentWindow().arena()) catch selected_paths.keys();

    if (fizzy.editor.folder) |path| {
        try drawFiles(path, tree);
    } else {
        fizzy.editor.file_tree_data_id = null;
        dvui.labelNoFmt(
            @src(),
            "Open a project folder to begin.",
            .{},
            .{ .color_text = dvui.themeGet().color(.control, .text) },
        );

        if (dvui.button(@src(), "Open Folder", .{ .draw_focus = false }, .{ .expand = .horizontal, .style = .highlight })) {
            if (try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{ .title = "Open Project Folder" })) |folder| {
                try fizzy.editor.setProjectFolder(folder);
            }
        }
    }
}

pub fn drawFiles(path: []const u8, tree: *fizzy.dvui.TreeWidget) !void {
    const unique_id = dvui.parentGet().extendId(@src(), 0);
    fizzy.editor.file_tree_data_id = unique_id;

    var filter_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    dvui.icon(
        @src(),
        "FilterIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = dvui.themeGet().color(.window, .text) },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );
    const filter_text_edit = dvui.textEntry(@src(), .{ .placeholder = "Filter..." }, .{
        .expand = .horizontal,
        .background = false,
    });
    const filter_text = filter_text_edit.getText();
    filter_text_edit.deinit();
    filter_hbox.deinit();

    const folder = std.fs.path.basename(path);

    const branch = tree.branch(@src(), .{
        .expanded = true,
        .animation_duration = 450_000,
        .animation_easing = dvui.easing.outBack,
    }, .{
        .id_extra = 0,
        .expand = .horizontal,
        .color_fill = .transparent,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(1),
    });
    defer branch.deinit();

    { // Add right click context menu for item options
        var context = dvui.context(@src(), .{ .rect = branch.button.data().borderRectScale().r }, .{});
        defer context.deinit();

        if (context.activePoint()) |point| {
            var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .box_shadow = .{
                .color = .black,
                .offset = .{ .x = 0, .y = 0 },
                .shrink = 0,
                .fade = 10,
                .alpha = 0.15,
            } });
            defer fw2.deinit();

            if ((dvui.menuItemLabel(@src(), "Close", .{}, .{
                .expand = .horizontal,
            })) != null) {
                if (fizzy.editor.folder) |f| {
                    fizzy.editor.ignore.deinit(fizzy.app.allocator);
                    fizzy.app.allocator.free(f);
                    fizzy.editor.folder = null;
                }

                fw2.close();
            }
        }
    }

    if (branch.button.clicked()) {
        selected_id = null;
        selectionFreeAll();
        selection_anchor = null;
    }

    const color = dvui.themeGet().color(.control, .fill_hover);

    _ = dvui.icon(
        @src(),
        "FolderIcon",
        if (branch.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
        .{ .fill_color = color },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );

    var fmt_string = std.fmt.allocPrint(dvui.currentWindow().lifo(), comptime "{s}", .{folder}) catch unreachable;
    defer dvui.currentWindow().lifo().free(fmt_string);

    for (fmt_string, 0..) |c, i| {
        fmt_string[i] = std.ascii.toUpper(c);
    }

    dvui.labelNoFmt(@src(), fmt_string, .{}, .{
        .color_fill = color,
        .font = dvui.Font.theme(.heading),
        .gravity_y = 0.5,
    });

    if (branch.expander(@src(), .{ .indent = 24 }, .{
        .color_fill = dvui.themeGet().color(.control, .fill),
        .corner_radius = .all(8),
        .expand = .both,
        .margin = .{ .x = 10, .w = 5 },
        .background = false,
    })) {
        var box = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .expand = .horizontal,
            .background = false,
            .gravity_y = 0.2,
        });
        defer box.deinit();

        try recurseFiles(path, tree, unique_id, filter_text);
    }
}

fn pointerReleaseInRectWithoutSelectionModifier(r: dvui.Rect.Physical) bool {
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .release and me.button.pointer() and r.contains(me.p)) {
                    return !me.mod.shift() and !me.mod.control() and !me.mod.command();
                }
            },
            else => {},
        }
    }
    return false;
}

const SimpleEntry = struct { name: []const u8, kind: std.Io.File.Kind };

fn lessThan(_: void, lhs: SimpleEntry, rhs: SimpleEntry) bool {
    if (lhs.kind == .directory and rhs.kind == .file) return true;
    if (lhs.kind == .file and rhs.kind == .directory) return false;

    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

pub fn editableLabel(id_extra: usize, label: []const u8, color: dvui.Color, kind: std.Io.File.Kind, full_path: []const u8) !void {
    const padding = dvui.Rect.all(3);
    const font = dvui.Font.theme(.body);

    const selected: bool = isFileSelected(id_extra);
    const editing: bool = if (edit_id) |id| id_extra == id else false;

    if (editing) {
        var te = dvui.textEntry(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .color_text = dvui.themeGet().color(.window, .text),
            .gravity_y = 0.5,
            .id_extra = id_extra,
            .font = font,
        });
        defer te.deinit();

        // Text edit should handle any click events, so if we find one unhandled after the text edit
        // we can assume the mouse was clicked anywhere else and that the edit needs to be confirmed.
        for (dvui.events()) |*event| {
            switch (event.evt) {
                .mouse => |mouse| {
                    if (mouse.action == .press and selected and editing and !event.handled) {
                        selected_id = null;
                        edit_id = null;
                    }
                },
                else => {},
            }
        }

        if (dvui.firstFrame(te.data().id)) {
            te.textSet(label, true);

            if (std.mem.indexOf(u8, label, ".")) |idx| {
                if (idx == 0) {
                    te.textLayout.selection.moveCursor(1, false);
                    te.textLayout.selection.moveCursor(label.len - 1, true);
                } else {
                    te.textLayout.selection.moveCursor(0, false);
                    te.textLayout.selection.moveCursor(idx, true);
                }
            }

            dvui.focusWidget(te.data().id, null, null);
        }

        if (te.enter_pressed or !selected) {
            const parent_folder = std.fs.path.dirname(full_path);
            var new_path: []const u8 = undefined;

            defer edit_id = null;

            const valid_path = blk: {
                std.Io.Dir.accessAbsolute(dvui.io, full_path, .{}) catch {
                    break :blk false;
                };

                break :blk true;
            };

            if (parent_folder) |folder| {
                new_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ folder, te.getText() });
            } else {
                new_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{te.getText()});
            }

            if (!std.mem.eql(u8, label, te.getText()) and te.getText().len > 0 and valid_path) {
                switch (kind) {
                    .directory => {
                        std.Io.Dir.renameAbsolute(full_path, new_path, dvui.io) catch dvui.log.err("Failed to rename folder: {s} to {s}", .{ label, te.getText() });

                        for (fizzy.editor.open_files.values()) |*file| {
                            if (std.mem.containsAtLeast(u8, file.path, 1, full_path)) {
                                const file_name = dvui.currentWindow().arena().dupe(u8, std.fs.path.basename(file.path)) catch "Failed to duplicate path";
                                fizzy.app.allocator.free(file.path);
                                file.path = try std.fs.path.join(fizzy.app.allocator, &.{ new_path, file_name });
                            }
                        }
                    },
                    .file => {
                        std.Io.Dir.renameAbsolute(full_path, new_path, dvui.io) catch dvui.log.err("Failed to rename file: {s} to {s}", .{ label, te.getText() });

                        if (fizzy.editor.getFileFromPath(full_path)) |file| {
                            fizzy.app.allocator.free(file.path);
                            file.path = fizzy.app.allocator.dupe(u8, new_path) catch {
                                dvui.log.err("Failed to duplicate path: {s}", .{new_path});
                                return error.FailedToDuplicatePath;
                            };
                        }
                    },
                    else => {},
                }
            }
        }
    } else {
        dvui.label(@src(), "{s}", .{label}, .{
            .color_text = color,
            .padding = padding,
            .margin = dvui.Rect.all(0),
            .id_extra = id_extra,
            .font = font,
            .gravity_y = 0.5,
        });
    }
}

pub fn recurseFiles(root_directory: []const u8, outer_tree: *fizzy.dvui.TreeWidget, unique_id: dvui.Id, outer_filter_text: []const u8) !void {
    var color_i: usize = 0;
    var id_extra: usize = 0;

    visible_file_rows_order.clearRetainingCapacity();
    errdefer pending_file_shift_range = null;

    const recursor = struct {
        fn search(directory: []const u8, tree: *fizzy.dvui.TreeWidget, inner_unique_id: dvui.Id, inner_id_extra: *usize, color_id: *usize, filter_text: []const u8, parent_branch: ?*fizzy.dvui.TreeWidget.Branch) !void {
            const io = dvui.io;
            var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true }) catch return;
            defer dir.close(io);

            var files = std.array_list.Managed(SimpleEntry).init(dvui.currentWindow().arena());

            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                try files.append(.{
                    .name = dvui.currentWindow().arena().dupe(u8, entry.name) catch "Arena failed to allocate",
                    .kind = entry.kind,
                });
            }

            std.mem.sort(
                SimpleEntry,
                files.items,
                {},
                lessThan,
            );

            for (files.items) |entry| {
                const abs_path = try std.fs.path.join(
                    dvui.currentWindow().arena(),
                    &.{ directory, entry.name },
                );

                if (fizzy.editor.folder) |proj_root| {
                    if (fizzy.editor.ignore.isIgnored(proj_root, abs_path, entry.name, entry.kind)) {
                        continue;
                    }
                }

                if (entry.kind == .file) {
                    if (std.ascii.indexOfIgnoreCase(entry.name, filter_text) == null) {
                        continue;
                    }
                } else if (filter_text.len > 0) {
                    search(abs_path, tree, inner_unique_id, inner_id_extra, color_id, filter_text, null) catch continue;
                    continue;
                }

                inner_id_extra.* = dvui.Id.update(tree.data().id, abs_path).asUsize();
                try visible_file_rows_order.append(fizzy.app.allocator, .{ .id = inner_id_extra.*, .path = abs_path });

                var color = dvui.themeGet().color(.control, .fill);
                if (fizzy.editor.colors.palette) |*palette| {
                    color = palette.getDVUIColor(color_id.*);
                }

                const padding = dvui.Rect.all(2);

                const selected: bool = isFileSelected(inner_id_extra.*);
                const editing: bool = if (edit_id) |id| inner_id_extra.* == id else false;

                const branch_id = tree.data().id.update(abs_path);

                var expanded = false;
                const expanded_indent: f32 = 14.0;

                if (fizzy.editor.explorer.open_branches.get(branch_id) != null) {
                    expanded = true;
                }

                if (new_file_path) |path| {
                    if (std.fs.path.dirname(path)) |d| {
                        if (std.mem.containsAtLeast(u8, d, 1, abs_path)) {
                            expanded = true;
                        }
                    }
                }

                const branch = tree.branch(@src(), .{
                    .expanded = expanded,
                    .animation_duration = 450_000,
                    .animation_easing = dvui.easing.outBack,
                    .process_events = !editing,
                    .can_accept_children = entry.kind == .directory,
                    .branch_id = inner_id_extra.*,
                }, .{
                    .id_extra = inner_id_extra.*,
                    .expand = .horizontal,
                    //.color_fill_hover = .fill,
                    .color_fill_hover = dvui.themeGet().color(.control, .fill).opacity(0.5),
                    .color_fill_press = dvui.themeGet().color(.control, .fill_press),
                    .color_fill = if (selected and tree.drag_point == null) dvui.themeGet().color(.control, .fill).opacity(0.5) else .transparent,
                    .padding = dvui.Rect.all(1),
                });
                defer branch.deinit();

                if (new_file_path) |path| {
                    if (std.mem.eql(u8, path, abs_path)) {
                        if (!dvui.firstFrame(branch.data().id)) {
                            if ((parent_branch != null and !parent_branch.?.expanding()) or branch.button.data().rect.h > 10.0) {
                                edit_id = inner_id_extra.*;
                                selected_id = inner_id_extra.*;
                                var close_rect = branch.button.data().borderRectScale().r;
                                close_rect.h = @max(10.0, close_rect.h);
                                new_file_close_rect = close_rect;
                                new_file_path = null;
                            }
                        }
                    }
                }

                const current_point = dvui.currentWindow().mouse_pt;

                const max_distance = if (!expanded) branch.data().borderRectScale().r.h * 3.0 else branch.data().borderRectScale().r.w / 8.0;

                var dx: f32 = std.math.floatMax(f32);

                if (current_point.x < branch.data().borderRectScale().r.x + if (expanded) (expanded_indent * dvui.currentWindow().natural_scale) else 0.0) {
                    dx = std.math.floatMax(f32);
                } else if (current_point.x > branch.data().borderRectScale().r.bottomRight().x) {
                    dx = @abs(current_point.x - branch.data().borderRectScale().r.bottomRight().x);
                } else {
                    dx = 0.0;
                }

                var dy: f32 = std.math.floatMax(f32);

                if (current_point.y < branch.data().borderRectScale().r.y) {
                    dy = @abs(current_point.y - branch.data().borderRectScale().r.y);
                } else if (current_point.y > branch.data().borderRectScale().r.bottomRight().y) {
                    dy = @abs(current_point.y - branch.data().borderRectScale().r.bottomRight().y);
                } else {
                    dy = 0.0;
                }

                const distance = @sqrt(dx * dx + dy * dy);

                const t = 1.0 - (distance / max_distance);

                color = dvui.themeGet().color(.window, .fill).lerp(color, t);

                if (branch.floating()) {
                    if (dvui.dataGetSlice(null, inner_unique_id, "removed_path", []u8) == null)
                        dvui.dataSetSlice(null, inner_unique_id, "removed_path", abs_path);

                    if (entry.kind == .file and tree.id_branch == inner_id_extra.*) {
                        if (fizzy.editor.tab_drag_from_tree_path) |old| {
                            if (!std.mem.eql(u8, old, abs_path)) {
                                fizzy.app.allocator.free(old);
                                fizzy.editor.tab_drag_from_tree_path = fizzy.app.allocator.dupe(u8, abs_path) catch null;
                            }
                        } else {
                            fizzy.editor.tab_drag_from_tree_path = fizzy.app.allocator.dupe(u8, abs_path) catch null;
                        }
                    }
                }

                if (branch.insertBefore()) {
                    const target_dir = if (entry.kind == .directory) abs_path else directory;
                    try applyFileMove(inner_unique_id, tree, target_dir);
                }

                if (branch.dropInto() and entry.kind == .directory) {
                    try applyFileMove(inner_unique_id, tree, abs_path);
                    // Expand the folder so the dropped item is visible
                    fizzy.editor.explorer.open_branches.put(branch_id, {}) catch {};
                }

                { // Add right click context menu for item options
                    var context = dvui.context(@src(), .{ .rect = branch.button.data().borderRectScale().r }, .{ .id_extra = inner_id_extra.* });
                    defer context.deinit();

                    if (context.activePoint()) |point| {
                        var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .box_shadow = .{
                            .color = .black,
                            .offset = .{ .x = 0, .y = 0 },
                            .shrink = 0,
                            .fade = 10,
                            .alpha = 0.15,
                        } });
                        defer fw2.deinit();

                        // Right-clicking a row that isn't already part of the selection takes over
                        // as a single-row selection; right-clicking a selected row preserves the
                        // multi-selection so context-menu actions apply to the group.
                        if (!isFileSelected(inner_id_extra.*)) {
                            applyFileClick(inner_id_extra.*, abs_path, .replace);
                        } else {
                            selected_id = inner_id_extra.*;
                        }

                        if (entry.kind == .file) {
                            if ((dvui.menuItemLabel(@src(), "Open", .{}, .{
                                .expand = .horizontal,
                            })) != null) {
                                const arena = dvui.currentWindow().arena();
                                const to_open = selectionTopMostOpenableFilesForOpenActions(arena) catch |err| blk: {
                                    dvui.log.err("Failed to collect files to open: {any}", .{err});
                                    break :blk &[_][]const u8{};
                                };
                                for (to_open) |p| {
                                    _ = fizzy.editor.openFilePath(p, fizzy.editor.currentGroupingID()) catch |e| {
                                        dvui.log.err("Failed to open file: {any} ({s})", .{ e, p });
                                    };
                                }

                                fw2.close();
                            }

                            if ((dvui.menuItemLabel(@src(), "Open to the side", .{}, .{
                                .expand = .horizontal,
                            })) != null) {
                                const arena = dvui.currentWindow().arena();
                                const to_open = selectionTopMostOpenableFilesForOpenActions(arena) catch |err| blk: {
                                    dvui.log.err("Failed to collect files to open: {any}", .{err});
                                    break :blk &[_][]const u8{};
                                };
                                var side_grouping: u64 = undefined;
                                var have_grouping = false;
                                for (to_open) |p| {
                                    if (!have_grouping) {
                                        side_grouping = if (fizzy.editor.open_files.count() == 0)
                                            fizzy.editor.currentGroupingID()
                                        else
                                            fizzy.editor.newGroupingID();
                                        have_grouping = true;
                                    }
                                    _ = fizzy.editor.openFilePath(p, side_grouping) catch {
                                        dvui.log.err("Failed to open file: {s}", .{p});
                                    };
                                }

                                fw2.close();
                            }

                            _ = dvui.separator(@src(), .{ .expand = .horizontal });
                        }

                        if ((dvui.menuItemLabel(@src(), open_message, .{}, .{ .expand = .horizontal })) != null) {
                            fizzy.editor.openInFileBrowser(if (entry.kind == .file) std.fs.path.dirname(abs_path) orelse abs_path else abs_path) catch {
                                dvui.log.err("Failed to open file browser", .{});
                            };

                            fw2.close();
                        }

                        if ((dvui.menuItemLabel(@src(), "New File...", .{}, .{ .expand = .horizontal })) != null) {
                            defer fw2.close();

                            const parent_dir: []const u8 = if (entry.kind == .directory) abs_path else directory;
                            const parent_owned = try dvui.currentWindow().arena().dupe(u8, parent_dir);
                            // Create a generic dialog that contains typical okay and cancel buttons and header
                            // The displayFn will be called during the drawing of the dialog, prior to ok and cancel buttons
                            var mutex = fizzy.dvui.dialog(@src(), .{
                                .displayFn = fizzy.Editor.Dialogs.NewFile.dialog,
                                .callafterFn = fizzy.Editor.Dialogs.NewFile.callAfter,
                                .title = "New File...",
                                .ok_label = "Create",
                                .cancel_label = "Cancel",
                                .resizeable = false,
                                .header_kind = .info,
                                .default = .ok,
                                .id_extra = branch_id.asUsize(),
                            });
                            dvui.dataSetSlice(null, mutex.id, "_parent_path", parent_owned);
                            mutex.mutex.unlock(dvui.io);
                        }

                        if ((dvui.menuItemLabel(@src(), "New Folder...", .{}, .{ .expand = .horizontal })) != null) {
                            switch (entry.kind) {
                                .directory => {
                                    const new_folder_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ abs_path, "New Folder" });
                                    std.Io.Dir.createDirAbsolute(dvui.io, new_folder_path, .default_dir) catch dvui.log.err("Failed to create folder: {s}", .{new_folder_path});
                                },
                                .file => {
                                    const new_folder_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ directory, "New Folder" });
                                    std.Io.Dir.createDirAbsolute(dvui.io, new_folder_path, .default_dir) catch dvui.log.err("Failed to create folder: {s}", .{new_folder_path});
                                },
                                else => {},
                            }

                            fw2.close();
                        }

                        if ((dvui.menuItemLabel(@src(), "Rename", .{}, .{
                            .expand = .horizontal,
                        })) != null) {
                            edit_id = inner_id_extra.*;
                            fw2.close();
                        }

                        {
                            if ((dvui.menuItemLabel(@src(), "Delete", .{}, .{
                                .expand = .horizontal,
                            })) != null) {
                                defer fw2.close();

                                const arena = dvui.currentWindow().arena();
                                const top = selectionPathsSorted(arena) catch |err| blk: {
                                    dvui.log.err("Failed to collect selection paths: {any}", .{err});
                                    break :blk &[_][]const u8{};
                                };
                                for (top) |del_path| {
                                    if (pathIsDirAbsolute(del_path)) {
                                        std.Io.Dir.deleteDirAbsolute(dvui.io, del_path) catch dvui.log.err("Failed to delete folder: {s}", .{del_path});
                                    } else {
                                        std.Io.Dir.deleteFileAbsolute(dvui.io, del_path) catch dvui.log.err("Failed to delete file: {s}", .{del_path});
                                    }
                                }
                            }
                        }
                    }
                }

                switch (entry.kind) {
                    .file => {
                        const ext = extension(entry.name);
                        //if (ext == .hidden) continue;
                        const icon = switch (ext) {
                            .fizzy, .psd => icons.tvg.lucide.@"file-pen-line",
                            .jpg, .png, .aseprite, .pyxel, .gif => icons.tvg.entypo.picture,
                            .pdf => icons.tvg.entypo.@"doc-text",
                            .json, .zig, .txt, .atlas => icons.tvg.entypo.code,
                            .tar, ._7z, .zip => icons.tvg.entypo.archive,
                            else => icons.tvg.entypo.archive,
                        };

                        const icon_color = color;

                        const file_icon_color: dvui.Color = if (ext == .fizzy) .transparent else icon_color;

                        if (ext == .fizzy) {
                            _ = fizzy.dvui.sprite(
                                @src(),
                                .{ .source = fizzy.editor.atlas.source, .sprite = fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.logo_default], .scale = 2.0 },
                                .{ .gravity_y = 0.5, .margin = padding, .padding = padding, .background = false },
                            );
                        } else {
                            dvui.icon(
                                @src(),
                                "FileIcon",
                                icon,
                                .{ .stroke_color = file_icon_color, .fill_color = file_icon_color },
                                .{
                                    .gravity_y = 0.5,
                                    .padding = padding,
                                    .background = false,
                                },
                            );
                        }

                        editableLabel(
                            inner_id_extra.*,
                            if (filter_text.len > 0) std.fs.path.relativePosix(dvui.currentWindow().arena(), ".", fizzy.editor.folder.?, abs_path) catch entry.name else entry.name,
                            if (fizzy.editor.getFileFromPath(abs_path) != null) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                            entry.kind,
                            abs_path,
                        ) catch {
                            dvui.log.err("Failed to draw editable label", .{});
                        };

                        if (fizzy.editor.getFileFromPath(abs_path)) |file| {
                            // Save spinner takes priority over the dirty dot: while a file is
                            // mid-save it's no longer "dirty waiting to be saved", it's "saving
                            // right now", and the user needs that distinction at a glance when
                            // multiple files are flushing in parallel. `isSaving` reads via an
                            // atomic load so the background `saveZip` worker can flip the flag
                            // safely from another thread.
                            if (file.isSaving()) {
                                fizzy.dvui.bubbleSpinner(@src(), .{
                                    .min_size_content = .{ .w = 14, .h = 14 },
                                    .gravity_y = 0.5,
                                    .color_text = dvui.themeGet().color(.window, .text),
                                });
                            } else if (file.dirty()) {
                                _ = dvui.icon(
                                    @src(),
                                    "DirtyIcon",
                                    icons.tvg.lucide.@"circle-small",
                                    .{ .stroke_color = dvui.themeGet().color(.window, .text) },
                                    .{ .gravity_y = 0.5 },
                                );
                            }
                        }

                        if (branch.button.clicked()) {
                            const mode = detectClickMode(branch.button.data().borderRectScale().r);
                            applyFileClick(inner_id_extra.*, abs_path, mode);
                            if (mode == .replace) {
                                switch (ext) {
                                    .fizzy, .png, .jpg => {
                                        _ = fizzy.editor.openFilePath(abs_path, fizzy.editor.currentGroupingID()) catch |err| {
                                            dvui.log.err("{any}: {s}", .{ err, abs_path });
                                        };
                                    },
                                    else => {},
                                }
                            }
                        }
                    },
                    .directory => {
                        const folder_name = std.fs.path.basename(abs_path);
                        const icon_color = color;

                        if (dvui.parentGet().data().rectScale().r.h > 10) {
                            _ = dvui.icon(
                                @src(),
                                "DropIcon",
                                if (branch.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
                                .{
                                    .fill_color = icon_color,
                                    .stroke_color = icon_color,
                                },
                                .{
                                    .gravity_y = 0.5,
                                    .padding = padding,
                                },
                            );

                            _ = dvui.icon(
                                @src(),
                                "FolderIcon",
                                if (branch.expanded) icons.tvg.entypo.folder else icons.tvg.entypo.folder,
                                .{
                                    .fill_color = icon_color,
                                    .stroke_color = icon_color,
                                },
                                .{
                                    .gravity_y = 0.5,
                                    .padding = padding,
                                },
                            );
                        }

                        editableLabel(
                            inner_id_extra.*,
                            folder_name,
                            dvui.themeGet().color(.control, .text),
                            entry.kind,
                            abs_path,
                        ) catch {
                            dvui.log.err("Failed to draw editable label", .{});
                        };

                        if (branch.button.clicked()) {
                            const mode = detectClickMode(branch.button.data().borderRectScale().r);
                            applyFileClick(inner_id_extra.*, abs_path, mode);
                        }

                        if (branch.expander(@src(), .{ .indent = expanded_indent }, .{
                            //.color_border = color.opacity(t),
                            .expand = .horizontal,
                            .corner_radius = .all(8),
                            // .box_shadow = .{
                            //     .color = .black,
                            //     .offset = .{ .x = -10 * t, .y = 0 },
                            //     .shrink = 10 * t,
                            //     .fade = 10 * t,
                            //     .alpha = 0.15 * t,
                            // },
                        })) {
                            fizzy.editor.explorer.open_branches.put(branch_id, {}) catch {
                                dvui.log.debug("Failed to track branch state!", .{});
                            };
                            try search(
                                abs_path,
                                tree,
                                inner_unique_id,
                                inner_id_extra,
                                color_id,
                                filter_text,
                                branch,
                            );
                        } else {
                            if (fizzy.editor.explorer.open_branches.contains(branch_id)) {
                                _ = fizzy.editor.explorer.open_branches.remove(branch_id);
                            }
                        }
                        // Keep open_branches in sync so hover-expand and drop-into expand persist next frame
                        if (branch.expanded) {
                            fizzy.editor.explorer.open_branches.put(branch_id, {}) catch {};
                        }
                        color_id.* = color_id.* + 1;
                    },
                    else => {},
                }
            }
        }
    }.search;

    try recursor(root_directory, outer_tree, unique_id, &id_extra, &color_i, outer_filter_text, null);
    flushPendingFileShiftRange();

    return;
}

pub fn isFileSelected(id: usize) bool {
    if (selected_id) |p| if (p == id) return true;
    return selected_paths.contains(id);
}

fn selectionFreeAll() void {
    var it = selected_paths.iterator();
    while (it.next()) |e| fizzy.app.allocator.free(e.value_ptr.*);
    selected_paths.clearRetainingCapacity();
}

fn selectionPut(id: usize, path: []const u8) void {
    if (selected_paths.getPtr(id)) |existing| {
        if (std.mem.eql(u8, existing.*, path)) return;
        fizzy.app.allocator.free(existing.*);
        existing.* = fizzy.app.allocator.dupe(u8, path) catch return;
        return;
    }
    const copy = fizzy.app.allocator.dupe(u8, path) catch return;
    selected_paths.put(fizzy.app.allocator, id, copy) catch {
        fizzy.app.allocator.free(copy);
    };
}

fn selectionRemove(id: usize) bool {
    if (selected_paths.fetchSwapRemove(id)) |kv| {
        fizzy.app.allocator.free(kv.value);
        return true;
    }
    return false;
}

/// Apply a modifier-aware click to the file-tree selection. Indexed by id_extra (path hash).
fn applyFileClick(id: usize, path: []const u8, mode: fizzy.dvui.TreeSelection.ClickMode) void {
    switch (mode) {
        .replace => {
            selectionFreeAll();
            selectionPut(id, path);
            selected_id = id;
            selection_anchor = id;
        },
        .toggle => {
            if (selectionRemove(id)) {
                if (selected_id == id) {
                    var it = selected_paths.iterator();
                    selected_id = if (it.next()) |entry| entry.key_ptr.* else null;
                }
            } else {
                selectionPut(id, path);
                selected_id = id;
            }
            selection_anchor = id;
        },
        .extend => {
            const pivot = selection_anchor orelse selected_id orelse id;
            pending_file_shift_range = .{
                .anchor_id = pivot,
                .clicked_id = id,
                .clicked_path = path,
            };
        },
    }
}

fn flushPendingFileShiftRange() void {
    const p = pending_file_shift_range orelse return;
    pending_file_shift_range = null;
    applyFileShiftRange(p.clicked_id, p.clicked_path, p.anchor_id);
}

fn applyFileShiftRange(clicked_id: usize, clicked_path: []const u8, anchor_id: usize) void {
    const rows = visible_file_rows_order.items;
    var a_idx: ?usize = null;
    var c_idx: ?usize = null;
    for (rows, 0..) |row, i| {
        if (row.id == anchor_id) a_idx = i;
        if (row.id == clicked_id) c_idx = i;
    }
    if (a_idx == null or c_idx == null) {
        selectionPut(clicked_id, clicked_path);
        selected_id = clicked_id;
        selection_anchor = anchor_id;
        return;
    }
    const lo = @min(a_idx.?, c_idx.?);
    const hi = @max(a_idx.?, c_idx.?);
    selectionFreeAll();
    for (rows[lo .. hi + 1]) |row| {
        selectionPut(row.id, row.path);
    }
    selected_id = clicked_id;
    if (selection_anchor == null) selection_anchor = anchor_id;
}

/// Derive the click mode from the most recent pointer release event that falls within `rect`.
/// Used after `branch.button.clicked()` so we can honor ctrl/cmd/shift without intercepting the
/// button's own event handling.
fn detectClickMode(rect: dvui.Rect.Physical) fizzy.dvui.TreeSelection.ClickMode {
    var mode: fizzy.dvui.TreeSelection.ClickMode = .replace;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .release or !me.button.pointer()) continue;
        if (!rect.contains(me.p)) continue;
        mode = fizzy.dvui.TreeSelection.clickModeFromMod(me.mod);
    }
    return mode;
}

/// True when `child` lies strictly inside `ancestor` as a filesystem path (e.g. `/a/b` under `/a`).
fn isStrictPathDescendant(child: []const u8, ancestor: []const u8) bool {
    if (child.len <= ancestor.len) return false;
    if (!std.mem.startsWith(u8, child, ancestor)) return false;
    return std.fs.path.isSep(child[ancestor.len]);
}

/// Another selected entry is a folder that already contains this path — skip it for multi-drag / move.
fn selectionPathExcludedByAncestor(path: []const u8) bool {
    var it = selected_paths.iterator();
    while (it.next()) |e| {
        const other = e.value_ptr.*;
        if (std.mem.eql(u8, path, other)) continue;
        if (isStrictPathDescendant(path, other)) return true;
    }
    return false;
}

/// Selected paths with no selected ancestor folder, sorted lexically (same set as multi-drag).
fn selectionPathsSorted(arena: std.mem.Allocator) ![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = selected_paths.iterator();
    while (it.next()) |e| {
        const src = e.value_ptr.*;
        if (selectionPathExcludedByAncestor(src)) continue;
        const copy = try arena.dupe(u8, src);
        try paths.append(arena, copy);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return paths.toOwnedSlice(arena);
}

fn pathIsDirAbsolute(abs: []const u8) bool {
    const io = dvui.io;
    var d = std.Io.Dir.openDirAbsolute(io, abs, .{}) catch return false;
    d.close(io);
    return true;
}

/// Same file kinds as primary-click open in the tree (not directories).
fn openablePath(abs_path: []const u8) bool {
    if (pathIsDirAbsolute(abs_path)) return false;
    return switch (extension(abs_path)) {
        .fizzy, .png, .jpg => true,
        else => false,
    };
}

fn appendOpenableFilesInTree(arena: std.mem.Allocator, root_abs: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const io = dvui.io;
    var dir = std.Io.Dir.openDirAbsolute(io, root_abs, .{ .iterate = true }) catch |err| {
        dvui.log.err("Failed to open directory for open: {s} ({any})", .{ root_abs, err });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(arena, &.{ root_abs, entry.path });
        if (!openablePath(full)) continue;
        try out.append(arena, try arena.dupe(u8, full));
    }
}

/// Top-most selection (no selected ancestor), then every openable canvas file: each selected file,
/// plus all openable descendants of selected directories. Sorted lexically. Not used for delete.
fn selectionTopMostOpenableFilesForOpenActions(arena: std.mem.Allocator) ![]const []const u8 {
    const top = try selectionPathsSorted(arena);
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer files.deinit(arena);
    for (top) |p| {
        if (pathIsDirAbsolute(p)) {
            try appendOpenableFilesInTree(arena, p, &files);
        } else if (openablePath(p)) {
            try files.append(arena, try arena.dupe(u8, p));
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return files.toOwnedSlice(arena);
}

/// Branch ids for `TreeWidget.selected_branch_ids`: same as selection, minus descendants when a parent folder is also selected.
fn selectionBranchIdsForMultiDrag(arena: std.mem.Allocator) ![]const usize {
    const IdPath = struct {
        id: usize,
        path: []const u8,
    };
    var tmp: std.ArrayListUnmanaged(IdPath) = .empty;
    defer tmp.deinit(arena);

    var it = selected_paths.iterator();
    while (it.next()) |e| {
        const path = e.value_ptr.*;
        if (selectionPathExcludedByAncestor(path)) continue;
        try tmp.append(arena, .{ .id = e.key_ptr.*, .path = path });
    }
    std.mem.sort(IdPath, tmp.items, {}, struct {
        fn lt(_: void, a: IdPath, b: IdPath) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);

    const out = try arena.alloc(usize, tmp.items.len);
    for (tmp.items, 0..) |p, i| out[i] = p.id;
    return out;
}

/// Move the drag source (and, for a multi-drag, every other selected path) into `target_dir`.
/// Renames files/folders on disk and rewrites open-file paths in-place. Clears the drag's
/// stashed `removed_path` when complete.
fn applyFileMove(unique_id: dvui.Id, tree: *fizzy.dvui.TreeWidget, target_dir: []const u8) !void {
    const arena = dvui.currentWindow().arena();

    // The primary (floating) row's path is stashed here by the branch that reports `floating()`.
    const primary_path_opt: ?[]const u8 = dvui.dataGetSlice(null, unique_id, "removed_path", []u8);
    const is_multi = tree.drag_branch_ids != null;

    if (is_multi) {
        // Snapshot paths first: moving invalidates `selected_paths` entries and their strings.
        // Omit paths that are already under another selected folder (the folder move covers them).
        var paths: std.ArrayList([]u8) = .empty;
        defer paths.deinit(arena);
        var it = selected_paths.iterator();
        while (it.next()) |e| {
            const path = e.value_ptr.*;
            if (selectionPathExcludedByAncestor(path)) continue;
            const copy = arena.dupe(u8, path) catch continue;
            paths.append(arena, copy) catch continue;
        }

        // Stable order keeps sibling-relative order roughly predictable for the user.
        std.mem.sort([]u8, paths.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        for (paths.items) |p| {
            _ = try moveOnePath(p, target_dir, arena);
        }

        // Rebuild the selection map from the new paths on disk.
        selectionFreeAll();
        selected_id = null;
        for (paths.items) |old_path| {
            const base = std.fs.path.basename(old_path);
            const new_path = std.fs.path.join(arena, &.{ target_dir, base }) catch continue;
            std.Io.Dir.accessAbsolute(dvui.io, new_path, .{}) catch continue;
            const new_id = dvui.Id.update(tree.data().id, new_path).asUsize();
            selectionPut(new_id, new_path);
            selected_id = new_id;
        }
        selection_anchor = selected_id;
    } else if (primary_path_opt) |removed_path| {
        _ = try moveOnePath(removed_path, target_dir, arena);
    }

    dvui.dataRemove(null, unique_id, "removed_path");
}

fn moveOnePath(source_path: []const u8, target_dir: []const u8, arena: std.mem.Allocator) !bool {
    const base = std.fs.path.basename(source_path);
    const new_path = try std.fs.path.join(arena, &.{ target_dir, base });
    if (std.mem.eql(u8, source_path, new_path)) return false;

    std.Io.Dir.renameAbsolute(source_path, new_path, dvui.io) catch {
        dvui.log.err("Failed to move {s} to {s}", .{ source_path, new_path });
        return false;
    };

    if (fizzy.editor.getFileFromPath(source_path)) |file| {
        fizzy.app.allocator.free(file.path);
        file.path = fizzy.app.allocator.dupe(u8, new_path) catch {
            dvui.log.err("Failed to duplicate path: {s}", .{new_path});
            return error.FailedToDuplicatePath;
        };
    }
    return true;
}

/// Remove stale selections whose underlying file no longer exists (e.g. moved by a multi-drag).
pub fn pruneMissingSelections() void {
    var i: usize = 0;
    while (i < selected_paths.count()) {
        const entry = selected_paths.entries.get(i);
        std.Io.Dir.accessAbsolute(dvui.io, entry.value, .{}) catch {
            const removed = selected_paths.fetchSwapRemove(entry.key) orelse {
                i += 1;
                continue;
            };
            if (selected_id == removed.key) selected_id = null;
            fizzy.app.allocator.free(removed.value);
            continue;
        };
        i += 1;
    }
}

pub fn extension(file: []const u8) Extension {
    const ext = std.fs.path.extension(file);
    if (std.mem.eql(u8, ext, "")) return .hidden;
    if (std.mem.eql(u8, ext, ".fiz")) return .fizzy;
    if (std.mem.eql(u8, ext, ".pixi")) return .fizzy;
    if (std.mem.eql(u8, ext, ".atlas")) return .atlas;
    if (std.mem.eql(u8, ext, ".png")) return .png;
    if (std.mem.eql(u8, ext, ".gif")) return .gif;
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return .jpg;
    if (std.mem.eql(u8, ext, ".pdf")) return .pdf;
    if (std.mem.eql(u8, ext, ".psd")) return .psd;
    if (std.mem.eql(u8, ext, ".aseprite")) return .aseprite;
    if (std.mem.eql(u8, ext, ".pyxel")) return .pyxel;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".zip")) return .zip;
    if (std.mem.eql(u8, ext, ".7z")) return ._7z;
    if (std.mem.eql(u8, ext, ".tar")) return .tar;
    if (std.mem.eql(u8, ext, ".txt")) return .txt;
    return .unsupported;
}
