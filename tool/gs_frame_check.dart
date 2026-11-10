import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_raster.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:fnesemu_core/src/core/ps2/state.dart';
import 'package:render_frame_gpu/render_frame_gpu.dart';

import '../packages/fnesemu_core/tool/headless/options.dart';
import '../packages/fnesemu_core/tool/headless/session.dart';

const _traceVersion = 3;

Uint8List _gsState(Gs gs) {
  final writer = StateWriter('gs-frame-trace', _traceVersion, 0);
  gs.saveState(writer);
  return writer.take();
}

bool _equals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> _record(String configPath, String directory) async {
  final config = jsonDecode(File(configPath).readAsStringSync()) as Map;
  final session = await Session.open(
      'ps2',
      List<String>.from(config['files'] as List),
      Options.parse(
          ['--frame-runner', '--input', (config['input'] ?? '') as String],
          flags: mediaFlags, valued: mediaValued),
      recordAudio: false);
  session.loadState(config['state'] as String);
  final target = config['frame'] as int;
  if (target <= session.frame) {
    throw ArgumentError('frame must follow the checkpoint');
  }
  while (session.frame < target - 1) {
    if (!await session.stepFrame()) {
      throw StateError('core stopped before capture');
    }
    session.core.imageBuffer();
  }

  Directory(directory).createSync(recursive: true);
  final gs = (session.core as Ps2).io.gs;
  File('$directory/gs-start.bin').writeAsBytesSync(_gsState(gs));
  final events =
      File('$directory/gs-stream.bin').openSync(mode: FileMode.write);
  final commands =
      File('$directory/draws.jsonl').openSync(mode: FileMode.write);
  final packets = File('$directory/packets.bin').openSync(mode: FileMode.write);
  final event = ByteData(16);
  var drawCount = 0, packetCount = 0, eventCount = 0, noEffect = 0;

  void writeData(TypedData data) {
    packets.writeFromSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }

  gsCommandRecorder = (op, reg, value) {
    event.setUint32(0, op, Endian.little);
    event.setUint32(4, reg, Endian.little);
    event.setInt64(8, value, Endian.little);
    events.writeFromSync(event.buffer.asUint8List());
    eventCount++;
  };
  gsDrawRecorder = (command, frame, before, after, depthBefore, depthAfter) {
    command['number'] = ++drawCount;
    command['event'] = eventCount;
    if (command['unsupported'] == 'no_raster_effect') noEffect++;
    if (frame != null) {
      final offset = packets.positionSync();
      writeData(frame.state);
      writeData(frame.input);
      writeData(before!);
      writeData(after!);
      if (depthBefore != null) {
        writeData(depthBefore);
        writeData(depthAfter!);
      }
      command['packet'] = {
        'offset': offset,
        'stateFloats': frame.state.length,
        'inputWidth': frame.inputWidth,
        'inputHeight': frame.inputHeight,
        'planes': frame.planes,
        'depth': depthBefore != null,
      };
      packetCount++;
    }
    commands.writeStringSync('${jsonEncode(command)}\n');
  };
  try {
    if (!await session.stepFrame()) throw StateError('core stopped in capture');
    final image = session.core.imageBuffer();
    savePng(image, '$directory/reference.png');
    File('$directory/gs-end.bin').writeAsBytesSync(_gsState(gs));
  } finally {
    gsCommandRecorder = null;
    gsDrawRecorder = null;
    events.closeSync();
    commands.closeSync();
    packets.closeSync();
    session.core.dispose();
  }
  final summary = {
    'version': _traceVersion,
    'frame': target,
    'events': eventCount,
    'draws': drawCount,
    'gpuPackets': packetCount,
    'unsupported': drawCount - packetCount - noEffect,
    'noRasterEffect': noEffect,
    'endianness': Endian.host == Endian.little ? 'little' : 'big',
  };
  File('$directory/manifest.json').writeAsStringSync(jsonEncode(summary));
  stdout.writeln(jsonEncode(summary));
}

