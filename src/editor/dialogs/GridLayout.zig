//! "Grid Layout" dialog: change the file's `column_width × row_height` (cell size)
//! and `columns × rows` (cell count) with a per-cell anchor that decides how each
//! existing tile is padded into a larger cell or cropped into a smaller one.
//!
//! The middle is a horizontal strip: intrinsic-width form column on the left (vertical fill),
//! preview on the right that expands with the window. The preview uses `CanvasWidget` so
//! panning / zooming honour `Settings.resolvedPanZoomScheme` (`auto` follows DVUI scroll heuristics).

const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const std = @import("std");

const NewFile = @import("NewFile.zig");
const CanvasWidget = @import("../widgets/CanvasWidget.zig");
const builtin = @import("builtin");

/// Editable grid fields for one mode (Slice vs Resize each keep their own backing).
pub const GridFormState = struct {
    column_width: u32 = 32,
    row_height: u32 = 32,
    columns: u32 = 1,
    rows: u32 = 1,
};

/// Resize tab form — module scope so `callAfter` can read it after the window closes.
pub var resize_form: GridFormState = .{};
/// Slice tab form — independent from resize so switching pills does not overwrite the other side.
pub var slice_form: GridFormState = .{};
/// Index into `anchors`/`anchor_labels`. 4 == .c (centered). Resize mode only.
pub var anchor_ix: usize = 4;

/// Two top-level operations on the grid:
///   `.resize` — change cell count and/or cell pixel size; per-cell content is re-anchored
///               (padded on growth, cropped on shrink) using the user-chosen anchor.
///   `.slice`  — metadata-only grid; own form backing (`slice_form`). Preview draws the full
///               layer composite (not per-sprite remapping) plus grid overlay.
pub const Mode = enum { slice, resize };
pub var mode: Mode = .resize;

// Slice auto-link: previous frame's slice form fields.
var slice_prev_columns: u32 = 1;
var slice_prev_rows: u32 = 1;
var slice_prev_column_width: u32 = 32;
var slice_prev_row_height: u32 = 32;

var preview_canvas: CanvasWidget = .{};

var left_scroll: dvui.ScrollInfo = .{ .horizontal = .auto };
/// Middle region only (below the fixed header + mode pill): scrolls when form + preview exceed viewport height.
var dialog_middle_scroll: dvui.ScrollInfo = .{ .horizontal = .auto, .vertical = .auto };

/// Last preview pane size used for `applyPreferredScaleToHost`; reset in `presetFromFile`.
var preview_pane_fit_w: f32 = 0;
var preview_pane_fit_h: f32 = 0;

/// Scroll viewport size from the previous frame — fits scale/center to the real preview port, not a too-large parent rect before layout settles.
var preview_viewport_fit_w: f32 = 0;
var preview_viewport_fit_h: f32 = 0;

/// `slice_full_layer` + `nw` + `nh` — when the Slice/Resize tab or pixel size changes, refit even if `nw==preview_last_nw`.
var preview_fit_key_cache: u64 = 0;

/// Last `{nw, nh}` we applied a preferred scale/fit for; reset in `presetFromFile`.
var preview_last_nw: u32 = 0;
var preview_last_nh: u32 = 0;

/// Fade preview after Slice↔Resize or the first fit-key refit on open — not window resize.
var preview_content_alpha: f32 = 1.0;
var preview_first_open_fade_pending: bool = false;
var preview_have_prev_slice_mode: bool = false;
var preview_prev_slice_full_layer: bool = false;

/// Refit the preview when host/viewport sizes differ by more than this many **logical** pixels.
/// A threshold of ~1px skipped refits during very slow corner-resize drags (sub-pixel per frame on
/// a trackpad). Small epsilon tracks real layout drift; fit only runs when dimensions actually move.
const preview_layout_min_delta: f32 = 0.01;

const anchors: [9]fizzy.math.layout_anchor.LayoutAnchor = .{
    .nw, .n, .ne,
    .w,  .c, .e,
    .sw, .s, .se,
};

const anchor_labels = [_][]const u8{ "NW", "N", "NE", "W", "C", "E", "SW", "S", "SE" };

/// Seed both mode forms with the active file's current grid so the dialog opens "no-op" by default.
pub fn presetFromFile(file: *fizzy.Internal.File) void {
    resize_form = .{
        .column_width = file.column_width,
        .row_height = file.row_height,
        .columns = file.columns,
        .rows = file.rows,
    };
    slice_form = resize_form;
    anchor_ix = 4;
    mode = .resize;
    preview_last_nw = 0;
    preview_last_nh = 0;

    slice_prev_columns = slice_form.columns;
    slice_prev_rows = slice_form.rows;
    slice_prev_column_width = slice_form.column_width;
    slice_prev_row_height = slice_form.row_height;

    // The preview canvas is module-global so its state (scale, origin, prev_size, first/second
    // center flags, scroll viewport) survives across dialog opens. On a re-open the cached
    // `prev_size` matches `data_size` and `second_center` is false, so `install` skips the
    // rescale/recenter pass and the preview ends up offscreen / at a stale zoom. Resetting to
    // a fresh widget forces a fit-to-pane on the next frame.
    preview_canvas = .{};
    left_scroll = .{ .horizontal = .auto };
    dialog_middle_scroll = .{ .horizontal = .auto, .vertical = .auto };
    preview_pane_fit_w = 0;
    preview_pane_fit_h = 0;
    preview_viewport_fit_w = 0;
    preview_viewport_fit_h = 0;
    preview_fit_key_cache = 0;
    preview_content_alpha = 0.0;
    preview_first_open_fade_pending = true;
    preview_have_prev_slice_mode = false;
}

/// Same as `Workspace.drawCanvas` / `workspaceMainCanvasVbox` behind the file widget.
fn workspaceCanvasChromeColor() dvui.Color {
    var content_color = dvui.themeGet().color(.window, .fill);
    switch (builtin.os.tag) {
        .macos, .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow()))
                content_color.opacity(fizzy.editor.settings.content_opacity)
            else
                content_color;
        },
        else => {},
    }
    return content_color;
}

/// Match `FileWidget.drawLayers`: window fill, then content fill (`fade = 1.5`), same order and colors.
fn drawPreviewViewportBackdrop(rs_box: dvui.RectScale, nw: f32, nh: f32) void {
    if (nw <= 0 or nh <= 0) return;
    const natural = dvui.Rect{ .x = 0, .y = 0, .w = nw, .h = nh };
    const phys = rs_box.rectToPhysical(natural);
    phys.fill(.all(0), .{ .color = dvui.themeGet().color(.window, .fill), .fade = 1.0 });
    phys.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.5 });
}

fn previewCheckerboardPalette() struct { tone: dvui.Color, c_tl: dvui.Color, c_tr: dvui.Color, c_bl: dvui.Color, c_br: dvui.Color } {
    const tone = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5).opacity(dvui.currentWindow().alpha);
    const c_tl = tone;
    const c_tr = tone.lerp(.red, 0.18);
    const c_bl = tone.lerp(.blue, 0.12);
    const c_br = c_tr.lerp(c_bl, 0.5);
    return .{ .tone = tone, .c_tl = c_tl, .c_tr = c_tr, .c_bl = c_bl, .c_br = c_br };
}

fn previewCheckerboardGridColorBilinear(c_tl: dvui.Color, c_tr: dvui.Color, c_bl: dvui.Color, c_br: dvui.Color, u: f32, v: f32) dvui.Color {
    const top = c_tl.lerp(c_tr, u);
    const bottom = c_bl.lerp(c_br, u);
    return top.lerp(bottom, v);
}

