const std = @import("std");

const zip = @import("src/deps/zip/build.zig");

const dvui = @import("dvui");
const velopack = @import("velopack_zig");

const content_dir = "assets/";

const ProcessAssetsStep = @import("src/tools/process_assets.zig");

const update = @import("update.zig");
const GitDependency = update.GitDependency;
fn update_step(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const deps = &.{
        GitDependency{
            // zig_objc
            .url = "https://github.com/foxnne/zig-objc",
            .branch = "main",
        },
        GitDependency{
            // zigwin32 (kristoff-it fork has the zig 0.16 fix branch)
            .url = "https://github.com/kristoff-it/zigwin32",
            .branch = "fix/zig16",
        },
        GitDependency{
            // icons
            .url = "https://github.com/foxnne/zig-lib-icons",
            .branch = "dvui",
        },
        GitDependency{
            // dvui
            .url = "https://github.com/foxnne/dvui-dev",
            .branch = "main",
        },
    };
    try update.update_dependency(step.owner.allocator, step.owner.graph.io, deps);
}

/// Installed artifacts go under `zig-out/<this>/…` so `packageall` and parallel targets never clobber each other.
/// Uses `arm64` (not `aarch64`) for Apple Silicon / arm64 Linux and Windows to match the six release triples.
///
/// Segment separator is `-` only: `vpk pack --channel` is merged into filenames that get parsed as NuGet
/// versions (e.g. `1.2.3-<channel>-full.nupkg`), and NuGet prerelease labels must not contain `_`.
fn zigOutSubdirForTarget(b: *std.Build, rt: std.Build.ResolvedTarget) []const u8 {
    const arch_name: []const u8 = switch (rt.result.cpu.arch) {
        .x86_64 => "x86-64",
        .aarch64 => "arm64",
        else => @tagName(rt.result.cpu.arch),
    };
    const os_name: []const u8 = switch (rt.result.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => @tagName(rt.result.os.tag),
    };
    const base = b.fmt("{s}-{s}", .{ arch_name, os_name });
    if (std.mem.indexOfScalar(u8, base, '_') == null)
        return base;
    const buf = b.allocator.alloc(u8, base.len) catch @panic("OOM");
    @memcpy(buf, base);
    for (buf) |*byte| {
        if (byte.* == '_') byte.* = '-';
    }
    return buf;
}

/// SDL (via dvui → lazy `sdl3`) requires SDK layout when `-Dtarget=*-macos` is not "native"
/// (`target.query.isNative()` is false). Do not set the root `b.sysroot` for that: it skews
/// the main link (objc, libc paths). Forward include / framework / lib paths into dvui instead.
const MacosSdlPaths = struct {
    include: std.Build.LazyPath,
    framework: std.Build.LazyPath,
    lib: std.Build.LazyPath,
};

fn resolveMacosSdkPath(b: *std.Build) ![]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdk| {
        const trimmed = std.mem.trim(u8, sdk, " \t\r\n");
        if (trimmed.len > 0) {
            return b.dupePath(trimmed);
        }
    }

    const argv: []const []const u8 = &.{
        "xcrun",
        "--sdk",
        "macosx",
        "--show-sdk-path",
    };
    const run = try std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
    });
    defer {
        b.allocator.free(run.stdout);
        b.allocator.free(run.stderr);
    }
    switch (run.term) {
        .exited => |code| if (code != 0) {
            std.log.err("SDL on macOS: explicit -Dtarget=*-macos needs an SDK path. xcrun exited with code {d}. Install Xcode Command Line Tools or set SDKROOT.", .{code});
            return error.MacosSdkPath;
        },
        else => {
            std.log.err("SDL on macOS: xcrun --show-sdk-path failed", .{});
            return error.MacosSdkPath;
        },
    }
    const path = std.mem.trimEnd(u8, run.stdout, " \t\r\n");
    if (path.len == 0) return error.MacosSdkPath;
    return b.dupePath(path);
}

