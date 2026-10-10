# Test
see docs/TEST.md

# Architecture
Follow the design rules in ARCHITECTURE.md: the parts, the direction of the
dependencies, and the interfaces between them.
- After adding/removing a core module, run `dart run tool/generate_core_registry.dart` in `packages/fnesemu_core`; do not modify App/GUI for it.

# Imports
- Within a package's `lib/`, import the same package's files by relative paths (lint `prefer_relative_imports`). Tests and tools import `lib/` by `package:` URIs.
- Keep the directives sorted (lint `directives_ordering`; `make format` applies both).
