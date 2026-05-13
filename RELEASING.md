# Releasing fizzy

Fizzy ships installers for six targets via [Velopack](https://velopack.io):

| Channel              | OS      | Arch    | Installer                       |
| -------------------- | ------- | ------- | ------------------------------- |
| `x86-64-linux`       | Linux   | x86_64  | `fizzy_linux_x86_64.AppImage`    |
| `arm64-linux`        | Linux   | arm64   | `fizzy_linux_arm64.AppImage`     |
| `x86-64-macos`       | macOS   | x86_64  | `fizzy_macos_x86_64.pkg`         |
| `arm64-macos`        | macOS   | arm64   | `fizzy_macos_arm64.pkg`          |
| `x86-64-windows`     | Windows | x86_64  | `fizzy_windows_x86_64.exe`       |
| `arm64-windows`      | Windows | arm64   | `fizzy_windows_arm64.exe`        |

Channel strings use hyphens only (no underscores): Velopack parses
`<version>-<channel>-…` as a NuGet version, and NuGet disallows `_` in the
prerelease segment.

The channel name is baked into each binary at `vpk pack` time and is what the
running installation asks the GitHub Releases API for when looking for an
update. Don't rename it casually — it's referenced in three places:
`build.zig` (`--channel`), each binary's embedded Velopack metadata, and the
asset names uploaded to releases.

## Version source of truth

The `VERSION` file at the repo root is the single source of truth.
`build.zig` reads it, plumbs it through `build_opts.app_version`, and passes
it to `vpk pack --packVersion`. The running binary logs it at startup
(`Fizzy version 0.0.3`). Override at build time with `-Dapp_version=0.0.4`
only for one-off experiments — don't release with a mismatched VERSION file.

## How auto-update works

The Velopack runtime in each binary calls the GitHub Releases API on the URL
baked in at build time (`-Drepo-url`, default `https://github.com/foxnne/fizzy`).
It looks at the latest non-prerelease release for assets matching its own
channel and downloads the `*-<channel>-full.nupkg`. The `releases.<channel>.json`
manifest tells it which nupkg is current.

For this to work, **three files per channel** must be present on the release:

1. The renamed installer (`fizzy_<os>_<arch>.<ext>`) — what humans download.
2. `fizzy-<version>-<channel>-full.nupkg` — the actual update payload Velopack
   downloads and applies.
3. `releases.<channel>.json` (or `RELEASES-<channel>` on older vpk) — the
   manifest that tells Velopack which nupkg version is current.

The release script handles all three for all six channels (18 files total).

## Cutting a release

### Bump VERSION and tag

```sh
# Edit VERSION (e.g. 0.0.3 -> 0.0.4)
$EDITOR VERSION
git add VERSION
git commit -m "release: 0.0.4"
git tag v0.0.4
git push origin main
git push origin v0.0.4
```

The tag push triggers `.github/workflows/release.yml`.

### Option A: Let CI do it

When the tag is pushed, the workflow runs on `macos-latest`, cross-compiles
all 6 targets, packages with `vpk`, and uploads to a **draft** release named
`v0.0.4`. Open the draft in the GitHub UI, fill in release notes, and click
**Publish release**. Auto-update on existing installs only sees the new
version after publishing.

If you don't have the signing secrets set up (see below), the macOS builds
will be unsigned — Gatekeeper will warn users. The release still goes out
fine; you'd just want to sign before announcing it widely.

### Option B: Run locally

If you'd rather drive the release from your Mac (uses your local Keychain
for signing, no CI secrets needed):

```sh
export FIZZY_MACOS_SIGN_APP="Developer ID Application: Your Name (TEAMID)"
export FIZZY_MACOS_SIGN_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
export FIZZY_MACOS_NOTARY_PROFILE="fizzy-notary"   # see one-time setup below

./scripts/release.sh
```

This does everything CI does, plus signs/notarizes the macOS bundle using
the certs in your login Keychain.

