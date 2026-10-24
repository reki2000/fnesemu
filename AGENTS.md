# Tests

Follow `docs/TEST.md` if it exists.

# Document Writing

Use a simple technical style. Do not insert line breaks within a sentence. Follow `docs/DOCUMENT.md` if it exists.
Write all document / code comments in English.
PR descriptions do not need a Validation section.

# Architecture

Follow `ARCHITECTURE.md` for component responsibilities, dependency directions, and interfaces.

- After adding or removing a core module, run `dart run tool/generate_core_registry.dart` in `packages/fnesemu_core`. Do not modify the app or GUI to accommodate the module change.

# Reference policy

- Do not consult, copy, translate, or adapt source code or implementation details from other emulators when implementing or debugging fnesemu.
- Base new implementations on publicly available hardware specifications, original technical documentation, independent test cases, and fnesemu's own code and architecture.
- Do not use another emulator's code as a reference even if its license permits reuse. When a hardware behavior is unclear, document the uncertainty and validate it with hardware documentation or independent tests.

# Imports

- Within a package's `lib/`, use relative imports for files in the same package (`prefer_relative_imports`). In tests and tools, use `package:` URIs to import files from `lib/`.
- Keep import directives sorted (`directives_ordering`). Run `make format` to apply both import rules.

# Worktrees

- Create working Git worktrees under the repository's `.worktrees/` directory. This directory is ignored by Git.

# Release

- Releases go from `develop` to `main`. Open a PR from `develop` into `main`.
- After the PR is merged, tag the merge commit on `main` with the version (`vX.Y.Z`).
- The tag starts the `Release verified binaries` workflow (`.github/workflows/release.yaml`). It uses the artifacts from the verified build of the tagged commit and updates the GitHub Release with them.
