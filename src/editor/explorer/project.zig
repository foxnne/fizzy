const std = @import("std");
const icons = @import("icons");

const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

pub fn draw() !void {
    if (fizzy.editor.folder) |folder| {
        const packing = fizzy.editor.isPackingActive();
        if (packProjectButton(packing)) {
            fizzy.editor.startPackProject() catch |err| {
                dvui.log.err("Failed to start project pack: {any}", .{err});
            };
        }

        if (fizzy.editor.project) |project| {
            if (fizzy.packer.atlas) |atlas| {
                if (dvui.button(@src(), "Export Project", .{ .draw_focus = false }, .{
                    .expand = .horizontal,
                    .style = .highlight,
                })) {
                    if (project.packed_atlas_output) |output| {
                        atlas.save(output, .data) catch {
                            dvui.log.err("Failed to save atlas data", .{});
                        };
                    }

                    if (project.packed_image_output) |image_output| {
                        atlas.save(image_output, .source) catch {
                            dvui.log.err("Failed to save atlas image", .{});
                        };
                    }
                }
            }

            const tl = dvui.textLayout(@src(), .{}, .{
                .expand = .none,
                .margin = dvui.Rect.all(0),
                .background = false,
            });
            defer tl.deinit();

            const project_path = std.fs.path.join(dvui.currentWindow().lifo(), &.{ folder, ".fizproject" }) catch {
                dvui.log.err("Failed to join project path", .{});
                return;
            };
            defer dvui.currentWindow().lifo().free(project_path);

            tl.addText(project_path, .{ .color_text = dvui.themeGet().color(.control, .text) });
        } else {
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .max_size_content = .{ .w = fizzy.editor.explorer.scroll_info.virtual_size.w, .h = std.math.floatMax(f32) },
            });
            defer box.deinit();

            const tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
            tl.addText("No project file found!\n\n", .{});
            tl.addText("Would you like to create a project file to specify constant output paths and other project-specific behaviors?\n", .{ .color_text = dvui.themeGet().color(.control, .text) });
            tl.deinit();

            if (dvui.button(@src(), "Create Project", .{}, .{ .expand = .horizontal })) {
                fizzy.editor.project = .{};
            }
            return;
        }

        pathTextEntry(.atlas) catch {
            dvui.log.err("Failed to draw path text entry", .{});
        };
        pathTextEntry(.image) catch {
            dvui.log.err("Failed to draw path text entry", .{});
        };
    }

    // {
    //     var set_text: bool = false;
    //     dvui.labelNoFmt(@src(), "Atlas Data Output:", .{}, .{});

    //     var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    //     defer box.deinit();

    //     if (dvui.buttonIcon(@src(), "example.atlas", icons.tvg.lucide.@"folder-open", .{}, .{
    //         .fill_color = .fromTheme(.text_press),
    //     }, .{
    //         .gravity_y = 0.5,
    //         .padding = dvui.Rect.all(4),
    //         .border = dvui.Rect.all(1),
    //         .margin = .{ .x = 1, .w = 1 },
    //     })) {
    //         const valid_path: bool = blk: {
    //             if (project.packed_atlas_output) |output| {
    //                 const base_name = std.fs.path.basename(output);
    //                 if (std.mem.indexOf(u8, output, base_name)) |i| {
    //                     if (!std.fs.path.isAbsolute(output[0..i])) {
    //                         break :blk false;
    //                     }

    //                     std.Io.Dir.accessAbsolute(dvui.io, output[0..i], .{}) catch {
    //                         break :blk false;
    //                     };
    //                 } else {
    //                     if (!std.fs.path.isAbsolute(output)) {
    //                         break :blk false;
    //                     }
    //                     std.Io.Dir.accessAbsolute(dvui.io, output, .{}) catch {
    //                         break :blk false;
    //                     };
    //                 }
    //             }

    //             break :blk true;
    //         };

    //         if (dvui.dialogNativeFileSave(fizzy.app.allocator, .{
    //             .title = "Select Atlas Data Output",
    //             .filters = &.{".atlas"},
    //             .filter_description = "Atlas file",
    //             .path = if (valid_path) project.packed_atlas_output else null,
    //         }) catch null) |path| {
    //             project.packed_atlas_output = fizzy.app.allocator.dupe(u8, path[0..]) catch null;
    //             set_text = true;
    //         } else {
    //             dvui.log.err("Project failed to copy new path", .{});
    //         }
    //     }

    //     const te = dvui.textEntry(@src(), .{
    //         .placeholder = "example.atlas",
    //     }, .{
    //         .padding = dvui.Rect.all(5),
    //         .expand = .horizontal,
    //         .margin = dvui.Rect.all(0),
    //         .color_text = if (project.packed_atlas_output) |_| .text else .text_press,
    //     });

    //     defer te.deinit();

    //     if (project.packed_atlas_output) |packed_atlas_output| {
    //         if (dvui.firstFrame(te.data().id) or set_text) {
    //             te.textSet(packed_atlas_output, false);
    //         }
    //     }

    //     if (te.text_changed) {
    //         const t = te.getText();
    //         if (t.len > 0) {
    //             project.packed_atlas_output = fizzy.app.allocator.dupe(u8, t) catch null;
    //         } else {
    //             project.packed_atlas_output = null;
    //         }
    //     }
    // }

    // _ = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .h = 10 } });

    // {
    //     var set_text: bool = false;
    //     dvui.labelNoFmt(@src(), "Atlas Image Output:", .{}, .{});

    //     var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    //     defer box.deinit();

    //     if (dvui.buttonIcon(@src(), "example.atlas", icons.tvg.lucide.@"folder-open", .{}, .{
    //         .fill_color = .fromTheme(.text_press),
    //     }, .{
    //         .gravity_y = 0.5,
    //         .padding = dvui.Rect.all(4),
    //         .border = dvui.Rect.all(1),
    //         .margin = .{ .x = 1, .w = 1 },
    //     })) {
    //         const valid_path: bool = blk: {
    //             if (project.packed_image_output) |output| {
    //                 const base_name = std.fs.path.basename(output);
    //                 if (std.mem.indexOf(u8, output, base_name)) |i| {
    //                     if (!std.fs.path.isAbsolute(output[0..i])) {
    //                         break :blk false;
    //                     }

    //                     std.Io.Dir.accessAbsolute(dvui.io, output[0..i], .{}) catch {
    //                         break :blk false;
    //                     };
    //                 } else {
    //                     if (!std.fs.path.isAbsolute(output)) {
    //                         break :blk false;
    //                     }
    //                     std.Io.Dir.accessAbsolute(dvui.io, output, .{}) catch {
    //                         break :blk false;
    //                     };
    //                 }
    //             }

    //             break :blk true;
    //         };

    //         if (dvui.dialogNativeFileSave(fizzy.app.allocator, .{
    //             .title = "Select Atlas Image Output",
    //             .filters = &.{".png"},
    //             .filter_description = "Image file",
    //             .path = if (valid_path) project.packed_image_output else null,
    //         }) catch null) |path| {
    //             project.packed_image_output = fizzy.app.allocator.dupe(u8, path[0..]) catch null;
    //             set_text = true;
    //         } else {
    //             dvui.log.err("Project failed to copy new path", .{});
    //         }
    //     }

    //     const te = dvui.textEntry(@src(), .{
    //         .placeholder = "example.png",
    //     }, .{
    //         .padding = dvui.Rect.all(5),
    //         .expand = .horizontal,
    //         .margin = dvui.Rect.all(0),
    //         .color_text = if (project.packed_image_output) |_| .text else .text_press,
    //     });

    //     defer te.deinit();

    //     if (project.packed_image_output) |packed_image_output| {
    //         if (dvui.firstFrame(te.data().id) or set_text) {
    //             te.textSet(packed_image_output, false);
    //         }
    //     }

    //     if (te.text_changed) {
    //         const t = te.getText();
    //         if (t.len > 0) {
    //             project.packed_image_output = fizzy.app.allocator.dupe(u8, t) catch null;
    //         } else {
    //             project.packed_image_output = null;
    //         }
    //     }
    // }

}

