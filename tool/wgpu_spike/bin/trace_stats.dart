// Counts the primitives, states and transfers of a GS frame trace.
//
// dart run bin/trace_stats.dart TRACE_DIR
import 'dart:convert';
import 'dart:io';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_raster.dart';
import 'package:wgpu_spike/trace.dart';

final counts = <String, int>{};
void count(String key, [int n = 1]) => counts[key] = (counts[key] ?? 0) + n;

class _CountingSink implements GsResidentSink {
  @override
  ImageBuffer? completedImage;
  @override
  void draw(GsHostDraw? draw, String unsupported) => count('sink draw');
  @override
  void beginUpload(int psm, int base, int bufferWidth, int x, int y,
      int width, int height) {
    count('upload psm ${psm.toRadixString(16)}');
    count('upload pixels', width * height);
  }

  @override
  bool uploadWord(int word) => false;
  @override
  void loadClut(int entry, int psm, int index) => count('clut entries');
  @override
  void copyLocal(int bitbltbuf, int trxpos, int trxreg) {
    count('copy psm ${(bitbltbuf >> 24 & 0x3f).toRadixString(16)}->'
        '${(bitbltbuf >> 56 & 0x3f).toRadixString(16)}');
    count('copy pixels', (trxreg & 0xfff) * (trxreg >> 32 & 0xfff));
  }

  @override
  void beginDownload(int psm, int base, int bufferWidth, int x, int y,
          int width, int height) =>
      count('download');
  @override
  void vblank(int field) => count('vblank');
}

void main(List<String> args) {
  final gs = loadGs('${args[0]}/gs-start.bin');
  gs.residentSink = _CountingSink();
  const names = ['point', 'line', 'linestrip', 'tri', 'tristrip', 'trifan',
    'sprite'];
  gsPrimitiveHook = (type, attrs, v) {
    final c = gs.contexts[attrs >> 9 & 1];
    final frame = c.frame, test = c.test, zbuf = c.zbuf;
    count('prim ${names[type]}');
    if (v.length == 3) {
      final xs = [for (final p in v) p.x], ys = [for (final p in v) p.y];
      final ext = [xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b),
        ys.reduce((a, b) => a > b ? a : b) - ys.reduce((a, b) => a < b ? a : b)]
          .reduce((a, b) => a > b ? a : b);
      if (ext >= 1 << 15) count('triangle extent >= 2048 px');
      if (ext >= 1 << 14) count('triangle extent >= 1024 px');
      final ofx = c.xyoffset & 0xffff, ofy = c.xyoffset >> 32 & 0xffff;
      for (final p in v) {
        if ((p.x - ofx).abs() >= 1 << 15 || (p.y - ofy).abs() >= 1 << 15) {
          count('vertex beyond 2048 px');
          break;
        }
      }
      final z = [for (final p in v) p.z].reduce((a, b) => a > b ? a : b);
      if (z >= 1 << 24) count('z >= 2^24');
    }
    count('frame psm ${(frame >> 24 & 0x3f).toRadixString(16)}');
    if (frame >> 32 & 0xffffffff != 0) count('fbmsk');
    if (c.fba != 0) count('fba');
    final zte = test >> 16 & 1 != 0, ztst = test >> 17 & 3;
    final zmsk = zbuf >> 32 & 1 != 0;
    if (zte && ztst >= 2 || !zmsk) {
      count('z psm ${(0x30 | zbuf >> 24 & 0xf).toRadixString(16)}'
          ' test $ztst${zmsk ? '' : ' write'}');
      if ((zbuf & 0x1ff) == (frame & 0x1ff)) count('z aliases frame');
    }
    if (test & 1 != 0) {
      count('atst ${test >> 1 & 7} afail ${test >> 12 & 3}');
    }
    if (test >> 14 & 1 != 0) count('date');
    if (attrs & 0x40 != 0) {
      count('blend ${(c.alpha & 0xff).toRadixString(16)}');
      if (gs.pabe != 0) count('pabe');
    }
    if (attrs & 0x20 != 0) count('fog');
    if (attrs & 0x08 != 0) count('gouraud');
    if (attrs & 0x80 != 0) count('aa1');
    if (gs.colclamp == 0) count('no colclamp');
    if (gs.dthe & 1 != 0) count('dither');
    if (attrs & 0x10 != 0) {
      final t0 = c.tex0, t1 = c.tex1;
      count('tex psm ${(t0 >> 20 & 0x3f).toRadixString(16)}'
          ' tfx ${t0 >> 35 & 3}${attrs & 0x100 != 0 ? ' uv' : ' stq'}');
      if (t1 >> 5 & 1 != 0) count('mag linear');
      final mxl = t1 >> 2 & 7, mmin = t1 >> 6 & 7;
      if (mxl > 0 || mmin != (t1 >> 5 & 1)) {
        count('mip mxl $mxl mmin $mmin lcm ${t1 & 1}');
      }
      count('clamp ${c.clamp & 3}/${c.clamp >> 2 & 3}');
    }
  };
  final clock = Stopwatch()..start();
  replay(gs, args[0]);
  stdout.writeln('replay ${clock.elapsedMilliseconds} ms');
  final keys = counts.keys.toList()..sort();
  stdout.writeln(const JsonEncoder.withIndent(' ')
      .convert({for (final k in keys) k: counts[k]}));
}
