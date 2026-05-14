const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const icons = @import("icons");

const App = fizzy.App;
const Editor = fizzy.Editor;

/// Workspaces are drawn recursively inside of the explorer paned widget
/// second pane, and contains drag/drop enabled tabs. Tabs can freely be dragged to
/// panes or other tab bars.
/// Workspaces can potentially draw open files, the project logo, or the project pane
/// containing the packed atlas.
pub const Workspace = @This();

open_file_index: usize = 0,
grouping: u64 = 0,
center: bool = false,

tabs_drag_index: ?usize = null,
tabs_removed_index: ?usize = null,
tabs_insert_before_index: ?usize = null,

columns_drag_name: []const u8 = undefined,
columns_drag_index: ?usize = null,
columns_target_id: ?dvui.Id = null,
columns_target_index: ?usize = null,
columns_removed_index: ?usize = null,
columns_insert_before_index: ?usize = null,

rows_drag_name: []const u8 = undefined,
rows_drag_index: ?usize = null,
rows_target_id: ?dvui.Id = null,
rows_target_index: ?usize = null,
rows_removed_index: ?usize = null,
rows_insert_before_index: ?usize = null,

horizontal_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
vertical_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },

horizontal_ruler_height: f32 = 0.0,
vertical_ruler_width: f32 = 0.0,

/// Physical-pixel content rect of this workspace's canvas vbox, captured each frame during
/// `drawCanvas` / `drawProject`. `null` until the workspace has rendered at least once. Used
/// by the editor-level load/save toast overlays to center cards over the area the user is
/// actually looking at (rather than the OS window rect).
canvas_rect_physical: ?dvui.Rect.Physical = null,

pub fn init(grouping: u64) Workspace {
    return .{
        .grouping = grouping,
        .columns_drag_name = std.fmt.allocPrint(fizzy.app.allocator, "column_drag_{d}", .{grouping}) catch "column_drag",
        .rows_drag_name = std.fmt.allocPrint(fizzy.app.allocator, "row_drag_{d}", .{grouping}) catch "row_drag",
    };
}

const handle_size = 10;
const handle_dist = 60;

const opacity = 60;

const color_0 = fizzy.math.Color.initBytes(0, 0, 0, 0);
const color_1 = fizzy.math.Color.initBytes(230, 175, 137, opacity);
const color_2 = fizzy.math.Color.initBytes(216, 145, 115, opacity);
const color_3 = fizzy.math.Color.initBytes(41, 23, 41, opacity);
const color_4 = fizzy.math.Color.initBytes(194, 109, 92, opacity);
const color_5 = fizzy.math.Color.initBytes(180, 89, 76, opacity);

const logo_colors: [12]fizzy.math.Color = [_]fizzy.math.Color{
    color_1, color_1, color_1,
    color_2, color_2, color_3,
    color_4, color_3, color_0,
    color_3, color_0, color_0,
};

var dragging: bool = false;

pub fn draw(self: *Workspace) !dvui.App.Result {
    defer self.columns_drag_index = null;
    defer self.rows_drag_index = null;

    // Process the column reorder, when both fields are set and we can take action
    defer self.processColumnReorder();
    defer self.processRowReorder();

    // Canvas Area
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_y = 0.0,
        .id_extra = self.grouping,
    });
    defer vbox.deinit();

    // Set the active workspace grouping when the user clicks on the workspace rect
    for (dvui.events()) |*e| {
        if (!vbox.matchEvent(e)) {
            continue;
        }

        if (e.evt == .mouse) {
            if (e.evt.mouse.action == .press or (e.evt.mouse.action == .position and e.evt.mouse.mod.matchBind("ctrl/cmd"))) {
                fizzy.editor.open_workspace_grouping = self.grouping;
            }
        }
    }

    if (fizzy.editor.explorer.pane == .project) {
        self.drawProject();
    } else {
        self.drawTabs();
        try self.drawCanvas();
    }

    return .ok;
}

/// Same `@src()` for every call so DVUI sees one stable id when switching between `drawCanvas` and
/// `drawProject` (avoids first-frame min-size / layout flash). Use `grouping` so multi-workspace panes stay distinct.
fn workspaceMainCanvasVbox(content_color: dvui.Color, background: bool, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = background,
        .color_fill = content_color,
        .id_extra = grouping,
    });
}

/// Rounded “card” behind the project empty state and the homepage. Shared id base + `grouping` so
/// switching project tab ↔ file pane (no open files) does not create a new widget each time.
fn workspaceEmptyStateCard(content_color: dvui.Color, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = content_color,
        .corner_radius = dvui.Rect.all(16),
        .margin = .{ .y = 10 },
        .id_extra = grouping,
    });
}

fn drawProject(self: *Workspace) void {
    var content_color = dvui.themeGet().color(.window, .fill);

    switch (builtin.os.tag) {
        .macos => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        else => {},
    }

    const show_packed_atlas = fizzy.editor.folder != null and fizzy.packer.atlas != null;

    // Match `drawCanvas`: no outer fill when showing centered card (transparency shows through like homepage).
    var canvas_vbox = workspaceMainCanvasVbox(content_color, show_packed_atlas, self.grouping);
    defer {
        self.canvas_rect_physical = canvas_vbox.data().contentRectScale().r;
        dvui.toastsShow(canvas_vbox.data().id, canvas_vbox.data().contentRectScale().r.toNatural());
        canvas_vbox.deinit();
    }

    if (show_packed_atlas) {
        const atlas = &fizzy.packer.atlas.?;
        var image_widget = fizzy.dvui.ImageWidget.init(@src(), .{
            .source = atlas.source,
            .canvas = &atlas.canvas,
        }, .{
            .id_extra = self.grouping,
            .expand = .both,
            .background = false,
            .color_fill = .transparent,
        });
        defer image_widget.deinit();

        image_widget.processEvents();
    } else {
        var box = workspaceEmptyStateCard(content_color, self.grouping);
        defer box.deinit();

        const alpha = dvui.alpha(1.0);
        dvui.alphaSet(1.0);
        defer dvui.alphaSet(alpha);

        const hint: []const u8 = if (fizzy.editor.folder == null)
            "Open a project folder, then pack to see the preview."
        else
            "Pack the project to see the preview.";

        dvui.labelNoFmt(
            @src(),
            hint,
            .{ .align_x = 0.5 },
            .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = dvui.themeGet().color(.control, .text),
                .font = dvui.Font.theme(.body),
            },
        );
    }
}

