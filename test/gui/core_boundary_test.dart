import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/app.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:fnesemu_core/core/core_api.dart';
import 'package:fnesemu_core/core/installed_core_modules.dart';
import 'package:idb_shim/idb_client_memory.dart';

void main() {
  test('GUI imports only the public core API', () {
    for (final file
        in Directory('lib/gui').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in RegExp(r'''import\s+['"]([^'"]+)['"]''')
          .allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        if (uri.contains('/core/')) {
          expect(uri.endsWith('/core/core_api.dart'), isTrue,
              reason: '${file.path}: $uri');
        }
      }
    }
  });
  testWidgets('empty core registry renders and disables old game history',
      (tester) async {
    CoreFactory.registerModules([]);
    addTearDown(
        () => CoreFactory.registerModules(createInstalledCoreModules()));
    late Storage storage;
    await tester.runAsync(() async {
      storage = await Storage.open(
          store: await BlobStore.open(factory: newIdbFactoryMemory()));
      await storage.recordRecent('missing-core', 'fixture.bin',
          rom: Uint8List.fromList([1, 2, 3]));
    });
    await tester.pumpWidget(MaterialApp(home: MainPage(storage: storage)));
    expect(CoreFactory.systems, isEmpty);
    expect(CoreFactory.biosSetups, isEmpty);
    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    final entry = find.ancestor(
        of: find.text('MISSING-CORE fixture.bin'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem));
    expect(tester.widget<PopupMenuItem>(entry).enabled, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
