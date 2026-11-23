import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/benchmark.dart';
import 'package:fnesemu_core/app_api.dart';

import 'memory_picked_directory.dart';
import 'seven_zip_fixtures.dart';

void main() {
  test('parses the scenes of bench.json with their defaults', () {
    final scenes = BenchScene.parse(jsonEncode({
      'scenes': [
        {
          'name': 'a',
          'core': 'nes',
          'state': 'nes/a.state',
          'rom': 'nes/a.nes',
          'warmup': 10,
          'measure': 100,
        },
        {
          'core': 'ps2',
          'state': 'ps2/b.state',
          'bios': ['ps2/bios.bin'],
          'disc': 'b.chd',
          'target': 50,
        },
      ]
    }));
    expect(scenes, hasLength(2));
    expect((scenes[0].name, scenes[0].rom, scenes[0].warmup, scenes[0].measure),
        ('a', 'nes/a.nes', 10, 100));
    expect(scenes[0].bios, isEmpty);
    expect(scenes[0].target, 60);
    expect((scenes[1].name, scenes[1].disc, scenes[1].target),
        ('ps2/b.state', 'b.chd', 50));
    expect(scenes[1].bios, ['ps2/bios.bin']);
    expect((scenes[1].warmup, scenes[1].measure), (60, 600));
  });

  test('ranks the discs by their names', () {
    expect(discRank('Game (J).chd', 'ps2/game (j).CHD'), 0);
    expect(discRank('Game (J).chd', 'game (j).cue'), 1);
    expect(discRank('Game (J).chd', 'other.iso'), 2);
    expect(discRank('Game (J).chd', 'other.bin'), 3);
    expect(discRank('Game (J).chd', 'other.nes'), isNull);
  });

  test('a result makes a line of the speed map results', () {
    const scene = BenchScene(name: 'a', core: 'nes', state: 's', target: 60);
    final ok = BenchResult(scene,
        timing: const BenchmarkTiming(120, 1000000, 500000),
        jit: true,
        cpuMHzEnd: 2400);
    final record = ok.record(
        machine: 'm',
        build: const AppBuild(
            version: '1.2.3',
            commit: '0123456789abcdef',
            time: '2026-11-23T01:02:03Z'),
        date: DateTime(2026, 11, 23),
        host: {'cpu': 'c', 'cpuMaxMHz': 4900, 'gpu': 'Software'});
    expect((record['jit'], record['cpuMHzEnd']), (true, 2400));
    expect(record['host'], {'cpu': 'c', 'cpuMaxMHz': 4900, 'gpu': 'Software'});
    expect(record['date'], '2026-11-23');
    expect((record['machine'], record['commit'], record['case']),
        ('m', '01234567', 'a'));
    expect((record['version'], record['gitCommit'], record['buildTime']),
        ('1.2.3', '0123456789abcdef', '2026-11-23T01:02:03Z'));
    expect((record['fps'], record['coreFps'], record['msPerFrame']),
        (120.0, 240.0, 8.33));
    final failed = const BenchResult(scene, error: 'disc not found')
        .record(machine: 'm', build: const AppBuild(), date: DateTime(2026));
    expect((failed['commit'], failed['version']), ('dev', 'dev'));
    expect(failed.containsKey('gitCommit'), isFalse);
    expect(failed['error'], 'disc not found');
    expect(failed.containsKey('fps'), isFalse);
    expect(failed.containsKey('host'), isFalse);
  });

  test('opens the files of a 7z and a zip archive', () async {
    final seven = await BenchArchive.open(MemoryPickedFile(
        'bench.7z', base64.decode(sevenZipFixtures['lzma2']!)));
    expect(seven.names, contains('dir/c.txt'));
    expect(utf8.decode(await seven.read('a.txt')), 'hello 7z\n');
    await seven.close();

    final zip = ZipEncoder().encodeBytes(
        Archive()..addFile(ArchiveFile.bytes('bench.json', utf8.encode('{}'))));
    final archive = await BenchArchive.open(MemoryPickedFile('b.zip', zip));
    expect(archive.names, ['bench.json']);
    expect(utf8.decode(await archive.read('bench.json')), '{}');
    expect(archive.read('missing'), throwsFormatException);

    expect(BenchArchive.open(MemoryPickedFile('b.txt', zip)),
        throwsFormatException);
  });

  testWidgets('the results dialog copies the results with the device name',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    String? machine;
    const scene = BenchScene(name: 'a', core: 'nes', state: 's');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BenchResultsDialog(
                results: const [
                  BenchResult(scene,
                      timing: BenchmarkTiming(60, 500000, 250000)),
                  BenchResult(scene, error: 'disc not found'),
                ],
                machine: 'old',
                build: const AppBuild(version: '1.0'),
                date: DateTime(2026, 11, 23),
                host: const {
                  'cpu': 'Test CPU',
                  'cpuMaxMHz': 3000,
                  'gpu': 'Software'
                },
                onMachine: (m) => machine = m))));
    expect(find.text('Test CPU · 3000 MHz · Software'), findsOneWidget);
    expect(find.text('1.0'), findsOneWidget);
    expect(find.text('120.0 fps  200%'), findsOneWidget);
    expect(find.text('disc not found'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('bench-machine')), 'pixel7');
    await tester.tap(find.text('Copy'));
    await tester.pump();
    final lines = copied!.split('\n').map(jsonDecode).toList();
    expect(lines, hasLength(2));
    expect((lines[0] as Map)['machine'], 'pixel7');
    expect((lines[0] as Map)['fps'], 120.0);
    expect(((lines[0] as Map)['host'] as Map)['cpu'], 'Test CPU');
    await tester.tap(find.text('Close'));
    expect(machine, 'pixel7');
  });
}