/// Same rule as `FileWidget.checkerboardVertexColor` (see drawing viewport).
fn previewCheckerboardVertexColor(
    c_tl: dvui.Color,
    c_tr: dvui.Color,
    c_bl: dvui.Color,
    c_br: dvui.Color,
    u: f32,
    v: f32,
    mu: f32,
    mv: f32,
    tone: dvui.Color,
) dvui.Color {
    const c_corner = previewCheckerboardGridColorBilinear(c_tl, c_tr, c_bl, c_br, u, v);
    const du = u - mu;
    const dv = v - mv;
    const dist = std.math.sqrt(du * du + dv * dv);
    var t = std.math.clamp(dist * 1.55, 0, 1);
    t = t * t * (3.0 - 2.0 * t);
    return tone.lerp(c_corner, t);
}

fn updatePreviewCheckerboardMouseUv(cv: *CanvasWidget, nw: f32, nh: f32) dvui.Point {
    const mouse_screen = dvui.currentWindow().mouse_pt;
    var target_mu: f32 = 0.5;
    var target_mv: f32 = 0.5;
    if (cv.rect.contains(mouse_screen)) {
        const md = cv.screen_rect_scale.pointFromPhysical(mouse_screen);
        if (nw > 0) target_mu = std.math.clamp(md.x / nw, 0, 1);
        if (nh > 0) target_mv = std.math.clamp(md.y / nh, 0, 1);
    }
    const prev_uv = dvui.dataGet(null, cv.id, "checkerboard_mouse_uv", dvui.Point) orelse dvui.Point{ .x = 0.5, .y = 0.5 };
    const smooth_t: f32 = 0.15;
    const mu = prev_uv.x + (target_mu - prev_uv.x) * smooth_t;
    const mv = prev_uv.y + (target_mv - prev_uv.y) * smooth_t;
    dvui.dataSet(null, cv.id, "checkerboard_mouse_uv", dvui.Point{ .x = mu, .y = mv });
    return .{ .x = mu, .y = mv };
}

/// Grid line color: reads clearly on top of the checker / content fill (brighter in dark theme, darker in light).
fn previewGridLineColor() dvui.Color {
    return dvui.themeGet().color(.window, .text).opacity(if (dvui.themeGet().dark) 0.58 else 0.52);
}

fn font() dvui.Font {
    return dvui.Font.theme(.body);
}

/// Tiled checker (UV repeat per cell, like `FileWidget` non-effect mode) for the preview's transparency backdrop.
fn drawCheckerboardPreviewTiled(
    file: *fizzy.Internal.File,
    cv: *CanvasWidget,
    rs_box: dvui.RectScale,
    nw: f32,
    nh: f32,
    proto_cell_w: f32,
    proto_cell_h: f32,
) void {
    if (proto_cell_w <= 0 or proto_cell_h <= 0) return;

    const geometry_natural = dvui.Rect{ .x = 0, .y = 0, .w = nw, .h = nh };
    const r = rs_box.rectToPhysical(geometry_natural);
    const tl = r.topLeft();
    const tr = r.topRight();
    const br = r.bottomRight();
    const bl = r.bottomLeft();
    const uv_x1 = nw / proto_cell_w;
    const uv_y1 = nh / proto_cell_h;
    const pal = previewCheckerboardPalette();
    const mu_mv = updatePreviewCheckerboardMouseUv(cv, nw, nh);
    const mu = mu_mv.x;
    const mv = mu_mv.y;

    const arena = dvui.currentWindow().arena();
    var builder = dvui.Triangles.Builder.init(arena, 4, 6) catch return;
    defer builder.deinit(arena);

    switch (fizzy.editor.settings.transparency_effect) {
        .rainbow => {
            const p_tl = dvui.Color.PMA.fromColor(previewCheckerboardVertexColor(pal.c_tl, pal.c_tr, pal.c_bl, pal.c_br, 0, 0, mu, mv, pal.tone));
            const p_tr = dvui.Color.PMA.fromColor(previewCheckerboardVertexColor(pal.c_tl, pal.c_tr, pal.c_bl, pal.c_br, 1, 0, mu, mv, pal.tone));
            const p_br = dvui.Color.PMA.fromColor(previewCheckerboardVertexColor(pal.c_tl, pal.c_tr, pal.c_bl, pal.c_br, 1, 1, mu, mv, pal.tone));
            const p_bl = dvui.Color.PMA.fromColor(previewCheckerboardVertexColor(pal.c_tl, pal.c_tr, pal.c_bl, pal.c_br, 0, 1, mu, mv, pal.tone));
            builder.appendVertex(.{ .pos = tl, .col = p_tl, .uv = .{ 0, 0 } });
            builder.appendVertex(.{ .pos = tr, .col = p_tr, .uv = .{ uv_x1, 0 } });
            builder.appendVertex(.{ .pos = br, .col = p_br, .uv = .{ uv_x1, uv_y1 } });
            builder.appendVertex(.{ .pos = bl, .col = p_bl, .uv = .{ 0, uv_y1 } });
        },
        .none, .animation => {
            const pma = dvui.Color.PMA.fromColor(pal.tone);
            builder.appendVertex(.{ .pos = tl, .col = pma, .uv = .{ 0, 0 } });
            builder.appendVertex(.{ .pos = tr, .col = pma, .uv = .{ uv_x1, 0 } });
            builder.appendVertex(.{ .pos = br, .col = pma, .uv = .{ uv_x1, uv_y1 } });
            builder.appendVertex(.{ .pos = bl, .col = pma, .uv = .{ 0, uv_y1 } });
        },
    }
    builder.appendTriangles(&.{ 1, 0, 3, 1, 3, 2 });
    const triangles = builder.build();
    dvui.renderTriangles(triangles, file.editor.checkerboard_tile.getTexture() catch null) catch {
        dvui.log.err("Grid layout preview: failed to render checkerboard", .{});
    };
}

