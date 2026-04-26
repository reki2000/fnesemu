import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';

import '../core/ps/cdrom.dart';
import '../util/int.dart';

const rateHz = 44100;
const loopHz = 60 * 250;
const million = 1000000;
const loopDurationUs = million / loopHz;

// resample checker from 37800Hz xa pcm to 44100Hz pcm
//  $env:Path += ";build\windows\x64\plugins\mp_audio_stream\shared\Debug"
//  dart run lib/tools/xa_resample.dart xa2.wav (37800Hz 16bit stereo pcm, exported from cdrom_xa.dart)
void main(List<String> args) async {
  final player = getAudioStream()
    ..init(bufferMilliSec: 4000, sampleRate: rateHz, channels: 2);

  final s16le2 = File(args[0]).readAsBytesSync().buffer.asInt16List();

  final s16leL = List.generate(s16le2.length ~/ 2, (i) => s16le2[i * 2]);
  final s16leR = List.generate(s16le2.length ~/ 2, (i) => s16le2[i * 2 + 1]);

  final xaBufferL = Queue<int>();
  final xaBufferR = Queue<int>();

  final cd = XaResampler();
  cd.pushInterpolated(xaBufferL, 0, s16leL, false);
  cd.pushInterpolated(xaBufferR, 1, s16leR, false);

  final xa = List.generate(
      xaBufferL.length,
      (i) => [
            xaBufferL.elementAt(i) / 0x8000,
            xaBufferR.elementAt(i) / 0x8000
          ]).expand((l) => [l[0], l[1]]);
  final samples = Float32List.fromList(xa.toList());

  int index = 0;
  while (index < samples.length) {
    player.push(samples.sublist(index, samples.length.min(index + rateHz * 2)));
    index += rateHz * 2;
    await Future.delayed(const Duration(milliseconds: 1000));
  }
}