Gs _loadStart(String directory) => Gs()
  ..loadState(StateReader(File('$directory/gs-start.bin').readAsBytesSync(),
      'gs-frame-trace', _traceVersion, 0));

ByteData _readStream(String directory, int expectedEvents) {
  final stream = File('$directory/gs-stream.bin').readAsBytesSync();
  if (stream.length != expectedEvents * 16) {
    throw const FormatException('GS stream event count does not match manifest');
  }
  return ByteData.sublistView(stream);
}

void _issueEvent(Gs gs, ByteData bytes, int at, Int64List transfer) {
  final op = bytes.getUint32(at, Endian.little);
  final register = bytes.getUint32(at + 4, Endian.little);
  final value = bytes.getInt64(at + 8, Endian.little);
  switch (op) {
    case 0:
      gs.writeRegister(register, value);
    case 1:
      gs.writePrivileged(register, value);
    case 2:
      gs.hostWord(value);
    case 3:
      gs.readQuad(transfer);
    case 4:
      gs.vblank();
    case 5:
      gs.setQ(value);
    default:
      throw FormatException('unknown GS operation $op');
  }
}

Gs _replayStream(String directory, int expectedEvents) {
  final gs = _loadStart(directory);
  final bytes = _readStream(directory, expectedEvents);
  final transfer = Int64List(2);
  for (var at = 0; at < bytes.lengthInBytes; at += 16) {
    _issueEvent(gs, bytes, at, transfer);
  }
  gs.image();
  if (!_equals(_gsState(gs), File('$directory/gs-end.bin').readAsBytesSync())) {
    throw StateError(
        'GS command stream did not reproduce the recorded final state');
  }
  stdout.writeln('GS stream reproduced final software state byte for byte');
  return gs;
}

typedef _Packet = ({
  Map command,
  Ps2SpriteFrame frame,
  Uint32List before,
  Uint32List after,
  Uint32List? depthBefore,
  Uint32List? depthAfter,
});

_Packet _readPacket(Map command, RandomAccessFile file) {
  final p = command['packet'] as Map;
  final bounds = command['bounds'] as List;
  final width = bounds[2] as int, height = bounds[3] as int;
  final iw = p['inputWidth'] as int, ih = p['inputHeight'] as int;
  final area = width * height;
  file.setPositionSync(p['offset'] as int);
  Uint8List bytes(int length) {
    final data = file.readSync(length);
    if (data.length != length) {
      throw const FormatException('truncated GPU packet');
    }
    return data;
  }

  Uint32List words() => Uint32List.sublistView(bytes(area * 4));
  final state = Float32List.sublistView(bytes((p['stateFloats'] as int) * 4));
  final frame = Ps2SpriteFrame(width, height, iw, ih, bytes(iw * ih * 4), state,
      planes: p['planes'] as int);
  final before = words(), after = words();
  final hasDepth = p['depth'] == true;
  return (
    command: command,
    frame: frame,
    before: before,
    after: after,
    depthBefore: hasDepth ? words() : null,
    depthAfter: hasDepth ? words() : null
  );
}

