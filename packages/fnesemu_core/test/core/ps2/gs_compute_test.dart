import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:test/test.dart';

/// a program that keeps its buffers on the host and, instead of drawing,
/// writes [marker] to word 0 of the local memory at each raster step
class _Program implements ComputeProgram {
  _Program(this.bindings);

  static const marker = 0x0badcafe;

  final List<ComputeBinding> bindings;
  final buffers = <int, Uint32List>{};
  final entries = <int>[];
  bool disposed = false;

  Uint32List _buffer(int binding) =>
      buffers[binding] ??= Uint32List(bindings[binding].bytes ~/ 4);

  @override
  void write(int binding, int byteOffset, Uint32List words,
      [int start = 0, int? end]) {
    _buffer(binding).setRange(byteOffset ~/ 4,
        byteOffset ~/ 4 + (end ?? words.length) - start, words, start);
  }

  @override
  void run(Uint32List dispatches, int count, Uint32List params,
      {bool wait = true}) {
    for (var k = 0; k < count; k++) {
      final entry = dispatches[k * 4];
      if (dispatches[k * 4 + 1] == 0) continue;
      entries.add(entry);
      if (entry == 1) _buffer(0)[0] = marker;
    }
  }

  @override
  void read(int binding, int byteOffset, Uint32List target) {
    target.setRange(0, target.length, _buffer(binding), byteOffset ~/ 4);
  }

  @override
  void dispose() => disposed = true;
}

class _Sink implements ComputeSink {
  _Sink({this.fails = false});

  final bool fails;
  _Program? made;

  @override
  String get name => 'test GPU';

  @override
  ComputeProgram program(
      String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
      {required int paramStride, required int maxDispatches}) {
    if (fails) throw StateError('no program');
    expect(entryPoints, contains('raster'));
    return made = _Program(bindings);
  }
}

Gs _gs() => Gs()
  ..writePrivileged(0, 1)
  ..writeRegister(0x4c, 1 << 16)
  ..writeRegister(0x4e, 1 << 32)
  ..writeRegister(0x40, 63 << 16 | 95 << 48)
  ..writeRegister(0x00, Gs.primSprite);

void _sprite(Gs gs) {
  gs.writeRegister(0x01, 0x00554433);
  gs.writeRegister(0x05, 0);
  gs.writeRegister(0x05, 16 * 16 | 16 * 16 << 16);
}

void main() {
  test(
      'a compute sink takes the memory and the draws, and gives the memory '
      'back at vblank', () {
    final sink = _Sink();
    final gs = _gs();
    gs.mem.words[5] = 0x1234;
    gs.computeSink = sink;
    final program = sink.made!;
    expect(gs.compute, isNotNull);
    expect(program.buffers[0]![5], 0x1234);

    _sprite(gs);
    // the core does not draw the sprite itself
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 1, 1), 0);
    gs.vblank();
    expect(program.entries, contains(1));
    expect(gs.mem.words[0], _Program.marker);
    expect(gs.mem.words[5], 0x1234);

    gs.computeSink = null;
    expect(gs.compute, isNull);
    expect(gs.residentSink, isNull);
    expect(program.disposed, isTrue);
    _sprite(gs);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 1, 1), 0x00554433);
  });

  test('the Gs draws by itself when the program cannot be made', () {
    final gs = _gs()..computeSink = _Sink(fails: true);
    expect(gs.compute, isNull);
    _sprite(gs);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 1, 1), 0x00554433);
  });
}
