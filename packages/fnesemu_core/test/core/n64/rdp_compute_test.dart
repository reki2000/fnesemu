import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/src/compute_sink.dart';
import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/graphics.dart';
import 'package:fnesemu_core/src/core/n64/rdp_compute.dart';
import 'package:test/test.dart';

/// A fake compute program that keeps its buffers on the host and writes
/// synthetic pixel data into binding 1 on each run.
class _Program implements ComputeProgram {
  _Program(List<ComputeBinding> bindings, {required this.waits})
      : buffers = [for (final b in bindings) Uint32List(b.bytes >> 2)];

  final List<Uint32List> buffers;
  final bool waits;
  int runs = 0, reads = 0, prefetches = 0;
  int fillWord = 0xf801f801;
  Completer<void>? _pending;

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
    final entry = dispatches[0];
    final groups = dispatches[1];
    if (entry == 0) {
      // _storeFill copies raw bytes into big-endian RDRAM: 0x01f8 LE -> 0xf801 BE.
      final le = ((fillWord & 0xff) << 8) | ((fillWord >> 8) & 0xff);
      buffers[1].fillRange(0, groups * 64, le | (le << 16));
    } else if (entry == 1) {
      // Packed 16-bit tile pixel: low 16 bits = color, high 16 bits = mask 1.
      final packed = (fillWord & 0xffff) | (1 << 16);
      buffers[1].fillRange(0, groups * 64, packed);
    }
  }

  @override
  void prefetch(int binding, int byteOffset, int bytes) {
    prefetches++;
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

class _Sink implements ComputeSink {
  _Sink({this.waits = true});

  @override
  final bool waits;
  _Program? last;

  @override
  String get name => 'fake';

  @override
  ComputeProgram program(
          String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
          {required int paramStride, required int maxDispatches}) =>
      last = _Program(bindings, waits: waits);
}

void main() {
  late N64Bus bus;
  late _Sink sink;

  setUp(() {
    bus = N64Bus();
  });

  test('sync deferred fill settles when RDRAM is touched', () {
    sink = _Sink(waits: true);
    final compute = N64RdpCompute(sink, bus);
    final rect = const N64RdpRect(0x1000, 16, 0, 0, 8, 2, 2);
    expect(compute.fill(rect, 0xf801f801), isTrue);
    compute.flush(defer: true, endStream: true);
    expect(sink.last!.runs, 1);
    expect(sink.last!.reads, 0);
    expect(bus.ramData.getUint16(0x1000), 0);

    // Touching the watched RDRAM range reads back the deferred batch.
    bus.touchRdram(0x1000, 4);
    expect(sink.last!.reads, 1);
    expect(bus.ramData.getUint16(0x1000), 0xf801);
    compute.dispose();
  });

  test('out-of-bounds rect is rejected for software fallback', () {
    sink = _Sink(waits: true);
    final compute = N64RdpCompute(sink, bus);
    expect(compute.fill(const N64RdpRect(0x1000, 8, 4, 0, 8, 2, 2), 0xffffffff),
        isFalse);
    expect(compute.fill(const N64RdpRect(0x1000, 2048, 0, 0, 1025, 1, 2), 0),
        isFalse);
    compute.dispose();
  });

  test('target change flushes the previous batch', () {
    sink = _Sink(waits: true);
    final compute = N64RdpCompute(sink, bus);
    expect(
        compute.fill(const N64RdpRect(0x1000, 16, 0, 0, 4, 1, 2), 0x11111111),
        isTrue);
    expect(sink.last!.runs, 0);
    expect(
        compute.fill(const N64RdpRect(0x2000, 16, 0, 0, 4, 1, 2), 0x22222222),
        isTrue);
    expect(sink.last!.runs, 1);
    compute.flush();
    expect(sink.last!.runs, 2);
    compute.dispose();
  });

  test('async sink defers readback until prefetch settles', () async {
    sink = _Sink(waits: false);
    final graphics = N64Graphics(bus)..computeSink = sink;
    // Direct RDP commands: SETCIMG (16-bit, width 16, addr 0x1000),
    // SETSCISSOR (0,0)-(16,16), SETOTHERMODE_H (fill mode), SETFILLCOLOR,
    // FILLRECT (0,0)-(7,1).
    void putCmd(int at, int w0, int w1) {
      bus.ramData.setUint32(at, w0);
      bus.ramData.setUint32(at + 4, w1);
    }

    const base = 0x4000;
    putCmd(base + 0, 0xff10000f, 0x00001000);
    putCmd(base + 8, 0xed000000, 0x00040040);
    putCmd(base + 16, 0xef300000, 0x00000000);
    putCmd(base + 24, 0xf7000000, 0xf801f801);
    putCmd(base + 32, 0xf601c004, 0x00000000);

    graphics.commands(base, base + 40, defer: true);
    expect(sink.last!.runs, 1);
    expect(sink.last!.prefetches, 1);
    expect(sink.last!.reads, 0);
    expect(graphics.waitsForCompute, isTrue);
    expect(graphics.computeWait, isNotNull);

    // Touching watched RDRAM before settlement marks waitRequested without throwing.
    bus.touchRdram(0x1000, 4);
    expect(graphics.waitRequested, isTrue);
    expect(sink.last!.reads, 0);

    final wait = graphics.computeWait!;
    sink.last!.settle();
    await wait;
    expect(graphics.waitsForCompute, isFalse);

    graphics.settleIfReady();
    expect(sink.last!.reads, 1);
    expect(bus.ramData.getUint16(0x1000), 0xf801);
    graphics.computeSink = null;
  });

  test('async display list pauses on target switch and resumes to completion',
      () async {
    sink = _Sink(waits: false);
    final graphics = N64Graphics(bus)..computeSink = sink;
    void putCmd(int at, int w0, int w1) {
      bus.ramData.setUint32(at, w0);
      bus.ramData.setUint32(at + 4, w1);
    }

    // F3DEX2 display list with two FILLRECTs to different targets.
    const ucode = 0x3000;
    const label = 'RSP Gfx ucode F3DEX2';
    for (var i = 0; i < label.length; i++) {
      bus.ram[ucode + i] = label.codeUnitAt(i);
    }
    const dl = 0x4000;
    putCmd(dl + 0, 0xff10000f, 0x00001000);
    putCmd(dl + 8, 0xed000000, 0x00040040);
    putCmd(dl + 16, 0xef300000, 0x00000000);
    putCmd(dl + 24, 0xf7000000, 0xf801f801);
    putCmd(dl + 32, 0xf601c004, 0x00000000);
    // Switch target to 0x2000 and draw a second fill.
    putCmd(dl + 40, 0xff10000f, 0x00002000);
    putCmd(dl + 48, 0xf601c004, 0x00000000);
    // G_ENDDL (F3DEX2 0xdf)
    putCmd(dl + 56, 0xdf000000, 0x00000000);

    bus.spRegs[4] = 1 << 6; // interrupt on break
    graphics.task(dl, 64, ucode, 64, defer: true);
    expect(graphics.hasPendingStream, isTrue);
    expect(bus.taskPending, isTrue);
    expect(graphics.waitsForCompute, isTrue);
    expect(bus.spRegs[4] & 0x203, 0);

    // First batch settles; resume runs the second batch and finishes the task.
    sink.last!.settle();
    await Future<void>.value();
    graphics.resumeStream();
    expect(graphics.hasPendingStream, isFalse);
    expect(bus.taskPending, isFalse);
    expect(bus.spRegs[4] & 0x203, 0x203);
    expect(bus.mi[2] & 1, 1);
    expect(bus.ramData.getUint16(0x1000), 0xf801);
    expect(graphics.waitsForCompute, isTrue);

    // Second batch settles.
    sink.last!.settle();
    await Future<void>.value();
    graphics.settleIfReady();
    expect(bus.ramData.getUint16(0x2000), 0xf801);
    graphics.computeSink = null;
  });
}
