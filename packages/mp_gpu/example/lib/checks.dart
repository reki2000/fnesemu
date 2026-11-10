// Checks of the mp_gpu features beyond the read-back waits, for the cores
// that are to draw on the GPU next.
//
// `features` draws with each feature into a small target and compares the
// pixels with what the feature should give. `vram` keeps an image of video
// memory in a texture, as a core could keep the memory of a PS2 (4 MB) or a
// DC (8 MB) on the GPU, and reads it in a shader by addresses that it
// computes: it checks that every texel comes back exactly and times the
// upload of the whole image and the draws.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mp_gpu/mp_gpu.dart';

const _probeSource = GpuProgramSource(
  bundle: 'shaders/probe.shaderbundle',
  vertexEntry: 'ProbeVertex',
  fragmentEntry: 'ProbeFragment',
  wgsl: 'shaders/probe.wgsl',
  attributes: [2, 2],
  bindings: [GpuBinding.uniform('Info', 0), GpuBinding.texture('image', 1)],
);

const _vramSource = GpuProgramSource(
  bundle: 'shaders/probe.shaderbundle',
  vertexEntry: 'ProbeVertex',
  fragmentEntry: 'VramFragment',
  wgsl: 'shaders/vram.wgsl',
  attributes: [2, 2],
  cacheBindGroups: false,
  bindings: [GpuBinding.uniform('VramInfo', 0), GpuBinding.texture('vram', 1)],
);

String get _platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

ByteData _floats(List<double> values) =>
    ByteData.sublistView(Float32List.fromList(values));

/// A rectangle of two triangles from ([x0], [y0]) to ([x1], [y1]) in clip
/// space, both counter clockwise, with u and v from [u0], [v0] to [u1],
/// [v1].
List<double> _rectangle(
  double x0,
  double y0,
  double x1,
  double y1, [
  double u0 = 0,
  double v0 = 0,
  double u1 = 0,
  double v1 = 0,
]) => [
  x0, y0, u0, v0, x1, y0, u1, v0, x1, y1, u1, v1, //
  x0, y0, u0, v0, x1, y1, u1, v1, x0, y1, u0, v1,
];