({int rgb, int rgba, int depth, int touched}) _compare(
    _Packet p, Uint8List pixels) {
  final planes = p.frame.planes;
  final width = p.frame.width ~/ planes, height = p.frame.height;
  final mask = p.command['colorMask'] as int;
  final forceAlpha = p.command['forceAlpha'] == true ? 0x80 : 0;
  final format = p.command['colorFormat'] as int;
  final shortColor = format == 2 || format == 10;
  final storedMask = shortColor
      ? 0xffff
      : format == 1
          ? 0xffffff
          : 0xffffffff;
  final alphaMask = shortColor
      ? 0x8000
      : format == 1
          ? 0
          : 0xff000000;
  final rgbMask = shortColor ? 0x7fff : 0xffffff;
  final z = p.frame.state[6].toInt() | p.frame.state[7].toInt() << 16;
  var rgb = 0, rgba = 0, depth = 0, touched = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      final color = (y * width * planes + x) * 4, flags = color + width * 4;
      final write = pixels[flags + 1], writeZ = pixels[flags + 2];
      if (write > 2 || writeZ > 1 || writeZ != 0 && p.depthAfter == null) {
        throw FormatException('invalid GPU write flags $write/$writeZ at $x,$y');
      }
      var actual = p.before[i];
      if (write != 0) {
        final writeMask = (write == 2 ? mask | alphaMask : mask) & storedMask;
        final alpha = pixels[flags] | forceAlpha;
        final value = shortColor
            ? (pixels[color] >> 3) |
                (pixels[color + 1] >> 3) << 5 |
                (pixels[color + 2] >> 3) << 10 |
                (alpha >> 7) << 15
            : pixels[color] |
                pixels[color + 1] << 8 |
                pixels[color + 2] << 16 |
                alpha << 24;
        actual = ((actual & writeMask) | (value & ~writeMask)) & storedMask;
      }
      final difference = actual ^ p.after[i];
      if (difference != 0) rgba++;
      if (difference & rgbMask != 0) rgb++;
      if ((p.before[i] ^ p.after[i]) & rgbMask != 0) touched++;
      final depthPixel = flags + width * 4;
      final writtenDepth = planes == 2
          ? z
          : pixels[depthPixel] |
              pixels[depthPixel + 1] << 8 |
              pixels[depthPixel + 2] << 16;
      if (p.depthAfter != null &&
          (writeZ != 0 ? writtenDepth : p.depthBefore![i]) !=
              p.depthAfter![i]) {
        depth++;
      }
    }
  }
  return (rgb: rgb, rgba: rgba, depth: depth, touched: touched);
}

Future<Uint8List?> _applyFeedback(
    GpuFrameSink gpu, Map command, Ps2SpriteFrame frame, Uint8List first) async {
  final ends = command['rowEnds'] as List?;
  if (ends == null) return first;

  final width = frame.width ~/ frame.planes;
  final stride = frame.width * 4;
  final bounds = command['bounds'] as List;
  final left = bounds[0] as int, top = bounds[1] as int;
  final tw = frame.state[28].toInt(), th = frame.state[29].toInt();
  if (frame.planes != 2 || (command['packet'] as Map)['depth'] == true ||
      command['colorFormat'] != 0 || ends.last != frame.height ||
      first.length != frame.height * stride) {
    throw const FormatException('invalid feedback packet');
  }
  final input = Uint8List.fromList(frame.input);
  final texture = ByteData.sublistView(input);
  final output = Uint8List(first.length);
  var pixels = first, start = 0;
  for (final (pass, endValue) in ends.indexed) {
    final end = endValue as int;
    if (end <= start || end > frame.height) {
      throw const FormatException('invalid feedback row range');
    }
    if (pass != 0) {
      final next = Ps2SpriteFrame(width, frame.height, frame.inputWidth,
          frame.inputHeight, input, frame.state, planes: frame.planes);
      final readback = await gpu.drawPs2(next)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (readback == null) return null;
      pixels = readback;
    }
    output.setRange(start * stride, end * stride, pixels, start * stride);
    if (end != frame.height) {
      final mask = command['colorMask'] as int;
      final forceAlpha = command['forceAlpha'] == true ? 0x80 : 0;
      for (var y = start; y < end && top + y < th; y++) {
        for (var x = 0; x < width && left + x < tw; x++) {
          final color = y * stride + x * 4, flags = color + width * 4;
          final write = pixels[flags + 1];
          if (write > 2 || pixels[flags + 2] != 0) {
            throw const FormatException('invalid GPU feedback write flags');
          }
          if (write == 0) continue;
          final offset = ((top + y) * frame.inputWidth + left + x) * 4;
          final alpha = pixels[flags] | forceAlpha;
          final value = pixels[color] | pixels[color + 1] << 8 |
              pixels[color + 2] << 16 | alpha << 24;
          final writeMask = write == 2 ? mask | 0xff000000 : mask;
          final old = texture.getUint32(offset, Endian.little);
          texture.setUint32(
              offset, (old & writeMask) | (value & ~writeMask), Endian.little);
        }
      }
    }
    start = end;
  }
  return output;
}

