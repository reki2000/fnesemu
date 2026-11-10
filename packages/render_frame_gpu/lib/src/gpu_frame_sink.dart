import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:mp_gpu/mp_gpu.dart';

import 'frame_renderer.dart';
import 'ps2_frame_renderer.dart';

/// Draws Dreamcast frames and PS2 coverage on the platform GPU.
class GpuFrameSink implements Ps2RenderFrameSink {
  GpuFrameSink._(this._queue, this._renderer);

  /// A sink, or null when the platform has no GPU that [GpuDevice] can use,
  /// or when it does not draw.
  static Future<GpuFrameSink?> create() async {
    try {
      final device = await GpuDevice.create();
      if (device == null) return null;
      final queue = await GpuQueue.create(device);
      if (queue == null) return null;
      final sink = GpuFrameSink._(queue, await FrameRenderer.create(device));
      try {
        sink._ps2 = await Ps2FrameRenderer.create(device);
      } catch (_) {
        // Dreamcast can still draw if the PS2 program is unavailable.
      }
      return sink;
    } catch (_) {
      return null;
    }
  }

  // Draws the frames, each into a target of its own, and returns their
  // pixels; see [GpuQueue].
  final GpuQueue _queue;
  final FrameRenderer _renderer;
  Ps2FrameRenderer? _ps2;
  int _ps2Marker = 0;
  GpuDevice get _device => _queue.device;

  /// The name of the GPU API, for the settings.
  String get name => _device.name;

  /// How the device waits before reads, for logs.
  String get readBack => _device.readBack;

  @override
  void submit(RenderFrame frame) {
    unawaited(_queue
        .render(frame.width, frame.height,
            (target) => _renderer.draw(frame, target))
        .then((rgba) {
      if (rgba != null) frame.onDrawn?.call(rgba);
    }));
  }

  @override
  Future<Uint8List?> drawPs2(Ps2RenderFrame frame) {
    final renderer = _ps2;
    if (renderer == null) return Future.value(null);
    return _queue.render(
        frame.width, frame.height, (target) => renderer.draw(frame, target));
  }

  /// Replays a two-pass CT32 feedback draw with only a final readback.
  Future<Uint8List?> drawPs2Feedback(Ps2SpriteFrame frame,
      {required int split, required int left, required int top,
      required int colorMask, required bool forceAlpha}) async {
    final renderer = _ps2;
    if (renderer == null || frame.planes != 2 || split <= 0 ||
        split >= frame.height) {
      return null;
    }
    final program = await renderer.feedbackProgram();
    if (program == null) return null;
    final firstMarker = _ps2Marker = _ps2Marker % 0xffffff + 1;
    final secondMarker = _ps2Marker = _ps2Marker % 0xffffff + 1;
    // The row below the frame holds the marker of the second draw, which
    // the feedback shader leaves at zero when a draw was not valid.
    final rgba = await _queue.render(frame.width, frame.height + 1, (target) {
      renderer.drawFeedback(program, frame, target, scratch: _queue.scratch,
          split: split, left: left, top: top, colorMask: colorMask,
          forceAlpha: forceAlpha, firstMarker: firstMarker,
          secondMarker: secondMarker);
    });
    final end = frame.width * frame.height * 4;
    if (rgba == null || rgba.length != end + frame.width * 4 ||
        rgba[end] != secondMarker & 255 ||
        rgba[end + 1] != secondMarker >> 8 & 255 ||
        rgba[end + 2] != secondMarker >> 16 || rgba[end + 3] != 255) {
      return null;
    }
    return Uint8List.sublistView(rgba, 0, end);
  }

  int _ps2AtlasSubmissions = 0;
  int get ps2AtlasSubmissions => _ps2AtlasSubmissions;

  /// Draws independent packets into one render target per group.
  Future<List<Uint8List?>> drawPs2Sprites(List<Ps2SpriteFrame> frames) async {
    final renderer = _ps2;
    final result = List<Uint8List?>.filled(frames.length, null);
    if (renderer == null || frames.isEmpty) return result;
    const atlasWidth = 2048, atlasHeight = 1024;
    var first = 0;
    while (first < frames.length) {
      final tiles = <Ps2SpriteTile>[];
      var x = 0, y = 0, shelf = 0, usedWidth = 0, usedHeight = 0;
      while (first + tiles.length < frames.length) {
        final frame = frames[first + tiles.length];
        if (frame.width > atlasWidth || frame.height > atlasHeight) break;
        if (x + frame.width > atlasWidth) {
          x = 0;
          y += shelf;
          shelf = 0;
        }
        final height = frame.height;
        if (y + height > atlasHeight) break;
        tiles.add((frame: frame, x: x, y: y, marker: 0));
        x += frame.width;
        if (x > usedWidth) usedWidth = x;
        if (height > shelf) shelf = height;
        if (y + shelf > usedHeight) usedHeight = y + shelf;
      }
      if (tiles.isEmpty) {
        result[first] = await drawPs2(frames[first]);
        first++;
        continue;
      }
      // Power-of-two sizes let the queue reuse targets between atlas groups.
      final width = 1 << (usedWidth - 1).bitLength;
      final height = 1 << (usedHeight - 1).bitLength;
      _ps2AtlasSubmissions++;
      final pixels = await _queue.render(
          width, height, (target) => renderer.drawSprites(target, tiles));
      if (pixels != null) {
        for (final (i, tile) in tiles.indexed) {
          final start = (tile.y * width + tile.x) * 4;
          final stride = tile.frame.width * 4;
          final tilePixels = Uint8List(stride * tile.frame.height);
          for (var row = 0; row < tile.frame.height; row++) {
            tilePixels.setRange(row * stride, (row + 1) * stride,
                pixels, start + row * width * 4);
          }
          result[first + i] = tilePixels;
        }
      }
      first += tiles.length;
    }
    return result;
  }
}
