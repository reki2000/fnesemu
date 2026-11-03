import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/iso9660.dart';
import 'package:test/test.dart';

class _CaseSkip implements Exception {
  const _CaseSkip();
}

void main() {
  // Aggregated cases: the per-case tests of this file are collected
  // in this table and executed by the aggregated test(s) at the end of
  // main; every case name stays visible here and in the run output.
  final aggCases = <(String, FutureOr<void> Function())>[];
  final aggTeardowns = <void Function()>[];
  void aggCase(String name, FutureOr<void> Function() body) =>
      aggCases.add((name, body));
  Future<void> runAggCases(
      Iterable<(String, FutureOr<void> Function())> cases) async {
    for (final (name, body) in cases) {
      print('case: $name');
      try {
        await body();
      } on _CaseSkip {
        print('skipped: $name');
      } finally {
        for (final teardown in aggTeardowns) {
          teardown();
        }
        aggTeardowns.clear();
      }
    }
  }

  aggCase('finds and reads a file in the root directory', () async {
    final sectors = <int, Uint8List>{};
    final pvd = Uint8List(2048);
    pvd.setRange(1, 6, ascii.encode('CD001'));
    ByteData.sublistView(pvd)
      ..setUint32(156 + 2, 20, Endian.little)
      ..setUint32(156 + 10, 2048, Endian.little);
    sectors[16] = pvd;
    final dir = Uint8List(2048);
    const name = 'SYSTEM.CNF;1';
    dir[0] = 33 + name.length;
    ByteData.sublistView(dir)
      ..setUint32(2, 30, Endian.little)
      ..setUint32(10, 5, Endian.little);
    dir[32] = name.length;
    dir.setRange(33, 33 + name.length, ascii.encode(name));
    sectors[20] = dir;
    sectors[30] = Uint8List(2048)..setRange(0, 5, ascii.encode('BOOT2'));

    final iso = Iso9660((lba) async => sectors[lba] ?? Uint8List(2048));
    final file = await iso.findRootFile('system.cnf');
    expect(file, (lba: 30, size: 5));
    expect(ascii.decode(await iso.readFile(file!)), 'BOOT2');
    expect(await iso.findRootFile('MISSING'), isNull);
  });

  aggCase('takes the BOOT2 file name from SYSTEM.CNF', () {
    expect(bootFileName('BOOT2 = cdrom0:\\ABCD_123.45;1\r\nVER = 1.00\r\n'),
        'ABCD_123.45');
    expect(bootFileName('VMODE = NTSC\n'), isNull);
  });


  const chunkCount = 1;
  final chunkSize = (aggCases.length + chunkCount - 1) ~/ chunkCount;
  for (var part = 0; part < chunkCount; part++) {
    final partCases =
        aggCases.skip(part * chunkSize).take(chunkSize).toList();
    if (partCases.isEmpty) continue;
    test('aggregated cases ${part + 1} of $chunkCount', () async {
      await runAggCases(partCases);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
