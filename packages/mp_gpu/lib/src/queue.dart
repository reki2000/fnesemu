import 'dart:async';
import 'dart:typed_data';

import 'gpu.dart';
import 'stamp.dart';

/// Draws jobs into offscreen targets of a [GpuDevice] and returns their
/// pixels.
///
/// The jobs that come while others are drawn wait, and are then drawn
/// together, each into a target of its own, and read back after one
/// [GpuDevice.settle]. When more than [maximumWaiting] jobs wait, the oldest
/// ones get null, so a slow GPU loses jobs instead of falling behind. The
/// targets are kept for later jobs of the same size.
///
/// On Flutter GPU, the target of a job has one more row below the rows of
/// the job. Every pass into it ends with a draw of a number of the job into
/// this row, and a read that does not show the number gives null: the GLES
/// backend may return a target as it was before, and may not run a pass
/// that draws nothing. A new target is first drawn with only its number
/// until the number comes back, for at most two seconds.
class GpuQueue {
  GpuQueue._(this.device) : _stamping = _stampingOf(device);

  static GpuStamping? _stampingOf(GpuDevice device) => switch (device) {
    GpuStamping s when s.stamps => s,
    _ => null,
  };

  /// A queue on [device], or null when a first target cannot be read back,
  /// which also tells that the GPU does not work.
  static Future<GpuQueue?> create(GpuDevice device) async {
    final queue = GpuQueue._(device);
    final target = await queue._newTarget(8, 8 + queue._extra);
    if (target == null) return null;
    queue._release(target);
    return queue;
  }

  final GpuDevice device;
  final GpuStamping? _stamping;

  /// The number of jobs that may wait.
  static const maximumWaiting = 8;

  // The free targets, the newest last.
  static const _maximumFree = 8;
  final _free = <GpuTarget>[];

  final _waiting = <_Job>[];
  bool _drawing = false;
  _Job? _current;
  int _stamp = 0;

  int get _extra => _stamping == null ? 0 : 1;

  /// Draws a job into a target of [width] x [height], or one row more on
  /// Flutter GPU, with [draw],
  /// and returns the RGBA bytes of the top [height] rows, row by row, or
  /// null when the job was dropped or could not be read back. [draw] gets
  /// the target and ends its passes; the last pass decides the pixels.
  Future<Uint8List?> render(
    int width,
    int height,
    void Function(GpuTarget target) draw,
  ) {
    final job = _Job(width, height, draw);
    _waiting.add(job);
    if (_waiting.length > maximumWaiting) _waiting.removeAt(0).finish(null);
    if (!_drawing) unawaited(_drawWaiting());
    return job.result.future;
  }

  /// A target of [width] x [height] for passes of the job that [render] is
  /// drawing, to sample in later passes of the job. It is not read back and
  /// is free again once the job is.
  GpuTarget scratch(int width, int height) {
    final job = _current;
    if (job == null) throw StateError('scratch outside of a draw');
    final target = _take(width, height) ?? device.target(width, height);
    targetStamps[target] = null;
    job.scratch.add(target);
    return target;
  }

  Future<void> _drawWaiting() async {
    _drawing = true;
    var jobs = <_Job>[];
    try {
      while (_waiting.isNotEmpty) {
        jobs = [..._waiting];
        _waiting.clear();
        final drawn = <_Job>[];
        for (final job in jobs) {
          final height = job.height + _extra;
          final target =
              _take(job.width, height) ?? await _newTarget(job.width, height);
          if (target == null) {
            job.finish(null);
          } else {
            job.target = target;
            drawn.add(job);
          }
        }
        for (final job in drawn) {
          _stampTarget(job.target!);
          _current = job;
          try {
            job.draw(job.target!);
          } finally {
            _current = null;
          }
        }
        await device.settle();
        for (final job in drawn) {
          final target = job.target!;
          final rgba = await device.read(target);
          job.finish(_checked(target, rgba, job.height));
          _release(target);
          job.scratch.forEach(_release);
        }
      }
    } catch (_) {
      for (final job in [...jobs, ..._waiting]) {
        job.finish(null);
      }
      _waiting.clear();
    } finally {
      _current = null;
      _drawing = false;
    }
  }

  /// Gives the target the next number, if the device stamps.
  void _stampTarget(GpuTarget target) {
    if (_stamping == null) return;
    targetStamps[target] = _stamp = _stamp % 0xffffff + 1;
  }

  /// The top [height] rows of [rgba], the pixels of [target], or null when
  /// they are missing or the stamp does not match.
  Uint8List? _checked(GpuTarget target, Uint8List? rgba, int height) {
    if (rgba == null || rgba.length != target.width * target.height * 4) {
      return null;
    }
    if (_stamping != null) {
      final stamp = targetStamps[target];
      final at = (target.height - 1) * target.width * 4;
      if (stamp == null ||
          rgba[at] != stamp & 0xff ||
          rgba[at + 1] != stamp >> 8 & 0xff ||
          rgba[at + 2] != stamp >> 16 ||
          rgba[at + 3] != 255) {
        return null;
      }
    }
    return Uint8List.sublistView(rgba, 0, target.width * height * 4);
  }

  GpuTarget? _take(int width, int height) {
    final index = _free.lastIndexWhere(
      (t) => t.width == width && t.height == height,
    );
    return index < 0 ? null : _free.removeAt(index);
  }

  void _release(GpuTarget target) {
    targetStamps[target] = null;
    _free.add(target);
    if (_free.length > _maximumFree) _free.removeAt(0);
  }

  /// A new target, or null when it cannot be read back. With stamps, it is
  /// drawn with its number until the number comes back.
  Future<GpuTarget?> _newTarget(int width, int height) async {
    final target = device.target(width, height);
    final stamping = _stamping;
    if (stamping == null) return target;
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 2000) {
      _stampTarget(target);
      stamping.stampOnly(target);
      await device.settle();
      final rgba = await device.read(target);
      if (_checked(target, rgba, 0) != null) return target;
    }
    targetStamps[target] = null;
    return null;
  }
}

class _Job {
  _Job(this.width, this.height, this.draw);

  final int width, height;
  final void Function(GpuTarget) draw;
  final result = Completer<Uint8List?>();
  GpuTarget? target;
  final scratch = <GpuTarget>[];

  void finish(Uint8List? rgba) {
    if (!result.isCompleted) result.complete(rgba);
  }
}
