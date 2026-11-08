// Reads source files to check component dependencies.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

Iterable<String> directives(File file) sync* {
  final pattern =
      RegExp(r'^(?:import|export|part)\s+(?!of\b)[^;]*;', multiLine: true);
  for (final directive in pattern.allMatches(file.readAsStringSync())) {
    for (final match
        in RegExp(r'''['"]([^'"]+)['"]''').allMatches(directive.group(0)!)) {
      yield match.group(1)!;
    }
  }
}

void main() {

  test('registered runtime cores do not depend on native I/O or tools', () {
    final pending = Directory('lib/src/core')
        .listSync()
        .whereType<Directory>()
        .map((directory) => File('${directory.path}/module.dart'))
        .where((file) => file.existsSync())
        .toList();
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final file = pending.removeLast().absolute;
      if (!visited.add(file.uri.normalizePath().path)) continue;
      for (final uri in directives(file)) {
        expect(uri, isNot('dart:io'), reason: file.path);
        if (uri.startsWith('dart:')) continue;
        final Uri dependency;
        if (uri.startsWith('package:fnesemu_core/')) {
          dependency = Directory('lib')
              .absolute
              .uri
              .resolve(uri.substring('package:fnesemu_core/'.length));
        } else if (uri.startsWith('package:')) {
          continue;
        } else {
          dependency = file.uri.resolve(uri);
        }
        expect(dependency.path, isNot(contains('/tool/')),
            reason: '${file.path}: $uri');
        expect(dependency.path, isNot(contains('/lib/gui/')),
            reason: '${file.path}: $uri');
        pending.add(File.fromUri(dependency));
      }
    }
  });
}
