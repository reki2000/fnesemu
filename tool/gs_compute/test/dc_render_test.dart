// Runs the DC renderer tests of the core with the compute program of
// dc_compute.dart attached to every renderer that they make, so that the
// tiles are shaded on the GPU.
//
// The tests are imported from their directory, as they are not in a
// library of fnesemu_core.
import 'package:fnesemu_core/src/core/dc/dc_compute.dart';
import 'package:fnesemu_core/src/core/dc/gpu_render.dart';
import 'package:gs_compute_check/sink.dart';
import 'package:test/test.dart';

import '../../../packages/fnesemu_core/test/core/dc/gpu_background_test.dart'
    as gpu_background;
import '../../../packages/fnesemu_core/test/core/dc/gpu_bump_test.dart'
    as gpu_bump;
import '../../../packages/fnesemu_core/test/core/dc/gpu_fog_test.dart'
    as gpu_fog;
import '../../../packages/fnesemu_core/test/core/dc/gpu_mipmap_test.dart'
    as gpu_mipmap;
import '../../../packages/fnesemu_core/test/core/dc/gpu_modifier_test.dart'
    as gpu_modifier;
import '../../../packages/fnesemu_core/test/core/dc/gpu_palette_test.dart'
    as gpu_palette;
import '../../../packages/fnesemu_core/test/core/dc/gpu_secondary_test.dart'
    as gpu_secondary;
import '../../../packages/fnesemu_core/test/core/dc/gpu_sort_test.dart'
    as gpu_sort;
import '../../../packages/fnesemu_core/test/core/dc/gpu_sprite_test.dart'
    as gpu_sprite;
import '../../../packages/fnesemu_core/test/core/dc/gpu_supersample_test.dart'
    as gpu_supersample;
import '../../../packages/fnesemu_core/test/core/dc/gpu_ta_test.dart' as gpu_ta;
import '../../../packages/fnesemu_core/test/core/dc/gpu_test.dart' as gpu;
import '../../../packages/fnesemu_core/test/core/dc/gpu_texture_path_test.dart'
    as gpu_texture_path;
import '../../../packages/fnesemu_core/test/core/dc/gpu_texture_test.dart'
    as gpu_texture;
import '../../../packages/fnesemu_core/test/core/dc/gpu_trilinear_test.dart'
    as gpu_trilinear;
import '../../../packages/fnesemu_core/test/core/dc/gpu_two_volume_test.dart'
    as gpu_two_volume;
import '../../../packages/fnesemu_core/test/core/dc/gpu_vq_test.dart' as gpu_vq;
import '../../../packages/fnesemu_core/test/core/dc/gpu_yuv_test.dart'
    as gpu_yuv;

void main() {
  final sink = WgpuComputeSink.open();
  if (sink == null) {
    test('the DC renderer tests on the GPU', () {}, skip: 'no adapter');
    return;
  }
  DcCompute? first;
  DcGpuRender.created = (render) {
    final base = first ??= DcCompute(sink, render.memory);
    // The tests read VRAM directly, so the tiles are written at once.
    render
      ..compute = base.share(render.memory)
      ..deferTiles = false;
  };
  group('gpu_background', gpu_background.main);
  group('gpu_bump', gpu_bump.main);
  group('gpu_fog', gpu_fog.main);
  group('gpu_mipmap', gpu_mipmap.main);
  group('gpu_modifier', gpu_modifier.main);
  group('gpu_palette', gpu_palette.main);
  group('gpu_secondary', gpu_secondary.main);
  group('gpu_sort', gpu_sort.main);
  group('gpu_sprite', gpu_sprite.main);
  group('gpu_supersample', gpu_supersample.main);
  group('gpu_ta', gpu_ta.main);
  group('gpu', gpu.main);
  group('gpu_texture_path', gpu_texture_path.main);
  group('gpu_texture', gpu_texture.main);
  group('gpu_trilinear', gpu_trilinear.main);
  group('gpu_two_volume', gpu_two_volume.main);
  group('gpu_vq', gpu_vq.main);
  group('gpu_yuv', gpu_yuv.main);
}