bool _hasResidentFeedback(Map command) =>
    command['rowEnds'] is List && (command['rowEnds'] as List).length == 2 &&
    command['colorFormat'] == 0 && (command['packet'] as Map)['depth'] == false;

Future<Uint8List?> _residentFeedback(
    GpuFrameSink gpu, Map command, Ps2SpriteFrame frame) {
  final bounds = command['bounds'] as List;
  final ends = command['rowEnds'] as List;
  return gpu.drawPs2Feedback(frame, split: ends.first as int,
      left: bounds[0] as int, top: bounds[1] as int,
      colorMask: command['colorMask'] as int, forceAlpha: command['forceAlpha'] == true);
}

Future<int> _replay(String directory, int? limit,
    {bool atlas = false, bool feedbackOnly = false}) async {
  final manifest =
      jsonDecode(File('$directory/manifest.json').readAsStringSync()) as Map;
  if (manifest['version'] != _traceVersion ||
      manifest['endianness'] !=
          (Endian.host == Endian.little ? 'little' : 'big')) {
    throw const FormatException('incompatible GS trace');
  }
  _replayStream(directory, manifest['events'] as int);
  final gpu = await GpuFrameSink.create();
  if (gpu == null) throw StateError('host GPU unavailable');
  final commands = File('$directory/draws.jsonl')
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map)
      .toList();
  final supported = commands.where((command) => command['packet'] != null);
  final noEffect = commands.where(
      (command) => command['unsupported'] == 'no_raster_effect').length;
  if (commands.length != manifest['draws'] ||
      supported.length != manifest['gpuPackets']) {
    throw const FormatException(
        'draw or GPU packet count does not match manifest');
  }
  final eligible = feedbackOnly
      ? supported.where(_hasResidentFeedback)
      : supported;
  final selected = limit == null ? eligible : eligible.take(limit);
  final file = File('$directory/packets.bin').openSync();
  final suffix = feedbackOnly ? '-feedback' : atlas ? '-atlas' : '';
  final report = File('$directory/replay$suffix.jsonl').openSync(mode: FileMode.write);
  final mismatchPixels =
      File('$directory/mismatches$suffix.bin').openSync(mode: FileMode.write);
  final watch = Stopwatch()..start();
  var retries = 0, feedbackDraws = 0;
  var tested = 0, passed = 0, mismatch = 0, failed = 0, touched = 0;
  try {
    final iterator = selected.iterator;
    while (iterator.moveNext()) {
      final batch = [_readPacket(iterator.current, file)];
      var bytes = batch.first.frame.input.length;
      while (batch.length < (atlas ? 96 : 8) &&
          bytes < 16 * 1024 * 1024 && iterator.moveNext()) {
        final packet = _readPacket(iterator.current, file);
        bytes += packet.frame.input.length;
        batch.add(packet);
      }
      final readbacks = List<Uint8List?>.filled(batch.length, null);
      final ordinary = <int>[];
      for (final (i, packet) in batch.indexed) {
        if (atlas && _hasResidentFeedback(packet.command)) {
          feedbackDraws++;
          for (var attempt = 0; attempt < 3 && readbacks[i] == null; attempt++) {
            readbacks[i] = await _residentFeedback(gpu, packet.command, packet.frame)
                .timeout(const Duration(seconds: 10), onTimeout: () => null);
          }
        } else {
          ordinary.add(i);
        }
      }
      for (var retry = 0; retry < (atlas ? 5 : 4); retry++) {
        final missing = ordinary.where((i) => readbacks[i] == null).toList();
        if (missing.isEmpty) break;
        if (atlas && retry < 3 && missing.length > 1) {
          final retried = await gpu.drawPs2Sprites([
            for (final i in missing) batch[i].frame,
          ]).timeout(const Duration(seconds: 30),
              onTimeout: () => List<Uint8List?>.filled(missing.length, null));
          for (final (j, i) in missing.indexed) {
            readbacks[i] = retried[j];
          }
          continue;
        }
        if (atlas) retries += missing.length;
        for (var first = 0; first < missing.length; first += 8) {
          await Future.wait([
            for (final i in missing.skip(first).take(8))
              gpu.drawPs2(batch[i].frame)
                  .timeout(const Duration(seconds: 10), onTimeout: () => null)
                  .then((pixels) => readbacks[i] = pixels),
          ]);
        }
      }
      for (final (index, p) in batch.indexed) {
        final command = p.command;
        var pixels = readbacks[index];
        final resident = atlas && _hasResidentFeedback(command);
        ({int rgb, int rgba, int depth, int touched})? diff;
        String? invalid;
        for (var attempt = 0; pixels != null && attempt < 3; attempt++) {
          try {
            if (!resident) pixels = await _applyFeedback(gpu, command, p.frame, pixels);
            if (pixels != null) diff = _compare(p, pixels);
            invalid = null;
            break;
          } on FormatException catch (error) {
            invalid = error.message;
            if (attempt == 2) break;
            retries++;
            pixels = await (resident
                    ? _residentFeedback(gpu, command, p.frame)
                    : gpu.drawPs2(p.frame))
                .timeout(const Duration(seconds: 10), onTimeout: () => null);
          }
        }
        tested++;
        final row = <String, Object?>{'draw': command['number']};
        if (command['rowEnds'] case final List ends) row['passes'] = ends.length;
        if (pixels == null) {
          row['status'] = 'readback_unavailable';
          failed++;
        } else if (diff == null) {
          row['status'] = 'invalid_readback';
          row['reason'] = invalid;
          row['gpuOutputOffset'] = mismatchPixels.positionSync();
          row['gpuOutputLength'] = pixels.length;
          mismatchPixels.writeFromSync(pixels);
          failed++;
        } else {
          touched += diff.touched;
          final exact = diff.rgba == 0 && diff.depth == 0;
          row.addAll({
            'status': exact ? 'match' : 'mismatch',
            'rgbDifference': diff.rgb,
            'rgbaDifference': diff.rgba,
            'depthDifference': diff.depth,
            'referenceRgbChanges': diff.touched
          });
          if (exact) {
            passed++;
          } else {
            row['gpuOutputOffset'] = mismatchPixels.positionSync();
            row['gpuOutputLength'] = pixels.length;
            mismatchPixels.writeFromSync(pixels);
            mismatch++;
          }
        }
        report.writeStringSync('${jsonEncode(row)}\n');
        if (tested % 500 == 0) stdout.writeln('GPU checked $tested draws');
      }
    }
  } finally {
    file.closeSync();
    report.closeSync();
    mismatchPixels.closeSync();
  }
  watch.stop();
  final summary = {
    'backend': gpu.name,
    'elapsedMs': watch.elapsedMicroseconds / 1000,
    if (atlas) 'atlasSubmissions': gpu.ps2AtlasSubmissions,
    if (atlas) 'individualRetries': retries,
    if (atlas) 'residentFeedbackDraws': feedbackDraws,
    'recorded': commands.length,
    'unsupported': commands.length - supported.length - noEffect,
    'noRasterEffect': noEffect,
    'untested': supported.length - tested,
    'tested': tested,
    'exact': passed,
    'mismatch': mismatch,
    'readbackUnavailable': failed,
    'referenceRgbChanges': touched
  };
  File('$directory/replay$suffix-summary.json').writeAsStringSync(jsonEncode(summary));
  stdout.writeln(jsonEncode(summary));
  return tested != 0 && mismatch == 0 && failed == 0 ? 0 : 2;
}