/// Draws with each feature and returns one result per feature: whether the
/// pixels were right, and the pixels that were read.
Future<Map<String, Object?>> checkFeatures(GpuDevice device) async {
  final queue = await GpuQueue.create(device);
  if (queue == null) return {'error': 'no queue'};
  final program = await device.program(_probeSource);
  const size = 16;
  final white = device.texture(1, 1, Uint8List.fromList([255, 255, 255, 255]));
  final whole = Float32List.fromList(_rectangle(-1, -1, 1, 1));
  final left = Float32List.fromList(_rectangle(-1, -1, 0, 1));

  // The RGBA bytes of pixel ([x], [y]) from the top left.
  List<int> at(Uint8List rgba, int x, int y) {
    final i = (y * size + x) * 4;
    return rgba.sublist(i, i + 4);
  }

  bool near(List<int> pixel, List<int> expected) {
    for (var i = 0; i < 4; i++) {
      if ((pixel[i] - expected[i]).abs() > 2) return false;
    }
    return true;
  }

  // Draws a job and checks the pixels at [points] against their colors.
  Future<Map<String, Object?>> check(
    void Function(GpuTarget target) draw,
    Map<(int, int), List<int>> points,
  ) async {
    final rgba = await queue.render(size, size, draw);
    if (rgba == null) return {'ok': false, 'read': null};
    final read = {for (final (x, y) in points.keys) '$x,$y': at(rgba, x, y)};
    final ok = points.entries.every(
      (e) => near(at(rgba, e.key.$1, e.key.$2), e.value),
    );
    return {'ok': ok, 'read': read};
  }

  // A pass over [target] that clears it to [clear] and draws [vertices]
  // with [color] in [state].
  void fill(
    GpuTarget target,
    List<double>? clear,
    Float32List vertices,
    List<double> color,
    GpuState state, {
    void Function(GpuPass pass)? before,
  }) {
    final pass = device.pass(
      target,
      program,
      [vertices],
      clearColor: clear,
      clearDepth: 1,
    );
    pass.uniform('Info', _floats(color));
    pass.texture('image', white);
    pass.state(state);
    before?.call(pass);
    pass.draw(0, vertices.length ~/ 4);
    pass.end();
  }

  const grey = [0.5, 0.5, 0.5, 0.5];
  final results = <String, Object?>{
    // 0.75 - 0.5 on the color; the alpha adds.
    'subtract': await check(
      (t) => fill(
        t,
        grey,
        whole,
        [0.75, 0.75, 0.75, 0.25],
        const GpuState(
          blend: true,
          destinationFactor: GpuBlendFactor.one,
          operation: GpuBlendOperation.subtract,
          alphaOperation: GpuBlendOperation.add,
        ),
      ),
      {
        (8, 8): [64, 64, 64, 191],
      },
    ),
    // 0.5 - 0.25.
    'reverseSubtract': await check(
      (t) => fill(
        t,
        grey,
        whole,
        [0.25, 0.25, 0.25, 0.25],
        const GpuState(
          blend: true,
          destinationFactor: GpuBlendFactor.one,
          operation: GpuBlendOperation.reverseSubtract,
        ),
      ),
      {
        (8, 8): [64, 64, 64, 64],
      },
    ),
    // The color replaces, the alpha keeps the target's.
    'alphaFactors': await check(
      (t) => fill(
        t,
        grey,
        whole,
        [1, 0, 0, 1],
        const GpuState(
          blend: true,
          sourceAlphaFactor: GpuBlendFactor.zero,
          destinationAlphaFactor: GpuBlendFactor.one,
        ),
      ),
      {
        (8, 8): [255, 0, 0, 128],
      },
    ),
    // Only the 8 x 8 pixels at 4, 4 from the top left.
    'scissor': await check(
      (t) => fill(
        t,
        const [0, 0, 1, 1],
        whole,
        [1, 0, 0, 1],
        const GpuState(),
        before: (pass) => pass.scissor(4, 4, 8, 8),
      ),
      {
        (2, 2): [0, 0, 255, 255],
        (5, 5): [255, 0, 0, 255],
        (11, 6): [255, 0, 0, 255],
        (13, 13): [0, 0, 255, 255],
        (6, 1): [0, 0, 255, 255],
      },
    ),
    // The left half goes counter clockwise and is kept; the right half goes
    // clockwise and is culled.
    'cullBack': await check(
      (t) => fill(
        t,
        const [0, 0, 1, 1],
        Float32List.fromList([
          ..._rectangle(-1, -1, 0, 1),
          // Clockwise.
          0, -1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, //
          0, -1, 0, 0, 1, 1, 0, 0, 1, -1, 0, 0,
        ]),
        [1, 0, 0, 1],
        const GpuState(cull: GpuCull.back),
      ),
      {
        (4, 8): [255, 0, 0, 255],
        (12, 8): [0, 0, 255, 255],
      },
    ),
    // Four corners and six indices.
    'indexed': await check(
      (t) {
        final pass = device.pass(
          t,
          program,
          [
            Float32List.fromList([
              -1, -1, 0, 0, 1, -1, 0, 0, 1, 1, 0, 0, -1, 1, 0, 0, //
            ]),
          ],
          clearColor: const [0, 0, 1, 1],
          clearDepth: 1,
          indices: [
            Uint32List.fromList([0, 1, 2, 0, 2, 3]),
          ],
        );
        pass.uniform('Info', _floats([0, 1, 0, 1]));
        pass.texture('image', white);
        pass.drawIndexed(0, 6);
        pass.end();
      },
      {
        (2, 2): [0, 255, 0, 255],
        (13, 13): [0, 255, 0, 255],
      },
    ),
    // A second pass that keeps the colors of the first.
    'load': await check(
      (t) {
        fill(t, const [0, 0, 1, 1], whole, [0, 0, 1, 1], const GpuState());
        fill(t, null, left, [1, 0, 0, 1], const GpuState());
      },
      {
        (4, 8): [255, 0, 0, 255],
        (12, 8): [0, 0, 255, 255],
      },
    ),
    // A texture written again after it was made.
    'overwrite': await check(
      (t) {
        final texture = device.texture(
          1,
          1,
          Uint8List.fromList([255, 0, 0, 255]),
        )..overwrite(Uint8List.fromList([0, 255, 0, 255]));
        final pass = device.pass(
          t,
          program,
          [whole],
          clearColor: const [0, 0, 1, 1],
          clearDepth: 1,
        );
        pass.uniform('Info', _floats([1, 1, 1, 1]));
        pass.texture('image', texture);
        pass.draw(0, 6);
        pass.end();
      },
      {
        (8, 8): [0, 255, 0, 255],
      },
    ),
  };
  return {'platform': _platform, 'device': device.name, ...results};
}