fn macosSdlPathsForExplicitTarget(b: *std.Build, target: std.Build.ResolvedTarget) !?MacosSdlPaths {
    if (target.result.os.tag != .macos) return null;
    if (b.graph.host.result.os.tag != .macos) return null;
    if (target.query.isNative()) return null;

    const sdk = try resolveMacosSdkPath(b);
    return MacosSdlPaths{
        .include = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
        .framework = .{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
        .lib = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
    };
}

pub fn build(b: *std.Build) !void {
    const windows_msvc_libc_opt = b.option([]const u8, "windows-msvc-libc", "zig libc manifest for *-windows-msvc when cross-compiling; forwarded by packageall for Windows children") orelse null;
    const fetch_msvc = b.option(bool, "fetch-msvc", "If *-windows-msvc libc is missing under .velopack-msvc/, run msvcup-setup first (downloads MSVC+SDK; requires network)") orelse false;

    // macOS `vpk pack` codesigning / notarization. Optional: when omitted, packaging produces an
    // unsigned bundle. Set all three to sign + notarize a release build.
    const macos_sign_app_identity = b.option([]const u8, "macos-sign-app", "macOS codesign identity for the app bundle (e.g. 'Developer ID Application: NAME (TEAMID)')") orelse
        b.graph.environ_map.get("FIZZY_MACOS_SIGN_APP");
    const macos_sign_install_identity = b.option([]const u8, "macos-sign-installer", "macOS codesign identity for the installer pkg (e.g. 'Developer ID Installer: NAME (TEAMID)')") orelse
        b.graph.environ_map.get("FIZZY_MACOS_SIGN_INSTALLER");
    const macos_notary_profile = b.option([]const u8, "macos-notary-profile", "notarytool keychain profile name (run `xcrun notarytool store-credentials <name>` first)") orelse
        b.graph.environ_map.get("FIZZY_MACOS_NOTARY_PROFILE");

    const target = b.standardTargetOptions(.{});
    // Artifacts install to `zig-out/<arch>-<os>/` (e.g. arm64-macos, x86-64-windows). Pass `-Dtarget=…` as usual.
    const optimize = b.standardOptimizeOption(.{});
    const macos_sdl_paths = try macosSdlPathsForExplicitTarget(b, target);
    const zig_out_subdir = zigOutSubdirForTarget(b, target);
    const zig_out_install_dir: std.Build.InstallDir = .{ .custom = zig_out_subdir };

    const cross_win_msvc = target.result.os.tag == .windows and target.result.abi == .msvc and b.graph.host.result.os.tag != .windows;

    const win_libc = velopack.resolveWindowsMsvcLibc(b, target, .{
        .explicit_path = windows_msvc_libc_opt,
        .install_dir_name = ".velopack-msvc",
        .fetch_if_missing = fetch_msvc,
    });

    var effective_win_libc: ?[]const u8 = win_libc.libc_path;
    if (effective_win_libc == null) {
        if (cross_win_msvc) effective_win_libc = b.libc_file;
    }

    // Velopack in the dev/install exe is opt-in (`-Dvelopack=true`). Release
    // packaging (`zig build package`) still links Velopack when the ABI supports
    // it via a second compile, so `zig build` / `run` / `test` never pull dotnet
    // or the static Velopack lib unless you ask. Windows *-gnu targets are
    // unchanged (no Velopack prebuilt for that ABI).
    const velopack_supported_for_target = !(target.result.os.tag == .windows and target.result.abi != .msvc);
    const velopack_enabled = b.option(
        bool,
        "velopack",
        "Link Velopack runtime in the install/run exe (auto-update). Default: false. `package` still produces a Velopack-linked binary when supported.",
    ) orelse false;

    if (velopack_enabled and !velopack_supported_for_target) {
        std.log.err(
            "-Dvelopack=true is unsupported for target ABI {s}: Velopack on Windows requires -Dtarget=x86_64-windows-msvc or -Dtarget=aarch64-windows-msvc.",
            .{@tagName(target.result.abi)},
        );
        return error.WindowsMsvcAbiRequired;
    }

    const velopack_required_fail: ?*std.Build.Step = if (cross_win_msvc and effective_win_libc == null)
        &b.addFail(
            \\Cross-compiling to *-windows-msvc needs MSVC + Windows SDK headers/libs.
            \\  One-shot install (macOS/Linux/Windows): zig build msvcup-setup
            \\  Then: zig build package -Dtarget=x86_64-windows-msvc   (auto-uses .velopack-msvc/zig-libc-x64.ini if present)
            \\  Or auto-download in this build: add -Dfetch-msvc  (forwards through packageall for Windows targets)
            \\  Or pass: --libc path.ini  /  -Dwindows-msvc-libc=path.ini
        ).step
    else
        null;

    const no_emit = b.option(bool, "no-emit", "Check for compile errors without emitting any code") orelse false;

    const app_version_opt = b.option([]const u8, "app_version", "App version for vpk packVersion and startup log; defaults to VERSION file");

    // GitHub repo URL baked into the binary so Velopack's auto-update can find
    // the latest release via the GitHub Releases API. Override at build time
    // with `-Drepo-url=...` (e.g. when shipping a fork). At runtime, the env
    // var `FIZZY_AUTOUPDATE_URL` still overrides this for local feed testing.
    const app_repo_url = b.option([]const u8, "repo-url", "GitHub repo URL used by Velopack auto-update (e.g. https://github.com/foxnne/fizzy)") orelse "https://github.com/foxnne/fizzy";

    var version_owned: ?[]u8 = null;
    defer if (version_owned) |buf| b.allocator.free(buf);

    const app_version: []const u8 = if (app_version_opt) |v| v else blk: {
        const raw = b.build_root.handle.readFileAlloc(b.graph.io, "VERSION", b.allocator, std.Io.Limit.limited(256)) catch |e| std.debug.panic("read VERSION: {}", .{e});
        version_owned = raw;
        break :blk std.mem.trimEnd(u8, raw, "\r\n");
    };

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "app_version", app_version);
    build_opts.addOption([]const u8, "app_repo_url", app_repo_url);
    build_opts.addOption(bool, "velopack_enabled", velopack_enabled);

    const step = b.step("update", "update git dependencies");
    step.makeFn = update_step;

    const msvcup_before_compile = velopack.addMsvcupSetupStep(b, ".velopack-msvc");
    const msvcup_setup_step = b.step("msvcup-setup", "Download MSVC SDK into .velopack-msvc/ via velopack-zig (writes zig-libc-*.ini)");
    msvcup_setup_step.dependOn(&msvcup_before_compile.step);

    const zip_pkg = zip.package(b, .{});

    const accesskit = b.option(dvui.AccesskitOptions, "accesskit", "Enable accesskit") orelse .off;

    const assetpack = @import("assetpack");
    const assets_module = assetpack.pack(b, b.path("assets"), .{});

    // Generated atlas / asset stubs (`src/generated/*.zig`) are imported
    // unconditionally by `fizzy.zig`, so the process-assets step has to
    // run before any target that touches fizzy.zig — exe, integration
    // tests, etc.
    const assets_processing = try ProcessAssetsStep.init(b, "assets", "src/generated/");
    const process_assets_step = b.step("process-assets", "generates struct for all assets");
    process_assets_step.dependOn(&assets_processing.step);

    const main_fizzy = try addFizzyExecutableForTarget(b, target, optimize, accesskit, build_opts, zip_pkg, assets_module, process_assets_step, macos_sdl_paths, velopack_enabled);
    const exe = main_fizzy.exe;
    const zstbi_module = main_fizzy.zstbi_module;
    const msf_gif_module = main_fizzy.msf_gif_module;
    const known_folders = main_fizzy.known_folders;

    const exe_for_package: *std.Build.Step.Compile = package_blk: {
        if (velopack_enabled) break :package_blk exe;
        if (!velopack_supported_for_target) break :package_blk exe;
        const pack_opts = b.addOptions();
        pack_opts.addOption([]const u8, "app_version", app_version);
        pack_opts.addOption([]const u8, "app_repo_url", app_repo_url);
        pack_opts.addOption(bool, "velopack_enabled", true);
        const pack_fizzy = try addFizzyExecutableForTarget(b, target, optimize, accesskit, pack_opts, zip_pkg, assets_module, process_assets_step, macos_sdl_paths, true);
        break :package_blk pack_fizzy.exe;
    };

    if (no_emit) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        const install_artifact = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = zig_out_install_dir },
        });

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run", "Run the app (does not run Velopack)");

        run_cmd.step.dependOn(&install_artifact.step);
        run_step.dependOn(&run_cmd.step);
        b.getInstallStep().dependOn(&install_artifact.step);
    }

    const package_step = b.step("package", "Velopack release artifacts (strip + vpk); not part of install or run");
    if (velopack_required_fail) |fail_step| {
        package_step.dependOn(fail_step);
    } else if (no_emit) {
        package_step.dependOn(&b.addFail("cannot run `package` with -Dno-emit").step);
    } else switch (target.result.os.tag) {
        .linux, .macos, .windows => {
            // Host strip can't process foreign object files when cross-compiling.
            const cross_os = target.result.os.tag != b.graph.host.result.os.tag;
            const strip_release_sh = b.addSystemCommand(&.{switch (optimize) {
                .Debug => "touch",
                else => if (cross_os) "touch" else "strip",
            }});
            strip_release_sh.addFileArg(exe_for_package.getEmittedBin());

            //const dotnet_tool_restore = velopack.addDotnetToolRestoreStep(b);
            //const vpk_vendor_repair = velopack.addVpkVendorRepairStep(b);
            //vpk_vendor_repair.step.dependOn(&dotnet_tool_restore.step);

            const vpk_pkg_sh = b.addSystemCommand(&.{"dotnet"});
            vpk_pkg_sh.addArg("vpk");
            // When packaging a foreign-OS bundle, vpk needs an OS directive (e.g. `vpk [win] pack ...`)
            // because by default it auto-detects from the host OS.
            if (cross_os) {
                vpk_pkg_sh.addArg(switch (target.result.os.tag) {
                    .windows => "[win]",
                    .linux => "[linux]",
                    .macos => "[osx]",
                    else => unreachable,
                });
            }
            vpk_pkg_sh.addArg("pack");
            vpk_pkg_sh.addArg("--packId");
            vpk_pkg_sh.addArg("fizzy");
            vpk_pkg_sh.addArg("--packVersion");
            vpk_pkg_sh.addArg(app_version);
            // Channel = zig-out subdir (`<arch>-<os>`, NuGet-safe — no underscores). Baked into
            // the binary by vpk; the updater matches this to release assets. Distinct per triple
            // so parallel `vpk pack` runs don't collide on RELEASES / nupkg names.
            vpk_pkg_sh.addArg("--channel");
            vpk_pkg_sh.addArg(zig_out_subdir);
            vpk_pkg_sh.addArg("--mainExe");
            vpk_pkg_sh.addArg(switch (target.result.os.tag) {
                .windows => "fizzy.exe",
                else => "fizzy",
            });

            vpk_pkg_sh.addArg("--delta");
            vpk_pkg_sh.addArg("None");
            vpk_pkg_sh.addArg("--yes");

            vpk_pkg_sh.addArg("--outputDir");
            const vpk_pkg_out_dir = vpk_pkg_sh.addOutputDirectoryArg(b.getInstallPath(zig_out_install_dir, "desktop"));
            vpk_pkg_sh.addArg("--packDir");
            vpk_pkg_sh.addDirectoryArg(exe_for_package.getEmittedBin().dirname());
            switch (target.result.os.tag) {
                .macos => {
                    vpk_pkg_sh.addArg("--packTitle");
                    vpk_pkg_sh.addArg("fizzy");
                    // Bundle id / document types / versions: assets/macos/info.plist (vpk rejects --bundleId with --plist).
                    vpk_pkg_sh.addArg("--plist");
                    const plist_path = b.path("assets/macos/info.plist").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("plist path: {}", .{e});
                    vpk_pkg_sh.addArg(plist_path);
                    vpk_pkg_sh.addArg("--icon");
                    const icns_path = b.path("assets/macos/fizzy.icns").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("icns path: {}", .{e});
                    vpk_pkg_sh.addArg(icns_path);

                    if (macos_sign_app_identity) |id| {
                        vpk_pkg_sh.addArg("--signAppIdentity");
                        vpk_pkg_sh.addArg(id);
                        // Required for notarization: enables hardened runtime + secure timestamp on
                        // every nested binary (vpk forwards the file to `codesign --entitlements`).
                        // Without this, Apple's notary service rejects with "signature does not
                        // include a secure timestamp" / "hardened runtime not enabled".
                        vpk_pkg_sh.addArg("--signEntitlements");
                        const entitlements_path = b.path("assets/macos/Fizzy.entitlements").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("entitlements path: {}", .{e});
                        vpk_pkg_sh.addArg(entitlements_path);
                    }
                    if (macos_sign_install_identity) |id| {
                        vpk_pkg_sh.addArg("--signInstallIdentity");
                        vpk_pkg_sh.addArg(id);
                    }
                    if (macos_notary_profile) |profile| {
                        vpk_pkg_sh.addArg("--notaryProfile");
                        vpk_pkg_sh.addArg(profile);
                    }
                },
                else => {},
            }
            vpk_pkg_sh.setEnvironmentVariable("DOTNET_ROLL_FORWARD", "Major");
            // Stream vpk's stdout/stderr live so failures surface their actual
            // diagnostic instead of just an exit-code-N message from the build
            // runner. With `addOutputDirectoryArg` in play, `infer_from_args`
            // can otherwise capture+drop stdio on certain runner configs.
            vpk_pkg_sh.stdio = .inherit;
            try velopack.attachMksquashfsToVpkRun(b, vpk_pkg_sh, target);

            //vpk_pkg_sh.step.dependOn(&vpk_vendor_repair.step);
            vpk_pkg_sh.step.dependOn(&strip_release_sh.step);

            const build_package_install = b.addInstallDirectory(.{
                .source_dir = vpk_pkg_out_dir,
                .install_dir = zig_out_install_dir,
                .install_subdir = "",
            });

            package_step.dependOn(&build_package_install.step);
        },
        else => {
            package_step.dependOn(&b.addFail("Velopack packaging is only supported for Linux, macOS, and Windows targets").step);
        },
    }

    const desktop_step = b.step("desktop", "Alias for `zig build package`");
    desktop_step.dependOn(package_step);

    const packageall_step = b.step("packageall", "Six zig build package runs; use -Dwindows-msvc-libc= or -Dfetch-msvc for Windows children from macOS/Linux");
    if (no_emit) {
        packageall_step.dependOn(&b.addFail("cannot run `packageall` with -Dno-emit").step);
    } else {
        const packageall_optimize_arg = b.fmt("-Doptimize={s}", .{@tagName(optimize)});

        // Build order is deliberately fail-fast: Windows first (most likely to
        // fail on a fresh CI runner because of MSVC SDK setup, libc.ini paths,
        // and cross-compile ABI surprises), then Linux (mksquashfs / AppImage
        // packaging quirks), then macOS last (native, lowest risk). When a
        // release run is going to break, this ordering surfaces the failure
        // 5-10 minutes sooner than the alphabetical order did.
        const packageall_triples = [_][]const u8{
            "x86_64-windows-msvc",
            "aarch64-windows-msvc",
            "x86_64-linux-gnu",
            "aarch64-linux-gnu",
            "x86_64-macos",
            "aarch64-macos",
        };

        var prev_step: ?*std.Build.Step = null;
        for (packageall_triples) |triple| {
            const zig_pkg_run = b.addSystemCommand(&.{
                b.graph.zig_exe,
                "build",
                "package",
                packageall_optimize_arg,
                b.fmt("-Dtarget={s}", .{triple}),
            });
            if (std.mem.endsWith(u8, triple, "-windows-msvc")) {
                if (windows_msvc_libc_opt) |libc_path| {
                    zig_pkg_run.addArg(b.fmt("-Dwindows-msvc-libc={s}", .{libc_path}));
                }
                if (fetch_msvc) zig_pkg_run.addArg("-Dfetch-msvc");
            }
            zig_pkg_run.setCwd(b.path("."));
            if (prev_step) |p| {
                zig_pkg_run.step.dependOn(p);
            }
            prev_step = &zig_pkg_run.step;
        }
        packageall_step.dependOn(prev_step.?);
    }

    // ---------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------
    //
    // Fizzy has two test layers (see tests/README.md):
    //
    //   1. Unit tests — pure-logic only (math, palette parsing, layer
    //      order). The test root imports nothing but std + the pure
    //      modules under test, so it compiles in well under a second
    //      and never needs dvui/SDL/assets.
    //
    //   2. Integration tests (added in Phase 2 of the testing plan)
    //      will use dvui's testing backend and exercise real fizzy
    //      drawing functions in a headless Window.
    //
    // Both share the same `zig build test` and `zig build check`
    // entry points.

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const tests_module = b.addModule("fizzy-tests", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/root.zig"),
    });

    // Wire each pure-logic source file as a named module on the test
    // target. Zig 0.15 disallows importing source files outside the test
    // module's own directory via relative paths, so we expose them by
    // name. Each of these files imports only `std`, so they remain free
    // of dvui / SDL / globals.
    inline for (.{
        .{ "fizzy-direction", "src/math/direction.zig" },
        .{ "fizzy-easing", "src/math/easing.zig" },
        .{ "fizzy-layer-order", "src/internal/layer_order.zig" },
        .{ "fizzy-palette-parse", "src/internal/palette_parse.zig" },
        .{ "fizzy-layout-anchor", "src/math/layout_anchor.zig" },
        .{ "fizzy-reduce", "src/algorithms/reduce.zig" },
        .{ "fizzy-grid-validate", "src/internal/grid_layout_validate.zig" },
        .{ "fizzy-animation", "src/Animation.zig" },
    }) |entry| {
        tests_module.addAnonymousImport(entry[0], .{
            .root_source_file = b.path(entry[1]),
            .target = target,
            .optimize = optimize,
        });
    }

    const unit_tests = b.addTest(.{
        .name = "fizzy-unit-tests",
        .root_module = tests_module,
        .filters = test_filters,
    });

    // `zig build test` is the CI entry point and must stay self-contained: pure
    // unit tests only, no dvui/SDL/Velopack/MSVC. Integration tests live under
    // `zig build test-integration` (Velopack + dvui-testing + comctl32 on Windows
    // → needs MSVC SDK on Windows hosts). `zig build test-all` runs both.
    const test_step = b.step("test", "Run fizzy unit tests (pure-logic only, no dvui/SDL/Velopack)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // `check` mirrors the split so editor compile-error checking matches CI.
    const check_step = b.step("check", "Compile fizzy unit tests without running them");
    check_step.dependOn(&unit_tests.step);

    // ---------------------------------------------------------------
    // Layer 2: headless integration tests against dvui's testing
    // backend. Wired under separate `test-integration` / `check-integration`
    // steps so `zig build test` stays MSVC-free on Windows CI runners. Skipped
    // when cross-compiling to *-windows-msvc without an MSVC libc INI.
    // ---------------------------------------------------------------
    const test_integration_step = b.step("test-integration", "Run fizzy headless integration tests (dvui-testing; needs MSVC on Windows)");
    const check_integration_step = b.step("check-integration", "Compile fizzy integration tests without running them");
    const test_all_step = b.step("test-all", "Run unit + integration tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(test_integration_step);

    if (velopack_required_fail) |fail_step| {
        test_integration_step.dependOn(fail_step);
        check_integration_step.dependOn(fail_step);
        return;
    }

    const dvui_testing_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
        .accesskit = accesskit,
    });

    // Build a module rooted at `src/fizzy.zig` carrying all the same
    // imports the production exe carries. Because fizzy.zig's transitive
    // imports (App.zig, Editor.zig, …) reference `dvui`, `assets`,
    // `known-folders`, etc. by name, those names must be wired here.
    // We point dvui at the *testing* backend so calling drawing
    // functions doesn't try to open a real OS window.
    const fizzy_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/fizzy.zig"),
    });
    fizzy_test_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    fizzy_test_module.addImport("backend", dvui_testing_dep.module("testing"));
    fizzy_test_module.addImport("assets", assets_module);
    fizzy_test_module.addImport("known-folders", known_folders);
    fizzy_test_module.addOptions("build_opts", build_opts);
    fizzy_test_module.addImport("zstbi", zstbi_module);
    fizzy_test_module.addImport("msf_gif", msf_gif_module);
    fizzy_test_module.addImport("zip", zip_pkg.module);
    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        fizzy_test_module.addImport("icons", dep.module("icons"));
    }
    if (target.result.os.tag == .macos) {
        if (b.lazyDependency("zig_objc", .{ .target = target, .optimize = optimize })) |dep| {
            fizzy_test_module.addImport("objc", dep.module("objc"));
        }
    } else if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            fizzy_test_module.addImport("win32", dep.module("win32"));
        }
    }

    const integration_module = b.addModule("fizzy-integration-tests", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/integration.zig"),
    });
    integration_module.addImport("fizzy", fizzy_test_module);
    integration_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));

    const integration_tests = b.addTest(.{
        .name = "fizzy-integration-tests",
        .root_module = integration_module,
        .filters = test_filters,
    });

    if (target.result.os.tag == .windows) {
        integration_tests.root_module.linkSystemLibrary("comctl32", .{});
    }
    // Zig's bundled libc++/libcxxabi cannot compile against MSVC headers from
    // --libc (vcruntime_typeinfo.h vs libc++ type_info, etc.). Native Windows
    // hosts use detected MSVC without forcing those paths into libc++.
    integration_tests.root_module.link_libcpp = !cross_win_msvc;
    zip.link(integration_tests);
    if (velopack_enabled) {
        try velopack.linkVelopack(b, integration_tests, .{ .target = target, .optimize = optimize });
    }

    integration_tests.step.dependOn(process_assets_step);

    test_integration_step.dependOn(&b.addRunArtifact(integration_tests).step);
    check_integration_step.dependOn(&integration_tests.step);

    if (win_libc.needs_setup) {
        exe.step.dependOn(&msvcup_before_compile.step);
        if (!velopack_enabled and velopack_supported_for_target) {
            exe_for_package.step.dependOn(&msvcup_before_compile.step);
        }
        integration_tests.step.dependOn(&msvcup_before_compile.step);
        unit_tests.step.dependOn(&msvcup_before_compile.step);
    }

    if (effective_win_libc) |ini| {
        if (target.result.os.tag == .windows and target.result.abi == .msvc) {
            if (cross_win_msvc) b.libc_file = null;
            const libc_lp: std.Build.LazyPath = .{ .cwd_relative = ini };

            var roots: [4]*std.Build.Step.Compile = undefined;
            var n: usize = 0;
            roots[n] = exe;
            n += 1;
            roots[n] = unit_tests;
            n += 1;
            roots[n] = integration_tests;
            n += 1;
            if (!velopack_enabled and velopack_supported_for_target) {
                roots[n] = exe_for_package;
                n += 1;
            }
            velopack.applyWindowsMsvcLibcRecursive(b, roots[0..n], libc_lp);

            // `applyWindowsMsvcLibcRecursive` walks Compile steps; DVUI's `sdl3-c` / `dvui-c` bindings
            // use `Step.TranslateC`. `zig translate-c` has no `--libc`; we add MSVC/UCRT + SDK
            // `-isystem` paths by scanning each root compile's module graph (see
            // `applyMsvcIncludesToReachableTranslateC`).
            applyMsvcIncludesToReachableTranslateC(b, roots[0..n], ini) catch |e| {
                std.debug.panic("MSVC translate-c include fixup failed: {s}", .{@errorName(e)});
            };
        }
    }
}

