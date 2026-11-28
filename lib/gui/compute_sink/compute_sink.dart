// Opens the compute GPU that the app gives the cores as a ComputeSink:
// wgpu-native through mp_compute on native platforms, and WebGPU on the
// Web.
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:mp_compute/mp_compute.dart' as mpc;

/// Makes [computeAdapters] and [openComputeSink] ready; on the Web, it
/// opens the GPU.
Future<void> prepareComputeSink() => mpc.ComputeDevice.prepare();

/// The descriptions of the GPUs, for [openComputeSink].
List<String> computeAdapters() => mpc.ComputeDevice.adapterList();

/// Opens the GPU whose description contains [adapter], or the first discrete
/// GPU (else the first adapter) when [adapter] is empty. Returns null and
/// tells [onError] why if it cannot. The cores that do not use compute
/// programs draw their frames by themselves.
ComputeSink? openComputeSink(
    {String adapter = '', void Function(String reason)? onError}) {
  final device = mpc.ComputeDevice.open(adapter: adapter, onError: onError);
  return device == null ? null : _WgpuComputeSink(device);
}

/// Closes a sink of [openComputeSink] that no core uses any more.
void closeComputeSink(ComputeSink sink) {
  if (sink is _WgpuComputeSink) sink._device.close();
}

class _WgpuComputeSink implements ComputeSink {
  _WgpuComputeSink(this._device);

  final mpc.ComputeDevice _device;

  @override
  String get name => _device.name;

  @override
  bool get waits => _device.waits;

  @override
  ComputeProgram program(
          String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
          {required int paramStride, required int maxDispatches}) =>
      _Program(_device.program(
          wgsl,
          entryPoints,
          [
            for (final b in bindings)
              mpc.ComputeBinding(
                  mpc.ComputeBindingKind.values[b.kind.index], b.bytes)
          ],
          paramStride: paramStride,
          maxDispatches: maxDispatches));
}

class _Program implements ComputeProgram {
  _Program(this._program);

  final mpc.ComputeProgram _program;

  @override
  void write(int binding, int byteOffset, Uint32List words,
          [int start = 0, int? end]) =>
      _program.write(binding, byteOffset, words, start, end);

  @override
  void run(Uint32List dispatches, int count, Uint32List params,
          {bool wait = true}) =>
      _program.run(dispatches, count, params, wait: wait);

  @override
  void prefetch(int binding, int byteOffset, int bytes) =>
      _program.prefetch(binding, byteOffset, bytes);

  @override
  Future<void>? get fetching => _program.fetching;

  @override
  void read(int binding, int byteOffset, Uint32List target) =>
      _program.read(binding, byteOffset, target);

  @override
  void dispose() => _program.dispose();
}
