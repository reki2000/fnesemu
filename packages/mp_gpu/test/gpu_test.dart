import 'package:flutter_test/flutter_test.dart';
import 'package:mp_gpu/mp_gpu.dart';

void main() {
  test('states that differ in one field have different keys', () {
    const base = GpuState();
    final states = [
      base,
      const GpuState(blend: true),
      const GpuState(sourceFactor: GpuBlendFactor.oneMinusDestinationAlpha),
      const GpuState(
        destinationFactor: GpuBlendFactor.oneMinusDestinationAlpha,
      ),
      const GpuState(depthCompare: GpuCompare.never),
      const GpuState(depthWrite: true),
      const GpuState(stencilCompare: GpuCompare.never),
      const GpuState(stencilOperation: GpuStencilOperation.invert),
      const GpuState(stencilReadMask: 0x7f),
      const GpuState(stencilWriteMask: 0x7f),
      const GpuState(operation: GpuBlendOperation.reverseSubtract),
      const GpuState(alphaOperation: GpuBlendOperation.add),
      const GpuState(sourceAlphaFactor: GpuBlendFactor.zero),
      const GpuState(destinationAlphaFactor: GpuBlendFactor.zero),
      const GpuState(cull: GpuCull.back),
    ];
    expect({for (final s in states) s.key}, hasLength(states.length));
  });

  test('samplers that differ in one field have different keys', () {
    const samplers = [
      GpuSampler(),
      GpuSampler(linear: true),
      GpuSampler(addressU: GpuAddress.mirror),
      GpuSampler(addressV: GpuAddress.mirror),
    ];
    expect({for (final s in samplers) s.key}, hasLength(samplers.length));
  });
}