fn drawTabs(self: *Workspace) void {
    if (fizzy.editor.open_files.values().len == 0) return;

    // Handle dragging of tabs between workspace reorderables (tab bars)
    defer self.processTabsDrag();

    {
        var tabs_anim = dvui.animate(@src(), .{ .duration = 500_000, .kind = .vertical, .easing = dvui.easing.outBack }, .{});
        defer tabs_anim.deinit();

        var tabs_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .id_extra = self.grouping,
        });
        defer tabs_box.deinit();

        var scroll_area = dvui.scrollArea(@src(), .{ .horizontal = .auto, .horizontal_bar = .hide, .vertical_bar = .hide }, .{
            .expand = .none,
            .background = false,
            .corner_radius = dvui.Rect.all(0),
            .id_extra = self.grouping,
        });
        defer scroll_area.deinit();

        {
            var tabs = dvui.reorder(@src(), .{ .drag_name = "tab_drag" }, .{
                .expand = .none,
                .background = false,
            });
            defer tabs.deinit();

            var tabs_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .id_extra = self.grouping,
            });
            defer tabs_hbox.deinit();

            const files = fizzy.editor.open_files.values();
            const files_len = files.len;

            // Find the neighbouring tabs (within this workspace grouping) of the active tab.
            var prev_same_group_index: ?usize = null;
            var next_same_group_index: ?usize = null;

            const active_in_this_group = blk: {
                if (fizzy.editor.open_workspace_grouping != self.grouping) break :blk false;
                if (self.open_file_index >= files_len) break :blk false;
                if (files[self.open_file_index].editor.grouping != self.grouping) break :blk false;
                break :blk true;
            };

            if (active_in_this_group) {
                const active_index = self.open_file_index;

                // Scan left from the active tab to find the previous tab in this grouping.
                var j: usize = active_index;
                while (j > 0) {
                    j -= 1;
                    if (files[j].editor.grouping == self.grouping) {
                        prev_same_group_index = j;
                        break;
                    }
                }

                // Scan right from the active tab to find the next tab in this grouping.
                j = active_index + 1;
                while (j < files_len) : (j += 1) {
                    if (files[j].editor.grouping == self.grouping) {
                        next_same_group_index = j;
                        break;
                    }
                }
            }

            for (files, 0..) |file, i| {
                const is_fizzy_file = fizzy.Internal.File.isFizzyExtension(std.fs.path.extension(file.path));

                if (file.editor.grouping != self.grouping) continue;

                var reorderable = tabs.reorderable(@src(), .{}, .{
                    .expand = .vertical,
                    .id_extra = i,
                    .padding = dvui.Rect.all(0),
                    .margin = dvui.Rect.all(0),
                });
                defer reorderable.deinit();

                const selected = self.open_file_index == i and fizzy.editor.open_workspace_grouping == self.grouping;

                var anim = dvui.animate(@src(), .{ .duration = 400_000, .kind = .horizontal, .easing = dvui.easing.outBack }, .{});
                defer anim.deinit();

                var hbox: dvui.BoxWidget = undefined;
                hbox.init(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .border = .all(0),
                    .color_fill = if (selected) .transparent else dvui.themeGet().color(.window, .fill).opacity(fizzy.editor.settings.content_opacity),
                    .background = true,
                    .id_extra = i,
                    .padding = dvui.Rect.all(2),
                    .margin = dvui.Rect.all(0),
                });

                defer hbox.deinit();

                const tab_hovered = fizzy.dvui.hovered(hbox.data());

                if (selected) {
                    if (!reorderable.floating()) {
                        dvui.Path.stroke(.{
                            .points = &.{
                                hbox.data().rectScale().r.bottomLeft(),
                                hbox.data().rectScale().r.bottomRight(),
                            },
                        }, .{
                            .color = dvui.themeGet().color(.window, .text),
                            .thickness = 1,
                        });
                    }
                }

                if (reorderable.floating()) {
                    self.tabs_drag_index = i;
                    hbox.data().options.color_fill = dvui.themeGet().color(.control, .fill);
                }
                hbox.drawBackground();

                if (!selected and active_in_this_group and tabs.drag_point == null) {
                    // Draw edge shadow between the active tab and its neighbours within this grouping.
                    if (prev_same_group_index) |prev_index| {
                        if (i == prev_index) {
                            // This tab is directly to the left of the active tab.
                            fizzy.dvui.drawEdgeShadow(hbox.data().rectScale(), .right, .{});
                        }
                    }

                    if (next_same_group_index) |next_index| {
                        if (i == next_index) {
                            // This tab is directly to the right of the active tab.
                            fizzy.dvui.drawEdgeShadow(hbox.data().rectScale(), .left, .{});
                        }
                    }
                }

                if (reorderable.removed()) {
                    self.tabs_removed_index = i;
                } else if (reorderable.insertBefore()) {
                    self.tabs_insert_before_index = i;
                }

                if (is_fizzy_file) {
                    _ = fizzy.dvui.sprite(@src(), .{
                        .source = fizzy.editor.atlas.source,
                        .sprite = fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.logo_default],
                        .scale = 2.0,
                    }, .{
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(4),
                    });
                } else {
                    dvui.icon(@src(), "file_icon", icons.tvg.lucide.file, .{
                        .stroke_color = if (is_fizzy_file) .transparent else dvui.themeGet().color(.control, .text),
                    }, .{
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(4),
                    });
                }

                dvui.label(@src(), "{s}", .{std.fs.path.basename(file.path)}, .{
                    .color_text = if (selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                    .padding = dvui.Rect.all(4),
                    .gravity_y = 0.5,
                });

                const close_inner = fizzy.dvui.windowHeaderCloseInnerSide();
                const close_pad = fizzy.dvui.window_header_close_margin;
                const tab_status_slot = close_inner + close_pad.x + close_pad.w;

                const status_close_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = tab_status_slot, .h = tab_status_slot },
                });
                defer status_close_box.deinit();

                // Saving has priority over hover/close/dirty indicators: the user wants visible
                // confirmation that the save is in flight, and the slot's size matches the close
                // button so the layout doesn't shift when saving starts/ends. `editor.saving`
                // can be written by a background save worker (`saveZip`), so we read it with an
                // atomic load — the write side uses an atomic store in matching `save*` paths.
                const is_saving = @atomicLoad(bool, &file.editor.saving, .monotonic);
                if (is_saving) {
                    fizzy.dvui.bubbleSpinner(@src(), .{
                        .id_extra = i *% 16 + 5,
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = dvui.themeGet().color(.window, .text),
                    });
                } else if (tab_hovered) {
                    var tab_close_button: dvui.ButtonWidget = undefined;
                    tab_close_button.init(@src(), .{ .draw_focus = false }, fizzy.dvui.windowHeaderCloseButtonOptions(.{
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .id_extra = i *% 16 + 1,
                    }));
                    defer tab_close_button.deinit();

                    tab_close_button.processEvents();
                    tab_close_button.drawBackground();
                    tab_close_button.drawFocus();

                    if (tab_close_button.hovered()) {
                        dvui.icon(@src(), "close", icons.tvg.lucide.x, .{
                            .stroke_color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10),
                            .fill_color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10),
                        }, .{
                            .expand = .ratio,
                            .gravity_x = 0.5,
                            .gravity_y = 0.5,
                            .id_extra = i *% 16 + 2,
                        });
                    }

                    if (tab_close_button.clicked()) {
                        fizzy.editor.closeFileID(file.id) catch |err| {
                            dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                        };
                        break;
                    }
                } else if (selected and !file.dirty()) {
                    const tab_text = dvui.themeGet().color(.window, .text);
                    var ghost_close: dvui.ButtonWidget = undefined;
                    ghost_close.init(@src(), .{ .draw_focus = false }, fizzy.dvui.windowHeaderCloseButtonOptions(.{
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .id_extra = i *% 16 + 3,
                        .style = .window,
                        .background = false,
                        .box_shadow = null,
                        .border = .all(0),
                        .color_fill = .transparent,
                        .color_fill_hover = .transparent,
                        .color_fill_press = .transparent,
                        .ninepatch_fill = &dvui.Ninepatch.none,
                        .ninepatch_hover = &dvui.Ninepatch.none,
                        .ninepatch_press = &dvui.Ninepatch.none,
                    }));
                    defer ghost_close.deinit();

                    ghost_close.processEvents();
                    // Invisible hit target only — `drawBackground` would run theme ninepatch.

                    dvui.icon(@src(), "close", icons.tvg.lucide.x, .{
                        .stroke_color = tab_text,
                        .fill_color = tab_text,
                    }, .{
                        .expand = .ratio,
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .id_extra = i *% 16 + 4,
                        .background = false,
                        .border = .all(0),
                        .box_shadow = null,
                        .ninepatch_fill = &dvui.Ninepatch.none,
                        .ninepatch_hover = &dvui.Ninepatch.none,
                        .ninepatch_press = &dvui.Ninepatch.none,
                    });

                    if (ghost_close.clicked()) {
                        fizzy.editor.closeFileID(file.id) catch |err| {
                            dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                        };
                        break;
                    }
                } else if (file.dirty()) {
                    dvui.icon(@src(), "dirty_icon", icons.tvg.lucide.@"circle-small", .{
                        .stroke_color = dvui.themeGet().color(.window, .text),
                    }, .{
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(2),
                        .id_extra = i *% 16 + 0,
                    });
                }

                loop: for (dvui.events()) |*e| {
                    if (!hbox.matchEvent(e)) {
                        continue;
                    }

                    switch (e.evt) {
                        .mouse => |me| {
                            if (me.action == .press and me.button.pointer()) {
                                fizzy.editor.setActiveFile(i);
                                dvui.refresh(null, @src(), hbox.data().id);

                                e.handle(@src(), hbox.data());
                                dvui.captureMouse(hbox.data(), e.num);
                                dvui.dragPreStart(me.p, .{ .size = reorderable.data().rectScale().r.size(), .offset = reorderable.data().rectScale().r.topLeft().diff(me.p) });
                            } else if (me.action == .release and me.button.pointer()) {
                                dvui.captureMouse(null, e.num);
                                dvui.dragEnd();
                            } else if (me.action == .motion) {
                                if (dvui.captured(hbox.data().id)) {
                                    e.handle(@src(), hbox.data());
                                    if (dvui.dragging(me.p, null)) |_| {
                                        reorderable.reorder.dragStart(reorderable.data().id.asUsize(), me.p, 0); // reorder grabs capture
                                        break :loop;
                                    }
                                }
                            }
                        },

                        else => {},
                    }
                }
            }
            if (tabs.finalSlot()) {
                self.tabs_insert_before_index = fizzy.editor.open_files.values().len;
            }
        }
    }
}

