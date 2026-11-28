import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc_compute.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

/// A program that keeps its buffers on the host and, instead of shading,
/// fills the tile of each slot with [color].
class _Program implements ComputeProgram {
  _Program(this.bindings, {required this.waits});

  static const color = 0xff123456;

  final List<ComputeBinding> bindings;
  final bool waits;
  final buffers = <int, Uint32List>{};
  var runs = 0;

  /// the results of the last prefetch on a sink that does not wait
  Completer<void>? arriving;

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
    runs++;
    _buffer(4).fillRange(0, params[1] * 1024, color);
  }

  @override
  void prefetch(int binding, int byteOffset, int bytes) {
    if (!waits) arriving = Completer();
  }

  @override
  Future<void>? get fetching =>
      arriving?.isCompleted == false ? arriving!.future : null;

  @override
  void read(int binding, int byteOffset, Uint32List target) {
    if (fetching != null) throw StateError('read before the results came');
    target.setRange(0, target.length, _buffer(binding), byteOffset ~/ 4);
  }

  @override
  void dispose() {}
}

class _Sink implements ComputeSink {
  _Sink({this.waits = true});

  @override
  final bool waits;
  _Program? made;

  @override
  String get name => 'test GPU';

  @override
  ComputeProgram program(
          String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
          {required int paramStride, required int maxDispatches}) =>
      made = _Program(bindings, waits: waits);
}

void main() {
  const reg = 0xa05f8000, frame = 0x400000;
  late DcBus bus;
  late _Sink sink;

  int bits(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    return bytes.getUint32(0, Endian.little);
  }

  void put(int address, List<int> words) {
    for (final (i, word) in words.indexed) {
      bus.gpu.vram.setUint32LE(address + i * 4, word);
    }
  }

  /// Renders one tile of a flat background into a 32-bit framebuffer at
  /// [frame], and ticks the render to its end.
  void render() {
    final words = [0, 0x20800000, 0];
    for (var i = 0; i < 3; i++) {
      words.addAll([
        bits(i == 1 ? 32.0 : 0.0),
        bits(i == 2 ? 32.0 : 0.0),
        bits(1),
        0xffffffff
      ]);
    }
    put(0x8000, words);
    bus.write32(reg + 0x8c, (1 << 24) | 0x10000);
    bus.write32(reg + 0x88, bits(0));
    put(0x9000, [0x80000000, ...List.filled(4, 0x80000000)]);
    for (final (offset, value) in [
      (0x2c, 0x9000),
      (0x48, 6),
      (0x4c, 16),
      (0x60, frame),
      (0x68, 31 << 16),
      (0x6c, 31 << 16)
    ]) {
      bus.write32(reg + offset, value);
    }
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(bus.gpu.render.busy, isFalse);
  }

  int stored(int x, int y) =>
      bus.gpu.vram.getUint32LE(frame + (y * 32 + x) * 4);

  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
    bus.write32(reg + 0x80, 0);
    sink = _Sink();
    bus.gpu.render.compute = DcCompute(sink, bus.gpu.render.memory);
  });

  test('the tiles of a render wait until the CPU reads them', () {
    render();
    expect(sink.made!.runs, 1);
    expect(bus.gpu.render.deferred, isTrue);
    expect(stored(0, 0), 0);
    expect(bus.read32(0xa5000000 + frame + 4), _Program.color);
    expect(bus.gpu.render.deferred, isFalse);
    expect(stored(31, 31), _Program.color);
  });

  test('a CPU write to a waiting tile comes after the tile', () {
    render();
    bus.write32(0xa5000000 + frame, 0x11223344);
    expect(stored(0, 0), 0x11223344);
    expect(stored(1, 0), _Program.color);
  });

  test('the next render and a saved state write the waiting tiles', () {
    render();
    expect(stored(0, 0), 0);
    render();
    expect(stored(0, 0), _Program.color);
    expect(bus.gpu.render.deferred, isTrue);
    bus.gpu.vram.setUint32LE(frame, 0);
    bus.gpu.saveState(StateWriter('dc', 0, 0));
    expect(bus.gpu.render.deferred, isFalse);
    expect(stored(0, 0), _Program.color);
  });

  test('a write elsewhere in VRAM leaves the tiles waiting', () {
    render();
    bus.write32(0xa5000000 + 0x100000, 1);
    expect(bus.gpu.render.deferred, isTrue);
  });

  group('on a sink that does not wait', () {
    setUp(() {
      sink = _Sink(waits: false);
      bus.gpu.render.compute = DcCompute(sink, bus.gpu.render.memory);
    });

    test('the core stops for the results after the render', () async {
      render();
      final render0 = bus.gpu.render;
      expect(render0.waitsForCompute, isTrue);
      final wait = render0.computeWait!;
      sink.made!.arriving!.complete();
      await wait;
      expect(render0.computeWait, isNull);
      expect(bus.read32(0xa5000000 + frame), _Program.color);
    });

    test('a reader before the results gets the old bytes', () {
      render();
      expect(bus.read32(0xa5000000 + frame), 0);
      expect(bus.gpu.render.deferred, isTrue);
      sink.made!.arriving!.complete();
    });

    test('tiles written late follow a CPU write of their bytes', () async {
      render();
      bus.write32(0xa5000000 + frame, 0x11223344);
      expect(stored(0, 0), 0x11223344);
      final wait = bus.gpu.render.computeWait!;
      sink.made!.arriving!.complete();
      await wait;
      expect(bus.read32(0xa5000000 + frame + 4), _Program.color);
      expect(stored(0, 0), _Program.color);
    });

    test('the next render drops the tiles whose results have not come', () {
      render();
      render();
      expect(stored(0, 0), 0);
      expect(bus.gpu.render.deferred, isTrue);
    });
  });

  test('the tiles are written at once without a program', () {
    bus.gpu.render.compute = null;
    render();
    expect(bus.gpu.render.deferred, isFalse);
    expect(stored(0, 0), 0xffffffff);
  });
}
