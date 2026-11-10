import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';

import '../packages/fnesemu_core/tool/headless/options.dart';
import '../packages/fnesemu_core/tool/headless/session.dart';
import 'gs_resident/batch.dart';

typedef _Reply = ({Map<String, Object?> timings, Uint8List rgba});

class _Worker {
  _Worker(this.process) : _output = StreamIterator(process.stdout) {
    process.stderr.listen(stderr.add);
  }

  final Process process;
  final StreamIterator<List<int>> _output;
  List<int> _chunk = const [];
  int _position = 0;
  Future<void> _writes = Future.value(), _reads = Future.value();

  Future<Uint8List> _read(int length) async {
    final result = Uint8List(length);
    var at = 0;
    while (at < length) {
      if (_position == _chunk.length) {
        if (!await _output.moveNext()) {
          throw StateError('Vulkan renderer closed its output');
        }
        _chunk = _output.current;
        _position = 0;
      }
      final available = _chunk.length - _position;
      final count = available < length - at ? available : length - at;
      result.setRange(at, at + count, _chunk, _position);
      at += count;
      _position += count;
    }
    return result;
  }

  Future<void> ready() async {
    if (ascii.decode(await _read(4)) != 'GSR1') {
      throw const FormatException('Vulkan renderer protocol');
    }
  }

  Future<_Reply> submit(Uint8List commands, Uint8List auxiliary, int width,
      int height, Uint8List? checkpoint) {
    final header = Uint32List.fromList([
      checkpoint?.length ?? 0,
      commands.length,
      auxiliary.length,
    ]);
    _writes = _writes.then((_) async {
      process.stdin.add(header.buffer.asUint8List());
      if (checkpoint != null) process.stdin.add(checkpoint);
      process.stdin.add(commands);
      process.stdin.add(auxiliary);
      await process.stdin.flush();
    });
    final reply = _reads.then((_) async {
      final header = Uint32List.sublistView(await _read(8));
      if (header[0] == 0 ||
          header[0] > 4096 ||
          header[1] != width * height * 4) {
        throw const FormatException('invalid Vulkan renderer response');
      }
      final timings = jsonDecode(utf8.decode(await _read(header[0])))
          as Map<String, Object?>;
      return (timings: timings, rgba: await _read(header[1]));
    });
    _reads = reply.then((_) {});
    return reply;
  }

  Future<void> close() async {
    await _writes;
    await process.stdin.close();
    await _reads;
    if (await process.exitCode != 0) throw StateError('Vulkan renderer failed');
    await _output.cancel();
  }
}

Uint8List _materialize(Object? data) =>
    (data as TransferableTypedData).materialize().asUint8List();

Future<void> _workerMain(SendPort host) async {
  final commands = ReceivePort();
  _Worker? worker;
  try {
    final active = _Worker(await Process.start('tool/gs_resident/replay',
        ['--stream', 'tool/gs_resident/replay.spv']));
    worker = active;
    await active.ready();
    host.send(commands.sendPort);
    await for (final message in commands) {
      if (message == null) {
        await active.close();
        worker = null;
        host.send(null);
        return;
      }
      final parts = message as List;
      final reply = active.submit(
        _materialize(parts[1]),
        _materialize(parts[2]),
        parts[3] as int,
        parts[4] as int,
        parts[5] == null ? null : _materialize(parts[5]),
      );
      unawaited(reply.then((result) {
        host.send([
          parts[0],
          {
            ...result.timings,
            'workerCompletedEpochUs': DateTime.now().microsecondsSinceEpoch,
          },
          TransferableTypedData.fromList([result.rgba])
        ]);
      }, onError: (Object error) {
        active.process.kill();
        host.send(error.toString());
        commands.close();
      }));
    }
  } catch (error) {
    host.send(error.toString());
  } finally {
    commands.close();
    worker?.process.kill();
  }
}

class _AsyncWorker {
  _AsyncWorker() {
    _messages.listen(_onMessage);
  }

  final _messages = ReceivePort();
  final _ready = Completer<SendPort>();
  final _closed = Completer<void>();
  final _pending = <int, Completer<_Reply>>{};
  int _next = 0;
  String? _failure;
  late final Isolate _isolate;
  late final SendPort _port;

  static Future<_AsyncWorker> start() async {
    final worker = _AsyncWorker();
    try {
      worker._isolate =
          await Isolate.spawn(_workerMain, worker._messages.sendPort);
      await worker._ready.future;
      return worker;
    } catch (_) {
      worker._messages.close();
      rethrow;
    }
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _port = message;
      _ready.complete(message);
    } else if (message == null) {
      _closed.complete();
    } else if (message is String) {
      _failure = message;
      final error = StateError(message);
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final reply in _pending.values) {
        reply.completeError(error);
      }
      _pending.clear();
      if (!_closed.isCompleted) _closed.complete();
    } else {
      final parts = message as List;
      final reply = _pending.remove(parts[0]);
      reply?.complete((
        timings: (parts[1] as Map).cast<String, Object?>(),
        rgba: _materialize(parts[2]),
      ));
    }
  }

  Future<_Reply> submit(ResidentBatch batch, Uint8List? checkpoint) {
    if (_failure case final failure?) throw StateError(failure);
    final id = _next++;
    final reply = _pending[id] = Completer<_Reply>();
    _port.send([
      id,
      TransferableTypedData.fromList([batch.commands]),
      TransferableTypedData.fromList([batch.auxiliary]),
      batch.width,
      batch.height,
      if (checkpoint == null)
        null
      else
        TransferableTypedData.fromList([checkpoint]),
    ]);
    return reply.future;
  }

  Future<void> close() async {
    try {
      if (_failure == null) {
        _port.send(null);
        await _closed.future;
      }
    } finally {
      _isolate.kill();
      _messages.close();
    }
  }
}

