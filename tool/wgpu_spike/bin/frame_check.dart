// Replays a GS frame trace (packages/fnesemu_core/tool/gs_trace_record.dart)
// through the software raster of the core and through the compute GS, and
// compares the local memory and the displayed buffer.
//
// dart run bin/frame_check.dart TRACE_DIR [--adapter NAME] [--rounds N]
//     [--max-memory-words N] [--max-display-over8 N]
//
// Writes software.png, gpu.png and diff.png (differences x8) to TRACE_DIR.
// Exits with 1 when more words of the local memory differ than
// --max-memory-words (1024), or more displayed pixels differ by more than 8
// in a channel than --max-display-over8 (0). The texture and colour
// interpolation of the compute GS is in 32-bit floats, and the core's in
// doubles, so a few values differ by a step.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';

import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_raster.dart';
import 'package:image/image.dart' as img;
import 'package:wgpu_spike/compute_gs.dart';
import 'package:wgpu_spike/gpu.dart';
import 'package:wgpu_spike/trace.dart';

/// the display buffer of [gs] read from [mem], one row per buffer row
img.Image display(Gs gs, GsMemory mem) {
  final circuit2 = gs.pmode & 2 != 0;
  final fb = circuit2 ? gs.dispfb2 : gs.dispfb1;
  final disp = circuit2 ? gs.display2 : gs.display1;
  final magh = (disp >> 23) & 15, magv = (disp >> 27) & 3;
  final width = (((disp >> 32) & 0xfff) + 1) ~/ (magh + 1);
  var lines = ((disp >> 44) & 0x7ff) + 1;
  final interlaced = gs.smode2 & 1 != 0, consecutive = gs.smode2 & 2 != 0;
  if (lines > (interlaced ? 480 : 240)) lines = interlaced ? 480 : 240;
  // the rows of field 0 as GsRaster's scanout reads them, each shown twice
  final height = interlaced ? (lines + 1) ~/ 2 : lines ~/ (magv + 1);
  final psm = (fb >> 15) & 0x1f;
  final bp = (fb & 0x1ff) * 32, bw = (fb >> 9) & 0x3f;
  final dbx = (fb >> 32) & 0x7ff, dby = (fb >> 43) & 0x7ff;
  final out = img.Image(width: width, height: height * 2);
  for (var y = 0; y < height; y++) {
    final source = interlaced && !consecutive ? y * 2 : y;
    final sy = interlaced ? source ~/ (magv + 1) : source;
    for (var x = 0; x < width; x++) {
      final raw = mem.read(psm, bp, bw, dbx + x, dby + sy);
      for (final row in [y * 2, y * 2 + 1]) {
        if (psm == GsPsm.ct16 || psm == GsPsm.ct16s) {
          out.setPixelRgb(x, row, (raw & 31) << 3, (raw >> 5 & 31) << 3,
              (raw >> 10 & 31) << 3);
        } else {
          out.setPixelRgb(
              x, row, raw & 0xff, raw >> 8 & 0xff, raw >> 16 & 0xff);
        }
      }
    }
  }
  return out;
}

/// a sink that drops all work, to time the command stream alone
class _IdleSink implements GsResidentSink {
  @override
  ImageBuffer? get completedImage => null;
  @override
  void draw(GsHostDraw? draw, String unsupported) {}
  @override
  void beginUpload(int psm, int base, int bufferWidth, int x, int y,
      int width, int height) {}
  @override
  bool uploadWord(int word) => false;
  @override
  void loadClut(int entry, int psm, int index) {}
  @override
  void copyLocal(int bitbltbuf, int trxpos, int trxreg) {}
  @override
  void beginDownload(int psm, int base, int bufferWidth, int x, int y,
      int width, int height) {}
  @override
  void vblank(int field) {}
}

Uint32List words(GsMemory mem) => Uint32List.view(
    mem.bytes.buffer, mem.bytes.offsetInBytes, GsMemory.size ~/ 4);