fn appendGridLineQuad(builder: *dvui.Triangles.Builder, tl: dvui.Point.Physical, br: dvui.Point.Physical, col: dvui.Color.PMA) void {
    const base: dvui.Vertex.Index = @intCast(builder.vertexes.items.len);
    builder.appendVertex(.{ .pos = tl, .col = col });
    builder.appendVertex(.{ .pos = .{ .x = br.x, .y = tl.y }, .col = col });
    builder.appendVertex(.{ .pos = br, .col = col });
    builder.appendVertex(.{ .pos = .{ .x = tl.x, .y = br.y }, .col = col });
    builder.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

fn drawPreviewGridOverlay(
    rs_box: dvui.RectScale,
    nw: f32,
    nh: f32,
    cols_vis: usize,
    rows_vis: usize,
    proto_cell_w: f32,
    proto_cell_h: f32,
    canvas_scale: f32,
    grid_color: dvui.Color,
) void {
    var line_slots: usize = 0;
    if (cols_vis > 1) line_slots += cols_vis - 1;
    if (rows_vis > 1) line_slots += rows_vis - 1;
    if (line_slots == 0) return;

    // Each grid line is drawn twice: a 2×-thick content-fill understroke, then the text-colored stroke on top.
    var builder = dvui.Triangles.Builder.init(dvui.currentWindow().arena(), line_slots * 8, line_slots * 12) catch return;
    defer builder.deinit(dvui.currentWindow().arena());

    const cw = dvui.currentWindow();
    const grid_thickness = std.math.clamp(cw.natural_scale * canvas_scale, 0, cw.natural_scale);
    const rs_den = @max(rs_box.s, 0.0001);

    const half_phys_fg = @max(grid_thickness, 1.0) * 0.5;
    const half_nat_fg = half_phys_fg / rs_den;

    const half_phys_halo = @max(grid_thickness, 1.0);
    const half_nat_halo = half_phys_halo / rs_den;

    const pma_halo: dvui.Color.PMA = .fromColor(dvui.themeGet().color(.content, .fill).opacity(cw.alpha));
    const pma_fg: dvui.Color.PMA = .fromColor(grid_color.opacity(cw.alpha));

    const grid_passes = [_]struct { half_nat: f32, col: dvui.Color.PMA }{
        .{ .half_nat = half_nat_halo, .col = pma_halo },
        .{ .half_nat = half_nat_fg, .col = pma_fg },
    };

    var ix: usize = 1;
    while (ix < cols_vis) : (ix += 1) {
        const xf = @as(f32, @floatFromInt(ix)) * proto_cell_w;
        for (grid_passes) |pass| {
            const r_phys = rs_box.rectToPhysical(.{
                .x = xf - pass.half_nat,
                .y = 0,
                .w = pass.half_nat * 2,
                .h = nh,
            });
            appendGridLineQuad(&builder, .{ .x = r_phys.x, .y = r_phys.y }, .{ .x = r_phys.x + r_phys.w, .y = r_phys.y + r_phys.h }, pass.col);
        }
    }

    var iy: usize = 1;
    while (iy < rows_vis) : (iy += 1) {
        const yf = @as(f32, @floatFromInt(iy)) * proto_cell_h;
        for (grid_passes) |pass| {
            const r_phys = rs_box.rectToPhysical(.{
                .x = 0,
                .y = yf - pass.half_nat,
                .w = nw,
                .h = pass.half_nat * 2,
            });
            appendGridLineQuad(&builder, .{ .x = r_phys.x, .y = r_phys.y }, .{ .x = r_phys.x + r_phys.w, .y = r_phys.y + r_phys.h }, pass.col);
        }
    }

    const tris = builder.build_unowned();
    dvui.renderTriangles(tris, null) catch {
        dvui.log.err("Grid layout preview: failed to render grid overlay", .{});
    };
}

fn appendTexturedRectQuad(
    builder: *dvui.Triangles.Builder,
    dest_phys: dvui.Rect.Physical,
    uv: dvui.Rect,
    tint: dvui.Color.PMA,
) void {
    const base: dvui.Vertex.Index = @intCast(builder.vertexes.items.len);
    const tl = dest_phys.topLeft();
    const tr = dest_phys.topRight();
    const br = dest_phys.bottomRight();
    const bl = dest_phys.bottomLeft();
    builder.appendVertex(.{ .pos = tl, .col = tint, .uv = .{ uv.x, uv.y } });
    builder.appendVertex(.{ .pos = tr, .col = tint, .uv = .{ uv.x + uv.w, uv.y } });
    builder.appendVertex(.{ .pos = br, .col = tint, .uv = .{ uv.x + uv.w, uv.y + uv.h } });
    builder.appendVertex(.{ .pos = bl, .col = tint, .uv = .{ uv.x, uv.y + uv.h } });
    builder.appendTriangles(&.{ base + 1, base, base + 3, base + 1, base + 3, base + 2 });
}

/// Samples the layer composite texture per **old grid cell**, mapping each sprite through `cellAnchoredBlit`
/// so the preview matches the result of `applyGridLayout` independently in every tile.
fn drawCompositePreviewPerCells(
    file: *fizzy.Internal.File,
    rs_box: dvui.RectScale,
    old_cols: u32,
    old_rows: u32,
    old_cw: u32,
    old_rh: u32,
    new_cols: u32,
    new_rows: u32,
    new_cw_: u32,
    new_rh_: u32,
    anchor_vis: fizzy.math.layout_anchor.LayoutAnchor,
) void {
    fizzy.render.syncLayerComposite(file) catch {
        dvui.log.err("Grid layout preview: composite failed", .{});
        return;
    };
    const ct = file.editor.layer_composite_target orelse return;
    const ctex = dvui.Texture.fromTargetTemp(ct) catch return;

    const fw_f = @as(f32, @floatFromInt(ct.width));
    const fh_f = @as(f32, @floatFromInt(ct.height));

    const visible_cols = @min(new_cols, old_cols);
    const visible_rows = @min(new_rows, old_rows);
    if (visible_cols == 0 or visible_rows == 0) return;

    const quad_count: u32 = visible_cols * visible_rows;
    const arena = dvui.currentWindow().arena();
    var builder = dvui.Triangles.Builder.init(arena, quad_count * 4, quad_count * 6) catch return;
    defer builder.deinit(arena);

    const tint = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(dvui.currentWindow().alpha));
    const blk = fizzy.math.layout_anchor.cellAnchoredBlit(old_cw, old_rh, new_cw_, new_rh_, anchor_vis);
    if (blk.sw == 0 or blk.sh == 0) return;

    var nrow: u32 = 0;
    while (nrow < visible_rows) : (nrow += 1) {
        var ncol: u32 = 0;
        while (ncol < visible_cols) : (ncol += 1) {
            const dest_natural = dvui.Rect{
                .x = @as(f32, @floatFromInt(ncol * new_cw_ + blk.dx)),
                .y = @as(f32, @floatFromInt(nrow * new_rh_ + blk.dy)),
                .w = @as(f32, @floatFromInt(blk.sw)),
                .h = @as(f32, @floatFromInt(blk.sh)),
            };
            const x0_px = ncol * old_cw + blk.sx;
            const y0_px = nrow * old_rh + blk.sy;
            const uv = dvui.Rect{
                .x = @as(f32, @floatFromInt(x0_px)) / fw_f,
                .y = @as(f32, @floatFromInt(y0_px)) / fh_f,
                .w = @as(f32, @floatFromInt(blk.sw)) / fw_f,
                .h = @as(f32, @floatFromInt(blk.sh)) / fh_f,
            };
            const dest_phys = rs_box.rectToPhysical(dest_natural);
            appendTexturedRectQuad(&builder, dest_phys, uv, tint);
        }
    }

    const tris = builder.build_unowned();
    dvui.renderTriangles(tris, ctex) catch {
        dvui.log.err("Grid layout preview: failed to render batched composite", .{});
    };
}

/// One quad for the full layer composite (slice preview — no per-cell remapping).
fn drawCompositePreviewFullLayer(file: *fizzy.Internal.File, rs_box: dvui.RectScale, nw: f32, nh: f32) void {
    if (nw <= 0 or nh <= 0) return;
    fizzy.render.syncLayerComposite(file) catch {
        dvui.log.err("Grid layout preview: composite failed", .{});
        return;
    };
    const ct = file.editor.layer_composite_target orelse return;
    const ctex = dvui.Texture.fromTargetTemp(ct) catch return;

    const dest_natural = dvui.Rect{ .x = 0, .y = 0, .w = nw, .h = nh };
    const dest_phys = rs_box.rectToPhysical(dest_natural);
    const tint = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(dvui.currentWindow().alpha));
    const uv = dvui.Rect{ .x = 0, .y = 0, .w = 1, .h = 1 };

    var builder = dvui.Triangles.Builder.init(dvui.currentWindow().arena(), 4, 6) catch return;
    defer builder.deinit(dvui.currentWindow().arena());
    appendTexturedRectQuad(&builder, dest_phys, uv, tint);
    const tris = builder.build_unowned();
    dvui.renderTriangles(tris, ctex) catch {
        dvui.log.err("Grid layout preview: failed to render full composite", .{});
    };
}

/// When entering Slice, keep the current form values if they already tile the layer exactly;
/// otherwise snap from the file's authoritative grid (never force 1×1 unless metadata disagrees
/// with pixel dimensions).
fn harmonizeSliceStateWithLayer(file: *fizzy.Internal.File) void {
    const canvas = file.canvasPixelSize();
    const tw = canvas.w;
    const th = canvas.h;
    if (tw == 0 or th == 0) return;
    const s = &slice_form;
    const form_tiles_layer = s.columns > 0 and s.column_width > 0 and s.rows > 0 and s.row_height > 0 and
        s.columns * s.column_width == tw and s.rows * s.row_height == th;

    if (!form_tiles_layer) {
        s.column_width = file.column_width;
        s.row_height = file.row_height;
        s.columns = file.columns;
        s.rows = file.rows;
        if (!(s.columns * s.column_width == tw and s.rows * s.row_height == th)) {
            s.columns = 1;
            s.rows = 1;
            s.column_width = tw;
            s.row_height = th;
        }
    }
    slice_prev_columns = s.columns;
    slice_prev_rows = s.rows;
    slice_prev_column_width = s.column_width;
    slice_prev_row_height = s.row_height;
}

