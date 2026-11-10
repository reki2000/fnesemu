import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:mp_gpu/mp_gpu.dart';

class Ps2FrameRenderer {
  Ps2FrameRenderer._(this._device, this._program, this._spriteProgram);

  static const _source = GpuProgramSource(
    bundle: 'packages/render_frame_gpu/shaders/ps2.shaderbundle',
    vertexEntry: 'Ps2Vertex',
    fragmentEntry: 'Ps2Fragment',
    wgsl: 'packages/render_frame_gpu/shaders/ps2.wgsl',
    attributes: [2, 3],
    bindings: [],
  );

  static const _spriteSource = GpuProgramSource(
    bundle: 'packages/render_frame_gpu/shaders/ps2.shaderbundle',
    vertexEntry: 'Ps2SpriteVertex',
    fragmentEntry: 'Ps2SpriteFragment',
    wgsl: 'packages/render_frame_gpu/shaders/ps2_sprite.wgsl',
    attributes: [2, 2, 3],
    cacheBindGroups: false,
    bindings: [
      GpuBinding.uniform('SpriteInfo', 0),
      GpuBinding.texture('sprite_input', 1),
    ],
  );

  static const _feedbackSource = GpuProgramSource(
    bundle: 'packages/render_frame_gpu/shaders/ps2.shaderbundle',
    vertexEntry: 'Ps2SpriteVertex',
    fragmentEntry: 'Ps2FeedbackFragment',
    wgsl: '',
    attributes: [2, 2, 3],
    bindings: [
      GpuBinding.uniform('FeedbackInfo', 0),
      GpuBinding.texture('first_input', 1),
      GpuBinding.texture('second_input', 3),
    ],
  );

  Future<GpuProgram?>? _feedbackProgram;

  /// The program of the feedback draws, or null on a platform without its
  /// shaders: it has none in WGSL.
  Future<GpuProgram?> feedbackProgram() =>
      _feedbackProgram ??= _device.program(_feedbackSource).then<GpuProgram?>(
          (program) => program, onError: (_) => null);

  static Future<Ps2FrameRenderer> create(GpuDevice device) async =>
      Ps2FrameRenderer._(device, await device.program(_source),
          await device.program(_spriteSource));

  final GpuDevice _device;
  final GpuProgram _program;
  final GpuProgram _spriteProgram;

  /// Draws [frame] into the top rows of [target].
  void draw(Ps2RenderFrame frame, GpuTarget target) {
    if (frame is Ps2SpriteFrame) {
      drawSprites(target, [(frame: frame, x: 0, y: 0, marker: 0)]);
      return;
    }
    final vertices = Float32List(frame.rectangles.length * 6 * 5);
    var offset = 0;

    void rectangle(int left, int top, int right, int bottom, int index) {
      final x0 = 2 * left / target.width - 1;
      final x1 = 2 * right / target.width - 1;
      final y0 = 1 - 2 * top / target.height;
      final y1 = 1 - 2 * bottom / target.height;
      final r = (index & 255) / 255;
      final g = (index >> 8 & 255) / 255;
      final b = (index >> 16 & 255) / 255;
      for (final (x, y) in [(x0, y0), (x1, y0), (x0, y1), (x0, y1), (x1, y0), (x1, y1)]) {
        vertices[offset++] = x;
        vertices[offset++] = y;
        vertices[offset++] = r;
        vertices[offset++] = g;
        vertices[offset++] = b;
      }
    }

    for (final (i, rect) in frame.rectangles.indexed) {
      rectangle(rect.left, rect.top, rect.right, rect.bottom, i + 1);
    }
    final pass = _device.pass(
        target, _program, [if (vertices.isNotEmpty) vertices],
        clearColor: const [0, 0, 0, 1], clearDepth: 0);
    pass.state(const GpuState());
    if (vertices.isNotEmpty) pass.draw(0, vertices.length ~/ 5);
    pass.end();
  }

