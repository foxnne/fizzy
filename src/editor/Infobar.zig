const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const icons = @import("icons");
const update_notify = @import("../update_notify.zig");
const Dialogs = fizzy.Editor.Dialogs;

pub const Infobar = @This();

/// Most recent SCREEN-space (physical pixel) Y of the infobar's top edge, set
/// during `draw`. Used by `update_notify.drawAbove` to anchor the launch toast
/// directly above the infobar. Physical coords because FloatingWidget's `from`
/// anchor takes a `Point.Physical`. `null` until the first draw has run.
pub var last_top_y_physical: ?f32 = null;

pub fn init() !Infobar {
    return .{};
}

pub fn deinit() void {
    // TODO: Free memory
}

pub fn draw(_: Infobar) !void {
    const font = dvui.Font.theme(.body).larger(-1.0);
    const font_mono = dvui.Font.theme(.mono).larger(-3.0);

    var scrollarea = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .background = false,
        .color_fill = dvui.themeGet().color(.control, .fill),
        .gravity_y = 1.0,
        .padding = .all(0),
        .margin = .all(0),
    });
    defer scrollarea.deinit();

    last_top_y_physical = scrollarea.data().rectScale().r.y;
    var infobox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .all(0),
        .margin = .all(0),
    });
    defer infobox.deinit();

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.control, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.control, .fill_press),
        });
        defer button.deinit();
        button.processEvents();
        button.drawBackground();

        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .all(0), .padding = .all(0) });
        defer box.deinit();

        dvui.icon(
            @src(),
            "info_icon",
            icons.tvg.entypo.@"info-circled",
            .{ .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5, .padding = .{
                .x = 4,
            } },
        );
        dvui.label(@src(), "fizzy", .{}, .{ .font = font, .gravity_y = 0.5, .margin = .all(0) });

        if (button.clicked()) {
            Dialogs.AboutFizzy.request();
        }

        if (update_notify.badgeVisible()) {
            const brs = button.data().rectScale();
            const br = brs.r;
            const tr = br.topRight();
            const center = tr.plus(.{ .x = -5 * brs.s, .y = 5 * brs.s });
            var dot = dvui.Rect.Physical.fromPoint(center).toSize(.{ .w = 9 * brs.s, .h = 9 * brs.s });
            dot.x -= 4.5 * brs.s;
            dot.y -= 4.5 * brs.s;
            dot.fill(dvui.Rect.Physical.all(4.5 * brs.s), .{
                .color = dvui.themeGet().color(.highlight, .fill),
                .fade = 0,
            });
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    if (fizzy.editor.folder) |folder| {
        dvui.icon(
            @src(),
            "project_icon",
            icons.tvg.entypo.folder,
            .{ .stroke_color = dvui.themeGet().color(.window, .text), .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );
        dvui.label(@src(), "{s}", .{std.fs.path.basename(folder)}, .{ .font = font, .gravity_y = 0.5 });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    if (fizzy.editor.activeFile()) |file| {
        dvui.icon(
            @src(),
            "file_icon",
            icons.tvg.lucide.file,
            .{ .stroke_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );
        dvui.label(@src(), "{s}", .{std.fs.path.basename(file.path)}, .{ .font = font, .gravity_y = 0.5 });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

        dvui.icon(
            @src(),
            "width_icon",
            icons.tvg.lucide.@"ruler-dimension-line",
            .{ .stroke_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );

        fizzy.Editor.Dialogs.drawDimensionsLabel(@src(), file.width(), file.height(), font_mono, "px", .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

        dvui.icon(
            @src(),
            "sprite_icon",
            dvui.entypo.grid,
            .{ .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );

        fizzy.Editor.Dialogs.drawDimensionsLabel(@src(), file.column_width, file.row_height, font_mono, "px", .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });

        //dvui.label(@src(), "{d}x{d} - {d}x{d}", .{ file.width(), file.height(), file.column_width, file.row_height }, .{ .font = font, .gravity_y = 0.5 });

        const mouse_pt = dvui.currentWindow().mouse_pt;
        const data_pt = file.editor.canvas.dataFromScreenPoint(mouse_pt);

        const file_rect = dvui.Rect.fromSize(.{ .w = @floatFromInt(file.width()), .h = @floatFromInt(file.height()) });

        if (file_rect.contains(data_pt)) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

            dvui.icon(
                @src(),
                "mouse_icon",
                icons.tvg.lucide.@"mouse-pointer",
                .{ .stroke_color = dvui.themeGet().color(.window, .text) },
                .{ .gravity_y = 0.5 },
            );

            const sprite_pt = file.spritePoint(data_pt);
            dvui.label(@src(), "{d:0.0},{d:0.0} - {d:0.0},{d:0.0}", .{ @floor(data_pt.x), @floor(data_pt.y), @floor(sprite_pt.x / @as(f32, @floatFromInt(file.column_width))), @floor(sprite_pt.y / @as(f32, @floatFromInt(file.row_height))) }, .{ .gravity_y = 0.5, .font = font_mono });
        }
    }
}
