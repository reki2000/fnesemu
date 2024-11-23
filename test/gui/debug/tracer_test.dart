import 'package:fnesemu/gui/debug/tracer.dart';
import 'package:test/test.dart';

void main() {
  group('RingBuffer', () {
    test('should add items and detect redundancy correctly', () {
      final ringBuffer = RingBuffer(3, maxDiffChars: 0);

      expect(ringBuffer.isExpected('log1'), false);
      ringBuffer.add('log0');
      ringBuffer.add('log00');
      ringBuffer.add('log1');
      ringBuffer.add('log2');
      ringBuffer.add('log3');
      expect(ringBuffer.prepare('log1'), true);
      expect(ringBuffer.isExpected('log2'), true);
      expect(ringBuffer.isExpected('log3'), true);
      expect(ringBuffer.isExpected('log2'), false);

      expect(ringBuffer.skippedCount, 3);
    });
  });
}
