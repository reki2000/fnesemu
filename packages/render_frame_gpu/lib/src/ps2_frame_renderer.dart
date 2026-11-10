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

  Future<GpuProgram>? _feedbackProgram;

  Future<GpuProgram> feedbackProgram() =>
      _feedbackProgram ??= _device.program(_feedbackSource);

  static Future<Ps2FrameRenderer> create(GpuDevice device) async =>
      Ps2FrameRenderer._(device, await device.program(_source),
          await device.program(_spriteSource));

  final GpuDevice _device;
  final GpuProgram _program;
  final GpuProgram _spriteProgram;

  void draw(Ps2RenderFrame frame, GpuTarget target, int marker) {
    if (frame is Ps2SpriteFrame) {
      _drawSprite(frame, target, marker);
      return;
    }
    final vertices = Float32List((frame.rectangles.length + 1) * 6 * 5);
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
    // The extra row distinguishes this readback from an older use of the target.
    rectangle(0, frame.height, 1, frame.height + 1, marker);
    final pass = _device.pass(target, _program, [vertices],
        clearColor: const [0, 0, 0, 1], clearDepth: 0);
    pass.state(const GpuState());
    pass.draw(0, vertices.length ~/ 5);
    pass.end();
  }

  void _drawSprite(Ps2SpriteFrame frame, GpuTarget target, int marker) {
    drawSprites(target, [(frame: frame, x: 0, y: 0, marker: marker)]);
  }

  void drawSprites(GpuTarget target, List<Ps2SpriteTile> tiles,
      {GpuTexture? input}) {
    final vertices = Float32List(tiles.length * 12 * 7);
    var offset = 0;
    for (final tile in tiles) {
      _spriteQuad(vertices, offset, target, tile, 0, tile.frame.width,
          tile.frame.height, 0);
      _spriteQuad(vertices, offset + 6 * 7, target, tile,
          tile.frame.height, 1, tile.frame.height + 1, tile.marker);
      offset += 12 * 7;
    }
    final pass = _device.pass(target, _spriteProgram, [vertices],
        clearColor: const [0, 0, 0, 1], clearDepth: 0);
    pass.state(const GpuState());
    for (final (i, tile) in tiles.indexed) {
      final frame = tile.frame;
      pass.uniform('SpriteInfo', ByteData.sublistView(frame.state));
      pass.texture('sprite_input', input ??
          _device.texture(frame.inputWidth, frame.inputHeight, frame.input));
      pass.draw(i * 12, 12);
    }
    pass.end();
  }

  // The first draw feeds a patch of the texture for the second draw.
  // Compose the two valid row ranges into the only CPU readback target.
  void drawFeedback(GpuProgram program, Ps2SpriteFrame frame, GpuTarget output,
      {required int split, required int left, required int top,
      required int colorMask, required bool forceAlpha,
      required int firstMarker, required int secondMarker}) {
    final input = _device.texture(frame.inputWidth, frame.inputHeight, frame.input);
    final first = _device.target(output.width, output.height);
    final patched = _device.target(input.width, input.height);
    final second = _device.target(output.width, output.height);
    final firstTile = (frame: frame, x: 0, y: 0, marker: firstMarker);
    final secondTile = (frame: frame, x: 0, y: 0, marker: secondMarker);
    final data = Float32List.fromList([
      output.width.toDouble(), output.height.toDouble(),
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
        forceAlpha ? 255 : 0);
    drawSprites(second, [secondTile], input: patched.colorTexture);
    data[7] = 1;
    _feedbackPass(program, output, firstTile, first.colorTexture,
        second.colorTexture, data, 0);
  }

  void _feedbackPass(GpuProgram program, GpuTarget output, Ps2SpriteTile tile,
      GpuTexture first, GpuTexture second, Float32List info, int marker) {
    final vertices = Float32List(6 * 7);
    _spriteQuad(vertices, 0, output, tile, 0, output.width, output.height, marker);
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
