import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/ps/bus.dart';
import 'package:fnesemu/core/ps/spu.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

// flutter: SPU: keyOn 0 006140 000400
// flutter: SPU: keyOn 1 006140 000407
// flutter: SPU: keyOn 2 006140 000800
// flutter: SPU: keyOn 3 006140 00080e

// flutter: SPU: keyOn 0 001000 00047d
// flutter: SPU: keyOn 1 001000 000485

const rateHz = 44100;

//
// dart run lib\tools\ps_spu.dart spu_ram.bin
//
// before running this script, set the dynamic library path:
// - windows: $env:Path += ";build\windows\x64\plugins\mp_audio_stream\shared\Debug"
// - Linux: export LD_LIBRARY_PATH=build/linux/x64/plugins/mp_audio_stream/shared
// - MacOS: export DYLD_LIBRARY_PATH=build/macos/Debug
//

class Events {
  final int clock;
  final bool keyOn;
  final int ch;
  final int address;
  final int pitch;
  final int volL;
  final int volR;
  final int adsr;

  Events(this.clock, this.keyOn, this.ch, this.address, this.pitch, this.volL,
      this.volR, this.adsr);
}

main(List<String> args) {
  final bus = Bus();
  final spu = Spu(bus);

  const playDurationSec = 12;

  final player = getAudioStream()
    ..init(
        bufferMilliSec: playDurationSec * 1000,
        sampleRate: rateHz,
        channels: 2);

  bool enabled =
      true; // "false" requires events.txt to have "#begin" and "#end"
  final events = List<Events>.empty(growable: true);
  for (final e in File(args[1]).readAsLinesSync()) {
    if (e == "#begin") {
      enabled = true;
      continue;
    }
    if (e == "#end") {
      enabled = false;
      continue;
    }

    if (!enabled) {
      continue;
    }

    final parts = e.split(",");
    events.add(Events(
        int.parse(parts[0]),
        parts[1] == "keyOn",
        int.parse(parts[2]),
        int.parse(parts[3].substring(2), radix: 16),
        int.parse(parts[4].substring(2), radix: 16),
        int.parse(parts[5].substring(2), radix: 16),
        int.parse(parts[6].substring(2), radix: 16),
        int.parse(parts[7].substring(2), radix: 16)));
  }

  spu.ram.setAll(0, File(args[0]).readAsBytesSync());

  const clockStepMs = 10;
  const samplesInStep = rateHz * clockStepMs ~/ 1000;

  final buf = Float32List(samplesInStep * 2);
  int bufIndex = 0;

  int clock = 0;

  for (final e in events) {
    while (e.clock > clock) {
      for (int i = 0; i < samplesInStep; i++) {
        clock += 768;
        final (l, r) = spu.render();
        buf[bufIndex++] = l;
        buf[bufIndex++] = r;
      }
      player.push(buf);
      bufIndex = 0;
    }

    if (e.keyOn) {
      spu.writeVoice(0x00, e.ch, e.volL); // vol l
      spu.writeVoice(0x02, e.ch, e.volR); // vol r
      spu.writeVoice(0x04, e.ch, e.pitch); // pitch
      spu.writeVoice(0x06, e.ch, e.address >> 3); // startAddress
      spu.writeVoice(0x08, e.ch, e.adsr & 0xffff); // adsr
      spu.writeVoice(0x0a, e.ch, e.adsr >> 16); // adsr
      spu.keyOn(1 << e.ch);
    } else {
      spu.keyOff(1 << e.ch);
    }
  }

  for (int j = 0; j < playDurationSec * rateHz ~/ samplesInStep; j++) {
    for (int i = 0; i < samplesInStep; i++) {
      final (l, r) = spu.render();
      buf[bufIndex++] = l;
      buf[bufIndex++] = r;
    }
    player.push(buf);
    bufIndex = 0;
  }

  // sleep(Duration(seconds: clock ~/ (768 * 44100)));
  sleep(Duration(seconds: playDurationSec));
}