const PathType = enum {
    atlas,
    image,
};

fn pathTextEntry(path_type: PathType) !void {
    if (fizzy.editor.project) |*project| {
        const output_path = switch (path_type) {
            .atlas => &project.packed_atlas_output,
            .image => &project.packed_image_output,
        };

        const index: usize = switch (path_type) {
            .atlas => 0,
            .image => 1,
        };

        defer _ = dvui.spacer(@src(), .{ .id_extra = index });

        const label_text = switch (path_type) {
            .atlas => "Atlas Data Output:",
            .image => "Atlas Image Output:",
        };

        var set_text: bool = false;
        dvui.labelNoFmt(@src(), label_text, .{}, .{
            .id_extra = index,
        });

        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = index });
        defer box.deinit();

        if (dvui.buttonIcon(@src(), "example.atlas", icons.tvg.lucide.@"folder-open", .{}, .{}, .{
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(4),
            .border = dvui.Rect.all(1),
            .margin = .{ .x = 1, .w = 1 },
            .id_extra = index,
        })) {
            const valid_path: bool = blk: {
                if (output_path.*) |output| {
                    const base_name = std.fs.path.basename(output);
                    if (std.mem.indexOf(u8, output, base_name)) |i| {
                        if (!std.fs.path.isAbsolute(output[0..i])) {
                            break :blk false;
                        }

                        std.Io.Dir.accessAbsolute(dvui.io, output[0..i], .{}) catch {
                            break :blk false;
                        };
                    } else {
                        if (!std.fs.path.isAbsolute(output)) {
                            break :blk false;
                        }
                        std.Io.Dir.accessAbsolute(dvui.io, output, .{}) catch {
                            break :blk false;
                        };
                    }
                }

                break :blk true;
            };

            fizzy.backend.showSaveFileDialog(if (path_type == .atlas) packedAtlasOutputCallback else packedImageOutputCallback, &.{
                if (path_type == .atlas) .{ .name = "Atlas Data", .pattern = "atlas" } else .{ .name = "Atlas Image", .pattern = "png;jpg;jpeg" },
            }, "", if (valid_path) output_path.* else null);
            set_text = true;
        }

        const te = dvui.textEntry(@src(), .{
            .placeholder = "example.atlas",
        }, .{
            .padding = dvui.Rect.all(5),
            .expand = .horizontal,
            .margin = dvui.Rect.all(0),
            .color_text = if (output_path.*) |_| dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
            .id_extra = index,
        });

        defer te.deinit();

        if (output_path.*) |packed_atlas_output| {
            if (dvui.firstFrame(te.data().id) or dvui.focusedWidgetId() != te.data().id) {
                te.textSet(packed_atlas_output, false);
            }
        }

        if (te.text_changed) {
            const t = te.getText();
            if (t.len > 0) {
                output_path.* = fizzy.app.allocator.dupe(u8, t) catch null;
            } else {
                output_path.* = null;
            }
        }
    }
}

