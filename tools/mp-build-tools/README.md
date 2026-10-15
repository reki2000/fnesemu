# mp-build-tools

Shared GitHub Actions for Flutter application builds, exact CI binary releases and GitHub Pages. Public Actions handle SDK setup, signing, artifact storage, digest validation and publication; longer platform commands are in `scripts/`.

| Action | Purpose | Caller permissions |
|---|---|---|
| `flutter-build` | Build, package and upload one native or portable Web target | `contents: read` |
| `read-version` | Read the root pubspec version and numeric native build name | `contents: read` |
| `release-binaries` | Promote the exact verified CI platform set to a Release | `actions: read`, `contents: write` |
| `deploy-pages` | Deploy the current CI Web archive to stable or develop | `contents: write` |

Check out the application first and run one target per job. Versions come from the repository root, including applications under `example/`. Pin Actions to a reviewed commit SHA and update pins deliberately in every caller. Examples under `examples/` are complete migration templates; replace `REPLACE_WITH_PUBLISHED_SHA` with the published Action commit before using them.

```yaml
- uses: actions/checkout@v4
  with:
    submodules: recursive
- uses: reki2000/mp-build-tools/flutter-build@<reviewed-commit-sha>
  with:
    target: web
    app-directory: example
    artifact-name: mp_bigfile_picker-example
    flutter-version: '3.47.5'
```

`app-directory` defaults to `.`, Flutter to `3.47.5` and artifact retention to 90 days. Native builds require `architecture`. Use `web/browser` (automatic), `android/all`, `linux/x64` or `arm64`, `windows/x64` or `arm64`, `macos/universal`, and `ios` or `ios-simulator/arm64` on matching runners. Linux ARM64 bootstraps the pinned SDK source; Windows ARM64 replaces Dart with its native SDK. macOS archives are checked for both architectures and ad-hoc signed; Windows includes matching MSVC runtime DLLs.

The build Action exposes `version`, numeric `build-name` and `artifact-id`, and sets its build environment for subsequent steps. Root versions without `+build` suffixes name the archives. Web uses the full prerelease version and native metadata uses the numeric version.

## Signing

Pass all four Android inputs together: `android-keystore-base64`, `android-keystore-password`, `android-key-alias`, `android-key-password`. Pass all four iOS inputs together: `ios-certificate-base64`, `ios-certificate-password`, `ios-profile-base64`, `ios-export-options-base64`. Use caller repository secrets; partial configuration fails. PR builds ignore signing inputs.

Without persistent secrets, Android uses temporary test keys and device IPAs are unsigned. Configure a persistent Android key before verification of ongoing distribution builds. iOS installation follows the selected provisioning profile. Store uploads, TestFlight and notarization are separate operations. Signing files are excluded from artifacts and cleaned from the runner.

## Exact verified releases

Keep tests, event conditions, runners, the platform matrix and completion gating in the caller repository. Upload `full-build-success` only after all tests and every platform succeed on main/manual runs. Internally verify those binaries, then tag that exact commit with the root pubspec version.

`release-binaries` accepts `tag`, `artifact-name`, optional `build-run-id`, and `build-workflow` (default `build-binaries.yaml`). Check out the existing tag before calling it. Its token defaults to the caller GitHub token and needs Actions read/contents write. It requires the exact successful full main/manual CI commit and nine unexpired platform artifacts, validates download digests, uploads a draft, then publishes after every upload succeeds. Published releases are retained. Nothing is rebuilt or re-signed; PR artifacts cannot be promoted.

## Pages

Call `deploy-pages` after the caller's tests/builds with contents write and a repository-wide serialized concurrency group. Pass `target-folder: develop` for develop or an empty folder for stable. Pass `dry-run: false` only for publication; its default is true.

The current run's `release-web-browser` artifact is deployed unchanged. Root cleanup preserves develop and custom-domain metadata while removing stale files. Select `gh-pages / (root)` in branch-based Pages settings after the first deployment. The relative base and hash routing expect a directory URL with a trailing slash; stable and develop paths share origin storage.

## Maintenance

Update commands in `scripts/build.sh`, archives in `scripts/package.sh` and source policy in `scripts/verify-release.cjs`. Keep public Actions pinned. The checks workflow validates Action/workflow metadata, release-source policy, and composite script paths/outputs on Linux, macOS and Windows. Complete every consumer's full native/Web CI before updating its reviewed pin.