fn renderPreview(
    mutex_id: dvui.Id,
    dlg_id: dvui.Id,
    file: *fizzy.Internal.File,
    nw: u32,
    nh: u32,
    new_cw_: u32,
    new_rh_: u32,
    new_cols: u32,
    new_rows: u32,
    anchor_vis: fizzy.math.layout_anchor.LayoutAnchor,
    slice_full_layer: bool,
) void {
    if (nw == 0 or nh == 0) return;

    const old_cols = file.columns;
    const old_rows = file.rows;
    const old_cw = file.column_width;
    const old_rh = file.row_height;

    const vp_host_w = preview_pane_fit_w;
    const vp_host_h = preview_pane_fit_h;
    const host_vp_ok = vp_host_w > 8 and vp_host_h > 8;

    const fit_key: u64 = (@as(u64, @intFromBool(slice_full_layer)) << 63) |
        (@as(u64, @intCast(nw)) << 32) |
        @as(u64, @intCast(nh));
    const fit_key_changed = fit_key != preview_fit_key_cache;
    if (fit_key_changed) {
        preview_viewport_fit_w = 0;
        preview_viewport_fit_h = 0;
        preview_canvas.scroll_info.viewport.x = 0;
        preview_canvas.scroll_info.viewport.y = 0;
    }

    const dims_changed = nw != preview_last_nw or nh != preview_last_nh;

    const shell_drag_or_resize = blk: {
        const wid = dvui.dataGet(null, mutex_id, "_grid_layout_float_wd_id", dvui.Id) orelse break :blk false;
        break :blk dvui.captured(wid);
    };

    const host_vp_versus_stored = host_vp_ok and (preview_viewport_fit_w < 4 or preview_viewport_fit_h < 4 or
        @abs(vp_host_w - preview_viewport_fit_w) >= preview_layout_min_delta or
        @abs(vp_host_h - preview_viewport_fit_h) >= preview_layout_min_delta);
    const needs_preinstall_refit = host_vp_ok and (fit_key_changed or dims_changed or host_vp_versus_stored or shell_drag_or_resize);

    const preview_data: dvui.Size = .{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) };

    if (needs_preinstall_refit) {
        preview_canvas.fitContentContainInHost(
            preview_data,
            dvui.Rect{ .x = 0, .y = 0, .w = vp_host_w, .h = vp_host_h },
            1.2,
        );
        preview_canvas.scroll_info.viewport.x = 0;
        preview_canvas.scroll_info.viewport.y = 0;
        if (fit_key_changed) {
            preview_fit_key_cache = fit_key;
        }
        if (dims_changed) {
            preview_last_nw = nw;
            preview_last_nh = nh;
        }
        dvui.refresh(null, @src(), preview_canvas.id);
    }

    // `CanvasWidget.install` rescale/recenter uses `parentGet()` under the scroll/scaler — wrong
    // for this dialog. Skip that branch; scale/center from real scroll viewport.
    preview_canvas.prev_size = .{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) };

    preview_canvas.install(@src(), .{
        .id = dlg_id.update("glp_cv"),
        .data_size = .{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) },
        .center = false,
    }, .{
        .expand = .both,
        .background = true,
        .color_fill = workspaceCanvasChromeColor(),
    });
    defer preview_canvas.deinit();

    const vpw = preview_canvas.scroll_info.viewport.w;
    const vph = preview_canvas.scroll_info.viewport.h;

    const vp_ok = vpw > 8 and vph > 8;
    const layout_mismatch = host_vp_ok and vp_ok and (@abs(vpw - vp_host_w) >= preview_layout_min_delta or @abs(vph - vp_host_h) >= preview_layout_min_delta);
    const needs_bootstrap_refit = !host_vp_ok and vp_ok and (fit_key_changed or dims_changed);

    var did_post_install_refit = false;
    if (layout_mismatch or needs_bootstrap_refit or (shell_drag_or_resize and vp_ok)) {
        preview_canvas.fitContentContainInHost(
            preview_data,
            dvui.Rect{ .x = 0, .y = 0, .w = vpw, .h = vph },
            1.2,
        );
        preview_canvas.scroll_info.viewport.x = 0;
        preview_canvas.scroll_info.viewport.y = 0;
        if (fit_key_changed) {
            preview_fit_key_cache = fit_key;
        }
        if (dims_changed) {
            preview_last_nw = nw;
            preview_last_nh = nh;
        }
        did_post_install_refit = true;
        preview_canvas.syncTransformCachesFromWidgets();
        dvui.refresh(null, @src(), preview_canvas.id);
    }

    preview_viewport_fit_w = vpw;
    preview_viewport_fit_h = vph;
    preview_pane_fit_w = vpw;
    preview_pane_fit_h = vph;

    const any_refit = needs_preinstall_refit or did_post_install_refit;

    {
        const slice_mode_changed = preview_have_prev_slice_mode and
            (preview_prev_slice_full_layer != slice_full_layer);
        const refit_triggers_fade = slice_mode_changed or
            (preview_first_open_fade_pending and fit_key_changed);
        const should_zero_fade_alpha = vp_ok and any_refit and refit_triggers_fade;

        const dt = @min(@max(dvui.secondsSinceLastFrame(), 0.0), 0.05);
        if (should_zero_fade_alpha) {
            preview_content_alpha = 0.0;
        } else if (vp_ok and preview_content_alpha < 1.0) {
            const fade_s: f32 = 0.1;
            preview_content_alpha = @min(1.0, preview_content_alpha + dt / fade_s);
        }
        if (preview_first_open_fade_pending and preview_content_alpha >= 1.0) {
            preview_first_open_fade_pending = false;
        }
        if (preview_content_alpha < 1.0) {
            dvui.refresh(null, @src(), preview_canvas.id);
        }
    }

    preview_prev_slice_full_layer = slice_full_layer;
    preview_have_prev_slice_mode = true;

    const preview_alpha_saved = dvui.alpha(preview_content_alpha);
    defer dvui.alphaSet(preview_alpha_saved);

    // Drop shadow under the preview texture, mirroring `FileWidget.drawLayers` so the preview
    // reads as a "document" floating over the dialog's right pane.
    {
        const scale = @max(preview_canvas.scale, 0.0001);
        const shadow_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .rect = .{ .x = 0, .y = 0, .w = @floatFromInt(nw), .h = @floatFromInt(nh) },
            .border = dvui.Rect.all(0),
            .box_shadow = .{
                .fade = 20 * 1 / scale,
                .corner_radius = dvui.Rect.all(2 * 1 / scale),
                .alpha = if (dvui.themeGet().dark) 0.4 else 0.2,
                .offset = .{
                    .x = 2 * 1 / scale,
                    .y = 2 * 1 / scale,
                },
            },
        });
        shadow_box.deinit();
    }

    const nw_f: f32 = @floatFromInt(nw);
    const nh_f: f32 = @floatFromInt(nh);
    const rs = preview_canvas.screen_rect_scale;
    drawPreviewViewportBackdrop(rs, nw_f, nh_f);
    drawCheckerboardPreviewTiled(
        file,
        &preview_canvas,
        rs,
        nw_f,
        nh_f,
        @floatFromInt(new_cw_),
        @floatFromInt(new_rh_),
    );

    if (slice_full_layer) {
        drawCompositePreviewFullLayer(file, rs, @floatFromInt(nw), @floatFromInt(nh));
    } else {
        drawCompositePreviewPerCells(
            file,
            rs,
            old_cols,
            old_rows,
            old_cw,
            old_rh,
            new_cols,
            new_rows,
            new_cw_,
            new_rh_,
            anchor_vis,
        );
    }

    const grid_col = previewGridLineColor();
    drawPreviewGridOverlay(
        rs,
        nw_f,
        nh_f,
        @max(new_cols, 1),
        @max(new_rows, 1),
        @floatFromInt(new_cw_),
        @floatFromInt(new_rh_),
        preview_canvas.scale,
        grid_col,
    );

    // Same order as `FileWidget`: draw first, then scroll/zoom input (wheel applies next frame).
    preview_canvas.processEvents();
}

