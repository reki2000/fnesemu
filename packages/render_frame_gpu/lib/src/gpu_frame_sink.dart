import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:mp_gpu/mp_gpu.dart';

import 'frame_renderer.dart';
import 'ps2_frame_renderer.dart';

/// Draws Dreamcast frames and PS2 coverage on the platform GPU.
class GpuFrameSink implements Ps2RenderFrameSink {
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

  final FrameRenderer _renderer;
  Ps2FrameRenderer? _ps2;
  int _ps2Marker = 0;
  GpuDevice get _device => _renderer.device;

  /// The name of the GPU API, for the settings.
  String get name => _device.name;

  /// How the device waits before reads, for logs.
  String get readBack => _device.readBack;

  // Targets that were read back once and are free.
  final _free = <GpuTarget>[];

  // The frames submitted while others are drawn. They are drawn together,
  // each into a target of its own, and read back once the device settles.
  // A GPU that falls far behind drops the oldest ones.
  static const _maximumWaiting = 8;
  final _waiting = <_QueuedFrame>[];
  bool _drawing = false;

  @override
  void submit(RenderFrame frame) {
    _enqueue(_QueuedFrame(frame.width, frame.height,
        (target) => _renderer.draw(frame, target), (rgba) {
      if (rgba != null) frame.onDrawn?.call(rgba);
    }));
  }

  @override
  Future<Uint8List?> drawPs2(Ps2RenderFrame frame) {
    final renderer = _ps2;
    if (renderer == null) return Future.value(null);
    final marker = _ps2Marker = _ps2Marker % 0xffffff + 1;
    final result = Completer<Uint8List?>();
    _enqueue(_QueuedFrame(frame.width, frame.height + 1,
        (target) => renderer.draw(frame, target, marker), (rgba) {
      final end = frame.width * frame.height * 4;
      final valid = rgba != null &&
          rgba.length == end + frame.width * 4 &&
          rgba[end] == marker & 255 &&
          rgba[end + 1] == marker >> 8 & 255 &&
          rgba[end + 2] == marker >> 16 &&
          rgba[end + 3] == 255;
      result.complete(valid ? Uint8List.sublistView(rgba, 0, end) : null);
    }));
    return result.future;
  }

  /// Replays a two-pass CT32 feedback draw with only a final readback.
  Future<Uint8List?> drawPs2Feedback(Ps2SpriteFrame frame,
      {required int split, required int left, required int top,
      required int colorMask, required bool forceAlpha}) async {
    final renderer = _ps2;
    if (renderer == null || name != 'Flutter GPU' || frame.planes != 2 ||
        split <= 0 || split >= frame.height) {
      return null;
    }
    final program = await renderer.feedbackProgram();
    final firstMarker = _ps2Marker = _ps2Marker % 0xffffff + 1;
    final secondMarker = _ps2Marker = _ps2Marker % 0xffffff + 1;
    final done = Completer<Uint8List?>();
    _enqueue(_QueuedFrame(frame.width, frame.height + 1, (target) {
      renderer.drawFeedback(program, frame, target, split: split, left: left,
          top: top, colorMask: colorMask, forceAlpha: forceAlpha,
          firstMarker: firstMarker, secondMarker: secondMarker);
    }, done.complete));
    final rgba = await done.future;
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
        if (frame.width > atlasWidth || frame.height + 1 > atlasHeight) break;
        if (x + frame.width > atlasWidth) {
          x = 0;
          y += shelf;
          shelf = 0;
        }
        final height = frame.height + 1;
        if (y + height > atlasHeight) break;
        final marker = _ps2Marker = _ps2Marker % 0xffffff + 1;
        tiles.add((frame: frame, x: x, y: y, marker: marker));
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
      // Power-of-two sizes let the sink reuse targets between atlas groups.
      final width = 1 << (usedWidth - 1).bitLength;
      final height = 1 << (usedHeight - 1).bitLength;
      final done = Completer<Uint8List?>();
      _ps2AtlasSubmissions++;
      _enqueue(_QueuedFrame(width, height,
          (target) => renderer.drawSprites(target, tiles), done.complete));
      final pixels = await done.future;
      if (pixels != null && pixels.length == width * height * 4) {
        for (final (i, tile) in tiles.indexed) {
          final start = (tile.y * width + tile.x) * 4;
          final end = start + tile.frame.height * width * 4;
          final marker = tile.marker;
          if (pixels[end] != marker & 255 || pixels[end + 1] != marker >> 8 & 255 ||
              pixels[end + 2] != marker >> 16 || pixels[end + 3] != 255) {
            continue;
          }
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

  void _enqueue(_QueuedFrame frame) {
    _waiting.add(frame);
    if (_waiting.length > _maximumWaiting) _waiting.removeAt(0).finish(null);
    if (!_drawing) unawaited(_drawWaiting());
  }

  Future<void> _drawWaiting() async {
    _drawing = true;
    var frames = <_QueuedFrame>[];
    try {
      while (_waiting.isNotEmpty) {
        frames = [..._waiting];
        _waiting.clear();
        final drawn = <(_QueuedFrame, GpuTarget)>[];
        for (final frame in frames) {
          final target = await _target(frame.width, frame.height);
          if (target == null) {
            frame.finish(null);
            continue;
          }
          frame.draw(target);
          drawn.add((frame, target));
        }
        await _device.settle();
        for (final (frame, target) in drawn) {
          final rgba = await _device.read(target);
          _free.add(target);
          if (_free.length > _maximumWaiting) _free.removeAt(0);
          frame.finish(rgba);
        }
      }
    } catch (_) {
      for (final frame in [...frames, ..._waiting]) {
        frame.finish(null);
      }
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

class _QueuedFrame {
  _QueuedFrame(this.width, this.height, this.draw, this._onDrawn);

  final int width, height;
  final void Function(GpuTarget) draw;
  void Function(Uint8List?)? _onDrawn;

  void finish(Uint8List? rgba) {
    final callback = _onDrawn;
    _onDrawn = null;
    callback?.call(rgba);
  }
}
