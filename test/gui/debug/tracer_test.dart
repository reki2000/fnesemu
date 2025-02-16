import 'dart:async';

import 'package:fnesemu/core/types.dart';
import 'package:fnesemu/gui/debug/tracer.dart';
import 'package:test/test.dart';

void main() {
  group('RingBuffer', () {
    final logs = List.generate(10, (i) => RepeatableLine(i, 'log$i'));
    test('should detect known item', () {
      final detector = RepeatDetector(3, maxDiffChars: 0);

      detector.add(logs[0]);
      expect(detector.detect(logs[0]), true);
      expect(detector.detect(logs[1]), false);
    });
    test('should not detect past item than its size', () {
      final detector = RepeatDetector(1, maxDiffChars: 0);

      detector.add(logs[0]);
      detector.add(logs[1]);
      expect(detector.detect(logs[0]), false);
      expect(detector.detect(logs[1]), true);
    });
    test('should count a repeat correctly', () {
      final detector = RepeatDetector(logs.length, maxDiffChars: 0);

      for (final log in logs) {
        detector.add(log);
      }
      expect(detector.detect(logs[2]), true);
      expect(detector.isRepeating(logs[3]), 0);
      expect(detector.isRepeating(logs[0]), 2);
    });
  });

  group('Tracer', () {
    test('should not skip non-loop backward jump', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      final tracer = Tracer(stream, maxDiffChars: 0);
      for (final s in [
        "0010: a a:00",
        "0011: b a:00",
        "0012: c a:00",
        "0000: c a:00",
        "0001: d a:00",
        "0010: a a:00",
        "0011: b a:00",
      ]) {
        tracer.addTraceLog(TraceLog(int.parse(s.substring(0, 4)), 0,
            s.substring(0, 7), s.substring(8)));
      }

      await stream.close();

      expect(
          out,
          [
            "0010: a a:00",
            "0011: b a:00",
            "0012: c a:00",
            "0000: c a:00",
            "0001: d a:00",
            "0010: a a:00",
            "0011: b a:00",
          ].map((e) => '$e\n'));
    });

    test('should skip repeated instructions', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      final tracer = Tracer(stream, maxDiffChars: 4);
      for (var s in [
        "0000: a a:00",
        "0001: b a:00",
        "0000: a a:00",
        "0012: f a:00",
      ]) {
        tracer.addTraceLog(TraceLog(int.parse(s.substring(0, 4)), 0,
            s.substring(0, 7), s.substring(8)));
      }

      await stream.close();

      expect(
          out,
          [
            "0000: a a:00",
            "0001: b a:00",
            "...skipped 1 lines...",
            "0012: f a:00",
          ].map((e) => '$e\n'));
    });
  });
}