pub fn processTabsDrag(self: *Workspace) void {
    if (self.tabs_insert_before_index) |insert_before| {
        if (self.tabs_removed_index) |removed| { // Dragging from this workspace

            if (removed > fizzy.editor.open_files.count()) return;
            if (removed > insert_before) {
                std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);
                fizzy.editor.setActiveFile(insert_before);
            } else {
                if (insert_before > 0) {
                    std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before - 1]);
                    std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before - 1]);
                    fizzy.editor.setActiveFile(insert_before - 1);
                } else {
                    std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                    std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);
                    fizzy.editor.setActiveFile(insert_before);
                }
            }

            self.tabs_removed_index = null;
            self.tabs_insert_before_index = null;
        } else { // Dragging from another workspace
            for (fizzy.editor.workspaces.values()) |*workspace| {
                if (workspace.tabs_removed_index) |removed| {
                    if (removed > insert_before) {
                        std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                        std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);

                        fizzy.editor.open_files.values()[insert_before].editor.grouping = self.grouping;
                        fizzy.editor.setActiveFile(insert_before);
                    } else {
                        if (insert_before > 0) {
                            std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before - 1]);
                            std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before - 1]);
                            fizzy.editor.open_files.values()[insert_before - 1].editor.grouping = self.grouping;
                            fizzy.editor.setActiveFile(insert_before - 1);
                        } else {
                            std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                            std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);
                            fizzy.editor.open_files.values()[insert_before].editor.grouping = self.grouping;
                            fizzy.editor.setActiveFile(insert_before);
                        }
                    }

                    self.tabs_removed_index = null;
                    self.tabs_insert_before_index = null;

                    workspace.tabs_removed_index = null;
                    workspace.tabs_insert_before_index = null;
                }
            }
        }
    }
}

/// Repoint `open_file_index` on workspaces that were showing the dragged tab as active.
fn repointWorkspacesAfterTabDrag(editor: *Editor, tab_bar_workspace: ?*Workspace, drag_index: usize) void {
    const dragged_file = &editor.open_files.values()[drag_index];
    if (tab_bar_workspace) |workspace| {
        if (workspace.open_file_index == editor.open_files.getIndex(dragged_file.id)) {
            for (editor.open_files.values()) |f| {
                if (f.editor.grouping == workspace.grouping and f.id != dragged_file.id) {
                    workspace.open_file_index = editor.open_files.getIndex(f.id) orelse 0;
                    break;
                }
            }
        }
    } else {
        for (editor.workspaces.values()) |*w| {
            if (w.open_file_index == drag_index) {
                for (editor.open_files.values()) |f| {
                    if (f.editor.grouping == w.grouping and f.id != dragged_file.id) {
                        w.open_file_index = editor.open_files.getIndex(f.id) orelse 0;
                        break;
                    }
                }
            }
        }
    }
}

const WorkspaceTabDragSrc = union(enum) {
    tab_bar: struct { ws: *Workspace, index: usize },
    tree_open: usize,
    tree_closed: []const u8,
    none,

    fn resolve(editor: *Editor) WorkspaceTabDragSrc {
        for (editor.workspaces.values()) |*w| {
            if (w.tabs_drag_index) |i| return .{ .tab_bar = .{ .ws = w, .index = i } };
        }
        if (editor.tab_drag_from_tree_path) |p| {
            if (editor.getFileFromPath(p)) |f| {
                const idx = editor.open_files.getIndex(f.id) orelse return .none;
                return .{ .tree_open = idx };
            }
            return .{ .tree_closed = p };
        }
        return .none;
    }
};

