import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/cdrom/disc_folder.dart';
import 'package:fnesemu/cdrom/image_file.dart';
import 'package:fnesemu/gui/game_list.dart';

class _Folder extends DiscFolder {
  @override
  String get name => 'fixtures';
  @override
  Stream<FolderFile> list() => const Stream.empty();
  @override
  ImageFile file(String path) => throw UnimplementedError();
}

void main() {
  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('game list filters and selects at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final items = [
        const DiscItem('invalid.cue'),
        ...List.generate(500, (i) => DiscItem('fixture-$i.gb'))
      ];
      final scan = ScanResult(_Folder(), [], items, ['invalid.cue'], false);
      DiscItem? selected;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () async {
                        selected = await showDialog<DiscItem>(
                            context: context,
                            builder: (_) => GameListDialog(
                                title: 'fixtures', scan: ValueNotifier(scan)));
                      },
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('fixture-499.gb'), findsNothing);
      await tester.enterText(find.byType(TextField), 'invalid');
      await tester.pump();
      expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
      await tester.enterText(find.byType(TextField), 'fixture-499');
      await tester.pump();
      await tester.tap(find.text('fixture-499.gb'));
      await tester.pumpAndSettle();
      expect(selected!.path, 'fixture-499.gb');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('game list shows the scan progress until the list is ready',
      (tester) async {
    final scan = ValueNotifier<ScanResult?>(null);
    final progress =
        ValueNotifier<ScanProgress?>(const ScanProgress(false, 10, 4, 1, 0));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GameListDialog(
                title: 'fixtures', scan: scan, progress: progress))));
    expect(find.text('Scanning: checking: 1 / 4 cue files'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.25);
    scan.value =
        ScanResult(_Folder(), [], [const DiscItem('fixture.gb')], [], false);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('fixture.gb'), findsOneWidget);
  });
}
