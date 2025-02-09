import 'dart:async';

import 'package:fnesemu/gui/debug/tracer.dart';
import 'package:test/test.dart';

void main() {
  group('RingBuffer', () {
    test('should add items and detect redundancy correctly', () {
      final ringBuffer = RingBuffer(3, maxDiffChars: 0);

      expect(ringBuffer.isExpected(Line('', 'log1')), 0);
      ringBuffer.add(Line('', 'log0')); // 0
      ringBuffer.add(Line('', 'log00')); // 0,00
      ringBuffer.add(Line('', 'log1')); // 0,00,1
      ringBuffer.add(Line('', 'log2')); // 00,1,2
      ringBuffer.add(Line('', 'log3')); // 1,2,3
      expect(ringBuffer.prepare(Line('', 'log1')), true);
      expect(ringBuffer.isExpected(Line('', 'log2')), 0);
      expect(ringBuffer.isExpected(Line('', 'log3')), 0);
      expect(ringBuffer.isExpected(Line('', 'log0')), 3);

      expect(ringBuffer.skippedCount, 0);
    });
  });

  group('Tracer', () {
    test('should not skip non-loop backward jump', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      final tracer = Tracer(stream, pcWidth: 4, maxDiffChars: 4);
      [
        "0010: a",
        "0011: b",
        "0012: jp 0000",
        "0000: c",
        "0001: d",
        "0010: a",
        "0011: b",
      ].forEach(tracer.addLog);

      await stream.close();

      expect(out, [
        "0010: a\n",
        "0011: b\n",
        "0012: jp 0000\n",
        "0000: c\n",
        "0001: d\n",
        "0010: a\n",
        "0011: b\n",
      ]);
    });

    test('should skip repeated instructions', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      final tracer = Tracer(stream, pcWidth: 4, maxDiffChars: 4);
      [
        "0000: a",
        "0001: b",
        "0000: a",
        "0012: f",
      ].forEach(tracer.addLog);

      await stream.close();

      expect(out, [
        "0000: a\n",
        "0001: b\n",
        "...skipped 1 lines...\n",
        "0012: f\n",
      ]);
    });
  });
}