/// Responsible for handling the cross-widget drag of tabs between multiple workspaces or between tabs and workspaces.
/// Also handles the same `tab_drag` from the Files tree (see `files.zig` + DVUI reorder_tree cross-widget pattern).
pub fn processTabDrag(self: *Workspace, data: *dvui.WidgetData) void {
    if (!dvui.dragName("tab_drag")) {
        fizzy.editor.clearFileTreeTabDragDropState();
        return;
    }

    const drag_src = WorkspaceTabDragSrc.resolve(fizzy.editor);
    switch (drag_src) {
        .none => return,
        else => {},
    }

    events_loop: for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = data.id, .r = data.rectScale().r, .drag_name = "tab_drag" })) continue;

        switch (drag_src) {
            .none => unreachable,
            .tab_bar => |tb| {
                const workspace = tb.ws;
                const drag_index = tb.index;

                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and fizzy.editor.workspaces.keys()[fizzy.editor.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        defer workspace.tabs_drag_index = null;
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, workspace, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = fizzy.editor.newGroupingID();
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
                    }
                } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        defer workspace.tabs_drag_index = null;
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, workspace, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = self.grouping;
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
                        self.open_file_index = fizzy.editor.open_files.getIndex(dragged_file.id) orelse 0;
                    }
                }
            },
            .tree_open => |drag_index| {
                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and fizzy.editor.workspaces.keys()[fizzy.editor.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, null, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = fizzy.editor.newGroupingID();
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
                    }
                } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, null, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = self.grouping;
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
                        self.open_file_index = fizzy.editor.open_files.getIndex(dragged_file.id) orelse 0;
                    }
                }
            },
            .tree_closed => |path| {
                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and fizzy.editor.workspaces.keys()[fizzy.editor.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        const new_g = fizzy.editor.newGroupingID();
                        const idx = fizzy.editor.openOrFocusFileAtGrouping(path, new_g) catch {
                            fizzy.editor.clearFileTreeTabDragDropState();
                            continue :events_loop;
                        };
                        repointWorkspacesAfterTabDrag(fizzy.editor, null, idx);
                        // Same as tab strip: new grouping may not have a workspace ptr yet this frame.
                        fizzy.editor.open_workspace_grouping = new_g;
                        fizzy.editor.clearFileTreeTabDragDropState();
                    }
                } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        const idx = fizzy.editor.openOrFocusFileAtGrouping(path, self.grouping) catch {
                            fizzy.editor.clearFileTreeTabDragDropState();
                            continue :events_loop;
                        };
                        repointWorkspacesAfterTabDrag(fizzy.editor, null, idx);
                        self.open_file_index = idx;
                        fizzy.editor.clearFileTreeTabDragDropState();
                    }
                }
            },
        }
    }
}

pub fn drawCanvas(self: *Workspace) !void {
    var content_color = dvui.themeGet().color(.window, .fill);

    switch (builtin.os.tag) {
        .macos => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        else => {},
    }

    const has_files = fizzy.editor.open_files.values().len > 0;

    var canvas_vbox = workspaceMainCanvasVbox(content_color, has_files, self.grouping);
    defer {
        self.canvas_rect_physical = canvas_vbox.data().contentRectScale().r;
        dvui.toastsShow(canvas_vbox.data().id, canvas_vbox.data().contentRectScale().r.toNatural());
        canvas_vbox.deinit();
    }
    defer self.processTabDrag(canvas_vbox.data());

    if (has_files) {
        if (self.open_file_index >= fizzy.editor.open_files.values().len) {
            self.open_file_index = fizzy.editor.open_files.values().len - 1;
        }

        const file = &fizzy.editor.open_files.values()[self.open_file_index];
        file.editor.canvas.id = canvas_vbox.data().id;
        file.editor.workspace = self;

        if (fizzy.editor.settings.show_rulers and !dvui.firstFrame(canvas_vbox.data().id)) {
            defer fizzy.dvui.drawEdgeShadow(canvas_vbox.data().rectScale(), .top, .{});
            self.drawRuler(.horizontal);
        }

        var canvas_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer canvas_hbox.deinit();

        if (fizzy.editor.settings.show_rulers and !dvui.firstFrame(canvas_vbox.data().id)) {
            defer fizzy.dvui.drawEdgeShadow(canvas_vbox.data().rectScale(), .left, .{});
            self.drawRuler(.vertical);
        }

        self.drawTransformDialog(canvas_vbox);

        if (self.grouping != file.editor.grouping) return;

        fizzy.perf.canvasPaneDrawn();

        var file_widget = fizzy.dvui.FileWidget.init(@src(), .{
            .file = file,
            .center = self.center,
        }, .{
            .expand = .both,
            .background = false,
            .color_fill = .transparent,
        });

        defer file_widget.deinit();
        file_widget.processEvents();
    } else {
        var box = workspaceEmptyStateCard(content_color, self.grouping);
        defer box.deinit();

        // Make sure alpha is 1 before we draw the homepage, as the logo hover animation breaks if alpha is not 1
        const alpha = dvui.alpha(1.0);
        dvui.alphaSet(1.0);
        defer dvui.alphaSet(alpha);

        try self.drawHomePage(canvas_vbox);
    }
}

pub const RulerOrientation = enum {
    horizontal,
    vertical,
};

pub fn drawRuler(self: *Workspace, orientation: RulerOrientation) void {
    const file = &fizzy.editor.open_files.values()[self.open_file_index];
    const font = dvui.Font.theme(.body).larger(-1);

    const largest_label = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{file.rows - 1}) catch {
        dvui.log.err("Failed to allocate largest label", .{});
        return;
    };
    const largest_label_size = font.textSize(largest_label);
    const natural_scale = dvui.currentWindow().natural_scale;
    const largest_label_phys = largest_label_size.scale(natural_scale, dvui.Size.Physical);
    const base_ruler_size = largest_label_size.w + fizzy.editor.settings.ruler_padding;

    const ruler_thickness: f32 = switch (orientation) {
        .horizontal => blk: {
            self.horizontal_ruler_height = font.textSize("M").h + fizzy.editor.settings.ruler_padding;
            break :blk self.horizontal_ruler_height;
        },
        .vertical => blk: {
            self.vertical_ruler_width = @max(base_ruler_size, font.textSize("M").h + fizzy.editor.settings.ruler_padding);
            break :blk self.vertical_ruler_width;
        },
    };

    switch (orientation) {
        .horizontal => {
            var canvas_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer canvas_hbox.deinit();

            var corner_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .min_size_content = .{ .h = self.vertical_ruler_width, .w = self.vertical_ruler_width },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            corner_box.deinit();

            var top_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = ruler_thickness, .w = ruler_thickness },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            defer top_box.deinit();

            self.drawRulerContent(file, font, orientation, ruler_thickness, largest_label, null);
        },
        .vertical => {
            var ruler_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .vertical,
                .min_size_content = .{ .w = ruler_thickness, .h = 1.0 },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            defer ruler_box.deinit();

            self.drawRulerContent(file, font, orientation, ruler_thickness, largest_label, largest_label_phys);
        },
    }
}