/// Keeps an image of [width] x [height] words in a texture and reads it
/// back through the shader of `vram.frag`, [rounds] times.
Future<Map<String, Object?>> checkVram(
  GpuDevice device,
  int width,
  int height, {
  int rounds = 20,
}) async {
  final result = <String, Object?>{
    'platform': _platform,
    'device': device.name,
    'words': '${width}x$height',
    'mb': width * height * 4 / (1 << 20),
  };
  final queue = await GpuQueue.create(device);
  if (queue == null) return {...result, 'error': 'no queue'};
  final program = await device.program(_vramSource);
  // The pixels of one draw: 512 x 512 words, from the first word and from
  // the last 512 x 512 words of the image.
  const out = 512;
  final random = Random(7);
  final image = Uint8List(width * height * 4);
  for (var i = 0; i < image.length; i++) {
    image[i] = random.nextInt(256);
  }
  final GpuTexture texture;
  final create = Stopwatch()..start();
  try {
    texture = device.texture(width, height, image);
  } catch (e) {
    return {...result, 'error': 'texture: $e'};
  }
  create.stop();

  // The word that pixel ([x], [y]) reads, as in vram.frag.
  int address(int x, int y, int base) {
    var a = 0;
    for (var i = 0; i < 11; i++) {
      a |= (x >> i & 1) << 2 * i | (y >> i & 1) << 2 * i + 1;
    }
    return a + base;
  }

  // Draws from word [base] and returns the number of wrong pixels, or 0
  // without [verify]; null when the pixels did not come back.
  Future<int?> draw(int base, {bool verify = true}) async {
    final rgba = await queue.render(out, out, (target) {
      // The top [out] rows: the queue may add a row below them.
      final bottom = 1 - 2 * out / target.height;
      final vertices = Float32List.fromList(
        _rectangle(-1, bottom, 1, 1, 0, out.toDouble(), out.toDouble(), 0),
      );
      final pass = device.pass(
        target,
        program,
        [vertices],
        clearColor: const [0, 0, 0, 0],
        clearDepth: 1,
      );
      pass.uniform(
        'VramInfo',
        _floats([width.toDouble(), height.toDouble(), base.toDouble(), 0]),
      );
      pass.texture('vram', texture);
      pass.draw(0, 6);
      pass.end();
    });
    if (rgba == null) return null;
    if (!verify) return 0;
    var wrong = 0;
    for (var y = 0; y < out; y++) {
      for (var x = 0; x < out; x++) {
        final word = address(x, y, base) * 4, pixel = (y * out + x) * 4;
        for (var k = 0; k < 4; k++) {
          if (rgba[pixel + k] != image[word + k]) {
            wrong++;
            break;
          }
        }
      }
    }
    return wrong;
  }

  // Exact reads at the start and at the end of the image.
  final last = width * height - out * out;
  result['wrongFirst'] = await draw(0);
  result['wrongLast'] = await draw(last);
  result['createMs'] = create.elapsedMicroseconds / 1000;

  // Each round writes the whole image and draws once from it.
  final upload = <double>[], total = <double>[];
  var nulls = 0;
  for (var i = 0; i < rounds; i++) {
    image[0] = i;
    final watch = Stopwatch()..start();
    texture.overwrite(image);
    upload.add(watch.elapsedMicroseconds / 1000);
    if (await draw(0, verify: false) == null) nulls++;
    total.add(watch.elapsedMicroseconds / 1000);
  }
  upload.sort();
  total.sort();
  texture.dispose();
  return {
    ...result,
    'uploadMsP50': upload[upload.length ~/ 2].toStringAsFixed(2),
    'roundMsP50': total[total.length ~/ 2].toStringAsFixed(2),
    'roundNulls': nulls,
  };
}
