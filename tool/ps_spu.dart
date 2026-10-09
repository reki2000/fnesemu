import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/ps/bus.dart';
import 'package:fnesemu/core/ps/spu/spu.dart';
import 'package:fnesemu/util/int.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

// flutter: SPU: keyOn 0 006140 000400
// flutter: SPU: keyOn 1 006140 000407
// flutter: SPU: keyOn 2 006140 000800
// flutter: SPU: keyOn 3 006140 00080e

// flutter: SPU: keyOn 0 001000 00047d
// flutter: SPU: keyOn 1 001000 000485

const rateHz = 44100;

//
// dart run lib\tools\ps_spu.dart --reverb="Room" spu_ram.bin spu_events.txt
//
// before running this script, set the dynamic library path:
// - windows: $env:Path += ";build\windows\x64\plugins\mp_audio_stream\shared\Debug"
// - Linux: export LD_LIBRARY_PATH=build/linux/x64/plugins/mp_audio_stream/shared
// - MacOS: export DYLD_LIBRARY_PATH=build/macos/Debug
//

class ReverbSetting {
  final List<int> data;
  final int size;
  const ReverbSetting(this.data, this.size);
}

// dAPF1  dAPF2  vIIR   vCOMB1 vCOMB2  vCOMB3  vCOMB4  vWALL   ;1F801DC0h..CEh
// vAPF1  vAPF2  mLSAME mRSAME mLCOMB1 mRCOMB1 mLCOMB2 mRCOMB2 ;1F801DD0h..DEh
// dLSAME dRSAME mLDIFF mRDIFF mLCOMB3 mRCOMB3 mLCOMB4 mRCOMB4 ;1F801DE0h..EEh
// dLDIFF dRDIFF mLAPF1 mRAPF1 mLAPF2  mRAPF2  vLIN    vRIN    ;1F801DF0h..FEh
const reverbSettings = {
  "Bios": ReverbSetting([
    0x0cf8, 0x08c8, 0x7e00, 0x5000, 0xB400, 0xb000, 0x4c00, 0xBA80, //
    0x6000, 0x5400, 0xD190, 0xAF78, 0xE8A0, 0xC1D8, 0xDE10, 0xB590, //
    0xF6B0, 0xD188, 0x82B0, 0x5708, 0x99A0, 0x7968, 0x8FB0, 0x62E8, //
    0xAF70, 0x82A8, 0x3D18, 0x2328, 0x1198, 0x0008, 0x8000, 0x8000, //
  ], 0xF6C0),
  "Room": ReverbSetting([
    0x007D, 0x005B, 0x6D80, 0x54B8, 0xBED0, 0x0000, 0x0000, 0xBA80, //
    0x5800, 0x5300, 0x04D6, 0x0333, 0x03F0, 0x0227, 0x0374, 0x01EF, //
    0x0334, 0x01B5, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, //
    0x0000, 0x0000, 0x01B4, 0x0136, 0x00B8, 0x005C, 0x8000, 0x8000, //
  ], 0x26c0),
  "StudioSmall": ReverbSetting([
    0x0033, 0x0025, 0x70F0, 0x4FA8, 0xBCE0, 0x4410, 0xC0F0, 0x9C00, //
    0x5280, 0x4EC0, 0x03E4, 0x031B, 0x03A4, 0x02AF, 0x0372, 0x0266, //
    0x031C, 0x025D, 0x025C, 0x018E, 0x022F, 0x0135, 0x01D2, 0x00B7, //
    0x018F, 0x00B5, 0x00B4, 0x0080, 0x004C, 0x0026, 0x8000, 0x8000, //
  ], 0x1f40),
  "StudioMedium": ReverbSetting([
    0x00B1, 0x007F, 0x70F0, 0x4FA8, 0xBCE0, 0x4510, 0xBEF0, 0xB4C0, //
    0x5280, 0x4EC0, 0x0904, 0x076B, 0x0824, 0x065F, 0x07A2, 0x0616, //
    0x076C, 0x05ED, 0x05EC, 0x042E, 0x050F, 0x0305, 0x0462, 0x02B7, //
    0x042F, 0x0265, 0x0264, 0x01B2, 0x0100, 0x0080, 0x8000, 0x8000, //
  ], 0x4840),
  "ChaosEcho": ReverbSetting([
    0x0001, 0x0001, 0x7FFF, 0x7FFF, 0x0000, 0x0000, 0x0000, 0x8100, //
    0x0000, 0x0000, 0x1FFF, 0x0FFF, 0x1005, 0x0005, 0x0000, 0x0000, //
    0x1005, 0x0005, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, //
    0x0000, 0x0000, 0x1004, 0x1002, 0x0004, 0x0002, 0x8000, 0x8000, //
  ], 0x18040),
  "Delay": ReverbSetting([
    0x0001, 0x0001, 0x7FFF, 0x7FFF, 0x0000, 0x0000, 0x0000, 0x0000, //
    0x0000, 0x0000, 0x1FFF, 0x0FFF, 0x1005, 0x0005, 0x0000, 0x0000, //
    0x1005, 0x0005, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, //
    0x0000, 0x0000, 0x1004, 0x1002, 0x0004, 0x0002, 0x8000, 0x8000, //
  ], 0x18040),
  "Off": ReverbSetting([
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, //
    0x0000, 0x0000, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, //
    0x0000, 0x0000, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, //
    0x0000, 0x0000, 0x0001, 0x0001, 0x0001, 0x0001, 0x0000, 0x0000, //
  ], 0x10),
};

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

  int argsIndex = 0;

  // apply reverb settings
  if (args[0].startsWith("--reverb")) {
    final key = args[0].substring("--reverb=".length);
    final setting = reverbSettings[key];
    if (setting == null) {
      print("Unknown reverb setting: $key");
      return;
    }

    argsIndex += 1;

    for (int i = 0; i < setting.data.length; i++) {
      spu.reverb.write16(i * 2 + 0xc0, setting.data[i]);
    }
    spu.reverb.writeEnabled = true;
    spu.reverb.outputVolume[0] = 0x8000;
    spu.reverb.outputVolume[1] = 0x8000;
    spu.reverb.reverbEnabled.fillRange(0, 24, true);
    spu.reverb.setBaseAddr(0x80000 - setting.size);
    print("SPU: reverb setting: ${spu.reverb.dump()}}");
  }

  // "false" requires events.txt to have "#begin" and "#end"
  bool enabled = true;
  final events = List<Events>.empty(growable: true);
  for (final e in File(args[argsIndex + 1]).readAsLinesSync()) {
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

  spu.ram.setAll(0, File(args[argsIndex]).readAsBytesSync());

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
      spu.writeVoice(0x06, e.ch, e.address.shr3); // startAddress
      spu.writeVoice(0x08, e.ch, e.adsr & 0xffff); // adsr
      spu.writeVoice(0x0a, e.ch, e.adsr.shr16); // adsr
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