/// Finds every `Step.TranslateC` reachable from each root compile's Zig module graph and adds
/// MSVC / Windows SDK `-isystem` paths from the zig-libc INI. We walk `Module.getGraph()` (imports)
/// rather than `Step.dependencies`: Zig wires `root_source_file` → `TranslateC` only in
/// `createModuleDependencies`, which runs after `build()` returns, so a step BFS from `Compile`
/// would miss DVUI's `dvui-c` / `sdl3-c` translate steps during Configure.
fn applyMsvcIncludesToReachableTranslateC(
    b: *std.Build,
    roots: []const *std.Build.Step.Compile,
    libc_ini_path: []const u8,
) !void {
    // `libc_ini_path` is absolute (resolved via `b.pathFromRoot`), so any Dir works as the base.
    const data = try b.build_root.handle.readFileAlloc(b.graph.io, libc_ini_path, b.allocator, .unlimited);

    var include_dir: ?[]const u8 = null;
    var sys_include_dir: ?[]const u8 = null;
    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "include_dir=")) {
            include_dir = std.mem.trim(u8, line["include_dir=".len..], " \r\t");
        } else if (std.mem.startsWith(u8, line, "sys_include_dir=")) {
            sys_include_dir = std.mem.trim(u8, line["sys_include_dir=".len..], " \r\t");
        }
    }
    if (include_dir == null or sys_include_dir == null) return;

    // `include_dir` points at `.../Windows Kits/10/Include/<ver>/ucrt`. The Windows SDK's
    // um/shared/winrt headers live as siblings of the `ucrt` directory.
    const sdk_inc_root = std.fs.path.dirname(include_dir.?) orelse return;
    const um_dir = try std.fs.path.join(b.allocator, &.{ sdk_inc_root, "um" });
    const shared_dir = try std.fs.path.join(b.allocator, &.{ sdk_inc_root, "shared" });
    const winrt_dir = try std.fs.path.join(b.allocator, &.{ sdk_inc_root, "winrt" });

    var seen_translate_c = std.AutoHashMap(*std.Build.Step.TranslateC, void).init(b.allocator);
    defer seen_translate_c.deinit();

    for (roots) |root_compile| {
        const graph = root_compile.root_module.getGraph();
        for (graph.modules) |mod| {
            const root_src = mod.root_source_file orelse continue;
            const gen = switch (root_src) {
                .generated => |g| g,
                else => continue,
            };
            const dep_step = gen.file.step;
            if (dep_step.id != .translate_c) continue;

            const tc: *std.Build.Step.TranslateC = @fieldParentPtr("step", dep_step);
            const gop = try seen_translate_c.getOrPut(tc);
            if (gop.found_existing) continue;

            const rt = tc.target.result;
            if (rt.os.tag == .windows and rt.abi == .msvc) {
                // `translate-c` uses aro, not MSVC cl.exe. MSVC's <stdint.h> uses literals like
                // `0xffffffffffffffffui64` which aro rejects — an `-I` shim must win before `-isystem`
                // pulls in VC/include.
                tc.addIncludePath(b.path("src/tools/msvc_translatec_shim"));
                // Order matters: MSVC's own headers first (override Windows SDK declarations when both
                // exist), then UCRT, then the Windows SDK trio.
                tc.addSystemIncludePath(.{ .cwd_relative = sys_include_dir.? });
                tc.addSystemIncludePath(.{ .cwd_relative = include_dir.? });
                tc.addSystemIncludePath(.{ .cwd_relative = um_dir });
                tc.addSystemIncludePath(.{ .cwd_relative = shared_dir });
                tc.addSystemIncludePath(.{ .cwd_relative = winrt_dir });
            }
        }
    }
}

