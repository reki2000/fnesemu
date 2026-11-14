import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:test/test.dart';

/// a program that keeps its buffers on the host and, instead of drawing,
/// writes [marker] to word 0 of the local memory at each raster step
class _Program implements ComputeProgram {
  _Program(this.bindings, {required this.waits});

  static const marker = 0x0badcafe;

  final List<ComputeBinding> bindings;
  final bool waits;
  final buffers = <int, Uint32List>{};
  final entries = <int>[];
  bool disposed = false;

  /// the prefetches on a sink that does not wait, until they come
  Completer<void>? arriving;
  final fetched = <int>{};

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
  void prefetch(int binding, int byteOffset, int bytes) {
    if (waits) return;
    if (arriving == null || arriving!.isCompleted) arriving = Completer();
    fetched.add(binding);
  }

  @override
  Future<void>? get fetching =>
      arriving?.isCompleted == false ? arriving!.future : null;

  @override
  void read(int binding, int byteOffset, Uint32List target) {
    if (!waits && (fetching != null || !fetched.remove(binding))) {
      throw StateError('read of binding $binding before it came');
    }
    target.setRange(0, target.length, _buffer(binding), byteOffset ~/ 4);
  }

  @override
  void dispose() => disposed = true;
}

class _Sink implements ComputeSink {
  _Sink({this.fails = false, this.waits = true});

  final bool fails;
  _Program? made;

  @override
  String get name => 'test GPU';

  @override
  final bool waits;

  @override
  ComputeProgram program(
      String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
      {required int paramStride, required int maxDispatches}) {
    if (fails) throw StateError('no program');
    expect(entryPoints, contains('raster'));
    return made = _Program(bindings, waits: waits);
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

  group('on a sink that does not wait', () {
    test('the memory comes before the vblank that the core waits for',
        () async {
      final sink = _Sink(waits: false);
      final gs = _gs()..computeSink = sink;
      final program = sink.made!;
      _sprite(gs);
      final wait = gs.computeWait()!;
      expect(program.entries, contains(1));
      expect(program.fetched, {0, 5});
      program.arriving!.complete();
      await wait;
      expect(gs.computeWait(), isNull);
      gs.vblank();
      expect(gs.mem.words[0], _Program.marker);
      expect(gs.compute!.unsupported, isEmpty);
    });

    test('work after the fetch asks for the memory again', () async {
      final sink = _Sink(waits: false);
      final gs = _gs()..computeSink = sink;
      final program = sink.made!;
      gs.computeWait();
      program.arriving!.complete();
      _sprite(gs);
      expect(gs.computeWait(), isNotNull);
    });

    test('a vblank before the memory came keeps the memory as it was', () {
      final sink = _Sink(waits: false);
      final gs = _gs()..computeSink = sink;
      _sprite(gs);
      gs.vblank();
      expect(gs.mem.words[0], 0);
      expect(gs.compute!.unsupported, isNotEmpty);
    });

    test('a local to host transfer asks the core to stop for the memory',
        () async {
      final sink = _Sink(waits: false);
      final gs = _gs()..computeSink = sink;
      final program = sink.made!;
      _sprite(gs);
      gs
        ..writeRegister(0x50, 0)
        ..writeRegister(0x51, 0)
        ..writeRegister(0x52, 16 | 16 << 32)
        ..writeRegister(0x53, 1);
      expect(gs.syncRequested, isTrue);
      final wait = gs.computeWait()!;
      program.arriving!.complete();
      await wait;
      gs.syncCompute();
      expect(gs.syncRequested, isFalse);
      expect(gs.mem.words[0], _Program.marker);
    });
  });

  test('the Gs draws by itself when the program cannot be made', () {
    final gs = _gs()..computeSink = _Sink(fails: true);
    expect(gs.compute, isNull);
    _sprite(gs);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 1, 1), 0x00554433);
  });
}