int _drawTarget(Gs gs) {
  // The local test scene alternates these two display buffers.
  return switch (gs.dispfb2) {
    0x94a0 => 0x9400,
    0x9400 => 0x94a0,
    _ => throw UnsupportedError('unexpected scanout buffer'),
  };
}

Uint8List _softwareScanout(Gs gs, int target) {
  final width =
      ((gs.display2 >> 32 & 0xfff) + 1) ~/ ((gs.display2 >> 23 & 15) + 1);
  final height = ((gs.display2 >> 44 & 0x7ff) + 1).clamp(1, 480);
  if (target >> 15 & 0x1f != GsPsm.ct24 || gs.smode2 & 3 != 3) {
    throw UnsupportedError('software comparison display mode');
  }
  final mem = gs.mem;
  final layout = mem.layout(GsPsm.ct24);
  final pages = layout.pagesInRow(target >> 9 & 0x3f);
  final base = (target & 0x1ff) * 32;
  final pixels = Uint32List(width * height);
  for (var y = 0; y < height; y += 2) {
    final first = y * width;
    for (var x = 0; x < width; x++) {
      pixels[first + x] =
          mem.word(layout.index(base, pages, x, y ~/ 2)) | 0xff000000;
    }
    if (y + 1 < height) {
      pixels.setRange(first + width, first + width * 2, pixels, first);
    }
  }
  return pixels.buffer.asUint8List();
}

Future<void> main(List<String> args) async {
  if (args.length != 4 || (args[3] != 'gpu' && args[3] != 'software')) {
    throw ArgumentError(
        'usage: gs_resident_live CONFIG OUTPUT FRAMES gpu|software');
  }
  final config = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final directory = Directory(args[1])..createSync(recursive: true);
  final frames = int.parse(args[2]);
  if (frames < 1) throw ArgumentError('positive frame count required');
  final useGpu = args[3] == 'gpu';
  final session = await Session.open(
      'ps2',
      List<String>.from(config['files'] as List),
      Options.parse(
          ['--frame-runner', '--input', (config['input'] ?? '') as String],
          flags: mediaFlags, valued: mediaValued),
      recordAudio: false);
  _AsyncWorker? worker;
  try {
    session.loadState(config['state'] as String);
    final targetFrame = config['frame'] as int;
    while (session.frame < targetFrame - 1) {
      if (!await session.stepFrame()) {
        throw StateError('core stopped before test');
      }
      session.core.imageBuffer();
    }
    if (session.frame != targetFrame - 1) {
      throw StateError('wrong checkpoint frame');
    }
    final gs = (session.core as Ps2).io.gs;
    GsResidentBatchEncoder? encoder;
    Uint8List? checkpoint;
    if (useGpu) {
      worker = await _AsyncWorker.start();
      checkpoint = residentCheckpoint(gs);
      encoder = GsResidentBatchEncoder(gs);
      gs.residentSink = encoder;
    }
    final outstanding = <Future<void>>[];
    final timings = <Map<String, Object?>>[];
    final startedAt = DateTime.now().microsecondsSinceEpoch;
    final clock = Stopwatch()..start();
    for (var n = 0; n < frames; n++) {
      final start = clock.elapsedMicroseconds;
      if (!await session.stepFrame()) {
        throw StateError('core stopped during test');
      }
      final frame = session.frame;
      final display = _drawTarget(gs);
      final sample = <String, Object?>{
        'frame': frame,
        'displayBuffer': display,
        'stepMs': (clock.elapsedMicroseconds - start) / 1000,
      };
      timings.add(sample);
      final renderer = encoder;
      if (renderer != null) {
        final batch = renderer.finish(display);
        sample['stepAndSealMs'] = (clock.elapsedMicroseconds - start) / 1000;
        sample['draws'] = batch.draws;
        sample['queuedAtMs'] = clock.elapsedMicroseconds / 1000;
        outstanding
            .add(worker!.submit(batch, checkpoint).then<void>((reply) async {
          sample['completedAtMs'] = clock.elapsedMicroseconds / 1000;
          sample['vulkan'] = reply.timings;
          final workerAt = reply.timings['workerCompletedEpochUs'] as int?;
          if (workerAt != null) {
            sample['workerCompletedAtMs'] = (workerAt - startedAt) / 1000;
          }
          final pixels = Uint32List.sublistView(reply.rgba);
          renderer.completedImage = ImageBuffer(
              batch.width, batch.height, pixels,
              displayWidth_: 320, displayHeight: batch.height ~/ 2);
          final image = session.core.imageBuffer();
          if (!identical(image.buffer, pixels)) {
            throw StateError('GS did not publish the completed GPU image');
          }
          await File('${directory.path}/gpu-$frame.rgba')
              .writeAsBytes(image.buffer.buffer.asUint8List());
        }));
        checkpoint = null;
      } else {
        final rgba = _softwareScanout(gs, display);
        session.core.imageBuffer();
        File('${directory.path}/software-$frame.rgba').writeAsBytesSync(rgba);
      }
    }
    await Future.wait(outstanding);
    clock.stop();
    final result = {
      'mode': args[3],
      'elapsedMs': clock.elapsedMicroseconds / 1000,
      'frames': timings,
    };
    File('${directory.path}/${args[3]}-live.json')
        .writeAsStringSync(jsonEncode(result));
    stdout.writeln(jsonEncode(result));
  } finally {
    (session.core as Ps2).io.gs.residentSink = null;
    session.core.dispose();
    if (worker != null) {
      await worker.close();
    }
  }
}
