import 'dart:typed_data';

import 'render_frame.dart';

/// An ordered batch of opaque GS rectangles, relative to the target origin.
/// Right and bottom are exclusive. The GS keeps the actual pixel colors.
class Ps2RenderFrame {
  const Ps2RenderFrame(this.width, this.height, this.rectangles);

  final int width, height;
  final List<({int left, int top, int right, int bottom})> rectangles;
}

/// One textured sprite. The output has two adjacent planes of equal width.
/// The first holds RGB. The second holds GS alpha in R, the color write
/// mode in G (0, 1, or 2 to keep alpha), and the depth write flag in B.
class Ps2SpriteFrame extends Ps2RenderFrame {
  Ps2SpriteFrame(int width, int height, this.inputWidth, this.inputHeight,
      this.input, this.state, {this.planes = 2})
      : super(width * planes, height, const []);

  final int inputWidth, inputHeight, planes;
  final Uint8List input;

  /// Seven vec4 blocks for size, depth, color, texturing, blending, tests
  /// and writes, in the order used by the sprite shaders.
  final Float32List state;
}

abstract interface class Ps2RenderFrameSink implements RenderFrameSink {
  /// Returns RGBA coverage with a one-based rectangle index in the RGB
  /// bytes (least significant byte first), or zero for untouched pixels.
  /// A [Ps2SpriteFrame] instead returns the two planes described by its type.
  /// Returns null if the batch could not be drawn or read back.
  Future<Uint8List?> drawPs2(Ps2RenderFrame frame);
}
