import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/ipu/ipu.dart';
import 'package:test/test.dart';

const _cmd = 0x10002000, _ctrl = 0x10002010;

/// writes [bits] (a string of '0' and '1') to the input FIFO, padded with
/// zeros to whole quadwords
void _feed(Ipu ipu, String bits) {
  final padded = bits.padRight(((bits.length + 127) ~/ 128) * 128, '0');
  final bytes = [
    for (var i = 0; i < padded.length; i += 8)
      int.parse(padded.substring(i, i + 8), radix: 2),
  ];
  for (var q = 0; q < bytes.length; q += 16) {
    for (var half = 0; half < 2; half++) {
      var v = 0;
      for (var k = 7; k >= 0; k--) {
        v = v << 8 | bytes[q + half * 8 + k];
      }
      ipu.writeFifo(0x10007010 + half * 8, 8, v);
    }
  }
}

List<int> _drain(Ipu ipu) {
  final out = <int>[];
  final quad = Int64List(2);
  while (ipu.fromIpu.hasData) {
    ipu.fromIpu.get(quad);
    out
      ..add(quad[0])
      ..add(quad[1]);
  }
  return out;
}

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


  aggCase('VDEC returns the code length and the value', () {
    final ipu = Ipu();
    _feed(ipu, '011' '00000001000' '00011' '11');
    ipu.write(_cmd, 4, 0x30000000); // macroblock address increment
    expect(ipu.read(_cmd, 4), 3 << 16 | 2);
    ipu.write(_cmd, 4, 0x30000000); // escape
    expect(ipu.read(_cmd, 4), 11 << 16 | 0x23);
    ipu.write(_cmd, 4, 0x38000000); // motion code -3
    expect(ipu.read(_cmd, 4), 5 << 16 | 0xfffd);
    ipu.write(_cmd, 4, 0x3c000000); // dmvector -1
    expect(ipu.read(_cmd, 4), 2 << 16 | 0xffff);
  });

  aggCase('VDEC decodes macroblock_type with the table of the picture type', () {
    final ipu = Ipu();
    _feed(ipu, '001' '01');
    ipu.write(_ctrl, 4, 2 << 24); // P picture
    ipu.write(_cmd, 4, 0x34000000);
    expect(ipu.read(_cmd, 4), 3 << 16 | 8); // forward only
    ipu.write(_ctrl, 4, 1 << 24); // I picture
    ipu.write(_cmd, 4, 0x34000000);
    expect(ipu.read(_cmd, 4), 2 << 16 | 17); // intra with quantiser
  });

  aggCase('a command without enough data waits for it', () {
    final ipu = Ipu();
    ipu.write(_cmd, 4, 0x40000000);
    expect(ipu.read(_ctrl, 4) >>> 31, 1);
    _feed(ipu, '1');
    expect(ipu.read(_ctrl, 4) >>> 31, 0);
    expect(ipu.read(_cmd, 4), 0x80000000);
  });

  aggCase('a reset during a command raises the interrupt', () {
    var raised = 0;
    final ipu = Ipu()..onInterrupt = () => raised++;
    ipu.write(_cmd, 4, 0x40000000);
    ipu.write(_ctrl, 4, 0x40000000);
    expect(raised, 1);
    expect(ipu.read(_ctrl, 4) >>> 31, 0);
    ipu.write(_ctrl, 4, 0x40000000);
    expect(raised, 1);
  });

  aggCase('BDEC of an intra macroblock with only DC coefficients', () {
    final ipu = Ipu();
    // luminance: DC size 0, end of block; chrominance: the same
    _feed(ipu, '10010' * 4 + '0010' * 2);
    // intra, DC reset, quantiser scale 1
    ipu.write(_cmd, 4, 0x20000000 | 1 << 27 | 1 << 26 | 1 << 16);
    expect(ipu.read(_ctrl, 4) >>> 31, 0);
    final out = _drain(ipu);
    expect(out.length, 96);
    final halves = [
      for (final w in out)
        for (var i = 0; i < 4; i++) (w >> (16 * i)) & 0xffff
    ];
    expect(halves, List.filled(384, 128));
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
