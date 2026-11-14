// A ComputeSink of the core on mp_compute.
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart' as core;
import 'package:mp_compute/mp_compute.dart';

class WgpuComputeSink implements core.ComputeSink {
  WgpuComputeSink(this.device);

  final ComputeDevice device;

  /// a sink on the first adapter whose description contains [adapter]
  static WgpuComputeSink? open({String adapter = ''}) {
    final device = ComputeDevice.open(
      adapter: adapter,
      onError: (reason) => print('compute: $reason'),
    );
    return device == null ? null : WgpuComputeSink(device);
  }

  @override
  String get name => device.name;

  @override
  bool get waits => device.waits;

  @override
  core.ComputeProgram program(
    String wgsl,
    List<String> entryPoints,
    List<core.ComputeBinding> bindings, {
    required int paramStride,
    required int maxDispatches,
  }) => _Program(
    device.program(
      wgsl,
      entryPoints,
      [
        for (final b in bindings)
          ComputeBinding(ComputeBindingKind.values[b.kind.index], b.bytes),
      ],
      paramStride: paramStride,
      maxDispatches: maxDispatches,
    ),
  );
}

class _Program implements core.ComputeProgram {
  _Program(this.program);

  final ComputeProgram program;

  @override
  void write(
    int binding,
    int byteOffset,
    Uint32List words, [
    int start = 0,
    int? end,
  ]) => program.write(binding, byteOffset, words, start, end);

  @override
  void run(
    Uint32List dispatches,
    int count,
    Uint32List params, {
    bool wait = true,
  }) => program.run(dispatches, count, params, wait: wait);

  @override
  void prefetch(int binding, int byteOffset, int bytes) =>
      program.prefetch(binding, byteOffset, bytes);

  @override
  Future<void>? get fetching => program.fetching;

  @override
  void read(int binding, int byteOffset, Uint32List target) =>
      program.read(binding, byteOffset, target);

  @override
  void dispose() => program.dispose();
}
