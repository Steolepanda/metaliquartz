# System: deployment and platform boundaries

**Sources:** `Config/*.xcconfig`, `Metaliquartz.xcodeproj/`, `Sources/Resources/Info.plist`,
`Scripts/`, `Vendor/Syphon/`
**Decisions:** `DEC-0001` (Swift 6), `DEC-0004` (Syphon), `DEC-0005` (sandbox), `DEC-0006`
(ad hoc signing)

## Purpose

Record the boundaries that decide what the build can do and where it can run. These are not
conventions: the build system enforces them, and a change here changes what the product *is*.

## Platform

`Config/Base.xcconfig`:

- `ARCHS = arm64`, `ONLY_ACTIVE_ARCH = NO`, `SUPPORTED_PLATFORMS = macosx`,
  `MACOSX_DEPLOYMENT_TARGET = 14.0`, `SDKROOT = macosx`.
- `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`.
- `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = -`, `ENABLE_APP_SANDBOX = NO`.
- `ENABLE_USER_SCRIPT_SANDBOXING = YES`, `DEAD_CODE_STRIPPING = YES`.

There is no Intel target and no XCFramework/universal build. Running on an Intel Mac is not
supported. The deployment target is asserted, not measured: no evidence page yet records which
macOS versions were actually exercised (see `roadmap/ROADMAP.md`).

`Config/Debug.xcconfig` selects `-Onone`, DWARF, testability, hardened runtime off and Metal debug
info. `Config/Release.xcconfig` selects `-O` whole-module, dSYM, **hardened runtime on** and Metal
debug info off.

## Targets and scheme

`Metaliquartz.xcodeproj` has three `PBXNativeTarget`s: `Metaliquartz` (application),
`MetaliquartzTests` (unit-test bundle) and `MetaliquartzUITests` (UI-testing bundle). One shared
scheme, `Metaliquartz`, builds all three and runs both test bundles with parallel testing disabled
(`-parallel-testing-enabled NO` in `Scripts/verify.sh`, `parallelizable = "NO"` in the scheme).
There is no SwiftPM manifest; the Xcode project is the only build definition.

## Bundle and document type

`Sources/Resources/Info.plist` declares the bundle display name, the graphics-design category,
high-resolution support and `NSCameraUsageDescription`, and exports the composition UTI as a
package (`LSTypeIsPackage`). The UTI is declared from code in
`UTType.metaliquartzComposition` using `CompositionFile.formatIdentifier`.

**Known gap (D2):** the app listens for inbound OSC over UDP but declares no
`NSLocalNetworkUsageDescription`.

## Signing and distribution

- Local development and Release both sign ad hoc (`CODE_SIGN_IDENTITY = -`). No `DEVELOPMENT_TEAM`
  is set, and `Scripts/public-preflight.sh` fails the publishing gate if one appears.
- `Scripts/archive-alpha.sh <outdir>` runs `Scripts/verify.sh`, archives Release for
  `generic/platform=macOS`, verifies the signature with `codesign --verify --deep --strict`,
  and emits `Metaliquartz-alpha-arm64.zip` plus a `.sha256`.
- Developer ID signing and notarization are deliberately out of scope. Do not describe a build as
  notarized or distribution-ready without a certificate, team, entitlements and a notarization
  run.
- App Sandbox is disabled because the app needs files, cameras, displays, inbound network and
  Syphon. `DEC-0005` records what enabling it would require.

## Scripts

| Script | Purpose | Writes |
| --- | --- | --- |
| `Scripts/verify.sh` | Complete gate: Metal toolchain, `swift-format lint --strict`, generated-definition check, Debug build, unit+UI tests, Release build | Temporary derived data, removed on exit |
| `Scripts/archive-alpha.sh` | Gate + archive + signature verification + ZIP + SHA-256 | Caller-provided output directory |
| `Scripts/soak-test.sh` | Runs the app for a duration, records resident memory once a minute, fails on early exit | CSV beside the app/composition inputs |
| `Scripts/public-preflight.sh` | Publishing scanner over prospective files, staged contents and reachable history; `--tree` scans exported files only | Redacted categories/paths on stdout/stderr |
| `Scripts/test-public-preflight.py` | Synthetic privacy scanner regressions, including historical and untracked secrets | Temporary fixture repositories, removed on exit |
| `Scripts/prepare-github-package.py` | Approved source snapshot; privacy, docs and generated-definition gates; ZIP integrity | Ignored `dist/github/` ZIP, checksum and file manifest |
| `Scripts/verify-docs` | Documentation structure gate (links, anchors, decisions, fixtures) | Nothing |

Public source packaging follows [DEC-0017](../decisions/DEC-0017-public-source-snapshot.md).
The original Git history is not part of the ZIP. The generator and its six-patch schema are
public inputs, so a clean extracted package can reproduce the generated-definition check.
The GitHub workflow fetches full history and runs the privacy gate before the documentation gate.

## Vendored dependency

Syphon is vendored at `Vendor/Syphon` (version 5, upstream commit
`71351d4b484cd2d1917867f7846a5cdca724552d`, BSD-2-Clause) and linked/embedded as
`Syphon.framework`. Only the Metal client/server classes are used. The local tree carries one
documented modification (removal of the deprecated `kIOSurfaceIsGlobal`) recorded in
`Vendor/Syphon/Metaliquartz-Vendor.md`. `THIRD_PARTY_NOTICES.md` carries the license notice.
Re-resolving to a branch or moving tag is forbidden (`AGENTS.md`).

## Environment limitations observed

- A file-sandboxed session cannot write the Metal compiler's default clang module cache, so
  `Scripts/verify.sh` fails at the Debug build with `could not build module 'metal_types'`. This
  is environmental, not a code defect; the gate must run outside that sandbox.
- `Scripts/verify.sh` requires `xcrun metal` or the downloadable Metal Toolchain component and, for
  the UI journeys, developer tool automation (`sudo DevToolsSecurity -enable`).
- UI tests need an unlocked, logged-in GUI session. They fail rather than skip on headless CI.

## Tests that protect this

There is no dedicated deployment test. `Scripts/verify.sh` itself is the gate; the build settings
are validated by the fact that Debug and Release both build. A future CI workflow (Phase 4 of the
reorganization) runs the docs gate per push.
