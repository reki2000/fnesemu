import 'dart:async';

import 'package:fnesemu/core/types.dart';
import 'package:fnesemu/core/tracer.dart';
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

      final tracer = Tracer(stream, maxDiffChars: 4);
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
  });
}
