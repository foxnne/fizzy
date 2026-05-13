//! Background check for Velopack/GitHub updates on launch. Network work runs on a
//! side thread so startup never blocks. When an update is detected, we arm a DVUI
//! toast with a "Relaunch to update" button so the user can install in one click
//! while it's visible (or use Help → Check for Updates / the infobar button later).

const std = @import("std");
const dvui = @import("dvui");
const auto_update = @import("auto_update.zig");
const fizzy = @import("fizzy.zig");

const Phase = enum(u8) {
    pending,
    done_no,
    done_yes,
};

var launched: bool = false;
var phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.pending));

var remote_ver: [128]u8 = undefined;
var remote_ver_len: usize = 0;

// Latched so we only arm the toast once per app session — calling `toastAdd`
// every frame would queue an unbounded stack of toasts.
var toast_armed: bool = false;

const TOAST_TIMEOUT_US: i32 = 10 * std.time.us_per_s;

/// Stable, non-null subwindow id for this toast. Using a non-null id makes DVUI's
/// default `toastsShow(null, …)` (run in `Window.end`) skip it, so we can render
/// it ourselves in a custom rect via `dvui.toastsFor(SUBWINDOW_ID)`.
const SUBWINDOW_ID: dvui.Id = @enumFromInt(0xF122_DA70_AD0E_71D0);

// Estimated toast size — used for the FloatingWidget bounding rect and for
// computing the bottom-left anchor relative to the infobar. The real toast
// auto-sizes inside, but the FloatingWidget needs an initial rect.
// Distance from the window's left edge to the toast's left edge (window-natural pixels).
// Used as the anchor point in `drawAbove`; the FloatingWidget self-sizes vertically.
const TOAST_MARGIN: f32 = 14.0;

/// Call once after `Editor` (and settings) exist. Safe to call multiple times.
pub fn startLaunchCheck(io: std.Io, simulate_out_of_date: bool) void {
    if (launched) return;
    launched = true;

    if (simulate_out_of_date) {
        const fake = "9.9.9 (simulated)";
        @memcpy(remote_ver[0..fake.len], fake);
        remote_ver_len = fake.len;
        phase.store(@intFromEnum(Phase.done_yes), .release);
        return;
    }

    if (!auto_update.impl) {
        phase.store(@intFromEnum(Phase.done_no), .release);
        return;
    }

    if (!auto_update.installLayoutSupported(io)) {
        phase.store(@intFromEnum(Phase.done_no), .release);
        return;
    }

    const thread = std.Thread.spawn(.{}, worker, .{io}) catch {
        phase.store(@intFromEnum(Phase.done_no), .release);
        return;
    };
    thread.detach();
}

fn worker(io: std.Io) void {
    var ver_buf: [128]u8 = undefined;
    const summary = auto_update.checkRemoteVersionSummary(io, std.heap.page_allocator, &ver_buf) catch {
        phase.store(@intFromEnum(Phase.done_no), .release);
        return;
    };
    switch (summary) {
        .available => |v| {
            const n = @min(v.len, remote_ver.len);
            @memcpy(remote_ver[0..n], v[0..n]);
            remote_ver_len = n;
            phase.store(@intFromEnum(Phase.done_yes), .release);
        },
        .no_update, .remote_empty => {
            phase.store(@intFromEnum(Phase.done_no), .release);
        },
        else => {
            phase.store(@intFromEnum(Phase.done_no), .release);
        },
    }
}

pub fn badgeVisible() bool {
    return phase.load(.acquire) == @intFromEnum(Phase.done_yes);
}

/// Arms the launch toast once an available update is detected. Must run on the
/// GUI thread between `Window.begin` / `Window.end` (call from a per-frame tick).
/// Subsequent calls are cheap no-ops.
pub fn tick() void {
    if (toast_armed) return;
    if (!badgeVisible()) return;
    toast_armed = true;

    // Non-null subwindow_id so DVUI's automatic toast render skips it — we draw
    // it ourselves via `drawAbove` so the placement is anchored to the infobar.
    const id_mutex = dvui.toastAdd(null, @src(), 0, SUBWINDOW_ID, displayUpdateToast, TOAST_TIMEOUT_US);
    id_mutex.mutex.unlock(dvui.io);
}

