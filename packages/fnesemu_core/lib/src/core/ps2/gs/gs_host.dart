part of 'gs.dart';

typedef _Rect = ({int left, int top, int right, int bottom});

class _GsHostBatch extends GsHostDraw {
  _GsHostBatch(this.frame);

  final int frame;
  final draws = <(_Rect, int)>[];
  @override
  int get width => right - left;
  @override
  int get height => bottom - top;
  int left = 2048, top = 2048, right = 0, bottom = 0;
  @override
  int area = 0;

  void add(_Rect rect, int rgba) {
    draws.add((rect, rgba));
    left = math.min(left, rect.left);
    top = math.min(top, rect.top);
    right = math.max(right, rect.right);
    bottom = math.max(bottom, rect.bottom);
    area += (rect.right - rect.left) * (rect.bottom - rect.top);
  }

  GsLayout layout(GsMemory mem) => mem.layout(GsPsm.ct32);
  int get bp => (frame & 0x1ff) * 32;
  int get bw => frame >> 16 & 0x3f;

  @override
  void drawSoftware(GsMemory mem) {
    final layout = this.layout(mem);
    for (final (rect, color) in draws) {
      for (var y = rect.top; y < rect.bottom; y++) {
        for (var x = rect.left; x < rect.right; x++) {
          mem.setWord(layout.index(bp, bw, x, y), color);
        }
      }
    }
  }

  @override
  void writeCoverage(GsMemory mem, Uint8List pixels) {
    if (pixels.length != (right - left) * (bottom - top) * 4) return;
    for (var i = 0; i < pixels.length; i += 4) {
      if (_index(pixels, i) > draws.length) return;
    }
    final layout = this.layout(mem);
    var i = 0;
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++, i += 4) {
        final index = _index(pixels, i);
        if (index != 0) {
          mem.setWord(layout.index(bp, bw, x, y), draws[index - 1].$2);
        }
      }
    }
  }

  static int _index(Uint8List pixels, int i) =>
      pixels[i] | pixels[i + 1] << 8 | pixels[i + 2] << 16;

  @override
  Ps2RenderFrame buildFrame() => Ps2RenderFrame(width, height, [
        for (final (rect, _) in draws)
          (
            left: rect.left - left,
            top: rect.top - top,
            right: rect.right - left,
            bottom: rect.bottom - top,
          ),
      ]);
}

extension on Gs {
  bool _queueHostSprite(int attrs, GsVertex a, GsVertex b) {
    // Texture, fog, blending and antialiasing need the GS pixel pipeline.
    if (_hostSink == null || attrs & 0xf0 != 0) return false;
    final ctx = contexts[attrs >> 9 & 1];
    final frame = ctx.frame;
    final bw = frame >> 16 & 0x3f;
    final test = ctx.test;
    if (bw == 0 ||
        frame >> 24 & 0x3f != GsPsm.ct32 ||
        frame >>> 32 != 0 ||
        ctx.zbuf >> 32 & 1 == 0 ||
        (test & 1 != 0 && test >> 1 & 7 != 1) ||
        test & 0x4000 != 0 ||
        (test & 0x10000 != 0 && test >> 17 & 3 != 1)) {
      return false;
    }

    final ox = ctx.xyoffset & 0xffff, oy = ctx.xyoffset >> 32 & 0xffff;
    final sc = ctx.scissor;
    // Use the GS integer sample position, then clip to the inclusive scissor.
    final left = math.max((math.min(a.x, b.x) - ox + 15) >> 4, sc & 0x7ff);
    final top = math.max((math.min(a.y, b.y) - oy + 15) >> 4, sc >> 32 & 0x7ff);
    final right =
        math.min((math.max(a.x, b.x) - ox + 15) >> 4, (sc >> 16 & 0x7ff) + 1);
    final bottom =
        math.min((math.max(a.y, b.y) - oy + 15) >> 4, (sc >> 48 & 0x7ff) + 1);
    if (left >= right || top >= bottom) return true;
    // The host raster assumes different coordinates never alias in GS memory.
    if (right > bw * 64 ||
        (frame & 0x1ff) + ((bottom - 1) >> 5) * bw + ((right - 1) >> 6) >=
            512) {
      return false;
    }
    _capturePendingField();
    final previous = _hostBatch;
    if (previous is! _GsHostBatch ||
        previous.frame != frame ||
        previous.draws.length == 4096 ||
        previous.selectedForGpu) {
      _flushHostBatch();
    }
    final batch = (_hostBatch ??= _GsHostBatch(frame)) as _GsHostBatch;
    final alpha = ctx.fba != 0 ? b.a | 0x80 : b.a;
    batch.add((left: left, top: top, right: right, bottom: bottom),
        b.r | b.g << 8 | b.b << 16 | alpha << 24);
    return true;
  }

  void _flushHostBatch() {
    final batch = _hostBatch;
    _hostBatch = null;
    if (batch == null) return;
    final coverage = batch.coverage;
    if (coverage != null) {
      batch.writeCoverage(_mem, coverage);
    } else if (!batch.selectedForGpu) {
      batch.drawSoftware(_mem);
    }
  }

  bool _submitHostBatch() {
    final batch = _hostBatch;
    final sink = _hostSink;
    if (sink == null || batch == null || pmode & 3 == 0) return false;
    if (batch.selectedForGpu) return identical(_submittedBatch, batch);
    // Keep small or sparse batches on the CPU to limit readback work.
    if (batch.area < batch.minimumArea || batch.area * 2 < batch.width * batch.height) {
      return false;
    }
    batch.selectedForGpu = true;
    if (_submittedBatch != null) return false;
    _submittedBatch = batch;
    // Give guest accesses in the rest of this frame a chance to resolve the
    // batch before spending time on GPU work.
    scheduleMicrotask(() {
      unawaited(_drawHostBatch(sink, batch));
    });
    return true;
  }

  Future<void> _drawHostBatch(Ps2RenderFrameSink sink, GsHostDraw batch) async {
    try {
      if (!identical(_hostBatch, batch)) return;
      final pixels = await sink.drawPs2(batch.buildFrame());
      if (identical(_hostBatch, batch)) batch.coverage = pixels;
    } catch (_) {
      // A failed readback leaves the batch without coverage.
    } finally {
      if (identical(_submittedBatch, batch)) _submittedBatch = null;
    }
  }
}
