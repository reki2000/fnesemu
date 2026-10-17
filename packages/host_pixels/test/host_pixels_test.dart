import 'dart:typed_data';

import 'package:host_pixels/host_pixels.dart';
import 'package:test/test.dart';

void main() {
  test('a byte view of a 32-bit frame keeps its pixels', () {
    final frame = Uint32List.fromList([0x04030201, 0x08070605]);
    expect(hostPixels(frame.buffer.asUint8List()), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  test('an unaligned view is returned as is', () {
    final bytes = Uint8List.fromList([0, 1, 2, 3, 4]);
    final view = Uint8List.sublistView(bytes, 1);
    expect(hostPixels(view), same(view));
  });

  test('native lists are passed through', () {
    final bytes = Uint8List(8);
    expect(hostPixels(bytes), same(bytes));
  }, testOn: 'vm');
}
