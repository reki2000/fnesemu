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
      final target = await sink._target(8, 8);
      if (target == null) return null;
      sink._free.add(target);
      return sink;
    } catch (_) {
      return null;
    }
  }

  final FrameRenderer _renderer;

  // Targets that were read back once and are free.
  final _free = <gpu.Texture>[];

  // The frames submitted while others are drawn. They are drawn together,
  // each into a target of its own, and read back after one frame of the
  // engine. A GPU that falls far behind drops the oldest ones.
  static const _maximumWaiting = 8;
  final _waiting = <RenderFrame>[];
  bool _drawing = false;

  @override
  void submit(RenderFrame frame) {
    _waiting.add(frame);
    if (_waiting.length > _maximumWaiting) _waiting.removeAt(0);
    if (!_drawing) unawaited(_drawWaiting());
  }

  Future<void> _drawWaiting() async {
    _drawing = true;
    try {
      while (_waiting.isNotEmpty) {
        final frames = [..._waiting];
        _waiting.clear();
        final drawn = <(RenderFrame, gpu.Texture)>[];
        for (final frame in frames) {
          final target = await _target(frame.width, frame.height);
          if (target == null) continue;
          _renderer.draw(frame, target: target);
          drawn.add((frame, target));
        }
        await SchedulerBinding.instance.endOfFrame;
        _renderer.nextFrame();
        for (final (frame, target) in drawn) {
          final rgba = await _read(target);
          _free.add(target);
          if (rgba != null) frame.onDrawn?.call(rgba);
        }
      }
    } catch (_) {
      _waiting.clear();
    } finally {
      _drawing = false;
    }
  }

  /// Draws [frame] into [target] and reads it back.
  Future<Uint8List?> _draw(RenderFrame frame, gpu.Texture target) async {
    _renderer.draw(frame, target: target);
    await SchedulerBinding.instance.endOfFrame;
    _renderer.nextFrame();
    return _read(target);
  }

  /// Reads [target] back after a frame of the engine passed since it was
  /// drawn.
  ///
  /// On the GLES backend, a read often showed the texture as it was at the
  /// read before. The pixels are read twice after the next frame of the
  /// engine; that was right for all but about one frame in a few hundred,
  /// which then shows the frame before.
  static Future<Uint8List?> _read(gpu.Texture target) async {
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

  /// A free target of the size, or a new one; null when a new one cannot
  /// be read back.
  ///
  /// A new target is filled with a white textured triangle until the white
  /// comes back, which also tells whether Flutter GPU works at all. A pass
  /// that draws nothing was not run on the GLES backend.
  Future<gpu.Texture?> _target(int width, int height) async {
    final index = _free.indexWhere(
      (t) => t.width == width && t.height == height,
    );
    if (index >= 0) return _free.removeAt(index);
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
      if (rgba != null && rgba.every((byte) => byte == 255)) return target;
    }
    return null;
  }
}