/// Slice/Resize mode pill — lives in the dialog shell header strip (non-scrolling).
fn gridLayoutDrawModePill(dlg_id: dvui.Id) void {
    const file_id_for_dialog = dvui.dataGet(null, dlg_id, "_grid_layout_file_id", u64);

    var horizontal_box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
        .expand = .none,
        .gravity_x = 0.5,
        .margin = .all(4),
    });
    defer horizontal_box.deinit();

    const field_names = std.meta.fieldNames(@TypeOf(mode));

    for (field_names, 0..) |tag, i| {
        const corner_radius: dvui.Rect = if (i == 0) .{
            .x = 100000,
            .h = 100000,
        } else if (i == field_names.len - 1) .{
            .y = 100000,
            .w = 100000,
        } else .all(0);

        var name = dvui.currentWindow().arena().dupe(u8, tag) catch {
            dvui.log.err("Failed to dupe tag {s}", .{tag});
            return;
        };
        @memcpy(name.ptr, tag);
        name[0] = std.ascii.toUpper(name[0]);

        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .corner_radius = corner_radius,
            .id_extra = i,
            .margin = .{ .y = 2, .h = 4 },
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .expand = .horizontal,
            .color_fill = if (mode == @as(@TypeOf(mode), @enumFromInt(i))) dvui.themeGet().color(.window, .fill).lighten(-4) else dvui.themeGet().color(.control, .fill),
            .box_shadow = if (i != @intFromEnum(mode)) .{
                .color = .black,
                .offset = .{ .x = 0.0, .y = 2 },
                .fade = 7.0,
                .alpha = 0.2,
                .corner_radius = corner_radius,
                .shrink = 0,
            } else null,
        });
        defer button.deinit();
        if (i != @intFromEnum(mode)) {
            button.processEvents();
        }

        var clip_rect = button.data().rectScale().r;

        clip_rect.y -= 10000;
        clip_rect.h += 20000;

        if (i == 0) {
            clip_rect.x -= 10000;
            clip_rect.w += 10000;
        } else if (i == field_names.len - 1) {
            clip_rect.w += 10000;
        }

        const clip = dvui.clip(clip_rect);
        defer dvui.clipSet(clip);

        button.drawFocus();
        button.drawBackground();

        dvui.labelNoFmt(@src(), name, .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = if (mode == @as(@TypeOf(mode), @enumFromInt(i))) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
            .margin = .all(0),
            .padding = .all(0),
        });

        if (button.clicked()) {
            const new_mode: Mode = @enumFromInt(i);
            if (new_mode == .slice and mode != .slice) {
                if (file_id_for_dialog) |fid| if (fizzy.editor.open_files.getPtr(fid)) |tf|
                    harmonizeSliceStateWithLayer(tf);
            }
            mode = new_mode;
            dvui.currentWindow().extra_frames_needed = 2;
        }
    }
}

/// Returns true while the form input is valid AND differs from the active file's current
/// grid (column_width / row_height / columns / rows). The dialog framework uses this to enable/disable
/// the OK button — re-applying an identical grid is a no-op so we disable accept rather than invoke.
pub fn dialog(id: dvui.Id) anyerror!bool {
    const form_font = font();

    const file_id_for_dialog = dvui.dataGet(null, id, "_grid_layout_file_id", u64);
    const target_file: ?*fizzy.Internal.File = if (file_id_for_dialog) |fid|
        fizzy.editor.open_files.getPtr(fid)
    else
        null;

    const unique_id = id.update("grid_layout");

    var valid: bool = true;

    // While opening, `windowFn` runs autoSize — allow the scroll area to report full content height
    // so the dialog grows to fit (up to main window size). After open, cap reported min height so
    // a short user resize does not push the footer off-screen (see DVUI `scrolling.zig` main_area).
    const grid_dialog_open_done = dvui.dataGet(null, id, "_grid_dialog_open_done", bool) orelse false;
    const mid_scroll_max: dvui.Options.MaxSize = if (grid_dialog_open_done)
        .height(0)
    else
        .height(dvui.max_float_safe);

    var mid_scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &dialog_middle_scroll,
        .horizontal_bar = .auto_overlay,
    }, .{
        .expand = .both,
        .gravity_y = 0,
        .background = false,
        .max_size_content = mid_scroll_max,
        .id_extra = unique_id.update("glp_mid_sc").asUsize(),
    });
    defer mid_scroll.deinit();

    defer {
        if (dialog_middle_scroll.offset(.vertical) > 0.0)
            fizzy.dvui.drawEdgeShadow(mid_scroll.data().contentRectScale(), .top, .{});

        if (dialog_middle_scroll.virtual_size.h > dialog_middle_scroll.viewport.h)
            fizzy.dvui.drawEdgeShadow(mid_scroll.data().contentRectScale(), .bottom, .{});
    }

    // Form (intrinsic width, full height) + preview (expands horizontally with the window).
    var form_preview_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .gravity_y = 0,
        .background = false,
        .id_extra = unique_id.update("glp_main_row").asUsize(),
    });
    defer form_preview_row.deinit();

    {
        const shell_left = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .gravity_x = 0,
            .gravity_y = 0,
            .background = false,
            .id_extra = unique_id.update("glp_shell_l").asUsize(),
        });

        const pane_left = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .gravity_x = 0,
            .gravity_y = 0,
            .background = false,
            .id_extra = unique_id.update("glp_pane_l").asUsize(),
        });

        var scroll_left = dvui.scrollArea(@src(), .{
            .scroll_info = &left_scroll,
            .horizontal_bar = .auto_overlay,
            .vertical_bar = .auto_overlay,
        }, .{
            .expand = .both,
            .gravity_x = 0,
            .gravity_y = 0,
            .background = false,
            .id_extra = unique_id.update("glp_sc_l").asUsize(),
        });

        var inner_left = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .gravity_x = 0,
            .gravity_y = 0,
            .padding = .all(4),
            .id_extra = unique_id.update("glp_inner_l").asUsize(),
        });

        switch (mode) {
            .resize => valid = drawResizeForm(unique_id, target_file, form_font) and valid,
            .slice => valid = drawSliceForm(unique_id, target_file, form_font) and valid,
        }

        inner_left.deinit();
        scroll_left.deinit();

        const v_scroll = left_scroll.offset(.vertical);
        const h_scroll = left_scroll.offset(.horizontal);
        if (v_scroll > 0.0) {
            fizzy.dvui.drawEdgeShadow(pane_left.data().contentRectScale(), .top, .{});
        }
        if (left_scroll.virtual_size.h > left_scroll.viewport.h) {
            fizzy.dvui.drawEdgeShadow(pane_left.data().contentRectScale(), .bottom, .{});
        }
        pane_left.deinit();

        if (left_scroll.virtual_size.w > left_scroll.viewport.w) {
            fizzy.dvui.drawEdgeShadow(shell_left.data().contentRectScale(), .right, .{});
        }
        if (h_scroll > 0.0) {
            fizzy.dvui.drawEdgeShadow(shell_left.data().contentRectScale(), .left, .{});
        }
        shell_left.deinit();
    }

    const preview_w: u32 = blk: {
        if (target_file) |tf| {
            if (mode == .slice) break :blk tf.canvasPixelSize().w;
        }
        break :blk resize_form.column_width * resize_form.columns;
    };
    const preview_h: u32 = blk: {
        if (target_file) |tf| {
            if (mode == .slice) break :blk tf.canvasPixelSize().h;
        }
        break :blk resize_form.row_height * resize_form.rows;
    };

    const slice_grid_ok: bool = if (mode == .slice) blk: {
        const tf = target_file orelse break :blk false;
        const c = tf.canvasPixelSize();
        if (c.w == 0 or c.h == 0) break :blk false;
        const s = slice_form;
        break :blk s.column_width * s.columns == c.w and s.row_height * s.rows == c.h;
    } else true;
    // Invalid slice proposal: still show the full layer in the preview (no shrink) using the
    // on-disk grid for sampling until the form is a valid tiling again.
    const pv_cw, const pv_rh, const pv_cols, const pv_rows, const pv_anchor = blk: {
        if (mode == .slice and !slice_grid_ok) {
            const tf = target_file orelse break :blk .{
                slice_form.column_width,
                slice_form.row_height,
                slice_form.columns,
                slice_form.rows,
                anchors[@min(anchor_ix, anchors.len - 1)],
            };
            break :blk .{ tf.column_width, tf.row_height, tf.columns, tf.rows, @as(fizzy.math.layout_anchor.LayoutAnchor, .nw) };
        }
        break :blk switch (mode) {
            .slice => .{
                slice_form.column_width,
                slice_form.row_height,
                slice_form.columns,
                slice_form.rows,
                anchors[@min(anchor_ix, anchors.len - 1)],
            },
            .resize => .{
                resize_form.column_width,
                resize_form.row_height,
                resize_form.columns,
                resize_form.rows,
                anchors[@min(anchor_ix, anchors.len - 1)],
            },
        };
    };

    {
        var preview_host = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .gravity_y = 0,
            .background = false,
            .id_extra = unique_id.update("glp_preview_host").asUsize(),
        });
        defer preview_host.deinit();

        defer {
            const rs_scroll = preview_host.data().rectScale();
            fizzy.dvui.drawEdgeShadow(rs_scroll, .top, .{});
            fizzy.dvui.drawEdgeShadow(rs_scroll, .bottom, .{});
            fizzy.dvui.drawEdgeShadow(rs_scroll, .left, .{});
            fizzy.dvui.drawEdgeShadow(rs_scroll, .right, .{});
        }

        if (target_file) |tf| {
            const dims_ok = fizzy.Internal.File.validateGridLayoutProposedDims(pv_cw, pv_rh, pv_cols, pv_rows);
            if (dims_ok) {
                renderPreview(
                    id,
                    unique_id,
                    tf,
                    preview_w,
                    preview_h,
                    pv_cw,
                    pv_rh,
                    pv_cols,
                    pv_rows,
                    pv_anchor,
                    mode == .slice,
                );
            } else {
                // Keep the preview pane filled: invalid form state still shows the current layer using on-disk grid.
                renderPreview(
                    id,
                    unique_id,
                    tf,
                    preview_w,
                    preview_h,
                    tf.column_width,
                    tf.row_height,
                    tf.columns,
                    tf.rows,
                    .nw,
                    mode == .slice,
                );
            }
        }
    }

    // OK is enabled only when the form is valid AND the proposed grid actually changes something.
    const changed: bool = blk: {
        const tf = target_file orelse break :blk false;
        break :blk switch (mode) {
            .slice => !(slice_form.column_width == tf.column_width and
                slice_form.row_height == tf.row_height and
                slice_form.columns == tf.columns and
                slice_form.rows == tf.rows),
            .resize => !(resize_form.column_width == tf.column_width and
                resize_form.row_height == tf.row_height and
                resize_form.columns == tf.columns and
                resize_form.rows == tf.rows),
        };
    };

    return valid and changed and (target_file != null);
}