It's safe to run after CI has already run — the script uses `gh release
upload --clobber` to overwrite existing assets on the same draft release.

Set `FIZZY_RELEASE_PUBLISH=1` if you want the script to publish automatically
instead of leaving it as a draft.

## One-time setup

### Local signing on your Mac

You need two **Developer ID** certificates from Apple — request them from
the Apple Developer portal:

- *Developer ID Application* — signs the `.app` bundle
- *Developer ID Installer* — signs the `.pkg` installer

Install both into your login Keychain. Find their exact names with:

```sh
security find-identity -v -p codesigning
```

Then create a `notarytool` profile so notarization runs without prompts:

```sh
xcrun notarytool store-credentials fizzy-notary \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "<app-specific password>"
```

You generate the app-specific password at <https://appleid.apple.com> →
Sign-In and Security → App-Specific Passwords. The team ID is in the top
right of <https://developer.apple.com/account>.

Export these into your shell (e.g. in `~/.zshrc`):

```sh
export FIZZY_MACOS_SIGN_APP="Developer ID Application: Your Name (TEAMID)"
export FIZZY_MACOS_SIGN_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
export FIZZY_MACOS_NOTARY_PROFILE="fizzy-notary"
```

### CI signing (optional)

If you want CI to sign instead of you, set the following secrets (either on
the repo under **Settings → Secrets and variables → Actions**, or on an
**environment** — the release workflow uses the environment **`fizzy_release`**,
so you can store them there for stricter access / required reviewers):

| Secret                        | What it is                                                 |
| ----------------------------- | ---------------------------------------------------------- |
| `FIZZY_MACOS_CERT_P12_BASE64`  | `base64 < combined.p12` of both Developer ID certs         |
| `FIZZY_MACOS_CERT_PASSWORD`    | password for the `.p12`                                    |
| `FIZZY_MACOS_SIGN_APP`         | "Developer ID Application: NAME (TEAMID)"                  |
| `FIZZY_MACOS_SIGN_INSTALLER`   | "Developer ID Installer: NAME (TEAMID)"                    |
| `FIZZY_APPLE_ID`               | Apple ID email                                             |
| `FIZZY_APPLE_APP_PASSWORD`     | app-specific password                                      |
| `FIZZY_APPLE_TEAM_ID`          | 10-character team ID                                       |

To bundle both certs into one `.p12`, in Keychain Access select both
identities (Cmd-click) → File → Export Items → Personal Information Exchange
(.p12).

The workflow detects whether these are set and skips signing if any are
missing.

## Testing the auto-updater without a real release

There are two paths:

1. **Local feed.** Run `zig build packageall -Doptimize=ReleaseFast`, then
   point a built copy at the local output dir:

   ```sh
   FIZZY_AUTOUPDATE_URL="$PWD/zig-out/x86-64-macos" ./zig-out/x86-64-macos/fizzy
   ```

   This bypasses GitHub entirely and reads the `releases.*.json` straight
   from disk. Good for verifying the Velopack runtime works.

2. **Pre-release on GitHub.** Cut a release marked as "pre-release" via the
   GitHub UI. The default `vpkc_new_source_github(..., prerelease: false)`
   in `App.zig` filters those out, so a published-but-prerelease release
   won't be picked up unless you toggle that flag. Useful for a final
   verification on a non-production tag.

## Troubleshooting

**"vpkc_new_source_github failed"** at startup: usually a network problem
reaching `api.github.com`, or a malformed repo URL. The URL must be
`https://github.com/<owner>/<repo>` with no trailing slash and no `.git`.

**Velopack reports no update available** when you expect one: most often
the channel embedded in the running binary doesn't match the `--channel`
that produced the release assets. Check `Fizzy.app/Contents/Resources/`
(macOS) or the `sq.version` file inside a Setup zip for the channel name
the binary will request.

**Notarization rejected with "signature does not include a secure
timestamp"**: signing was done without `--signEntitlements`. The build.zig
already passes the entitlements file when `FIZZY_MACOS_SIGN_APP` is set;
make sure that env var is exported when running `zig build package`
directly (the release script handles this for you).
