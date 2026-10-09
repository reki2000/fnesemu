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
  test('NES and PCE components do not import their orchestration classes', () {
    for (final core in ['nes', 'pce']) {
      for (final file in Directory('lib/core/$core/component')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))) {
        for (final uri in directives(file)) {
          expect(uri.endsWith('/$core.dart'), isFalse,
              reason: '${file.path}: $uri');
        }
      }
    }
  });

  test('abstract Mapper does not depend on construction or implementations',
      () {
    expect(
        directives(File('lib/core/nes/mapper/mapper.dart')),
        everyElement(
          anyOf(startsWith('dart:'), startsWith('package:fnesemu_core/util/'),
              'mirror.dart'),
        ));
  });

  test('shared 68000 and ss do not depend on console implementations', () {
    final pending = [
      File('lib/core/components/m68k/cpu.dart'),
      File('lib/core/components/m68k/disasm.dart'),
      File('lib/core/ss/module.dart'),
    ];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final file = pending.removeLast().absolute;
      if (!visited.add(file.uri.normalizePath().path)) continue;
      for (final uri in directives(file)) {
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
        expect(dependency.path, isNot(contains('/lib/core/md/')),
            reason: '${file.path}: $uri');
        pending.add(File.fromUri(dependency));
      }
    }
  });

  test('registered runtime cores do not depend on native I/O or tools', () {
    final pending = Directory('lib/core')
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