/// Resize-mode form: cell width (x), cell height (y), columns (x), rows (y); 9-way anchor; current vs after readout.
fn drawResizeForm(
    unique_id: dvui.Id,
    target_file: ?*fizzy.Internal.File,
    form_font: dvui.Font,
) bool {
    var valid: bool = true;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });

    if (target_file) |af| {
        dvui.label(@src(), "Current size: {d} × {d} px", .{ af.width(), af.height() }, .{
            .gravity_x = 0,
            .font = form_font,
            .color_text = dvui.themeGet().color(.control, .text),
        });
    } else {
        valid = false;
    }

    dvui.label(@src(), "After apply: {d} × {d} px", .{
        resize_form.column_width * resize_form.columns,
        resize_form.row_height * resize_form.rows,
    }, .{
        .gravity_x = 0,
        .font = form_font,
        .color_text = dvui.themeGet().color(.control, .text),
    });

    if (!fizzy.Internal.File.validateGridLayoutProposedDims(
        resize_form.column_width,
        resize_form.row_height,
        resize_form.columns,
        resize_form.rows,
    )) {
        valid = false;
        dvui.label(
            @src(),
            "Resulting size must fit within 4096 × 4096 px.",
            .{},
            .{
                .gravity_x = 0,
                .color_text = dvui.themeGet().color(.err, .text),
                .font = form_font,
            },
        );
    }

    // ── Cell width (x)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Cell width (x):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res_cw = dvui.textEntryNumber(@src(), u32, .{
            .min = NewFile.min_size[0],
            .max = NewFile.max_size[0],
            .value = &resize_form.column_width,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("cw").asUsize(),
            .font = form_font,
        });
        if (res_cw.value == .Valid) {
            resize_form.column_width = res_cw.value.Valid;
        } else {
            valid = false;
        }
    }

    // ── Cell height (y)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Cell height (y):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res_rh = dvui.textEntryNumber(@src(), u32, .{
            .min = NewFile.min_size[1],
            .max = NewFile.max_size[1],
            .value = &resize_form.row_height,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("rh").asUsize(),
            .font = form_font,
        });
        if (res_rh.value == .Valid) {
            resize_form.row_height = res_rh.value.Valid;
        } else {
            valid = false;
        }
    }

    // ── Columns (x)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Columns (x):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res_col = dvui.textEntryNumber(@src(), u32, .{
            .min = 1,
            .max = NewFile.max_size[0],
            .value = &resize_form.columns,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("cols").asUsize(),
            .font = form_font,
        });
        if (res_col.value == .Valid) {
            resize_form.columns = res_col.value.Valid;
        } else {
            valid = false;
        }
    }

    // ── Rows (y)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Rows (y):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res_row = dvui.textEntryNumber(@src(), u32, .{
            .min = 1,
            .max = NewFile.max_size[1],
            .value = &resize_form.rows,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("rows").asUsize(),
            .font = form_font,
        });
        if (res_row.value == .Valid) {
            resize_form.rows = res_row.value.Valid;
        } else {
            valid = false;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 8 } });

    // ── Anchor 3×3 button grid (single-select toggle).
    dvui.label(@src(), "Anchor", .{}, .{ .gravity_x = 0, .font = form_font });

    const row_tag = [_][]const u8{ "_r0", "_r1", "_r2" };
    {
        var grid_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .gravity_x = 0.5,
            .id_extra = unique_id.update("agrid").asUsize(),
        });
        defer grid_box.deinit();

        var r: usize = 0;
        while (r < 3) : (r += 1) {
            var row_b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .gravity_x = 0.5,
                .id_extra = unique_id.update(row_tag[r]).asUsize(),
            });
            defer row_b.deinit();

            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const ix = r * 3 + c;
                const selected = ix == anchor_ix;
                const color = if (selected)
                    dvui.themeGet().color(.window, .fill).lighten(-4)
                else
                    dvui.themeGet().color(.control, .fill);
                const button_opts: dvui.Options = .{
                    .padding = .all(4),
                    .margin = .all(2),
                    .corner_radius = .all(4),
                    .min_size_content = .{ .w = 36, .h = 28 },
                    .color_fill = color,
                    .color_fill_hover = if (selected) color else null,
                    .id_extra = unique_id.update(anchor_labels[ix]).asUsize(),
                };

                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{}, button_opts);
                defer button.deinit();

                if (!selected) button.processEvents();
                button.drawBackground();

                dvui.labelNoFmt(@src(), anchor_labels[ix], .{}, button_opts.strip().override(button.style()).override(.{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .color_text = if (selected)
                        dvui.themeGet().color(.window, .text)
                    else
                        dvui.themeGet().color(.control, .text),
                    .font = form_font,
                }));
                if (button.clicked()) {
                    anchor_ix = ix;
                    dvui.currentWindow().extra_frames_needed = 2;
                }
            }
        }
    }

    return valid;
}

