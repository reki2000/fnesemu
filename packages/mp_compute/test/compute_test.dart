import 'dart:typed_data';

import 'package:mp_compute/mp_compute.dart';
import 'package:test/test.dart';

const _wgsl = '''
struct Params { add: u32, pad0: u32, pad1: u32, pad2: u32 }
@group(0) @binding(0) var<storage, read_write> values: array<u32>;
@group(0) @binding(1) var<storage, read> source: array<u32>;
@group(0) @binding(2) var<uniform> P: Params;

@compute @workgroup_size(64)
fn add(@builtin(global_invocation_id) id: vec3u) {
  values[id.x] += source[id.x] + P.add;
}

@compute @workgroup_size(64)
fn twice(@builtin(global_invocation_id) id: vec3u) {
  values[id.x] *= 2u;
}
''';

void main() {
  String? reason;
  final device = ComputeDevice.open(onError: (r) => reason = r);

  test('runs dispatches in order with their own parameters', () {
    final program = device!.program(
      _wgsl,
      ['add', 'twice'],
      const [
        ComputeBinding(ComputeBindingKind.storage, 1024),
        ComputeBinding(ComputeBindingKind.readOnlyStorage, 1024),
        ComputeBinding(ComputeBindingKind.params, 16),
      ],
      maxDispatches: 4,
    );
    final source = Uint32List.fromList(List.generate(256, (i) => i));
    program.write(0, 0, Uint32List(256));
    program.write(1, 0, source);
    final params = Uint32List(4 * 64)
      ..[0] = 1
      ..[2 * 64] = 100;
    // add (+i+1), twice, add (+i+100) over the 256 values
    final dispatches = Uint32List.fromList([
      0,
      4,
      1,
      1,
      1,
      4,
      1,
      1,
      0,
      4,
      1,
      1,
    ]);
    program.run(dispatches, 3, params);
    final out = Uint32List(256);
    program.read(0, 0, out);
    for (var i = 0; i < 256; i++) {
      expect(out[i], (i + 1) * 2 + i + 100, reason: 'value $i');
    }
    // a partial write and read
    program.write(0, 16, Uint32List.fromList([7, 8, 9]), 1, 3);
    final part = Uint32List(3);
    program.read(0, 12, part);
    expect(part, [out[3], 8, 9]);
    program.dispose();
  }, skip: device == null ? 'no compute device: $reason' : false);

  test('lists the adapters that a device chooses from', () {
    final listed = ComputeDevice.adapterList();
    expect(listed, [
      for (final l in device!.adapters.split('\n'))
        if (l.isNotEmpty) l.substring(2),
    ]);
    final other = ComputeDevice.open(adapter: listed.last);
    expect(other!.name, listed.last);
    other.close();
  }, skip: device == null ? 'no compute device: $reason' : false);
}
