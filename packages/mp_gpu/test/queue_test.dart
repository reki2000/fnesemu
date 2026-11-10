import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp_gpu/mp_gpu.dart';
import 'package:mp_gpu/src/stamp.dart';

void main() {
  test('a job gets the top rows of a target with one more row', () async {
    final device = _FakeDevice();
    final queue = (await GpuQueue.create(device))!;
    final rgba = await queue.render(4, 3, (t) => device.fill(t, 7));
    expect(rgba, hasLength(4 * 3 * 4));
    expect(rgba!.every((b) => b == 7), isTrue);
    expect(device.targets.last.height, 4);
  });

  test('a read that shows an older pass gives null', () async {
    final device = _FakeDevice();
    final queue = (await GpuQueue.create(device))!;
    expect(await queue.render(4, 3, (t) => device.fill(t, 1)), isNotNull);
    device.staleReads = 1;
    expect(await queue.render(4, 3, (t) => device.fill(t, 2)), isNull);
    final rgba = await queue.render(4, 3, (t) => device.fill(t, 3));
    expect(rgba![0], 3);
  });

  test('a new target is drawn until its stamp comes back', () async {
    final device = _FakeDevice()..staleReads = 3;
    final queue = await GpuQueue.create(device);
    expect(queue, isNotNull);
    expect(device.targets, hasLength(1));
  });

  test('targets are kept for jobs of the same size', () async {
    final device = _FakeDevice();
    final queue = (await GpuQueue.create(device))!;
    for (var i = 0; i < 3; i++) {
      await queue.render(16, 8, (t) => device.fill(t, i));
    }
    expect(device.targets.where((t) => t.width == 16), hasLength(1));
  });

  test('jobs that wait together are all drawn', () async {
    final device = _FakeDevice();
    final queue = (await GpuQueue.create(device))!;
    final results = await Future.wait([
      for (var i = 0; i < 4; i++) queue.render(2, 2, (t) => device.fill(t, i)),
    ]);
    expect([for (final r in results) r![0]], [0, 1, 2, 3]);
  });

  test('the oldest of too many waiting jobs get null', () async {
    final device = _FakeDevice();
    final queue = (await GpuQueue.create(device))!;
    final results = await Future.wait([
      for (var i = 0; i < GpuQueue.maximumWaiting + 3; i++)
        queue.render(2, 2, (t) => device.fill(t, i)),
    ]);
    expect(results.where((r) => r == null), hasLength(2));
    expect(results.last![0], GpuQueue.maximumWaiting + 2);
  });

  test('scratch targets carry no stamp and are reused', () async {
    final device = _FakeDevice();
    final queue = (await GpuQueue.create(device))!;
    for (var i = 0; i < 2; i++) {
      await queue.render(2, 2, (t) {
        final scratch = queue.scratch(5, 5);
        expect(targetStamps[scratch], isNull);
        device.fill(t, i);
      });
    }
    expect(device.targets.where((t) => t.width == 5), hasLength(1));
  });

  test('a device without stamps gives targets of the job size', () async {
    final device = _FakeDevice(stamps: false);
    final queue = (await GpuQueue.create(device))!;
    final rgba = await queue.render(4, 3, (t) => device.fill(t, 5));
    expect(rgba![0], 5);
    expect(device.targets.last.height, 3);
  });
}

/// A device whose passes fill a target with one byte and draw its stamp,
/// and whose reads show the target as at the settle before when
/// [staleReads] is above zero.
class _FakeDevice implements GpuDevice, GpuStamping {
  _FakeDevice({this.stamps = true});

  @override
  final bool stamps;
  final targets = <_FakeTarget>[];
  int staleReads = 0;

  void fill(GpuTarget target, int byte) => pass(
    target,
    _FakeProgram(),
    const [],
    clearColor: [byte / 255, 0, 0, 0],
    clearDepth: 0,
  ).end();

  @override
  String get name => 'fake';

  @override
  String get readBack => 'none';

  @override
  bool get stencil => true;

  @override
  Future<GpuProgram> program(GpuProgramSource source) async => _FakeProgram();

  @override
  GpuTexture texture(int width, int height, Uint8List rgba) =>
      throw UnimplementedError();

  @override
  GpuTarget target(int width, int height) {
    final target = _FakeTarget(width, height);
    targets.add(target);
    return target;
  }

  @override
  GpuPass pass(
    GpuTarget target,
    GpuProgram program,
    List<Float32List> vertices, {
    required List<double> clearColor,
    required double clearDepth,
  }) => _FakePass(target as _FakeTarget, (clearColor[0] * 255).round());

  @override
  void stampOnly(GpuTarget target) => fill(target, 0);

  @override
  Future<void> settle() async {
    if (staleReads > 0) {
      staleReads--;
      return;
    }
    for (final t in targets) {
      t.shown.setAll(0, t.pixels);
    }
  }

  @override
  Future<Uint8List?> read(GpuTarget target) async =>
      Uint8List.fromList((target as _FakeTarget).shown);
}

class _FakeProgram implements GpuProgram {}

class _FakeTarget implements GpuTarget {
  _FakeTarget(this.width, this.height)
    : pixels = Uint8List(width * height * 4),
      shown = Uint8List(width * height * 4);

  @override
  final int width, height;
  final Uint8List pixels, shown;

  @override
  GpuTexture get colorTexture => throw UnimplementedError();
}

class _FakePass implements GpuPass {
  _FakePass(this._target, this._byte);

  final _FakeTarget _target;
  final int _byte;

  @override
  void uniform(String name, ByteData data) {}

  @override
  void texture(
    String name,
    GpuTexture texture, [
    GpuSampler sampler = const GpuSampler(),
  ]) {}

  @override
  void state(GpuState state) {}

  @override
  void stencilReference(int value) {}

  @override
  void draw(int first, int count, [int array = 0]) {}

  @override
  void end({void Function(bool success)? onComplete}) {
    final t = _target;
    t.pixels.fillRange(0, t.pixels.length, _byte);
    final stamp = targetStamps[t];
    if (stamp != null) {
      final at = (t.height - 1) * t.width * 4;
      t.pixels.setAll(at, [stamp & 0xff, stamp >> 8 & 0xff, stamp >> 16, 255]);
    }
  }
}