/// Render any armed toast in the bottom-left corner, with its bottom edge sitting
/// `gap_above_infobar` natural-pixels above `infobar_top_y_physical` (the infobar's
/// top edge in screen-space). No-op when there's no active toast for this subwindow.
///
/// Call once per frame from the editor's main draw, AFTER the infobar so the
/// caller knows the infobar's screen-space top-edge Y.
pub fn drawAbove(infobar_top_y_physical: f32, gap_above_infobar: f32) void {
    // Cheap exit when there's nothing armed for our subwindow.
    if (dvui.toastsFor(SUBWINDOW_ID) == null) return;

    // Anchor the toast's bottom-left corner at (TOAST_MARGIN, infobar_top - gap)
    // in physical screen pixels. Using `from` instead of a fixed `rect` lets the
    // FloatingWidget self-size to the toast pill's natural dimensions, so its
    // bottom edge sits EXACTLY at the anchor — no leftover slack between the
    // floating widget and the toast inside.
    //
    // `from_gravity_x = 1` → the anchor point is the floating's left edge.
    // `from_gravity_y = 0` → the anchor point is the floating's bottom edge.
    const scale = dvui.windowNaturalScale();
    const anchor_physical: dvui.Point.Physical = .{
        .x = TOAST_MARGIN * scale,
        .y = infobar_top_y_physical - gap_above_infobar * scale,
    };

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{
        .from = anchor_physical,
        .from_gravity_x = 1.0,
        .from_gravity_y = 0.0,
    }, .{});
    defer fw.deinit();

    var vbox = dvui.box(@src(), .{}, .{ .expand = .none });
    defer vbox.deinit();

    var it = dvui.toastsFor(SUBWINDOW_ID) orelse return;
    while (it.next()) |t| {
        t.display(t.id) catch |err| {
            dvui.log.err("update toast display: {any}", .{err});
        };
    }
}

/// Custom toast renderer. Mirrors `dvui.toastDisplay` (fade animator + auto-remove
/// when the dialog timer expires) but lays out a horizontal row with a button.
fn displayUpdateToast(id: dvui.Id) !void {
    var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = 500_000 }, .{
        .id_extra = id.asUsize(),
        .gravity_x = 0.0,
    });
    defer animator.deinit();

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .corner_radius = dvui.Rect.all(1000),
        .padding = .{ .x = 16, .y = 8, .w = 8, .h = 8 },
        .color_fill = dvui.themeGet().color(.content, .fill),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 6.0,
            .alpha = 0.25,
            .corner_radius = dvui.Rect.all(1000),
        },
    });
    defer box.deinit();

    dvui.labelNoFmt(@src(), "Update available!", .{}, .{
        .gravity_y = 0.5,
        .color_text = dvui.themeGet().color(.content, .text),
        .padding = .{ .x = 4, .w = 12 },
    });

    if (dvui.button(@src(), "Relaunch to update", .{}, .{
        .gravity_y = 0.5,
        .style = .highlight,
        .corner_radius = dvui.Rect.all(1000),
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
    })) {
        // `checkDownloadApplyAndExit` blocks while it downloads, then asks the
        // Velopack updater to relaunch (`b_restart = true`) and `std.process.exit(0)`s.
        auto_update.checkDownloadApplyAndExit(dvui.io, std.heap.page_allocator) catch |err| {
            dvui.log.err("update install from toast failed: {any}", .{err});
            // Surface a follow-up toast so the user knows the button click went somewhere.
            dvui.toast(@src(), .{ .message = "Update failed — see About → Check for Updates." });
        };
        dvui.toastRemove(id);
        return;
    }

    if (dvui.timerDone(id)) {
        animator.startEnd();
    }

    if (animator.end()) {
        dvui.toastRemove(id);
        animator.data().min_size = .{};
    }
}
