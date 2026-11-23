import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/util/state.dart' show StateWriter;
import 'package:test/test.dart';

Uint8List _nrom(int fill) {
  final bytes = Uint8List(16 + 0x8000 + 0x2000)
    ..fillRange(16, 16 + 0x7ff0, fill);
  bytes.setAll(0, [0x4e, 0x45, 0x53, 0x1a, 2, 1, 0, 0]);
  bytes.setAll(16 + 0x7ffc, [0x00, 0x80]);
  return bytes;
}

void main() {
  test('reads the core, version and media of a state', () {
    final w = StateWriter('test', 3, 0x123456789a)..int32(7);
    final header = StateHeader.of(w.take());
    expect(header.core, 'test');
    expect(header.version, 3);
    expect(header.media, 0x123456789a);
  });

  test('rejects bytes that are not a state', () {
    expect(() => StateHeader.of(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<StateMismatch>()));
  });

  test('stateMedia is the media of a saved state and differs by ROM', () {
    final nes = Nes()..setRom(_nrom(0xea));
    final other = Nes()..setRom(_nrom(0x00));
    expect(StateHeader.of(nes.saveState()).media, nes.stateMedia);
    expect(StateHeader.of(nes.saveState()).core, 'nes');
    expect(other.stateMedia, isNot(nes.stateMedia));
  });
}
