import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:fnesemu_core/app_api.dart';

import 'frame_renderer.dart';

/// Draws the frames that a core submits with Flutter GPU and returns the
/// drawn pixels through [RenderFrame.onDrawn].
class GpuFrameSink implements RenderFrameSink {
  GpuFrameSink._(this._renderer);

  /// The name of the renderer for the settings.
  static const name = 'Flutter GPU';

  /// A sink, or null when Flutter GPU is not available, as on the Web or
  /// when the engine runs without it.
  static Future<GpuFrameSink?> create() async {
    try {
      final sink = GpuFrameSink._(await FrameRenderer.create());
      return await sink._target(8, 8) == null ? null : sink;
    } catch (_) {
      return null;
    }
  }

  final FrameRenderer _renderer;
  gpu.Texture? _texture;

  // The frames are drawn one by one. While one is drawn, only the newest of
  // the frames submitted meanwhile waits; the older ones are dropped, so
  // that a slow GPU makes the pixels late by at most a frame.
  bool _drawing = false;
  RenderFrame? _waiting;

  @override
  void submit(RenderFrame frame) {
    _waiting = frame;
    if (!_drawing) unawaited(_drawWaiting());
  }

  Future<void> _drawWaiting() async {
    _drawing = true;
    try {
      while (true) {
        final frame = _waiting;
        if (frame == null) break;
        _waiting = null;
        final target = await _target(frame.width, frame.height);
        if (target == null) continue;
        final rgba = await _draw(frame, target);
        if (rgba != null) frame.onDrawn?.call(rgba);
      }
    } catch (_) {
      _waiting = null;
    } finally {
      _drawing = false;
    }
  }

  /// Draws [frame] into [target] and reads it back.
  ///
  /// On the GLES backend, a read often showed the texture as it was at the
  /// read before. The pixels are read twice after the next frame of the
  /// engine; that was right for all but about one frame in a few hundred,
  /// which then shows the frame before.
  Future<Uint8List?> _draw(RenderFrame frame, gpu.Texture target) async {
    _renderer.draw(frame, target: target);
    await SchedulerBinding.instance.endOfFrame;
    Future<ByteData?> read() async {
      final image = target.asImage();
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    }

    await read();
    final data = await read();
    return data == null ? null : Uint8List.sublistView(data);
  }

  /// A target of the size, or null when it cannot be read back.
  ///
  /// A new target is filled with a white textured triangle until the white
  /// comes back, which also tells whether Flutter GPU works at all. A pass
  /// that draws nothing was not run on the GLES backend.
  Future<gpu.Texture?> _target(int width, int height) async {
    final current = _texture;
    if (current != null && current.width == width && current.height == height) {
      return current;
    }
    final target = FrameRenderer.createTarget(width, height);
    final vertices = Float32List(3 * RenderFrame.vertexFloats);
    final corners = [(0.0, 0.0), (2.0 * width, 0.0), (0.0, 2.0 * height)];
    for (final (i, (x, y)) in corners.indexed) {
      vertices.setAll(i * RenderFrame.vertexFloats, [x, y, 1, 0, 0]);
      vertices.fillRange(
        i * RenderFrame.vertexFloats + 5,
        i * RenderFrame.vertexFloats + 9,
        1,
      );
    }
    final frame = RenderFrame(
      width: width,
      height: height,
      clearColor: 0xff000000,
      clearDepth: 0,
      depthScale: 0.5,
      vertices: vertices,
      batches: [
        RenderBatch(
          pass: RenderBatch.opaque,
          first: 0,
          count: 1,
          texture: 0,
          state: RenderBatch.pack(
            depthCompare: 7,
            depthWrite: false,
            sourceFactor: 1,
            destinationFactor: 0,
            shading: 1,
            fog: 0,
            textureAlpha: false,
            offset: false,
          ),
        ),
      ],
      textures: [
        RenderTexture(
          width: 8,
          height: 8,
          sampler: 1,
          rgba: Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, 255),
        ),
      ],
      fogTable: Uint8List(256),
      fogScale: 1,
      fogColor: 0,
      vertexFogColor: 0,
      alphaReference: 0,
    );
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 2000) {
      final rgba = await _draw(frame, target);
      if (rgba != null && rgba.every((byte) => byte == 255)) {
        return _texture = target;
      }
    }
    return null;
  }
}
