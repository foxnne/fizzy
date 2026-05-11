#!/usr/bin/env bash
# pixi release script — runs from macOS, builds + signs + uploads to GitHub.
#
# Workflow:
#   1. Edit VERSION (e.g. 0.0.3 -> 0.0.4), commit it.
#   2. Tag the commit: git tag v0.0.4 && git push origin v0.0.4
#   3. Run: ./scripts/release.sh
#
# What this does:
#   - Reads VERSION as the source of truth for the release version.
#   - Confirms HEAD has a tag matching v<VERSION>.
#   - Builds all 6 targets in release mode via `zig build packageall`.
#   - Signs + notarizes macOS bundles if signing env vars are set.
#   - Renames installers to pixi_<os>_<arch>.<ext> for human download.
#   - Leaves *.nupkg and releases.<channel>.json under their canonical names
#     (Velopack auto-update looks for those literally; do not rename).
#   - Creates a *draft* GitHub release with `gh release create` and uploads
#     all 18 assets (6 installers + 6 nupkgs + 6 release manifests).
#   - Prints the draft URL. You review, edit notes, and click Publish in the
#     browser. Velopack-linked binaries only start finding the update once
#     the release is published (not while it's a draft).
#
# Env vars consumed (all optional; missing signing → unsigned macOS build):
#   PIXI_MACOS_SIGN_APP        - Developer ID Application identity
#   PIXI_MACOS_SIGN_INSTALLER  - Developer ID Installer identity
#   PIXI_MACOS_NOTARY_PROFILE  - notarytool keychain profile name
#   GITHUB_TOKEN               - for `gh` (or use `gh auth login` once)
#   PIXI_RELEASE_NOTES         - free-form notes; default: "Release v<VERSION>"
#   PIXI_RELEASE_PUBLISH       - if "1", publishes the release (otherwise draft)
#   PIXI_RELEASE_SKIP_BUILD    - if "1", skip `zig build packageall`
#                                (assumes zig-out is already populated)

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ----- preflight -----------------------------------------------------------

if [[ ! -f VERSION ]]; then
    echo "error: no VERSION file at $repo_root" >&2
    exit 1
fi

version="$(tr -d '[:space:]' < VERSION)"
if [[ -z "$version" ]]; then
    echo "error: VERSION file is empty" >&2
    exit 1
fi

tag="v$version"
echo "==> Release version: $version (tag: $tag)"