const FizzyExecutable = struct {
    exe: *std.Build.Step.Compile,
    zstbi_module: *std.Build.Module,
    msf_gif_module: *std.Build.Module,
    known_folders: *std.Build.Module,
};

fn addFizzyExecutableForTarget(
    b: *std.Build,
    resolved_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    accesskit: dvui.AccesskitOptions,
    build_opts: *std.Build.Step.Options,
    zip_pkg: zip.Package,
    assets_module: *std.Build.Module,
    process_assets_step: *std.Build.Step,
    macos_sdl_paths: ?MacosSdlPaths,
    velopack_enabled: bool,
) !FizzyExecutable {
    const dvui_dep = if (macos_sdl_paths) |p|
        b.dependency("dvui", .{
            .target = resolved_target,
            .optimize = optimize,
            .backend = .sdl3,
            .accesskit = accesskit,
            .system_include_path = p.include,
            .system_framework_path = p.framework,
            .library_path = p.lib,
        })
    else
        b.dependency("dvui", .{ .target = resolved_target, .optimize = optimize, .backend = .sdl3, .accesskit = accesskit });

    const zstbi_lib = b.addLibrary(.{
        .name = "zstbi",
        .root_module = b.addModule("zstbi", .{
            .target = resolved_target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/deps/stbi/zstbi.zig" },
        }),
    });
    const zstbi_module = zstbi_lib.root_module;
    zstbi_module.addCSourceFile(.{ .file = std.Build.path(b, "src/deps/stbi/zstbi.c") });

    const msf_gif_lib = b.addLibrary(.{
        .name = "msf_gif",
        .root_module = b.addModule("msf_gif", .{
            .target = resolved_target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/deps/msf_gif/msf_gif.zig" },
        }),
    });
    const msf_gif_module = msf_gif_lib.root_module;
    msf_gif_module.addCSourceFile(.{ .file = std.Build.path(b, "src/deps/msf_gif/msf_gif.c") });

    const exe = b.addExecutable(.{
        .name = "fizzy",
        .root_module = b.addModule("App", .{
            .target = resolved_target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/App.zig" },
        }),
    });
    exe.root_module.strip = false;

    exe.root_module.addImport("assets", assets_module);
    const known_folders = b.dependency("known_folders", .{
        .target = resolved_target,
        .optimize = optimize,
    }).module("known-folders");
    exe.root_module.addImport("known-folders", known_folders);
    exe.root_module.addOptions("build_opts", build_opts);
    exe.step.dependOn(process_assets_step);

    if (optimize != .Debug) {
        switch (resolved_target.result.os.tag) {
            .windows => {
                exe.subsystem = .Windows;
                // MSVC's libcmt links `WinMainCRTStartup` (needs `WinMain`) for /SUBSYSTEM:WINDOWS.
                // Fizzy exposes `main`, so force the C `main` entry which works for either subsystem.
                if (resolved_target.result.abi == .msvc) {
                    exe.entry = .{ .symbol_name = "mainCRTStartup" };
                }
            },
            else => exe.subsystem = .Posix,
        }
    }

    exe.root_module.addImport("zstbi", zstbi_module);
    exe.root_module.addImport("msf_gif", msf_gif_module);
    exe.root_module.addImport("zip", zip_pkg.module);
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("backend", dvui_dep.module("sdl3"));

    if (b.lazyDependency("icons", .{ .target = resolved_target, .optimize = optimize })) |dep| {
        exe.root_module.addImport("icons", dep.module("icons"));
    }

    if (resolved_target.result.os.tag == .macos) {
        if (macos_sdl_paths) |p| {
            // Non-"native" macOS targets (`-Dtarget=aarch64-macos` on Apple Silicon, etc.) need the
            // same SDK layout for Obj-C sources as for SDL; zig-objc paths do not always reach .m
            // compiles (e.g. Security.framework → <libDER/DERItem.h>).
            exe.root_module.addSystemIncludePath(p.include);
            exe.root_module.addSystemFrameworkPath(p.framework);
            exe.root_module.addLibraryPath(p.lib);
        }
        if (b.lazyDependency("zig_objc", .{
            .target = resolved_target,
            .optimize = optimize,
        })) |dep| {
            exe.root_module.addImport("objc", dep.module("objc"));
        }
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/objc/FizzyVisualEffectView.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/objc/FizzyMenuTarget.m") });
    } else if (resolved_target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            exe.root_module.addImport("win32", dep.module("win32"));
        }
        exe.root_module.linkSystemLibrary("comctl32", .{});
    }

    const cross_win_msvc_exe = resolved_target.result.os.tag == .windows and
        resolved_target.result.abi == .msvc and
        b.graph.host.result.os.tag != .windows;
    exe.root_module.link_libcpp = !cross_win_msvc_exe;
    zip.link(exe);
    if (velopack_enabled) {
        try velopack.linkVelopack(b, exe, .{ .target = resolved_target, .optimize = optimize });
    }

    return .{
        .exe = exe,
        .zstbi_module = zstbi_module,
        .msf_gif_module = msf_gif_module,
        .known_folders = known_folders,
    };
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}

fn addImport(
    compile: *std.Build.Step.Compile,
    name: [:0]const u8,
    module: *std.Build.Module,
) void {
    compile.root_module.addImport(name, module);
}

fn addCGif(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.addIncludePath(std.Build.path(b, "src/deps/cgif/inc"));
    compile.addCSourceFile(.{ .file = std.Build.path(b, "src/deps/cgif/cgif.c") });
    compile.addCSourceFile(.{ .file = std.Build.path(b, "src/deps/cgif/cgif_raw.c") });
}