  /// Draws the sprites of [tiles] at their places in [target]. A tile with
  /// a marker other than zero also gets the marker in the row below it.
  void drawSprites(GpuTarget target, List<Ps2SpriteTile> tiles,
      {GpuTexture? input}) {
    final counts = [for (final tile in tiles) tile.marker == 0 ? 6 : 12];
    final vertices = Float32List(counts.fold(0, (n, c) => n + c) * 7);
    var offset = 0;
    for (final tile in tiles) {
      _spriteQuad(vertices, offset, target, tile, 0, tile.frame.width,
          tile.frame.height, 0);
      offset += 6 * 7;
      if (tile.marker != 0) {
        _spriteQuad(vertices, offset, target, tile,
            tile.frame.height, 1, tile.frame.height + 1, tile.marker);
        offset += 6 * 7;
      }
    }
    final pass = _device.pass(target, _spriteProgram, [vertices],
        clearColor: const [0, 0, 0, 1], clearDepth: 0);
    pass.state(const GpuState());
    var first = 0;
    for (final (i, tile) in tiles.indexed) {
      final frame = tile.frame;
      pass.uniform('SpriteInfo', ByteData.sublistView(frame.state));
      pass.texture('sprite_input', input ??
          _device.texture(frame.inputWidth, frame.inputHeight, frame.input));
      pass.draw(first, counts[i]);
      first += counts[i];
    }
    pass.end();
  }

  // The first draw feeds a patch of the texture for the second draw.
  // Compose the two valid row ranges into the only CPU readback target.
  // The rows of the frame and a marker row below them, the size of the
  // intermediate targets, go to the top of [output]. [scratch] gives the
  // intermediate targets.
  void drawFeedback(GpuProgram program, Ps2SpriteFrame frame, GpuTarget output,
      {required GpuTarget Function(int width, int height) scratch,
      required int split, required int left, required int top,
      required int colorMask, required bool forceAlpha,
      required int firstMarker, required int secondMarker}) {
    final width = frame.width, height = frame.height + 1;
    final input = _device.texture(frame.inputWidth, frame.inputHeight, frame.input);
    final first = scratch(width, height);
    final patched = scratch(input.width, input.height);
    final second = scratch(width, height);
    final firstTile = (frame: frame, x: 0, y: 0, marker: firstMarker);
    final secondTile = (frame: frame, x: 0, y: 0, marker: secondMarker);
    final data = Float32List.fromList([
      width.toDouble(), height.toDouble(),
      input.width.toDouble(), input.height.toDouble(),
      left.toDouble(), top.toDouble(), split.toDouble(), 0,
      for (var shift = 0; shift < 32; shift += 8)
        (colorMask >> shift & 255).toDouble(),
      for (var shift = 0; shift < 24; shift += 8)
        (firstMarker >> shift & 255).toDouble(),
      frame.state[28],
      for (var shift = 0; shift < 24; shift += 8)
        (secondMarker >> shift & 255).toDouble(),
      frame.state[29],
    ]);
    drawSprites(first, [firstTile], input: input);
    _feedbackPass(program, patched, firstTile, first.colorTexture, input, data,
        patched.height, forceAlpha ? 255 : 0);
    drawSprites(second, [secondTile], input: patched.colorTexture);
    data[7] = 1;
    _feedbackPass(program, output, firstTile, first.colorTexture,
        second.colorTexture, data, height, 0);
  }

  void _feedbackPass(GpuProgram program, GpuTarget output, Ps2SpriteTile tile,
      GpuTexture first, GpuTexture second, Float32List info, int height,
      int marker) {
    final vertices = Float32List(6 * 7);
    _spriteQuad(vertices, 0, output, tile, 0, output.width, height, marker);
    final pass = _device.pass(output, program, [vertices],
        clearColor: const [0, 0, 0, 0], clearDepth: 0);
    pass.uniform('FeedbackInfo', ByteData.sublistView(info));
    pass.texture('first_input', first);
    pass.texture('second_input', second);
    pass.state(const GpuState());
    pass.draw(0, 6);
    pass.end();
  }

  void _spriteQuad(Float32List vertices, int offset, GpuTarget target,
      Ps2SpriteTile tile, int top, int right, int bottom, int marker) {
    for (final (x, y) in [
      (0, top), (right, top), (0, bottom),
      (0, bottom), (right, top), (right, bottom),
    ]) {
      vertices[offset++] = 2 * (x + tile.x) / target.width - 1;
      vertices[offset++] = 1 - 2 * (y + tile.y) / target.height;
      vertices[offset++] = x.toDouble();
      vertices[offset++] = y.toDouble();
      vertices[offset++] = (marker & 255) / 255;
      vertices[offset++] = (marker >> 8 & 255) / 255;
      vertices[offset++] = (marker >> 16 & 255) / 255;
    }
  }
}

typedef Ps2SpriteTile = ({Ps2SpriteFrame frame, int x, int y, int marker});