/// `largest_row_index_*` come from `drawRuler` (widest row index string and its measured size in physical pixels).
fn drawRulerContent(
    self: *Workspace,
    file: *fizzy.Internal.File,
    font: dvui.Font,
    orientation: RulerOrientation,
    ruler_size: f32,
    largest_row_index_label: []const u8,
    largest_row_index_size_phys: ?dvui.Size.Physical,
) void {
    const scale = file.editor.canvas.scale;
    const canvas = file.editor.canvas;

    switch (orientation) {
        .horizontal => {
            self.horizontal_scroll_info.virtual_size.w = canvas.scroll_info.virtual_size.w;
            self.horizontal_scroll_info.virtual_size.h = ruler_size;
            self.horizontal_scroll_info.viewport.w = canvas.scroll_info.viewport.w;
            self.horizontal_scroll_info.viewport.x = canvas.scroll_info.viewport.x;
        },
        .vertical => {
            self.vertical_scroll_info.virtual_size.h = canvas.scroll_info.virtual_size.h;
            self.vertical_scroll_info.virtual_size.w = ruler_size;
            self.vertical_scroll_info.viewport.h = canvas.scroll_info.viewport.h;
            self.vertical_scroll_info.viewport.y = canvas.scroll_info.viewport.y;
        },
    }

    const scroll_info = switch (orientation) {
        .horizontal => &self.horizontal_scroll_info,
        .vertical => &self.vertical_scroll_info,
    };

    var scroll_area = dvui.scrollArea(@src(), .{
        .scroll_info = scroll_info,
        .container = true,
        .process_events_after = true,
        .horizontal_bar = .hide,
        .vertical_bar = .hide,
    }, .{ .expand = .both });
    defer scroll_area.deinit();

    const scale_rect = switch (orientation) {
        .horizontal => dvui.Rect{ .x = -canvas.origin.x, .y = 0, .w = 0, .h = 0 },
        .vertical => dvui.Rect{ .x = 0, .y = -canvas.origin.y, .w = 0, .h = 0 },
    };
    var scaler = dvui.scale(@src(), .{ .scale = &file.editor.canvas.scale }, .{ .rect = scale_rect });
    defer scaler.deinit();

    const outer_rect: dvui.Rect = switch (orientation) {
        .horizontal => .{
            .x = 0,
            .y = 0,
            .w = @as(f32, @floatFromInt(file.width())),
            .h = ruler_size / scale,
        },
        .vertical => .{
            .x = 0,
            .y = 0,
            .w = ruler_size / scale,
            .h = @as(f32, @floatFromInt(file.height())),
        },
    };
    var outer_box = dvui.box(@src(), .{ .dir = switch (orientation) {
        .horizontal => .horizontal,
        .vertical => .horizontal,
    } }, .{
        .expand = .none,
        .rect = outer_rect,
    });
    defer outer_box.deinit();

    const drag_name = switch (orientation) {
        .horizontal => self.columns_drag_name,
        .vertical => self.rows_drag_name,
    };

    var reorder = fizzy.dvui.reorder(@src(), .{ .drag_name = drag_name }, .{
        .expand = .both,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .background = false,
        .corner_radius = dvui.Rect.all(0),
    });
    defer reorder.deinit();

    const reorder_box_dir: dvui.enums.Direction = switch (orientation) {
        .horizontal => .horizontal,
        .vertical => .vertical,
    };
    var reorder_box = dvui.box(@src(), .{ .dir = reorder_box_dir }, .{
        .expand = .both,
        .background = false,
        .corner_radius = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer reorder_box.deinit();

    const ruler_stroke_color = dvui.themeGet().color(.control, .fill_hover).lighten(switch (orientation) {
        .horizontal => 2.0,
        .vertical => 0.0,
    });

    const edge_stroke_points = switch (orientation) {
        .horizontal => .{
            reorder_box.data().rectScale().r.topRight(),
            reorder_box.data().rectScale().r.bottomRight(),
        },
        .vertical => .{
            reorder_box.data().rectScale().r.bottomRight(),
            reorder_box.data().rectScale().r.bottomLeft(),
        },
    };
    defer dvui.Path.stroke(.{ .points = &edge_stroke_points }, .{
        .color = ruler_stroke_color,
        .thickness = 1.0,
    });

    const count = switch (orientation) {
        .horizontal => file.columns,
        .vertical => file.rows,
    };
    const cell_min_size: dvui.Size = switch (orientation) {
        .horizontal => .{ .w = @as(f32, @floatFromInt(file.column_width)), .h = 1.0 },
        .vertical => .{ .w = 1.0, .h = @as(f32, @floatFromInt(file.row_height)) },
    };
    const reorder_mode: fizzy.dvui.ReorderWidget.Reorderable.Mode = switch (orientation) {
        .horizontal => .any_y,
        .vertical => .any_x,
    };
    const reorder_expand: dvui.Options.Expand = switch (orientation) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };

    // Shared layout width for every row tick (widest index string); actual glyph size may differ per cell.
    const vertical_row_layout_size_phys: ?dvui.Size.Physical = switch (orientation) {
        .vertical => largest_row_index_size_phys,
        .horizontal => null,
    };

    // Captured during iteration: the highlighted target slot (drop location) screen rect.
    var target_rs_screen: ?dvui.RectScale = null;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        var reorderable = reorder.reorderable(@src(), .{
            .mode = reorder_mode,
            .clamp_to_edges = true,
        }, .{
            .expand = reorder_expand,
            .id_extra = index,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .min_size_content = cell_min_size,
        });
        defer reorderable.deinit();

        if (reorderable.targetRectScale()) |trs| {
            target_rs_screen = trs;
        }

        var button_color = if (reorder.drag_point != null) dvui.themeGet().color(.control, .fill).opacity(0.85) else dvui.themeGet().color(.window, .fill);

        if (fizzy.dvui.hovered(reorderable.data())) {
            button_color = dvui.themeGet().color(.control, .fill_hover);
            dvui.cursorSet(.hand);
        }

        var cell_box: dvui.BoxWidget = undefined;
        cell_box.init(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = true,
            .color_fill = button_color,
            .id_extra = index,
        });

        switch (orientation) {
            .horizontal => {
                if (reorderable.floating()) {
                    self.columns_drag_index = index;
                    reorder.reorderable_size.h = 0.0;
                    dvui.cursorSet(.hand);
                }
                if (reorderable.removed()) self.columns_removed_index = index;
                if (reorderable.insertBefore()) self.columns_insert_before_index = index;
                if (reorderable.targetID()) |target_id| self.columns_target_id = target_id;
                if (self.columns_drag_index) |_| {
                    var mouse_pt = @constCast(&file.editor.canvas).dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    mouse_pt.y = 0.0;
                    mouse_pt.x = std.math.clamp(mouse_pt.x, 0.0, @as(f32, @floatFromInt(file.width() - 1)));
                    self.columns_target_index = file.columnIndex(mouse_pt);
                }
            },
            .vertical => {
                if (reorderable.floating()) {
                    self.rows_drag_index = index;
                    reorder.reorderable_size.w = 0.0;
                    dvui.cursorSet(.hand);
                }
                if (reorderable.removed()) self.rows_removed_index = index;
                if (reorderable.insertBefore()) self.rows_insert_before_index = index;
                if (reorderable.targetID()) |target_id| self.rows_target_id = target_id;
                if (self.rows_drag_index) |_| {
                    var mouse_pt = @constCast(&file.editor.canvas).dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    mouse_pt.x = 0.0;
                    mouse_pt.y = std.math.clamp(mouse_pt.y, 0.0, @as(f32, @floatFromInt(file.height() - 1)));
                    self.rows_target_index = file.rowIndex(mouse_pt);
                }
            },
        }

        {
            defer cell_box.deinit();

            // The dragged item's cell_box is parented to the reorderable's floating widget
            // (rendered at the mouse position). We collapse that floating widget to h/w = 0
            // above, but `dvui.renderText` is not clipped by that, so the label would still
            // appear at the cursor. Skip the visible cell rendering entirely while floating;
            // the dragged label is drawn over the highlighted target slot below instead.
            if (!reorderable.floating()) {
                cell_box.drawBackground();

                const label = switch (orientation) {
                    .horizontal => file.fmtColumn(dvui.currentWindow().arena(), @intCast(index)) catch {
                        dvui.log.err("Failed to allocate label", .{});
                        return;
                    },
                    .vertical => std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{index}) catch {
                        dvui.log.err("Failed to allocate label", .{});
                        return;
                    },
                };

                self.drawRulerLabel(.{
                    .font = font,
                    .label = label,
                    .rect = cell_box.data().rectScale().r,
                    .color = dvui.themeGet().color(.control, .text).opacity(0.5),
                    .mode = switch (orientation) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .largest_label = if (orientation == .vertical) largest_row_index_label else null,
                    .ref_size_physical = vertical_row_layout_size_phys,
                });

                const cell_rect = cell_box.data().rectScale().r;
                const cell_stroke_points = switch (orientation) {
                    .horizontal => .{ cell_rect.topLeft(), cell_rect.bottomLeft() },
                    .vertical => .{ cell_rect.topLeft(), cell_rect.topRight() },
                };
                dvui.Path.stroke(.{ .points = &cell_stroke_points }, .{ .color = ruler_stroke_color, .thickness = 2.0 });
            }

            loop: for (dvui.events()) |*e| {
                if (!cell_box.matchEvent(e)) continue;

                switch (e.evt) {
                    .mouse => |me| {
                        if (me.action == .press and me.button.pointer()) {
                            e.handle(@src(), cell_box.data());
                            dvui.captureMouse(cell_box.data(), e.num);
                            dvui.dragPreStart(me.p, .{
                                .size = reorderable.data().rectScale().r.size(),
                                .offset = reorderable.data().rectScale().r.topLeft().diff(me.p),
                            });
                        } else if (me.action == .release and me.button.pointer()) {
                            dvui.captureMouse(null, e.num);
                            dvui.dragEnd();
                            switch (orientation) {
                                .horizontal => self.columns_drag_index = null,
                                .vertical => self.rows_drag_index = null,
                            }
                        } else if (me.action == .motion) {
                            if (dvui.captured(cell_box.data().id)) {
                                e.handle(@src(), cell_box.data());
                                if (dvui.dragging(me.p, null)) |_| {
                                    reorderable.reorder.dragStart(reorderable.data().id.asUsize(), me.p, 0);
                                    break :loop;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    const final_slot_id = switch (orientation) {
        .horizontal => file.columns,
        .vertical => file.rows,
    };
    if (reorder.needFinalSlot()) {
        var reorderable = reorder.reorderable(@src(), .{
            .mode = reorder_mode,
            .last_slot = true,
            .clamp_to_edges = true,
        }, .{
            .expand = reorder_expand,
            .id_extra = final_slot_id,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .min_size_content = cell_min_size,
        });
        defer reorderable.deinit();

        if (reorderable.targetRectScale()) |trs| {
            target_rs_screen = trs;
        }

        if (reorderable.insertBefore()) {
            switch (orientation) {
                .horizontal => self.columns_insert_before_index = final_slot_id,
                .vertical => self.rows_insert_before_index = final_slot_id,
            }
        }
    }

    // Drag overlay: draw the dragged column/row label on the highlighted target slot in
    // highlight-text color (no extra fill, the reorderable's own focus fill is the
    // background) and a thick err-colored marker line at the dragged-from position in the
    // ruler that lines up with the equivalent indicator in the file canvas.
    const drag_idx_for_overlay = switch (orientation) {
        .horizontal => self.columns_drag_index,
        .vertical => self.rows_drag_index,
    };
    if (drag_idx_for_overlay) |di| {
        const target_idx_opt = switch (orientation) {
            .horizontal => self.columns_target_index,
            .vertical => self.rows_target_index,
        };
        const same_slot = target_idx_opt == di;

        if (target_rs_screen) |trs| {
            const drag_label_opt: ?[]const u8 = switch (orientation) {
                .horizontal => file.fmtColumn(dvui.currentWindow().arena(), @intCast(di)) catch null,
                .vertical => std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{di}) catch null,
            };
            if (drag_label_opt) |drag_label| {
                if (same_slot) {
                    // Reorderable still draws theme focus fill for the drop target; paint control
                    // hover on top so "no move" matches ruler button hover styling.
                    trs.r.fill(.all(0), .{ .color = dvui.themeGet().color(.control, .fill_hover), .fade = 1.0 });
                }
                self.drawRulerLabel(.{
                    .font = font,
                    .label = drag_label,
                    .rect = trs.r,
                    .color = if (same_slot)
                        dvui.themeGet().color(.control, .text).opacity(0.5)
                    else
                        dvui.themeGet().color(.highlight, .text),
                    .mode = switch (orientation) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .largest_label = if (orientation == .vertical) largest_row_index_label else null,
                    .ref_size_physical = vertical_row_layout_size_phys,
                });
            }
        }

        // Use the canvas data->screen mapping for the cross-axis position so the marker
        // line aligns exactly with the err indicator drawn over the file canvas grid.
        // The other axis uses the ruler's own screen extents so the line fills the ruler.
        const target_idx_for_line = switch (orientation) {
            .horizontal => self.columns_target_index,
            .vertical => self.rows_target_index,
        };
        if (target_idx_for_line) |ti| {
            if (di != ti) {
                const removed_data_rect = switch (orientation) {
                    .horizontal => file.columnRect(di),
                    .vertical => file.rowRect(di),
                };
                const removed_canvas_screen = file.editor.canvas.screenFromDataRect(removed_data_rect);
                const ruler_screen = outer_box.data().contentRectScale().r;
                const err_color = dvui.themeGet().color(.err, .fill);
                const thickness = 3.0 * dvui.currentWindow().natural_scale;
                switch (orientation) {
                    .horizontal => {
                        const edge_x = if (di < ti)
                            removed_canvas_screen.x
                        else
                            removed_canvas_screen.x + removed_canvas_screen.w;
                        dvui.Path.stroke(.{ .points = &.{
                            .{ .x = edge_x, .y = ruler_screen.y },
                            .{ .x = edge_x, .y = ruler_screen.y + ruler_screen.h },
                        } }, .{ .thickness = thickness, .color = err_color });
                    },
                    .vertical => {
                        const edge_y = if (di < ti)
                            removed_canvas_screen.y
                        else
                            removed_canvas_screen.y + removed_canvas_screen.h;
                        dvui.Path.stroke(.{ .points = &.{
                            .{ .x = ruler_screen.x, .y = edge_y },
                            .{ .x = ruler_screen.x + ruler_screen.w, .y = edge_y },
                        } }, .{ .thickness = thickness, .color = err_color });
                    },
                }
            }
        }
    }
}

pub const TextLabelOptions = struct {
    pub const Mode = enum {
        horizontal,
        vertical,
    };

    font: dvui.Font,
    label: []const u8,
    rect: dvui.Rect.Physical,
    color: dvui.Color,
    mode: Mode = .horizontal,
    /// Widest row index string (e.g. `"99"`); layout cell size uses this, text may be a shorter index.
    largest_label: ?[]const u8 = null,
    /// When set, layout size for that widest string (already × `natural_scale`); skips `textSize(largest_label)` per cell.
    ref_size_physical: ?dvui.Size.Physical = null,
};

pub fn drawRulerLabel(_: *Workspace, options: TextLabelOptions) void {
    const font = options.font;
    const label = options.label;
    const rect = options.rect;
    const color = options.color;
    const natural = dvui.currentWindow().natural_scale;

    const ref_for_layout = options.largest_label orelse label;
    const label_size = options.ref_size_physical orelse font.textSize(ref_for_layout).scale(natural, dvui.Size.Physical);
    const actual_label_size = if (std.mem.eql(u8, ref_for_layout, label))
        label_size
    else
        font.textSize(label).scale(natural, dvui.Size.Physical);

    const padding = fizzy.editor.settings.ruler_padding * natural;

    var label_rect = rect;

    if (label_size.w + padding <= label_rect.w and options.mode == .horizontal) {
        label_rect.h = label_size.h + padding;
        label_rect.x += (label_rect.w - actual_label_size.w) / 2.0;
        label_rect.y += (label_rect.h - actual_label_size.h) / 2.0;

        dvui.renderText(.{
            .text = label,
            .font = font,
            .color = color,
            .rs = .{
                .r = label_rect,
                .s = natural,
            },
        }) catch {
            dvui.log.err("Failed to render text", .{});
        };
    } else if (label_size.h + padding <= label_rect.h and options.mode == .vertical) {
        label_rect.w = label_size.h + padding;
        label_rect.x += (label_rect.w - actual_label_size.w) / 2.0;
        label_rect.y += (label_rect.h - actual_label_size.h) / 2.0;

        dvui.renderText(.{
            .text = label,
            .font = font,
            .color = color,
            .rs = .{
                .r = label_rect,
                .s = natural,
            },
        }) catch {
            dvui.log.err("Failed to render text", .{});
        };
    }
}

pub fn processColumnReorder(self: *Workspace) void {
    if (self.columns_removed_index) |columns_removed_index| {
        if (self.columns_insert_before_index) |columns_insert_before_index| {
            defer self.columns_removed_index = null;
            defer self.columns_insert_before_index = null;

            if (columns_removed_index == columns_insert_before_index or columns_removed_index + 1 == columns_insert_before_index) return;

            const file = &fizzy.editor.open_files.values()[self.open_file_index];

            file.reorderColumns(columns_removed_index, columns_insert_before_index) catch {
                dvui.log.err("Failed to reorder columns", .{});
                return;
            };

            // We'll store the previous indices for clarity.
            const prev_removed_index = columns_removed_index;
            const prev_insert_before_index = columns_insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .columns,
                        .removed_index = prev_insert_before_index - 1,
                        .insert_before_index = prev_removed_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            } else {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .columns,
                        .removed_index = prev_insert_before_index,
                        .insert_before_index = prev_removed_index + 1,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }
    }
}

pub fn processRowReorder(self: *Workspace) void {
    if (self.rows_removed_index) |rows_removed_index| {
        if (self.rows_insert_before_index) |rows_insert_before_index| {
            defer self.rows_removed_index = null;
            defer self.rows_insert_before_index = null;
            if (rows_removed_index == rows_insert_before_index or rows_removed_index + 1 == rows_insert_before_index) return;

            const file = &fizzy.editor.open_files.values()[self.open_file_index];

            file.reorderRows(rows_removed_index, rows_insert_before_index) catch {
                dvui.log.err("Failed to reorder rows", .{});
                return;
            };

            // We'll store the previous indices for clarity.
            const prev_removed_index = rows_removed_index;
            const prev_insert_before_index = rows_insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .rows,
                        .removed_index = prev_insert_before_index - 1,
                        .insert_before_index = prev_removed_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            } else {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .rows,
                        .removed_index = prev_insert_before_index,
                        .insert_before_index = prev_removed_index + 1,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }
    }
}

pub fn drawTransformDialog(self: *Workspace, canvas_vbox: *dvui.BoxWidget) void {
    const file = &fizzy.editor.open_files.values()[self.open_file_index];
    if (file.editor.transform) |*transform| {
        var rect = canvas_vbox.data().rect;
        rect.w = 0;
        rect.h = 0;

        var fw: dvui.FloatingWidget = undefined;
        fw.init(@src(), .{}, .{
            .rect = .{ .x = canvas_vbox.data().rectScale().r.toNatural().x + 10, .y = canvas_vbox.data().rectScale().r.toNatural().y + 10, .w = 0, .h = 0 },
            .expand = .none,
            .background = true,
            .color_fill = dvui.themeGet().color(.control, .fill),
            .corner_radius = dvui.Rect.all(8),
            .box_shadow = .{
                .color = .black,
                .alpha = 0.2,
                .fade = 8,
                .corner_radius = dvui.Rect.all(8),
            },
        });
        defer fw.deinit();

        var anim = dvui.animate(@src(), .{ .kind = .vertical, .duration = 450_000, .easing = dvui.easing.outBack }, .{});
        defer anim.deinit();

        var anim_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
        });
        defer anim_box.deinit();

        dvui.labelNoFmt(@src(), "TRANSFORM", .{ .align_x = 0.5 }, .{
            .padding = dvui.Rect.all(4),
            .expand = .horizontal,
            .font = dvui.Font.theme(.heading).withWeight(.bold),
        });
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        var degrees: f32 = std.math.radiansToDegrees(transform.rotation);

        var slider_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
        });

        if (dvui.sliderEntry(@src(), "{d:0.0}°", .{
            .value = &degrees,
            .min = 0,
            .max = 360,
            .interval = 1,
        }, .{ .expand = .horizontal, .color_fill = dvui.themeGet().color(.window, .fill) })) {
            transform.rotation = std.math.degreesToRadians(degrees);
        }
        slider_box.deinit();

        if (transform.ortho) {
            var box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer box.deinit();
            dvui.label(@src(), "Width: {d:0.0}", .{transform.point(.bottom_left).diff(transform.point(.bottom_right).*).length()}, .{ .expand = .horizontal, .font = dvui.Font.theme(.heading) });
            dvui.label(@src(), "Height: {d:0.0}", .{transform.point(.top_left).diff(transform.point(.bottom_left).*).length()}, .{ .expand = .horizontal, .font = dvui.Font.theme(.heading) });
        }

        {
            var box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer box.deinit();
            if (dvui.buttonIcon(@src(), "transform_cancel", icons.tvg.lucide.@"trash-2", .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{ .style = .err, .expand = .horizontal })) {
                fizzy.editor.cancel() catch {
                    dvui.log.err("Failed to cancel transform", .{});
                };
            }
            if (dvui.buttonIcon(@src(), "transform_accept", icons.tvg.lucide.check, .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{ .style = .highlight, .expand = .horizontal })) {
                fizzy.editor.accept() catch {
                    dvui.log.err("Failed to accept transform", .{});
                };
            }
        }
    }
}

pub fn drawHomePage(_: *Workspace, canvas_vbox: *dvui.BoxWidget) !void {
    const logo_pixel_size = 32;
    const logo_width = 3;
    const logo_height = 5;

    const logo_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .none,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = false,
        .padding = dvui.Rect.all(10),
    });
    defer logo_vbox.deinit();

    { // Logo

        const vbox2 = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .gravity_x = 0.5,
            .min_size_content = .{ .w = logo_pixel_size * logo_width, .h = logo_pixel_size * logo_height },
            .padding = dvui.Rect.all(20),
        });
        defer vbox2.deinit();

        for (0..4) |i| {
            const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .min_size_content = .{ .w = logo_pixel_size * logo_width, .h = logo_pixel_size },
                .margin = dvui.Rect.all(0),
                .padding = dvui.Rect.all(0),
                .id_extra = i,
            });
            defer hbox.deinit();

            for (0..3) |j| {
                const index = i * logo_width + j;
                var fizzy_color = logo_colors[index];

                if (fizzy_color.value[3] < 1.0 and fizzy_color.value[3] > 0.0) {
                    const theme_bg = dvui.themeGet().color(.window, .fill);
                    fizzy_color = fizzy_color.lerp(fizzy.math.Color.initBytes(theme_bg.r, theme_bg.g, theme_bg.b, 255), fizzy_color.value[3]);
                    fizzy_color.value[3] = 1.0;
                }

                const color = fizzy_color.bytes();

                const pixel = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .min_size_content = .{ .w = logo_pixel_size, .h = logo_pixel_size },
                    .id_extra = index,
                    .background = false,
                    .color_fill = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                });

                const rect = pixel.data().rect.outset(.{ .x = 0, .y = 0 });
                const rs = pixel.data().rectScale();
                pixel.deinit();

                if (fizzy_color.value[3] <= 0.0) continue;

                try drawBubble(rect, rs, color, index);
            }
        }
    }

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .none,
        .gravity_x = 0.5,
    });

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = true }, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
            .padding = dvui.Rect.all(2),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.window, .fill_press),
        });
        defer button.deinit();

        button.processEvents();
        button.drawBackground();

        fizzy.dvui.labelWithKeybind(
            "New File",
            dvui.currentWindow().keybinds.get("new_file") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
        );

        if (button.clicked()) {
            fizzy.editor.requestNewFileDialog();
        }
    }
    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = true }, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
            .padding = dvui.Rect.all(2),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.window, .fill_press),
        });
        defer button.deinit();

        button.processEvents();
        button.drawBackground();

        fizzy.dvui.labelWithKeybind(
            "Open Folder",
            dvui.currentWindow().keybinds.get("open_folder") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
        );

        if (button.clicked()) {
            fizzy.backend.showOpenFolderDialog(setProjectFolderCallback, null);
        }
    }

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = true }, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
            .padding = dvui.Rect.all(2),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.window, .fill_press),
        });
        defer button.deinit();

        button.processEvents();
        button.drawBackground();

        fizzy.dvui.labelWithKeybind(
            "Open Files",
            dvui.currentWindow().keybinds.get("open_files") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0, .font = dvui.Font.theme(.heading) },
        );

        if (button.clicked()) {
            // if (try dvui.dialogNativeFileOpenMultiple(dvui.currentWindow().arena(), .{
            //     .title = "Open Files...",
            //     .filter_description = ".pixi, .png",
            //     .filters = &.{ "*.pixi", "*.png" },
            // })) |files| {
            //     for (files) |file| {
            //         _ = fizzy.editor.openFilePath(file, fizzy.editor.open_workspace_grouping) catch {
            //             std.log.err("Failed to open file: {s}", .{file});
            //         };
            //     }
            // }

            fizzy.backend.showOpenFileDialog(openFilesCallback, &.{
                .{ .name = "Image Files", .pattern = "fizzy;png;jpg;jpeg" },
            }, "", null);
        }
    }
    vbox.deinit();

    const spacer = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .h = 30 } });

    {
        var recents_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .gravity_x = 0.5,
            .max_size_content = .{ .h = (canvas_vbox.data().rect.h - spacer.rect.y) / 3.0, .w = canvas_vbox.data().rect.w / 2.0 },
        });
        defer recents_box.deinit();

        var scroll_area = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .color_border = dvui.themeGet().color(.control, .fill),
            .corner_radius = dvui.Rect.all(8),
            .color_fill = .transparent,
        });
        defer scroll_area.deinit();

        var i: usize = fizzy.editor.recents.folders.items.len;
        while (i > 0) : (i -= 1) {
            var anim = dvui.animate(@src(), .{
                .kind = .horizontal,
                .duration = 150_000 + 150_000 * @as(i32, @intCast(i)),
                .easing = dvui.easing.outBack,
            }, .{
                .id_extra = i,
                .expand = .horizontal,
            });
            defer anim.deinit();

            const folder = fizzy.editor.recents.folders.items[i - 1];
            if (dvui.button(@src(), folder, .{
                .draw_focus = false,
            }, .{
                .expand = .horizontal,
                .font = dvui.Font.theme(.mono).larger(-2.0),
                .id_extra = i,
                .margin = dvui.Rect.all(1),
                .padding = dvui.Rect.all(2),
                .color_fill = .transparent,
                .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
                .color_fill_press = dvui.themeGet().color(.window, .fill_press),
                .color_text = dvui.themeGet().color(.control, .text).opacity(0.5),
            })) {
                try fizzy.editor.setProjectFolder(folder);
            }
        }
    }
}