if ! command -v gh >/dev/null 2>&1; then
    echo "error: GitHub CLI (gh) not found; install with \`brew install gh\` and run \`gh auth login\`" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh not authenticated; run \`gh auth login\`" >&2
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not on PATH" >&2
    exit 1
fi

if ! command -v dotnet >/dev/null 2>&1; then
    echo "error: dotnet not on PATH (Velopack's vpk needs it)" >&2
    exit 1
fi

# Verify HEAD is tagged with v$version. We don't auto-create the tag — the
# operator is expected to have done that explicitly so they own the decision.
head_sha="$(git rev-parse HEAD)"
tag_sha="$(git rev-parse --verify --quiet "refs/tags/$tag" || true)"
if [[ -z "$tag_sha" ]]; then
    echo "error: tag $tag does not exist locally; run \`git tag $tag && git push origin $tag\`" >&2
    exit 1
fi
if [[ "$tag_sha" != "$head_sha" ]]; then
    echo "warning: tag $tag points at $tag_sha, but HEAD is $head_sha" >&2
    echo "         continuing, but the release will reflect the tag's commit, not HEAD" >&2
fi

# Warn (not fail) on dirty working tree. Sometimes you want to test a release
# build locally without committing every WIP doc tweak first.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: working tree is dirty; uncommitted changes won't be in the release" >&2
fi

# ----- signing env: report -------------------------------------------------

sign_app="${PIXI_MACOS_SIGN_APP:-}"
sign_install="${PIXI_MACOS_SIGN_INSTALLER:-}"
notary_profile="${PIXI_MACOS_NOTARY_PROFILE:-}"

if [[ -n "$sign_app" && -n "$sign_install" && -n "$notary_profile" ]]; then
    echo "==> macOS signing: enabled (app=${sign_app}, installer=${sign_install}, notary=${notary_profile})"
else
    echo "==> macOS signing: DISABLED (set PIXI_MACOS_SIGN_APP, PIXI_MACOS_SIGN_INSTALLER, PIXI_MACOS_NOTARY_PROFILE to enable)"
    if [[ -n "$sign_app" || -n "$sign_install" || -n "$notary_profile" ]]; then
        echo "    one or more macOS signing vars are set but not all three — skipping signing" >&2
    fi
fi

# ----- build all 6 targets -------------------------------------------------

if [[ "${PIXI_RELEASE_SKIP_BUILD:-0}" != "1" ]]; then
    # MSVC SDK setup is run as its OWN step, not just via -Dfetch-msvc on
    # packageall. The reason: build.zig wires msvcup_before_compile as a
    # dependency of the root compile artifacts only (exe, tests). Transitive
    # compiles (SDL3, freetype, …) don't inherit that dependency, so Zig's
    # scheduler can — and on CI does — fire them in parallel with msvcup.
    # SDL3 then tries to read .velopack-msvc/zig-libc-x64.ini before msvcup
    # has written it and fails with FileNotFound.
    #
    # Running msvcup-setup serially before packageall side-steps the race:
    # the .ini files exist at graph-build time, resolveWindowsMsvcLibc
    # returns a valid path immediately, needs_setup stays false, msvcup
    # isn't even added to the graph for the per-target child builds, and
    # there's no parallel window for transitive compiles to lose.
    #
    # No-op locally if .velopack-msvc/ is already populated.
    if [[ ! -f .velopack-msvc/zig-libc-x64.ini || ! -f .velopack-msvc/zig-libc-arm64.ini ]]; then
        echo "==> Setting up MSVC SDK for cross-compile to Windows (zig build msvcup-setup)"
        zig build msvcup-setup
    else
        echo "==> .velopack-msvc/ already populated, skipping msvcup-setup"
    fi

    echo "==> Building all targets (zig build packageall -Doptimize=ReleaseFast)"
    zig build packageall -Doptimize=ReleaseFast
else
    echo "==> PIXI_RELEASE_SKIP_BUILD=1, reusing existing zig-out/"
fi

# ----- collect + rename artifacts ------------------------------------------

# The 6 channels match `zigOutSubdirForTarget` in build.zig and the
# `--channel` arg passed to `vpk pack`. They are the literal channel names
# baked into each binary; do not change without also changing build.zig.
declare -a channels=(
    "x86-64-linux"
    "arm64-linux"
    "x86-64-macos"
    "arm64-macos"
    "x86-64-windows"
    "arm64-windows"
)

# Map channel -> (os, arch, installer-extension) used to build the public
# installer name: pixi_<os>_<arch>.<ext>
declare -A channel_os=(
    [x86-64-linux]=linux
    [arm64-linux]=linux
    [x86-64-macos]=macos
    [arm64-macos]=macos
    [x86-64-windows]=windows
    [arm64-windows]=windows
)
declare -A channel_arch=(
    [x86-64-linux]=x86_64
    [arm64-linux]=arm64
    [x86-64-macos]=x86_64
    [arm64-macos]=arm64
    [x86-64-windows]=x86_64
    [arm64-windows]=arm64
)
declare -A channel_ext=(
    [x86-64-linux]=AppImage
    [arm64-linux]=AppImage
    [x86-64-macos]=pkg
    [arm64-macos]=pkg
    [x86-64-windows]=exe
    [arm64-windows]=exe
)

staging="$repo_root/zig-out/release-staging"
rm -rf "$staging"
mkdir -p "$staging"

# Locate an installer for a channel by extension. Velopack names the installer
# something like Pixi-<version>-<channel>-Setup.<ext> or similar, but we just
# match by extension within that channel's output dir — there's only one.
find_installer() {
    local dir="$1" ext="$2"
    # `-not -name '*.nupkg'` because .nupkg is a zip-with-extension on some
    # platforms; we never want to match it as the installer.
    find "$dir" -maxdepth 1 -type f -name "*.$ext" -not -name '*.nupkg' | head -n 1
}

# Copy a file into staging while detecting cross-channel name collisions.
# vpk historically has emitted the same nupkg name for different OS targets
# (e.g. `pixi-0.0.3-full.nupkg` on both arm64-windows and x86_64-windows
# when --channel isn't set). The --channel arg we now pass in build.zig
# should keep names unique, but this is a defensive check: if two channels
# stage a file under the same name, the GitHub release upload would fail
# silently (or overwrite), so we fail loudly here instead.
stage_canonical() {
    local src="$1"
    local base
    base="$(basename "$src")"
    if [[ -e "$staging/$base" ]]; then
        echo "error: collision in staging — two channels produced $base" >&2
        echo "       this usually means vpk did not include the channel in the filename." >&2
        echo "       check that build.zig is passing --channel <distinct-name> to vpk pack." >&2
        exit 1
    fi
    cp "$src" "$staging/$base"
    uploads+=("$staging/$base")
}

uploads=()

for ch in "${channels[@]}"; do
    out="$repo_root/zig-out/$ch"
    if [[ ! -d "$out" ]]; then
        echo "error: missing $out — did `zig build packageall` actually run?" >&2
        exit 1
    fi

    ext="${channel_ext[$ch]}"
    installer="$(find_installer "$out" "$ext")"
    if [[ -z "$installer" ]]; then
        echo "error: no *.${ext} installer found in $out for channel $ch" >&2
        echo "       contents:" >&2
        ls -la "$out" >&2
        exit 1
    fi

    # Renamed installer: staged under the public name. This name is intentional
    # and stable; users will link to it. The Velopack runtime never looks for
    # this filename — it queries the GitHub API for the nupkg.
    public_name="pixi_${channel_os[$ch]}_${channel_arch[$ch]}.${ext}"
    if [[ -e "$staging/$public_name" ]]; then
        echo "error: two channels would produce $public_name (table misconfigured)" >&2
        exit 1
    fi
    cp "$installer" "$staging/$public_name"
    uploads+=("$staging/$public_name")
    echo "    $ch: $(basename "$installer") -> $public_name"

    # nupkg(s) — keep canonical names. vpk emits one with `--delta None`.
    # We glob `*-full.nupkg` rather than `*-${ch}-full.nupkg` because vpk
    # has historically inconsistent channel-in-filename behaviour. Each
    # channel has its own output dir, and stage_canonical fails if two
    # channels somehow produce the same filename.
    nupkg_count=0
    while IFS= read -r -d '' nupkg; do
        stage_canonical "$nupkg"
        nupkg_count=$((nupkg_count + 1))
        echo "    $ch: $(basename "$nupkg") (canonical)"
    done < <(find "$out" -maxdepth 1 -type f -name "*-full.nupkg" -print0)
    if [[ "$nupkg_count" == 0 ]]; then
        echo "error: no *-full.nupkg in $out for channel $ch" >&2
        ls -la "$out" >&2
        exit 1
    fi

    # Release manifest. Newer Velopack writes `releases.<channel>.json`; older
    # writes `RELEASES-<channel>`. We upload both formats when present so old
    # and new Velopack runtimes both work. NB: bare `RELEASES` (no suffix) is
    # NOT a candidate — vpk only emits that when --channel is unset, and we
    # always pass --channel; a bare-name file would also collide across the 6
    # channels in the staging dir and indicates the channel arg silently failed.
    found_manifest=0
    for candidate in "releases.${ch}.json" "RELEASES-${ch}" "RELEASES.${ch}"; do
        if [[ -f "$out/$candidate" ]]; then
            stage_canonical "$out/$candidate"
            echo "    $ch: $candidate (manifest)"
            found_manifest=$((found_manifest + 1))
        fi
    done
    if [[ "$found_manifest" == 0 ]]; then
        echo "error: no Velopack release manifest in $out for channel $ch" >&2
        echo "       expected one of: releases.${ch}.json, RELEASES-${ch}" >&2
        echo "       (if you see a bare 'RELEASES' here, build.zig's --channel arg isn't propagating)" >&2
        echo "       contents:" >&2
        ls -la "$out" >&2
        exit 1
    fi
done

echo "==> Staged ${#uploads[@]} files in $staging"

# ----- create + populate the release ---------------------------------------

notes="${PIXI_RELEASE_NOTES:-Release $tag}"

# If the release already exists, upload missing assets to it (idempotent re-runs).
if gh release view "$tag" >/dev/null 2>&1; then
    echo "==> Release $tag already exists; uploading assets with --clobber"
    gh release upload "$tag" "${uploads[@]}" --clobber
else
    echo "==> Creating draft release $tag"
    gh release create "$tag" \
        --draft \
        --title "$tag" \
        --notes "$notes" \
        "${uploads[@]}"
fi

if [[ "${PIXI_RELEASE_PUBLISH:-0}" == "1" ]]; then
    echo "==> Publishing release $tag"
    gh release edit "$tag" --draft=false
fi

release_url="$(gh release view "$tag" --json url -q .url)"
echo ""
echo "==> Done. Release: $release_url"
if [[ "${PIXI_RELEASE_PUBLISH:-0}" != "1" ]]; then
    echo "    (draft) Review the release in the browser, then publish."
    echo "    Auto-update on existing installs only kicks in after publishing."
fi
