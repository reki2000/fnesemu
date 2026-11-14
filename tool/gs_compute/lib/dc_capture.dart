// The inputs of one DC render, as the CORE read them when its first tile
// was due: the registers of the renderer and the fog, the palette and the
// VRAM. A capture replays on a renderer of its own, on the CPU or on a
// compute program, so that a browser can check the compute CORE without
// the rest of the core.
//
// The file is little endian: 'DCRC', the version 1, the count of register
// pairs and the pairs (offset, value), the palette control and its 1024
// words, and the 8 MiB of VRAM.
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc_compute.dart';
import 'package:fnesemu_core/src/core/dc/gpu_palette.dart';
import 'package:fnesemu_core/src/core/dc/gpu_render.dart';

const _magic = 0x43524344; // 'DCRC'

/// The registers of a render besides STARTRENDER, and those of the fog.
final _registers = [
  for (final offset in DcGpuRender.offsets)
    if (offset != 0x14) offset,
  0xb0,
  0xb4,
  0xb8,
  0xbc,
  0xc0,
  for (var offset = 0x200; offset < 0x400; offset += 4) offset,
];

/// The inputs of [render] now.
Uint8List captureRender(DcGpuRender render) {
  final words = <int>[_magic, 1, _registers.length];
  for (final offset in _registers) {
    words.addAll([offset, render.read(offset)]);
  }
  words.add(render.palette.control);
  words.addAll(render.palette.words);
  final header = Uint32List.fromList(words).buffer.asUint8List();
  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(render.memory))
      .takeBytes();
}

/// A renderer with the inputs of [capture], ready to start.
DcGpuRender replayRenderer(Uint8List capture) {
  final data = ByteData.sublistView(capture);
  int word(int i) => data.getUint32(i * 4, Endian.little);
  if (word(0) != _magic || word(1) != 1) {
    throw const FormatException('not a DC render capture');
  }
  final count = word(2);
  var at = 3 + count * 2;
  final palette = DcGpuPalette()..control = word(at);
  for (var i = 0; i < 1024; i++) {
    palette.words[i] = word(at + 1 + i);
  }
  at += 1025;
  final memory = Uint8List.fromList(capture.sublist(at * 4));
  final render = DcGpuRender(memory, palette, onNormal: (_) {});
  for (var i = 0; i < count; i++) {
    render.write(word(3 + i * 2), word(4 + i * 2));
  }
  return render;
}

/// The framebuffer bytes that a render of [capture] writes, rendered on
/// [compute] or, without it, on the CPU; and the microseconds of the fastest
/// of [rounds] renders, as the renders of a game follow each other. On a
/// sink that cannot wait, a render awaits its results as the core does.
Future<(Uint8List, int)> replay(
  Uint8List capture,
  DcCompute? compute, {
  int rounds = 1,
}) async {
  final render = replayRenderer(capture);
  if (compute != null) render.compute = compute.share(render.memory);
  final clock = Stopwatch();
  var fastest = 0;
  for (var round = 0; round < rounds; round++) {
    clock
      ..reset()
      ..start();
    render.write(0x14, 1);
    while (render.busy) {
      render.tickMasterClocks(2);
    }
    if (render.computeWait case final wait?) await wait;
    render.flushTiles();
    clock.stop();
    final us = clock.elapsedMicroseconds;
    if (round == 0 || us < fastest) fastest = us;
  }
  final start = render.read(0x60) & 0x7fffff;
  final stride = render.read(0x4c) * 8;
  final rows = (render.read(0x6c) >> 16) + 1;
  final end = (start + rows * stride).clamp(0, render.memory.length);
  final pixels = Uint8List.fromList(render.memory.sublist(start, end));
  return (pixels, fastest);
}

/// The count of pixels of [a] and [b] that differ by more than 8 in a
/// channel, for the framebuffer format of [capture].
int over8(Uint8List capture, Uint8List a, Uint8List b) {
  final render = replayRenderer(capture);
  final mode = render.read(0x48) & 7;
  final bytes = mode <= 3
      ? 2
      : mode == 4
      ? 3
      : 4;
  List<int> channels(Uint8List p, int i) {
    if (bytes == 2) {
      final v = p[i] | p[i + 1] << 8;
      return switch (mode) {
        1 => [(v >> 11) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3],
        2 => [
          (v >> 12) << 4,
          ((v >> 8) & 15) << 4,
          ((v >> 4) & 15) << 4,
          (v & 15) << 4,
        ],
        _ => [((v >> 10) & 31) << 3, ((v >> 5) & 31) << 3, (v & 31) << 3],
      };
    }
    return [for (var k = 0; k < bytes; k++) p[i + k]];
  }

  var count = 0;
  for (var i = 0; i + bytes <= a.length && i + bytes <= b.length; i += bytes) {
    final x = channels(a, i), y = channels(b, i);
    for (var k = 0; k < x.length; k++) {
      if ((x[k] - y[k]).abs() > 8) {
        count++;
        break;
      }
    }
  }
  return count;
}
