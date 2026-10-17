// Reads source files to check package boundaries.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// the core files which [dir] may import
  void expectOnlyPublicCore(String dir, {Set<String> allowed = const {}}) {
    for (final file
        in Directory(dir).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in RegExp(r'''import\s+['"]([^'"]+)['"]''')
          .allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        if (uri.startsWith('package:fnesemu_core/')) {
          expect(
              uri == 'package:fnesemu_core/app_api.dart' ||
                  (file.path.endsWith('core_boundary_test.dart') &&
                      allowed.contains(uri)),
              isTrue,
              reason: '${file.path}: $uri');
        }
      }
    }
  }

  test('GUI imports only the public core API', () {
    expectOnlyPublicCore('lib');
  });

  test('app tests import only the public core API', () {
    // the registry, to test the app without cores
    expectOnlyPublicCore('test', allowed: {
      'package:fnesemu_core/src/internal/core_registry_generated.dart',
      'package:fnesemu_core/src/internal/core_registry.dart',
    });
  });
}
