import 'dart:typed_data';

import 'unsupported.dart'
    if (dart.library.js_interop) 'web.dart'
    if (dart.library.io) 'native.dart'
    as backend;

/// The GPU of the platform, for offscreen drawing: Flutter GPU on native
/// platforms and WebGPU on the Web.
///
/// A [GpuPass] draws triangles into a [GpuTarget], and [read] returns its
/// pixels. The draw state is set per draw as in [GpuState]; a backend with
/// fixed pipelines keeps one for each state.
abstract class GpuDevice {
  /// The GPU of the platform, or null when it is not available.
  static Future<GpuDevice?> create() => backend.createDevice();

  /// The name of the API, for settings and logs.
  String get name;

  /// Whether the depth buffers of targets have a stencil.
  bool get stencil;

  /// Loads the shaders of [source] for this platform.
  Future<GpuProgram> program(GpuProgramSource source);

  /// A texture of [width] x [height] with the RGBA bytes [rgba], row by row
  /// from the top.
  GpuTexture texture(int width, int height, Uint8List rgba);

  /// A color target of [width] x [height] with a depth and stencil buffer.
  GpuTarget target(int width, int height);

  /// Starts a pass that clears [target] and then draws triangles of the
  /// vertex arrays [vertices] with [program]. [clearColor] holds red,
  /// green, blue and alpha in 0 to 1. The stencil is cleared to 0.
  GpuPass pass(
    GpuTarget target,
    GpuProgram program,
    List<Float32List> vertices, {
    required List<double> clearColor,
    required double clearDepth,
  });

  /// Waits until the passes ended so far can be read. Call it once after
  /// ending a group of passes, not once per pass.
  Future<void> settle();

  /// The RGBA bytes of [target], row by row from the top, as the passes
  /// ended before the last [settle] left it, or null when it cannot be read.
  Future<Uint8List?> read(GpuTarget target);
}

/// The shaders of a program for each platform and how their inputs are
/// laid out.
class GpuProgramSource {
  const GpuProgramSource({
    required this.bundle,
    required this.vertexEntry,
    required this.fragmentEntry,
    required this.wgsl,
    required this.attributes,
    required this.bindings,
  });

  /// The asset of the shader bundle for Flutter GPU, and the names of the
  /// vertex and the fragment shader in it.
  final String bundle, vertexEntry, fragmentEntry;

  /// The asset of the WGSL source for WebGPU, with the entry points
  /// `vertex_main` and `fragment_main` and all bindings in group 0.
  final String wgsl;

  /// The number of floats of each vertex attribute, in the order of their
  /// locations. The attributes of a vertex follow each other.
  final List<int> attributes;

  /// The uniform blocks and textures of the shaders.
  final List<GpuBinding> bindings;
}

/// A uniform block or a texture of a program. [name] is the name in the
/// shaders for Flutter GPU, [binding] the binding in the WGSL source. The
/// sampler of a texture takes the next binding.
class GpuBinding {
  const GpuBinding.uniform(this.name, this.binding, {this.vertex = false})
    : texture = false;
  const GpuBinding.texture(this.name, this.binding)
    : texture = true,
      vertex = false;

  final String name;
  final int binding;
  final bool texture;

  /// Whether the vertex shader uses it; otherwise the fragment shader does.
  final bool vertex;
}

/// Loaded shaders; see [GpuDevice.program].
abstract class GpuProgram {}

/// A texture to sample; see [GpuDevice.texture].
abstract class GpuTexture {
  int get width;
  int get height;
}

/// A color target with its depth and stencil buffer; see
/// [GpuDevice.target].
abstract class GpuTarget {
  int get width;
  int get height;
}

/// Draws into a target; see [GpuDevice.pass].
abstract class GpuPass {
  /// Sets the uniform block [name] of the next draws to [data].
  void uniform(String name, ByteData data);

  /// Sets the texture [name] of the next draws.
  void texture(
    String name,
    GpuTexture texture, [
    GpuSampler sampler = const GpuSampler(),
  ]);

  /// Sets the state of the next draws.
  void state(GpuState state);

  /// Sets the stencil reference of the next draws.
  void stencilReference(int value);

  /// Draws the triangles of [count] vertices from vertex [first] of the
  /// vertex array [array] of the pass.
  void draw(int first, int count, [int array = 0]);

  /// Ends the pass and submits it. [onComplete] is called when the GPU has
  /// run it, with whether it succeeded.
  void end({void Function(bool success)? onComplete});
}

/// How a texture is sampled.
class GpuSampler {
  const GpuSampler({
    this.linear = false,
    this.addressU = GpuAddress.clamp,
    this.addressV = GpuAddress.clamp,
  });

  final bool linear;
  final GpuAddress addressU, addressV;

  int get key => (linear ? 1 : 0) | addressU.index << 1 | addressV.index << 3;
}

enum GpuAddress { repeat, mirror, clamp }

enum GpuCompare {
  never,
  less,
  equal,
  lessEqual,
  greater,
  notEqual,
  greaterEqual,
  always,
}

enum GpuBlendFactor {
  zero,
  one,
  sourceColor,
  oneMinusSourceColor,
  sourceAlpha,
  oneMinusSourceAlpha,
  destinationColor,
  oneMinusDestinationColor,
  destinationAlpha,
  oneMinusDestinationAlpha,
}

enum GpuStencilOperation { keep, zero, replace, invert }

/// The state of draws: blending, the depth test and the stencil test. Back
/// faces are drawn too. The stencil operation applies where both tests
/// pass; elsewhere the stencil is kept.
class GpuState {
  const GpuState({
    this.blend = false,
    this.sourceFactor = GpuBlendFactor.one,
    this.destinationFactor = GpuBlendFactor.zero,
    this.depthCompare = GpuCompare.always,
    this.depthWrite = false,
    this.stencilCompare = GpuCompare.always,
    this.stencilOperation = GpuStencilOperation.keep,
    this.stencilReadMask = 0xff,
    this.stencilWriteMask = 0xff,
  });

  /// Whether the color blends with [sourceFactor] and [destinationFactor],
  /// the same for the alpha.
  final bool blend;
  final GpuBlendFactor sourceFactor, destinationFactor;
  final GpuCompare depthCompare;
  final bool depthWrite;
  final GpuCompare stencilCompare;
  final GpuStencilOperation stencilOperation;
  final int stencilReadMask, stencilWriteMask;

  /// A number that differs between different states.
  int get key =>
      (blend ? 1 : 0) |
      sourceFactor.index << 1 |
      destinationFactor.index << 5 |
      depthCompare.index << 9 |
      (depthWrite ? 1 : 0) << 12 |
      stencilCompare.index << 13 |
      stencilOperation.index << 16 |
      (stencilReadMask & 0xff) << 18 |
      (stencilWriteMask & 0xff) << 26;
}
