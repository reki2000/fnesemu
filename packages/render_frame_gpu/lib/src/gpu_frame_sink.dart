import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:mp_gpu/mp_gpu.dart';

import 'frame_renderer.dart';

/// Draws the frames that a core submits on the GPU of the platform and
/// returns the drawn pixels through [RenderFrame.onDrawn].
class GpuFrameSink implements RenderFrameSink {
  GpuFrameSink._(this._renderer);

  /// A sink, or null when the platform has no GPU that [GpuDevice] can use,
  /// or when it does not draw.
  static Future<GpuFrameSink?> create() async {
    try {
      final device = await GpuDevice.create();
      if (device == null) return null;
      final sink = GpuFrameSink._(await FrameRenderer.create(device));
      final target = await sink._target(8, 8);
      if (target == null) return null;
      sink._free.add(target);
      return sink;
    } catch (_) {
      return null;
    }
  }

  final FrameRenderer _renderer;
  GpuDevice get _device => _renderer.device;

  /// The name of the GPU API, for the settings.
  String get name => _device.name;

  // Targets that were read back once and are free.
  final _free = <GpuTarget>[];

  // The frames submitted while others are drawn. They are drawn together,
  // each into a target of its own, and read back once the device settles.
  // A GPU that falls far behind drops the oldest ones.
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
        final drawn = <(RenderFrame, GpuTarget)>[];
        for (final frame in frames) {
          final target = await _target(frame.width, frame.height);
          if (target == null) continue;
          _renderer.draw(frame, target);
          drawn.add((frame, target));
        }
        await _device.settle();
        for (final (frame, target) in drawn) {
          final rgba = await _device.read(target);
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
  Future<Uint8List?> _draw(RenderFrame frame, GpuTarget target) async {
    _renderer.draw(frame, target);
    await _device.settle();
    return _device.read(target);
  }

  /// A free target of the size, or a new one; null when a new one cannot
  /// be read back.
  ///
  /// A new target is filled with a white textured triangle until the white
  /// comes back, which also tells whether the GPU works at all. A pass that
  /// draws nothing was not run on the GLES backend of Flutter GPU.
  Future<GpuTarget?> _target(int width, int height) async {
    final index = _free.indexWhere(
      (t) => t.width == width && t.height == height,
    );
    if (index >= 0) return _free.removeAt(index);
    final target = _device.target(width, height);
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
