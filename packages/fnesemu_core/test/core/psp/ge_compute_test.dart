import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/src/compute_sink.dart';
import 'package:fnesemu_core/src/core/psp/ge_compute.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

import 'psp_test.dart' show buildProgram;

/// A sink whose program runs nothing: it keeps the buffers, so that a test
/// can play the GPU by writing them.
class _Sink implements ComputeSink {
  _Sink({this.waits = true});

  _Program? last;

  @override
  String get name => 'fake';

  @override
  final bool waits;

  @override
  ComputeProgram program(
          String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
          {required int paramStride, required int maxDispatches}) =>
      last = _Program(bindings, waits: waits);
}

class _Program implements ComputeProgram {
  _Program(List<ComputeBinding> bindings, {this.waits = true})
      : buffers = [for (final b in bindings) Uint32List(b.bytes >> 2)];

  final List<Uint32List> buffers;
  final bool waits;
  int runs = 0, reads = 0;
  Completer<void>? _pending;

  Uint32List get vram => buffers[0];

  void settle() {
    final c = _pending;
    _pending = null;
    c?.complete();
  }

  @override
  void write(int binding, int byteOffset, Uint32List words,
      [int start = 0, int? end]) {
    final to = end ?? words.length;
    buffers[binding].setRange(
        byteOffset >> 2, (byteOffset >> 2) + to - start, words, start);
  }

  @override
  void run(Uint32List dispatches, int count, Uint32List params,
      {bool wait = true}) {
    runs++;
  }

  @override
  void prefetch(int binding, int byteOffset, int bytes) {
    if (!waits) _pending = Completer<void>();
  }

  @override
  Future<void>? get fetching => _pending?.future;

  @override
  void read(int binding, int byteOffset, Uint32List target) {
    if (!waits && _pending != null) {
      throw StateError('read before prefetch settled');
    }
    reads++;
    target.setRange(0, target.length, buffers[binding], byteOffset >> 2);
  }

  @override
  void dispose() {}
}

void main() {
  late PspMemory mem;
  late _Sink sink;
  late GeCompute gpu;
  const fb = PspMemory.vramAt, z = PspMemory.vramAt + 0x100000;

  setUp(() {
    mem = PspMemory();
    sink = _Sink();
    gpu = GeCompute(mem, sink)..attach();
  });

  /// records a clear of the first [lines] lines of the frame buffer
  void clear(int lines) {
    expect(gpu.target(fb, 512, 3, z, 512, 272), isTrue);
    gpu
      ..reserve()
      ..word(0, 0)
      ..word(1, 0)
      ..word(2, 0xffffffff)
      ..word(3, 1)
      ..emit(GeCompute.clear, 0, 0, 512, lines, false);
  }

  test('a CPU read of a page that a draw wrote reads it back', () {
    clear(1);
    expect(mem.vramPages![0], PspVramGuard.gpuNewer);
    expect(sink.last!.runs, 0);
    // the GPU draws the line
    sink.last!.vram[0] = 0x12345678;
    expect(mem.read32(fb), 0x12345678);
    expect(sink.last!.runs, 1);
    expect(mem.vramPages![0], PspVramGuard.synced);
    expect(gpu.syncs, 1);
  });

  test('a CPU write submits the recorded work before it', () {
    clear(1);
    mem.write32(fb + 0x80000, 0xcafe);
    // the draw was sent before the write, which waits for the next submit
    expect(sink.last!.runs, 1);
    expect(mem.vramPages![0x80], PspVramGuard.cpuDirty);
    expect(sink.last!.vram[0x20000], 0);
    gpu.endFrame(fb, 512, 3);
    expect(sink.last!.vram[0x20000], 0xcafe);
    expect(mem.vramPages![0x80], PspVramGuard.synced);
    // a later write marks the page again
    mem.write16(fb + 0x80002, 0x1234);
    expect(mem.vramPages![0x80], PspVramGuard.cpuDirty);
  });

  test('the display shows the frame buffer of the frame before', () {
    mem.write32(fb, 0xff0000ff);
    gpu.endFrame(fb, 512, 3);
    expect(gpu.display, isNull);
    mem.write32(fb, 0xff00ff00);
    gpu.endFrame(fb, 512, 3);
    expect(gpu.display![0], 0xff0000ff);
    expect(gpu.displayStride, 512);
    expect(gpu.displayFormat, 3);
  });

  test('an async sink exposes computeWait and delivers the frame after it',
      () async {
    final asyncSink = _Sink(waits: false);
    final asyncGpu = GeCompute(mem, asyncSink)..attach();
    mem.write32(fb, 0xff112233);
    asyncGpu.endFrame(fb, 512, 3);
    expect(asyncGpu.computeWait, isNotNull);
    expect(asyncGpu.display, isNull);
    asyncSink.last!.settle();
    await asyncGpu.computeWait;
    expect(asyncGpu.computeWait, isNull);
    expect(asyncGpu.display![0], 0xff112233);
    asyncGpu.detach();
  });

  test('a transfer into video memory runs on the GPU unless it overlaps', () {
    expect(gpu.transfer(fb, 2048, fb + 1024, 2048, 2048, 4), isFalse);
    expect(gpu.transfer(fb, 2048, fb + 0x10000, 2048, 64, 4), isTrue);
    expect(mem.vramPages![0x10], PspVramGuard.gpuNewer);
    // into main memory it stays on the CPU
    expect(gpu.transfer(fb, 2048, PspMemory.ramAt, 2048, 64, 4), isFalse);
  });

  test('a CPU-drawn picture shows the same with the sink attached', () {
    final rom = buildProgram();
    final core = Psp()..computeSink = sink;
    final pad = PadState()..press(0, const PadButton('x'));
    core
      ..input = pad
      ..setRom(rom);
    var frames = 0;
    while (!core.runFrame(286).stopped && frames++ < 300) {}
    // one more frame end shows the last picture
    expect(core.mem.read32(0x08900008), 0x0d15ea5e);
    final image = core.imageBuffer();
    expect(image.buffer[0], 0xff223344);
    expect(image.buffer[1], 0xff667788);
  });
}