void main(List<String> args) {
  final dir = args.first;
  String option(String name, String fallback) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final rounds = int.parse(option('--rounds', '1'));

  final software = loadGs('$dir/gs-start.bin');
  var clock = Stopwatch()..start();
  replay(software, dir);
  final softwareMs = clock.elapsedMilliseconds;

  // the replay without drawing: the cost of the command stream itself
  for (var round = 0; round < 3; round++) {
    final idle = loadGs('$dir/gs-start.bin')..residentSink = _IdleSink();
    gsPrimitiveHook = (type, attrs, vertices) {};
    clock = Stopwatch()..start();
    replay(idle, dir);
    stdout.writeln('{"replayWithoutWorkMs":${clock.elapsedMicroseconds / 1000}}');
    gsPrimitiveHook = null;
  }

  final here = File(Platform.script.toFilePath()).parent.parent.path;
  final gpu = GsGpu.open(GsGpu.defaultLibrary(),
      File(Platform.environment['GSGPU_WGSL'] ?? '$here/gs.wgsl')
          .readAsStringSync(),
      adapter: option('--adapter', 'NVIDIA'));
  stdout.write(gpu.adapters);

  late Gs hardware;
  late ComputeGsSink sink;
  late Uint32List vram;
  for (var round = 0; round < rounds; round++) {
    hardware = loadGs('$dir/gs-start.bin');
    sink = ComputeGsSink(hardware, gpu)
      ..chunkSteps = int.parse(option('--chunk', '64'))
      ..attach();
    clock = Stopwatch()..start();
    replay(hardware, dir);
    final issueMs = clock.elapsedMicroseconds / 1000;
    sink.detach();
    final totalMs = clock.elapsedMicroseconds / 1000;
    vram = gpu.readVram();
    stdout.writeln(jsonEncode({
      'round': round,
      'softwareMs': softwareMs,
      'issueMs': issueMs,
      'totalMs': totalMs,
      'gpuRunMs': sink.gpuMs,
      'uploadMs': sink.uploadMs,
      'waitMs': sink.waitMs,
      'uploadWords': sink.uploadWords,
      'submits': sink.submits,
      'draws': sink.draws,
      'steps': sink.stepCounts,
      'unsupported': sink.unsupported,
    }));
  }

  // the whole local memory
  final expected = words(software.mem);
  var differing = 0;
  final pages = <int, int>{};
  for (var i = 0; i < expected.length; i++) {
    if (expected[i] != vram[i]) {
      differing++;
      pages[i >> 11] = (pages[i >> 11] ?? 0) + 1;
    }
  }
  final dump = int.parse(option('--dump', '0'));
  for (var i = 0, shown = 0; i < expected.length && shown < dump; i++) {
    if (expected[i] != vram[i]) {
      shown++;
      stdout.writeln('word ${i.toRadixString(16)} page ${i >> 11}: '
          'core ${expected[i].toRadixString(16).padLeft(8, '0')} '
          'gpu ${vram[i].toRadixString(16).padLeft(8, '0')}');
    }
  }
  final worst = pages.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln(jsonEncode({
    'memoryWordsDiffering': differing,
    'pagesDiffering': pages.length,
    'worstPages': {for (final e in worst.take(12)) '${e.key}': e.value},
  }));

  // the displayed buffer
  final gpuMem = GsMemory();
  words(gpuMem).setAll(0, vram);
  final a = display(software, software.mem), b = display(software, gpuMem);
  final diff = img.Image(width: a.width, height: a.height);
  var pixels = 0, over8 = 0, maximum = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final p = a.getPixel(x, y), q = b.getPixel(x, y);
      final dr = (p.r - q.r).abs().toInt(), dg = (p.g - q.g).abs().toInt();
      final db = (p.b - q.b).abs().toInt();
      final d = [dr, dg, db].reduce((m, n) => m > n ? m : n);
      if (d > 0) pixels++;
      if (d > 8) over8++;
      if (d > maximum) maximum = d;
      diff.setPixelRgb(x, y, (dr * 8).clamp(0, 255), (dg * 8).clamp(0, 255),
          (db * 8).clamp(0, 255));
    }
  }
  File('$dir/software.png').writeAsBytesSync(img.encodePng(a));
  File('$dir/gpu.png').writeAsBytesSync(img.encodePng(b));
  File('$dir/diff.png').writeAsBytesSync(img.encodePng(diff));
  stdout.writeln(jsonEncode({
    'display': '${a.width}x${a.height}',
    'pixelsDiffering': pixels,
    'over8': over8,
    'max': maximum,
  }));
  final pass =
      differing <= int.parse(option('--max-memory-words', '1024')) &&
          over8 <= int.parse(option('--max-display-over8', '0'));
  stdout.writeln(pass ? 'PASS' : 'FAIL');
  exit(pass ? 0 : 1);
}
