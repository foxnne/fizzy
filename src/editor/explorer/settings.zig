const builtin = @import("builtin");
const std = @import("std");

const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
// const Core = @import("mach").Core;
const Editor = fizzy.Editor;

const nfd = @import("nfd");
// const imgui = @import("zig-imgui");

pub fn draw() !void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
    });
    defer vbox.deinit();

    {
        var box = dvui.groupBox(@src(), "Appearance", .{
            .expand = .horizontal,
        });
        defer box.deinit();

        {
            var dropdown: dvui.DropdownWidget = undefined;
            dropdown.init(@src(), .{ .label = "Theme" }, .{
                .expand = .horizontal,
                .corner_radius = dvui.Rect.all(1000),
            });
            defer dropdown.deinit();

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .vertical,
                .gravity_x = 1.0,
            });

            dvui.label(@src(), "{s}", .{dvui.themeGet().name}, .{ .margin = .all(0), .padding = .all(0) });

            dvui.icon(
                @src(),
                "dropdown_triangle",
                dvui.entypo.triangle_down,
                .{},
                .{ .gravity_y = 0.5 },
            );

            hbox.deinit();

            if (dropdown.dropped()) {
                for (fizzy.editor.themes.items) |theme| {
                    if (dropdown.addChoiceLabel(theme.name)) {
                        try Editor.Settings.setThemeName(&fizzy.editor.settings, fizzy.app.allocator, theme.name);
                        fizzy.editor.applySettingsTheme() catch {
                            dvui.log.err("Failed to apply theme", .{});
                        };
                        fizzy.editor.markSettingsDirty();
                        dvui.refresh(null, @src(), vbox.data().id);
                        break;
                    }
                }
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });
        }

        {
            var font_group = dvui.groupBox(@src(), "Font Sizes", .{
                .expand = .horizontal,
            });
            defer font_group.deinit();

            if (dvui.sliderEntry(@src(), "Body: {d:0.0}", .{
                .value = &fizzy.editor.settings.font_body_size,
                .interval = 1.0,
                .max = 20.0,
                .min = 6.0,
            }, .{
                .expand = .horizontal,
            })) {
                fizzy.editor.applyFontSizesFromSettings();
                fizzy.editor.markSettingsDirty();
                dvui.refresh(null, @src(), vbox.data().id);
            }

            if (dvui.sliderEntry(@src(), "Heading: {d:0.0}", .{
                .value = &fizzy.editor.settings.font_heading_size,
                .interval = 1.0,
                .max = 20.0,
                .min = 6.0,
            }, .{
                .expand = .horizontal,
            })) {
                fizzy.editor.applyFontSizesFromSettings();
                fizzy.editor.markSettingsDirty();
                dvui.refresh(null, @src(), vbox.data().id);
            }

            if (dvui.sliderEntry(@src(), "Title: {d:0.0}", .{
                .value = &fizzy.editor.settings.font_title_size,
                .interval = 1.0,
                .max = 20.0,
                .min = 6.0,
            }, .{
                .expand = .horizontal,
            })) {
                fizzy.editor.applyFontSizesFromSettings();
                fizzy.editor.markSettingsDirty();
                dvui.refresh(null, @src(), vbox.data().id);
            }

            if (dvui.sliderEntry(@src(), "Monospace: {d:0.0}", .{
                .value = &fizzy.editor.settings.font_mono_size,
                .interval = 1.0,
                .max = 20.0,
                .min = 6.0,
            }, .{
                .expand = .horizontal,
            })) {
                fizzy.editor.applyFontSizesFromSettings();
                fizzy.editor.markSettingsDirty();
                dvui.refresh(null, @src(), vbox.data().id);
            }
        }

        if (dvui.sliderEntry(@src(), "Window Opacity: {d:0.01}", .{
            .value = &if (dvui.themeGet().dark) fizzy.editor.settings.window_opacity_dark else fizzy.editor.settings.window_opacity_light,
            .interval = 0.01,
            .max = 1.0,
            .min = 0.0,
        }, .{
            .expand = .horizontal,
        })) {
            fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(if (dvui.themeGet().dark) fizzy.editor.settings.window_opacity_dark else fizzy.editor.settings.window_opacity_light));
            fizzy.editor.markSettingsDirty();
            dvui.refresh(null, @src(), vbox.data().id);
        }

        if (dvui.sliderEntry(@src(), "Content Opacity: {d:0.01}", .{
            .value = &fizzy.editor.settings.content_opacity,
            .interval = 0.01,
            .max = 1.0,
            .min = 0.0,
        }, .{
            .expand = .horizontal,
        })) {
            fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(fizzy.editor.settings.content_opacity));
            fizzy.editor.markSettingsDirty();
            dvui.refresh(null, @src(), vbox.data().id);
        }

        {
            var dropdown: dvui.DropdownWidget = undefined;
            dropdown.init(@src(), .{ .label = "Transparency effect" }, .{
                .expand = .horizontal,
                .corner_radius = dvui.Rect.all(1000),
            });
            defer dropdown.deinit();

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .vertical,
                .gravity_x = 1.0,
            });

            const label_text = switch (fizzy.editor.settings.transparency_effect) {
                .none => "None",
                .rainbow => "Rainbow",
                .animation => "Animation",
            };
            dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });

            dvui.icon(
                @src(),
                "dropdown_triangle",
                dvui.entypo.triangle_down,
                .{},
                .{ .gravity_y = 0.5 },
            );

            hbox.deinit();

            if (dropdown.dropped()) {
                if (dropdown.addChoiceLabel("None")) {
                    fizzy.editor.settings.transparency_effect = .none;
                    fizzy.editor.markSettingsDirty();
                    dvui.refresh(null, @src(), vbox.data().id);
                }
                if (dropdown.addChoiceLabel("Rainbow")) {
                    fizzy.editor.settings.transparency_effect = .rainbow;
                    fizzy.editor.markSettingsDirty();
                    dvui.refresh(null, @src(), vbox.data().id);
                }
                if (dropdown.addChoiceLabel("Animation")) {
                    fizzy.editor.settings.transparency_effect = .animation;
                    fizzy.editor.markSettingsDirty();
                    dvui.refresh(null, @src(), vbox.data().id);
                }
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });
        }

        if (dvui.checkbox(@src(), &fizzy.editor.settings.show_rulers, "Show Rulers", .{
            .expand = .none,
        })) {
            fizzy.editor.markSettingsDirty();
        }
    }

    {
        var box = dvui.groupBox(@src(), "Debugging", .{
            .expand = .horizontal,
        });
        defer box.deinit();

        if (dvui.checkbox(@src(), &fizzy.editor.settings.perf_logging, "Console perf logging", .{
            .expand = .none,
        })) {
            fizzy.perf.console_logging_enabled = fizzy.editor.settings.perf_logging;
            fizzy.editor.markSettingsDirty();
        }

        if (dvui.checkbox(@src(), &fizzy.editor.settings.debug_simulate_update_available, "Simulate update available (restart app)", .{
            .expand = .none,
        })) {
            fizzy.editor.markSettingsDirty();
        }

        dvui.label(@src(), "{d:0>3.0} fps", .{dvui.FPS()}, .{});
    }
}
