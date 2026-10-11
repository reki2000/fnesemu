// the rules between the cores in ARCHITECTURE.md
import 'dart:io';

import 'package:test/test.dart';

const coreDir = 'lib/src/core';

/// the part of lib/ which [path] (relative to lib/) belongs to: a module
/// name, 'components', 'shared' (lib/src/core/*.dart) or 'util'
String layerOf(String path) {
  final parts = path.replaceFirst(RegExp(r'^src/'), '').split('/');
  if (parts[0] == 'util') return 'util';
  if (parts.length == 2) return 'shared';
  return parts[1];
}

/// the files of lib/ which [file] imports, relative to lib/
Iterable<String> importsOf(File file) sync* {
  final dir = file.parent.uri;
  for (final m in RegExp(r'''^(?:import|export)\s+['"]([^'"]+)['"]''',
          multiLine: true)
      .allMatches(file.readAsStringSync())) {
    final uri = m.group(1)!;
    if (uri.startsWith('dart:')) continue;
    if (uri.startsWith('package:')) {
      if (uri.startsWith('package:fnesemu_core/')) {
        yield uri.substring('package:fnesemu_core/'.length);
      }
      continue;
    }
    final path = dir.resolve(uri).toFilePath();
    yield path.substring(path.indexOf('lib/') + 4);
  }
}

void main() {
  final files = Directory(coreDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  final modules = Directory(coreDir)
      .listSync()
      .whereType<Directory>()
      .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .where((name) => name != 'components')
      .toSet();

  String rel(File f) => f.path.substring(f.path.indexOf('lib/') + 4);

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

  test('components import only themselves and util', () {
    for (final file in files.where((f) => layerOf(rel(f)) == 'components')) {
      for (final to in importsOf(file).map(layerOf)) {
        expect(to == 'components' || to == 'util', isTrue,
            reason: '${file.path} imports $to');
      }
    }
  });

  test('shared core files import no module, except the registry', () {
    for (final file in files.where((f) => layerOf(rel(f)) == 'shared')) {
      if (file.path.endsWith('installed_core_modules.dart')) continue;
      for (final to in importsOf(file).map(layerOf)) {
        expect(to == 'shared' || to == 'util', isTrue,
            reason: '${file.path} imports $to');
      }
    }
  });

  test('util imports no core', () {
    for (final file in Directory('lib/src/util')
        .listSync(recursive: true)
        .whereType<File>()) {
      for (final to in importsOf(file).map(layerOf)) {
        expect(to, 'util', reason: '${file.path} imports $to');
      }
    }
  });
}