bool _validReadback(Ps2SpriteFrame frame, Uint8List pixels) {
  if (pixels.length != frame.width * frame.height * 4) return false;
  final planeStride = frame.width ~/ frame.planes * 4;
  final rowStride = frame.width * 4;
  final allowsDepth = frame.state[26] != 0;
  for (var row = 0; row < pixels.length; row += rowStride) {
    for (var at = row + planeStride; at < row + 2 * planeStride; at += 4) {
      if (pixels[at + 1] > 2 || pixels[at + 2] > (allowsDepth ? 1 : 0)) {
        return false;
      }
    }
  }
  return true;
}

void _saveDrawTarget(Gs gs, int displayBuffer, String path) {
  gs.writePrivileged(0x12000090, displayBuffer);
  gs.vblank();
  gs.vblank();
  savePng(gs.image(), path);
}

Map<String, double> _measureSoftware(
    String directory, ByteData bytes, List<Map> draws) {
  final gs = _loadStart(directory);
  final transfer = Int64List(2);
  final clock = Stopwatch()..start();
  var nextDraw = 0, drawTicks = 0;
  for (var at = 0; at < bytes.lengthInBytes; at += 16) {
    if (nextDraw < draws.length && draws[nextDraw]['event'] == at ~/ 16 + 1) {
      final start = clock.elapsedTicks;
      _issueEvent(gs, bytes, at, transfer);
      drawTicks += clock.elapsedTicks - start;
      nextDraw++;
    } else {
      _issueEvent(gs, bytes, at, transfer);
    }
  }
  clock.stop();
  if (nextDraw != draws.length) throw StateError('incomplete timed software replay');
  return {'drawMs': 1000 * drawTicks / clock.frequency,
    'streamMs': 1000 * clock.elapsedTicks / clock.frequency};
}

