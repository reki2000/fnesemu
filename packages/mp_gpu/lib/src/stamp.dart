import 'gpu.dart';

/// A device whose passes can end with a stamp: a draw of a number into the
/// last row of the target, which a read then checks. Only the Flutter GPU
/// backend implements it; WebGPU reads what the passes drew.
abstract interface class GpuStamping {
  /// Whether the stamp program loaded.
  bool get stamps;

  /// Ends a pass that clears [target] and draws only its stamp.
  void stampOnly(GpuTarget target);
}

/// The stamp of each target, a number from 1 to 0xffffff, which every pass
/// into the target draws into its last row. A target without one is drawn
/// as it is.
final targetStamps = Expando<int>();

/// The shaders of the device check and the stamps: a texture times a color,
/// with x and y in clip space and u and v.
const checkSource = GpuProgramSource(
  bundle: 'packages/mp_gpu/shaders/check.shaderbundle',
  vertexEntry: 'CheckVertex',
  fragmentEntry: 'CheckFragment',
  wgsl: '',
  attributes: [2, 2],
  bindings: [GpuBinding.uniform('Info', 0), GpuBinding.texture('image', 1)],
);