/// Slice-mode form: image dimensions are pinned to the file's current `width × height`. Field order
/// matches resize: cell width, cell height, columns, rows. The user edits any field and the dialog
/// auto-fills the linked value whenever it divides evenly. The grid is invalid if values don't
/// multiply back to the locked total.
fn drawSliceForm(
    unique_id: dvui.Id,
    target_file: ?*fizzy.Internal.File,
    form_font: dvui.Font,
) bool {
    var valid: bool = true;
    const tf = target_file orelse return false;
    const canvas = tf.canvasPixelSize();
    const total_w: u32 = canvas.w;
    const total_h: u32 = canvas.h;
    if (total_w == 0 or total_h == 0) {
        dvui.label(@src(), "No layer pixels to slice.", .{}, .{
            .gravity_x = 0,
            .color_text = dvui.themeGet().color(.err, .text),
            .font = form_font,
        });
        return false;
    }

    dvui.label(@src(), "Image size: {d} × {d} px (locked)", .{ total_w, total_h }, .{
        .gravity_x = 0,
        .font = form_font,
        .color_text = dvui.themeGet().color(.control, .text),
    });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 6 } });

    // ── Cell width (x)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Cell width (x):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res = dvui.textEntryNumber(@src(), u32, .{
            .min = 1,
            .max = @max(total_w, 1),
            .value = &slice_form.column_width,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("s_cw").asUsize(),
            .font = form_font,
        });
        if (res.value == .Valid) slice_form.column_width = res.value.Valid else valid = false;
    }

    // ── Cell height (y)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Cell height (y):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res = dvui.textEntryNumber(@src(), u32, .{
            .min = 1,
            .max = @max(total_h, 1),
            .value = &slice_form.row_height,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("s_ch").asUsize(),
            .font = form_font,
        });
        if (res.value == .Valid) slice_form.row_height = res.value.Valid else valid = false;
    }

    // ── Columns (x)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Columns (x):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res = dvui.textEntryNumber(@src(), u32, .{
            .min = 1,
            .max = @max(total_w, 1),
            .value = &slice_form.columns,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("s_cols").asUsize(),
            .font = form_font,
        });
        if (res.value == .Valid) slice_form.columns = res.value.Valid else valid = false;
    }

    // ── Rows (y)
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Rows (y):", .{}, .{ .gravity_y = 0.5, .font = form_font });
        const res = dvui.textEntryNumber(@src(), u32, .{
            .min = 1,
            .max = @max(total_h, 1),
            .value = &slice_form.rows,
            .show_min_max = true,
        }, .{
            .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
            .label = .{ .label_widget = .prev },
            .gravity_x = 1.0,
            .id_extra = unique_id.update("s_rows").asUsize(),
            .font = form_font,
        });
        if (res.value == .Valid) slice_form.rows = res.value.Valid else valid = false;
    }

    // Auto-link: prefer count-driven autofill (if columns or rows changed, derive the cell size).
    // If only the cell size changed, derive the count. Single-frame lag is fine — both fields
    // converge on the next render.
    if (slice_form.columns != slice_prev_columns and slice_form.columns > 0 and total_w % slice_form.columns == 0) {
        slice_form.column_width = total_w / slice_form.columns;
    } else if (slice_form.column_width != slice_prev_column_width and slice_form.column_width > 0 and total_w % slice_form.column_width == 0) {
        slice_form.columns = total_w / slice_form.column_width;
    }
    if (slice_form.rows != slice_prev_rows and slice_form.rows > 0 and total_h % slice_form.rows == 0) {
        slice_form.row_height = total_h / slice_form.rows;
    } else if (slice_form.row_height != slice_prev_row_height and slice_form.row_height > 0 and total_h % slice_form.row_height == 0) {
        slice_form.rows = total_h / slice_form.row_height;
    }
    slice_prev_columns = slice_form.columns;
    slice_prev_rows = slice_form.rows;
    slice_prev_column_width = slice_form.column_width;
    slice_prev_row_height = slice_form.row_height;

    // Validation: in slice mode the *only* legal grids are those whose cell × count matches the
    // locked image size. We surface the mismatch inline rather than silently snapping so the
    // user sees what the constraint is.
    const cw_eff = slice_form.column_width;
    const rh_eff = slice_form.row_height;
    const w_match = cw_eff > 0 and slice_form.columns > 0 and cw_eff * slice_form.columns == total_w;
    const h_match = rh_eff > 0 and slice_form.rows > 0 and rh_eff * slice_form.rows == total_h;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 6 } });

    if (!(w_match and h_match)) {
        valid = false;
        dvui.label(@src(), "Cells must tile the image exactly.", .{}, .{
            .gravity_x = 0,
            .color_text = dvui.themeGet().color(.err, .text),
            .font = form_font,
        });
        if (!w_match) {
            dvui.label(@src(), "  • {d} × {d} ≠ {d} (x)", .{ cw_eff, slice_form.columns, total_w }, .{
                .gravity_x = 0,
                .color_text = dvui.themeGet().color(.err, .text),
                .font = form_font,
            });
        }
        if (!h_match) {
            dvui.label(@src(), "  • {d} × {d} ≠ {d} (y)", .{ rh_eff, slice_form.rows, total_h }, .{
                .gravity_x = 0,
                .color_text = dvui.themeGet().color(.err, .text),
                .font = form_font,
            });
        }
    }

    return valid;
}