Future<void> _fullReplay(String directory, {bool omitDraws = false, int? target}) async {
  final manifest =
      jsonDecode(File('$directory/manifest.json').readAsStringSync()) as Map;
  if (manifest['version'] != _traceVersion) {
    throw const FormatException('incompatible GS trace');
  }
  final events = manifest['events'] as int;
  final software = _replayStream(directory, events);
  if (target != null) _saveDrawTarget(software, target, '$directory/target-software.png');
  final gs = _loadStart(directory);
  final bytes = _readStream(directory, events);
  final gpu = omitDraws ? null : await GpuFrameSink.create();
  if (!omitDraws && gpu == null) throw StateError('host GPU unavailable');
  final draws = File('$directory/draws.jsonl').readAsLinesSync()
      .map((line) => jsonDecode(line) as Map).toList();
  final softwareSamples = omitDraws
      ? const <Map<String, double>>[]
      : [for (var i = 0; i < 3; i++) _measureSoftware(directory, bytes, draws)];
  if (!omitDraws) stdout.writeln(jsonEncode({'softwareTiming': softwareSamples}));
  final transfer = Int64List(2);
  var atDraw = 0, rendered = 0, noEffect = 0, feedbackDraws = 0;
  GsHostDraw? pending;
  gsReplayDraw = (draw, _) {
    if (atDraw >= draws.length || pending != null) {
      throw StateError('unexpected draw in GS event stream');
    }
    pending = draw;
    atDraw++;
  };
  final clock = Stopwatch()..start();
  var setupTicks = 0, packetTicks = 0, gpuTicks = 0, writebackTicks = 0;
  try {
    for (var at = 0; at < bytes.lengthInBytes; at += 16) {
      final before = atDraw;
      final isDraw = before < draws.length && draws[before]['event'] == at ~/ 16 + 1;
      final start = isDraw ? clock.elapsedTicks : 0;
      _issueEvent(gs, bytes, at, transfer);
      if (atDraw == before) continue;
      setupTicks += clock.elapsedTicks - start;
      final command = draws[before];
      if (atDraw != before + 1 || command['event'] != at ~/ 16 + 1) {
        throw StateError('draw $atDraw is out of order');
      }
      final draw = pending;
      pending = null;
      if (draw == null) {
        if (command['unsupported'] != 'no_raster_effect') {
          throw StateError('draw $atDraw cannot be replayed on GPU');
        }
        noEffect++;
        continue;
      }
      if (gpu == null) continue;
      final packetStart = clock.elapsedTicks;
      final frame = draw.buildFrame() as Ps2SpriteFrame;
      final gpuStart = clock.elapsedTicks;
      packetTicks += gpuStart - packetStart;
      final resident = _hasResidentFeedback(command);
      if (resident) feedbackDraws++;
      Uint8List? result;
      for (var attempt = 0; attempt < 4; attempt++) {
        final first = await (resident
                ? _residentFeedback(gpu, command, frame)
                : gpu.drawPs2(frame))
            .timeout(const Duration(seconds: 10), onTimeout: () => null);
        if (first == null || !_validReadback(frame, first)) continue;
        try {
          final pixels = resident ? first : await _applyFeedback(gpu, command, frame, first);
          if (pixels != null && _validReadback(frame, pixels)) {
            result = pixels;
            break;
          }
        } on FormatException {
          continue;
        }
      }
      if (result == null) throw StateError('GPU readback failed at draw $atDraw');
      final writebackStart = clock.elapsedTicks;
      gpuTicks += writebackStart - gpuStart;
      draw.writeCoverage(gs.mem, result);
      writebackTicks += clock.elapsedTicks - writebackStart;
      rendered++;
      if (rendered % 500 == 0) stdout.writeln('GPU applied $rendered draws');
    }
    clock.stop();
    if (atDraw != draws.length || !omitDraws && rendered != manifest['gpuPackets']) {
      throw StateError('incomplete GS replay');
    }
    if (omitDraws) {
      if (target != null) {
        _saveDrawTarget(gs, target, '$directory/target-draws-omitted.png');
      } else {
        savePng(gs.image(), '$directory/full-draws-omitted.png');
      }
      return;
    }
    if (target != null) _saveDrawTarget(gs, target, '$directory/target-gpu.png');
    savePng(gs.image(), '$directory/full-gpu.png');
    double ms(int ticks) => 1000 * ticks / clock.frequency;
    final summary = {'frame': manifest['frame'], 'events': events,
      'gpuDraws': rendered, 'noRasterEffect': noEffect,
      'residentFeedbackDraws': feedbackDraws, 'softwareTiming': softwareSamples,
      'gpuTiming': {
        'drawMs': ms(setupTicks + packetTicks + gpuTicks + writebackTicks),
        'streamMs': ms(clock.elapsedTicks),
        'drawSetupMs': ms(setupTicks),
        'packetBuildMs': ms(packetTicks),
        'submitThroughReadbackMs': ms(gpuTicks),
        'vramWritebackMs': ms(writebackTicks),
      },
    };
    File('$directory/full-gpu-summary.json').writeAsStringSync(jsonEncode(summary));
    stdout.writeln(jsonEncode(summary));
  } finally {
    gsReplayDraw = null;
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ColoredBox(color: Color(0xff000000)));
  try {
    if ((args.length == 2 || args.length == 3) &&
        (args.first == 'full' || args.first == 'full-omit')) {
      await _fullReplay(args[1], omitDraws: args.first == 'full-omit',
          target: args.length == 3 ? int.parse(args[2]) : null);
      exit(0);
    }
    if (args.length == 3 && args.first == 'record') {
      await _record(args[1], args[2]);
      exit(0);
    }
    if ((args.length == 2 || args.length == 3) &&
        (args.first == 'replay' || args.first == 'replay-atlas' ||
         args.first == 'replay-feedback')) {
      exit(await _replay(args[1], args.length == 3 ? int.parse(args[2]) : null,
          atlas: args.first != 'replay', feedbackOnly: args.first == 'replay-feedback'));
    }
    throw ArgumentError('usage: record CONFIG OUTPUT | '
        'replay|replay-atlas|replay-feedback TRACE [LIMIT] | '
        'full|full-omit TRACE [DISPFB2]');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
}
