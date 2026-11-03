// Reads source files to check architecture layers.
@TestOn('vm')
library;

// the rules between the cores in ARCHITECTURE.md
import 'dart:io';

import 'package:test/test.dart';

const coreDir = 'lib/src/core';

/// the part of lib/ which [path] (relative to lib/) belongs to: a module
/// name, 'components', 'shared' (lib/src/*.dart) or 'util'
String layerOf(String path) {
  if (!path.startsWith('src/')) return 'public';
  final parts = path.replaceFirst(RegExp(r'^src/'), '').split('/');
  if (parts[0] == 'util' ||
      parts[0] == 'components' ||
      parts[0] == 'internal') {
    return parts[0];
  }
  if (parts.length == 1) return 'shared';
  return parts[1];
}

/// the files of lib/ which [file] imports, relative to lib/
Iterable<String> importsOf(File file) sync* {
  final dir = file.parent.uri;
  for (final m
      in RegExp(r'''^(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true)
          .allMatches(file.readAsStringSync())) {
    final uri = m.group(1)!;
    if (uri.startsWith('dart:')) continue;
    if (uri.startsWith('package:')) {
      if (uri.startsWith('package:fnesemu_core/')) {
        yield uri.substring('package:fnesemu_core/'.length);
      }
      continue;
    }
    final path = dir.resolve(uri).path;
    yield path.substring(path.indexOf('lib/') + 4);
  }
}

void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  final modules = Directory(coreDir)
      .listSync()
      .whereType<Directory>()
      .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toSet();

  String rel(File f) => f.uri.path.substring(f.uri.path.indexOf('lib/') + 4);

  test('a core module imports no other module', () {
    for (final file in files) {
      final from = layerOf(rel(file));
      if (!modules.contains(from)) continue;
      for (final to in importsOf(file).map(layerOf)) {
        expect(!modules.contains(to) || to == from, isTrue,
            reason: '${file.path} imports $to');
      }
    }
  });

}