/// Custom window shell for the grid-layout dialog: matches `fizzy.dvui.dialogWindow` (open
/// `autoSize()` animation, nudge + center on modal rect). `min_size_content` is half the main
/// window so the first layout pass does not collapse the shell; DVUI then grows to fit content
/// (see `FloatingWindowWidget` `Size.max(min_size, min_sizeGet)`). Do not use `max_size_content`
/// here — in DVUI it *caps* reported min size and was shrinking the dialog.
pub fn windowFn(id: dvui.Id) anyerror!void {
    const modal = dvui.dataGet(null, id, "_modal", bool) orelse {
        dvui.log.err("GridLayout windowFn lost data for dialog {x}", .{id});
        dvui.dialogRemove(id);
        return;
    };

    if (modal) {
        fizzy.editor.dim_titlebar = true;
    }

    const title = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
        dvui.dialogRemove(id);
        return;
    };
    const ok_label = dvui.dataGetSlice(null, id, "_ok_label", []u8) orelse {
        dvui.dialogRemove(id);
        return;
    };
    const cancel_label = dvui.dataGetSlice(null, id, "_cancel_label", []u8);
    const default = dvui.dataGet(null, id, "_default", dvui.enums.DialogResponse);
    const callafter = dvui.dataGet(null, id, "_callafter", fizzy.dvui.CallAfterFn);
    const displayFn = dvui.dataGet(null, id, "_displayFn", fizzy.dvui.DisplayFn);

    // Default shell: wide enough for form + preview; DVUI autoSize grows to content if larger.
    const wr = dvui.windowRect();
    const init_w = @round(wr.w * 0.62);
    const init_h = @round(wr.h * 0.52);
    const center_on = dvui.currentWindow().subwindows.current_rect;

    var win = fizzy.dvui.floatingWindow(@src(), .{
        .modal = modal,
        .center_on = center_on,
        .window_avoid = .nudge,
        .process_events_in_deinit = true,
        .resize = .all,
    }, .{
        .id_extra = id.asUsize(),
        .color_text = .black,
        .corner_radius = dvui.Rect.all(10),
        .min_size_content = .{ .w = init_w, .h = @max(init_h, 400) },
        .border = .all(0),
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.85),
        .box_shadow = .{
            .color = .black,
            .alpha = 0.35,
            .fade = 10,
            .corner_radius = dvui.Rect.all(10),
        },
    });
    defer win.deinit();
    // `renderPreview` refits when the preview viewport changes; during very slow resize drags the
    // scroll viewport can lag the shell by sub-pixel amounts for multiple frames. While this window
    // holds capture (resize or drag), refit every frame so scale/center stay correct.
    dvui.dataSet(null, id, "_grid_layout_float_wd_id", win.data().id);

    if (dvui.dataGet(null, id, "_grid_dialog_open_done", bool) orelse false) {
        win.stopAutoSizing();
    }

    if (dvui.animationGet(win.data().id, "_close_x")) |a| {
        if (a.done()) {
            fizzy.Editor.Explorer.files.new_file_close_rect = null;
            dvui.dialogRemove(id);
        }
    } else if (fizzy.Editor.Explorer.files.new_file_close_rect) |close_rect| {
        dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
        fizzy.Editor.Explorer.files.new_file_close_rect = null;
    } else {
        // Call `autoSize` only while opening. Doing it every frame leaves `auto_size` true and the
        // window keeps animating/snapping to content min size — user resize appears "locked".
        const open_done = dvui.dataGet(null, id, "_grid_dialog_open_done", bool) orelse false;
        if (!open_done) {
            win.autoSize();
            var anim_busy = false;
            if (dvui.animationGet(win.data().id, "_auto_width")) |a| {
                if (!a.done()) anim_busy = true;
            }
            if (dvui.animationGet(win.data().id, "_auto_height")) |a2| {
                if (!a2.done()) anim_busy = true;
            }
            if (!anim_busy and !dvui.firstFrame(win.data().id) and win.data().rect.w > 32 and win.data().rect.h > 32) {
                dvui.dataSet(null, id, "_grid_dialog_open_done", true);
                win.stopAutoSizing();
            }
        }
    }

    // Header (title) + mode pill are fixed; middle expands and scrolls inside `dialog()`; footer fixed.
    var shell = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer shell.deinit();

    const header_kind: fizzy.dvui.DialogHeaderKind = switch (dvui.dataGet(null, id, "_header_kind", u8) orelse 0) {
        @intFromEnum(fizzy.dvui.DialogHeaderKind.none) => .none,
        @intFromEnum(fizzy.dvui.DialogHeaderKind.info) => .info,
        @intFromEnum(fizzy.dvui.DialogHeaderKind.warning) => .warning,
        @intFromEnum(fizzy.dvui.DialogHeaderKind.err) => .err,
        else => .none,
    };

    var header_openflag = true;
    win.dragAreaSet(fizzy.dvui.windowHeader(title, "", &header_openflag, header_kind));
    if (!header_openflag) {
        if (callafter) |ca| {
            ca(id, .cancel) catch {
                dvui.log.err("GridLayout dialog callafter cancel failed", .{});
                return;
            };
        }
        var close_rect = win.data().rectScale().r;
        close_rect.x = close_rect.center().x;
        close_rect.y = close_rect.center().y;
        close_rect.w = 1;
        close_rect.h = 1;
        dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
    }

    gridLayoutDrawModePill(id);

    var valid: bool = true;

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .all(8),
            .expand = .both,
            .gravity_x = 0.5,
        });
        defer hbox.deinit();

        if (displayFn) |df| {
            valid = df(id) catch false;
        }
    }

    { // Footer — match `fizzy.dvui.dialogWindow` (horizontal strip, gravity_x centered).
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.5,
            .padding = .{ .y = 6, .h = 8 },
        });
        defer hbox.deinit();

        if (cancel_label) |cl| {
            var cancel_data: dvui.WidgetData = undefined;
            const gravx: f32, const tindex: u16 = switch (dvui.currentWindow().button_order) {
                .cancel_ok => .{ 0.0, 1 },
                .ok_cancel => .{ 1.0, 3 },
            };
            if (dvui.button(@src(), cl, .{}, .{
                .tab_index = tindex,
                .data_out = &cancel_data,
                .gravity_x = gravx,
                .box_shadow = .{
                    .color = .black,
                    .alpha = 0.25,
                    .offset = .{ .x = -4, .y = 4 },
                    .fade = 8,
                },
            })) {
                if (callafter) |ca| {
                    ca(id, .cancel) catch {
                        dvui.log.err("GridLayout dialog callafter cancel failed", .{});
                        return;
                    };
                }
                var close_rect = win.data().rectScale().r;
                close_rect.x = close_rect.center().x;
                close_rect.y = close_rect.center().y;
                close_rect.w = 1;
                close_rect.h = 1;
                dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
            }
            if (default != null and dvui.firstFrame(hbox.data().id) and default.? == .cancel and !valid) {
                dvui.focusWidget(cancel_data.id, null, null);
            }
        }

        const alpha = dvui.alpha(if (valid) 1.0 else 0.5);
        defer dvui.alphaSet(alpha);

        var ok_data: dvui.WidgetData = undefined;
        const ok_opts: dvui.Options = .{
            .tab_index = 2,
            .data_out = &ok_data,
            .style = if (valid) .highlight else .control,
            .box_shadow = .{
                .color = .black,
                .alpha = 0.25,
                .offset = .{ .x = -4, .y = 4 },
                .fade = 8,
            },
        };
        var ok_button: dvui.ButtonWidget = undefined;
        ok_button.init(@src(), .{}, ok_opts);
        defer ok_button.deinit();
        if (valid) ok_button.processEvents();
        ok_button.drawFocus();
        ok_button.drawBackground();
        dvui.labelNoFmt(@src(), ok_label, .{}, ok_opts.strip().override(ok_button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));

        if (ok_button.clicked()) {
            if (!valid) return;
            if (callafter) |ca| {
                ca(id, .ok) catch {
                    dvui.log.err("GridLayout dialog callafter ok failed", .{});
                    return;
                };
            }
            var close_rect_ok = win.data().rectScale().r;
            close_rect_ok.x = close_rect_ok.center().x;
            close_rect_ok.y = close_rect_ok.center().y;
            close_rect_ok.w = 1;
            close_rect_ok.h = 1;
            dvui.dataSet(null, win.data().id, "_close_rect", close_rect_ok);
        }
        if (default != null and dvui.firstFrame(hbox.data().id) and default.? == .ok and valid) {
            dvui.focusWidget(ok_data.id, null, null);
        }
    }
}

pub fn callAfter(id: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    switch (response) {
        .ok => {
            const file_id = dvui.dataGet(null, id, "_grid_layout_file_id", u64) orelse return;
            const file = fizzy.editor.open_files.getPtr(file_id) orelse return;

            switch (mode) {
                .slice => {
                    const s = slice_form;
                    if (!fizzy.Internal.File.validateGridLayoutProposedDims(s.column_width, s.row_height, s.columns, s.rows))
                        return;
                    file.applyGridSliceOnly(.{
                        .column_width = s.column_width,
                        .row_height = s.row_height,
                        .columns = s.columns,
                        .rows = s.rows,
                    }) catch |err| {
                        dvui.log.err("Failed to apply grid slice: {s}", .{@errorName(err)});
                        return;
                    };
                },
                .resize => {
                    const r = resize_form;
                    if (!fizzy.Internal.File.validateGridLayoutProposedDims(r.column_width, r.row_height, r.columns, r.rows))
                        return;
                    file.applyGridLayout(.{
                        .column_width = r.column_width,
                        .row_height = r.row_height,
                        .columns = r.columns,
                        .rows = r.rows,
                        .anchor = anchors[@min(anchor_ix, anchors.len - 1)],
                    }) catch |err| {
                        dvui.log.err("Failed to apply grid layout: {s}", .{@errorName(err)});
                        return;
                    };
                },
            }

            dvui.refresh(null, @src(), dvui.currentWindow().data().id);
            fizzy.editor.requestCompositeWarmup();
        },
        .cancel => {},
        else => {},
    }
}
