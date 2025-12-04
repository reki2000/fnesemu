import 'dart:async';

import 'package:fnesemu/core/tracer.dart';
import 'package:fnesemu/core/types.dart';
import 'package:test/test.dart';

void main() {
  group('Tracer', () {
    test('should skip repeating', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      final tracer = Tracer(stream, maxDiffChars: 0);
      for (final s in [
        "0010: a a:00",
        "0010: a a:01",
        "0011: b a:00",
      ]) {
        tracer.addTraceLog(TraceLog(int.parse(s.substring(0, 4)), 0,
            s.substring(0, 7), s.substring(8), [int.parse(s.substring(10))]));
      }

      await stream.close();

      expect(
          out,
          [
            "0010: a a:00 cl:0",
            "0010: a a:01 cl:0",
            "0011: b a:00 cl:0",
          ].map((e) => '$e\n'));
    });

    test('should skip repeated instructions', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      // Set minSkipThreshold to 0 to maintain original behavior
      final tracer = Tracer(stream, maxDiffChars: 4, minSkipThreshold: 0);
      for (var s in [
        "0000: a a:00",
        "0001: b a:00",
        "0000: a a:00",
        "0012: f a:00",
      ]) {
        tracer.addTraceLog(TraceLog(int.parse(s.substring(0, 4)), 0,
            s.substring(0, 7), s.substring(8), List.empty()));
      }

      await stream.close();

      expect(
          out,
          [
            "0000: a a:00 cl:0",
            "0001: b a:00 cl:0",
            "...skipped 1 lines...",
            "0012: f a:00 cl:0",
          ].map((e) => '$e\n'));
    });

    test('should not skip when repeat count is below threshold', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      // Use default minSkipThreshold (3), so repeats of 3 or less should not be skipped
      final tracer = Tracer(stream, maxDiffChars: 0);

      // Create a pattern that repeats 3 times (at threshold)
      for (var i = 0; i < 3; i++) {
        tracer.addTraceLog(TraceLog(0x1000, i, "1000: nop", "A:00", [0]));
        tracer.addTraceLog(TraceLog(0x1001, i, "1001: inc", "A:01", [1]));
      }

      // Add different instruction to end the pattern
      tracer.addTraceLog(TraceLog(0x2000, 10, "2000: jmp", "A:01", [1]));

      await stream.close();

      expect(out, [
        "1000: nop A:00 cl:0\n",
        "1001: inc A:01 cl:0\n",
        "1000: nop A:00 cl:1\n",
        "1001: inc A:01 cl:1\n",
        "1000: nop A:00 cl:2\n",
        "1001: inc A:01 cl:2\n",
        "2000: jmp A:01 cl:10\n",
      ]);
    });

    test('should skip when repeat count exceeds threshold', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      // Use default minSkipThreshold (3), so repeats of 4 or more should be skipped
      final tracer = Tracer(stream, maxDiffChars: 0);

      // Create a pattern that repeats 6 times (above threshold)
      for (var i = 0; i < 6; i++) {
        tracer.addTraceLog(TraceLog(0x1000, i, "1000: nop", "A:00", [0]));
        tracer.addTraceLog(TraceLog(0x1001, i, "1001: inc", "A:01", [1]));
      }

      // Add different instruction to end the pattern
      tracer.addTraceLog(TraceLog(0x2000, 10, "2000: jmp", "A:01", [1]));

      await stream.close();

      expect(out, [
        "1000: nop A:00 cl:0\n",
        "1001: inc A:01 cl:0\n",
        "...skipped 10 lines...\n", // 6 cycles * 2 instructions - 2 already shown = 10
        "2000: jmp A:01 cl:10\n",
      ]);
    });

    test('should handle threshold boundary correctly', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      // Use default minSkipThreshold (3)
      final tracer = Tracer(stream, maxDiffChars: 0);

      // Create a pattern that repeats exactly 3 times (at threshold)
      for (var i = 0; i < 3; i++) {
        tracer.addTraceLog(TraceLog(0x1000, i, "1000: loop", "A:00", [0]));
      }

      // Add different instruction to end the pattern
      tracer.addTraceLog(TraceLog(0x2000, 10, "2000: end", "A:01", [1]));

      await stream.close();

      // Should not skip when exactly at threshold
      expect(out, [
        "1000: loop A:00 cl:0\n",
        "1000: loop A:00 cl:1\n",
        "1000: loop A:00 cl:2\n",
        "2000: end A:01 cl:10\n",
      ]);
    });

    test('should handle very long repeats efficiently', () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      // Use default minSkipThreshold (3)
      final tracer = Tracer(stream, maxDiffChars: 0);

      // Create a very long repeat pattern (1000 times)
      for (var i = 0; i < 1000; i++) {
        tracer.addTraceLog(TraceLog(0x1000, i, "1000: wait", "A:00", [0]));
      }

      // Add different instruction to end the pattern
      tracer.addTraceLog(TraceLog(0x2000, 1000, "2000: done", "A:01", [1]));

      await stream.close();

      // Should skip the long repeat
      expect(out, [
        "1000: wait A:00 cl:0\n",
        "...skipped 999 lines...\n",
        "2000: done A:01 cl:1,000\n", // format3 adds comma for 1000
      ]);
    });

    test('should handle multiple repeat patterns with different thresholds',
        () async {
      final stream = StreamController<String>();
      final out = List<String>.empty(growable: true);
      stream.stream.listen((log) => out.add(log));

      final tracer = Tracer(stream, maxDiffChars: 0, minSkipThreshold: 2);

      // First pattern: 2 repeats (at threshold - should not skip)
      tracer.addTraceLog(TraceLog(0x1000, 0, "1000: a", "A:00", [0]));
      tracer.addTraceLog(TraceLog(0x1000, 1, "1000: a", "A:00", [0]));

      // Different instruction
      tracer.addTraceLog(TraceLog(0x2000, 2, "2000: b", "A:01", [1]));

      // Second pattern: 5 repeats (above threshold - should skip)
      for (var i = 0; i < 5; i++) {
        tracer.addTraceLog(TraceLog(0x3000, i + 3, "3000: c", "A:02", [2]));
      }

      // End
      tracer.addTraceLog(TraceLog(0x4000, 8, "4000: d", "A:03", [3]));

      await stream.close();

      expect(out, [
        "1000: a A:00 cl:0\n",
        "1000: a A:00 cl:1\n",
        "2000: b A:01 cl:2\n",
        "3000: c A:02 cl:3\n",
        "...skipped 4 lines...\n",
        "4000: d A:03 cl:8\n",
      ]);
    });
  });
}