/// "Pack Project" button. Same look-and-feel as `dvui.button`, but with a bubble spinner
/// pinned to the right edge while a pack is in flight. Always interactive — rapid clicks /
/// per-save repack triggers coalesce via `Editor.startPackProject` cancelling predecessors.
fn packProjectButton(packing: bool) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .expand = .horizontal,
        .style = .highlight,
    });
    defer bw.deinit();

    bw.processEvents();
    bw.drawBackground();
    const clicked = bw.clicked();

    // Center label across the full button rect via gravity. Mirrors `dvui.button`'s call
    // signature so the text picks up the same hovered/pressed colors.
    const label_text: []const u8 = if (packing) "Packing…" else "Pack Project";
    const content_opts = (dvui.Options{}).strip().override(bw.style()).override(.{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    dvui.labelNoFmt(@src(), label_text, .{ .align_x = 0.5, .align_y = 0.5 }, content_opts);

    // Spinner overlays at the right edge — same content rect as the label, but anchored to
    // `gravity_x = 1.0`. Sized to roughly match the cap height so it doesn't fight the label.
    if (packing) {
        fizzy.dvui.bubbleSpinner(@src(), (dvui.Options{}).strip().override(bw.style()).override(.{
            .min_size_content = .{ .w = 16, .h = 16 },
            .gravity_x = 1.0,
            .gravity_y = 0.5,
            .padding = .{ .w = 4 },
        }));
    }

    bw.drawFocus();
    return clicked;
}

pub fn packedAtlasOutputCallback(paths: ?[][:0]const u8) void {
    if (fizzy.editor.project) |*project| {
        const output_path = &project.packed_atlas_output;

        if (paths) |paths_| {
            for (paths_) |path| {
                output_path.* = fizzy.app.allocator.dupe(u8, path) catch null;
            }
        }
    }
}

pub fn packedImageOutputCallback(paths: ?[][:0]const u8) void {
    if (fizzy.editor.project) |*project| {
        const output_path = &project.packed_image_output;

        if (paths) |paths_| {
            for (paths_) |path| {
                output_path.* = fizzy.app.allocator.dupe(u8, path) catch null;
            }
        }
    }
}