pub fn drawBubble(rect: dvui.Rect, rs: dvui.RectScale, color: [4]u8, id_extra: usize) !void {
    var new_rect = dvui.Rect{
        .x = rect.x - (1 / dvui.currentWindow().rectScale().s),
        .y = rect.y - rect.h,
        .w = rect.w + (1 / dvui.currentWindow().rectScale().s),
        .h = rect.h,
    };

    for (dvui.events()) |evt| {
        switch (evt.evt) {
            .mouse => |me| {
                const dx = @abs(me.p.x - (rs.r.x + rs.r.w * 0.5)) / rs.s;
                const dy = @abs(me.p.y - (rs.r.y - rs.r.h * 0.5)) / rs.s;
                const distance = @sqrt(dx * dx + dy * dy);

                const min_h: f32 = 0;
                const max_h: f32 = rect.h;

                const max_distance: f32 = rect.h * 2.0;

                var t = distance / max_distance;
                if (t > 1.0) t = 1.0;
                if (t < 0.0) t = 0.0;
                const scaled_h = max_h - (max_h - min_h) * t;

                new_rect.h = @ceil(scaled_h);
                new_rect.y = @ceil(rect.y - new_rect.h);
            },
            else => {},
        }
    }

    const corner_radius: dvui.Rect = .{ .x = rs.r.w / 2.0, .y = rs.r.h / 2.0 };

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .rect = new_rect,
        .id_extra = id_extra,
        .color_fill = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
    });

    var path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
    defer path.deinit();

    const rad = corner_radius;
    const r = box.data().contentRectScale().r;
    box.deinit();
    const tl = dvui.Point.Physical{ .x = r.x + rad.x, .y = r.y + rad.x };
    const bl = dvui.Point.Physical{ .x = r.x + rad.h, .y = r.y + r.h - rad.h };
    const br = dvui.Point.Physical{ .x = r.x + r.w - rad.w, .y = r.y + r.h - rad.w };
    const tr = dvui.Point.Physical{ .x = r.x + r.w - rad.y, .y = r.y + rad.y };
    path.addRect(rs.r.outsetAll(1), dvui.Rect.Physical.all(0));

    if (new_rect.h > 0) {
        path.addArc(tl, rad.x, dvui.math.pi * 1.5, dvui.math.pi, true);
        path.addArc(bl, rad.h, dvui.math.pi, dvui.math.pi * 0.5, true);
        path.addArc(br, rad.w, dvui.math.pi * 0.5, 0, true);
        path.addArc(tr, rad.y, dvui.math.pi * 2.0, dvui.math.pi * 1.5, false);
    }

    path.build().fillConvex(.{ .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, .fade = 1.0 });
}

// This should never be able to return more than one folder
pub fn setProjectFolderCallback(folder: ?[][:0]const u8) void {
    if (folder) |f| {
        fizzy.editor.setProjectFolder(f[0]) catch {
            dvui.log.err("Failed to set project folder: {s}", .{f[0]});
        };
    }
}

pub fn openFilesCallback(files: ?[][:0]const u8) void {
    if (files) |f| {
        for (f) |file| {
            _ = fizzy.editor.openFilePath(file, fizzy.editor.open_workspace_grouping) catch {
                dvui.log.err("Failed to open file: {s}", .{file});
            };
        }
    }
}
