# Tests

Follow `docs/TEST.md` if it exists.

# Python environment

`scripts/e2e.py` and `scripts/regress.py` need Python 3.11 or later with Pillow and numpy (`scripts/requirements.txt`).
The default `python3` on `PATH` (mise 3.15, or `/usr/bin/python3`) may lack them.
Create a virtual environment once and run the scripts with it:

```
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements.txt
.venv/bin/python scripts/e2e.py run --root docs/local-e2e <target>
```

`.venv/` must stay out of Git.

When you try inputs by trial and error, do not rerun the case from frame 1 each time.
Use the session mode of `scripts/e2e.py`, which keeps the emulator running between steps:

```
.venv/bin/python scripts/e2e.py session start --root docs/local-e2e <core>/<case>
.venv/bin/python scripts/e2e.py session press --root docs/local-e2e "<sequence>"
.venv/bin/python scripts/e2e.py session step --root docs/local-e2e FRAMES --every E
.venv/bin/python scripts/e2e.py session input --root docs/local-e2e
.venv/bin/python scripts/e2e.py session stop --root docs/local-e2e
```

`FRAMES` is the number of frames to advance from the current frame, not a target frame.
Run `session input` to print the input to pass to `set --input`.
Always run `session stop` when you finish.

# Document Writing

Use a simple technical style. Do not insert line breaks within a sentence. Follow `docs/DOCUMENT.md` if it exists.
Write all document / code comments in English.
PR descriptions do not need a Validation section.

# Architecture

Follow `ARCHITECTURE.md` for component responsibilities, dependency directions, and interfaces.

- After adding or removing a core module, run `dart run tool/generate_core_registry.dart` in `packages/fnesemu_core`. Do not modify the app or GUI to accommodate the module change.

# Performance

Before changing Dart code for speed, read `packages/fnesemu_core/tool/dart_aot_tips.md`. It covers profiling, the compiler behavior seen in the x64 output, the measurement rules and the guidelines.

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

- Releases go from `develop` to `main`. Before opening the PR, set `version:` in the root `pubspec.yaml` on `develop` to the release version (`X.Y.Z+0`). The tag must match this version.
- Pushing a new version to `develop` opens the `develop` → `main` PR automatically (`.github/workflows/release-pr.yaml`). It skips the PR when the tag already exists or a release PR is already open. It opens the PR with the `RELEASE_PR_TOKEN` secret, a fine-grained token with Pull requests write access. Merge that PR.
- Tag the merge commit on `main` with `vX.Y.Z`. The tag starts the `Release verified binaries` workflow (`.github/workflows/release.yaml`). It waits for the `Build binaries` run of the tagged commit to succeed, checks that the tag matches `pubspec.yaml`, attaches the verified binaries to a draft GitHub Release, and then publishes it.
- The workflow leaves an already published GitHub Release unchanged.
