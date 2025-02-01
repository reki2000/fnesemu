import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/md/sn76489.dart';
import 'package:fnesemu/core/md/ym2612.dart';
import 'package:fnesemu/util/double.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

import 'package:mp_audio_stream/mp_audio_stream.dart';

const rateHz = 44100;
const loopHz = 60 * 250;
const million = 1000000;
const loopDurationUs = million / loopHz;

class VgmPlayer {
  final psg = Sn76489();
  final fm = Ym2612();

  final player = getAudioStream()
    ..init(bufferMilliSec: 4000, sampleRate: rateHz, channels: 2);

  late VgmFile vgm;

  bool running = true;

  List<int> dataBlock = [];
  int dataBlockIndex = 0;

  int fetchDataBlock() => dataBlock[dataBlockIndex++];

  void init(VgmFile vgm) {
    this.vgm = vgm;

    if (vgm.fmClock != 0) {
      fm.setClockHz(vgm.fmClock);
    }

    if (vgm.psgClock != 0) {
      psg.setClockHz(vgm.psgClock);
    }
  }

  int fetch() => vgm.fetch8();

  int execCommands() {
    final cmd = fetch();
    // print("cmd: ${cmd.hex8}");

    switch (cmd & 0xf0) {
      case 0x70: // wait n samples
        return cmd & 0x0f + 1;
      case 0x80: // ym2612 dac output, then wait n samples
        fm.writePort8(0, 0x2a);
        fm.writeData8(0, fetchDataBlock());
        return cmd & 0xf;
    }

    switch (cmd) {
      case 0x50: // PSG write
        psg.write8(fetch());
        break;
      case 0x52:
      case 0x53: // YM2612 write
        final port = cmd & 1;
        fm.writePort8(port, fetch());
        fm.writeData8(port, fetch());
        break;
      case 0x61:
        // wait n samples
        return vgm.fetch16();
      case 0x62: // wait 735 samples
        return 735;
      case 0x63: // wait 882 samples
        return 882;
      case 0x66: // end of sound data
        running = false;
        break;

      case 0x4f: // GG stereo
        fetch();
        break;

      case 0x67: // data block
        fetch(); // skip 66h
        final type = fetch();
        if (type > 0x3f) {
          throw 'Unknown data block type: ${type.hex8}';
        }

        final len = vgm.fetch32();
        print("data block type: ${type.hex8} len: ${len.hex32}");

        dataBlock = List.generate(len, (i) => fetch());
        break;

      case 0xe0: // data block index seek
        dataBlockIndex = vgm.fetch32();
        break;

      default:
        throw 'Unknown command: ${cmd.hex8}';
    }

    return 0;
  }

  void playback() async {
    int waitAccum = 0;
    int elapsedSamples = 0;
    int elapsedOutSamples = 0;
    int elapsedFmSamples = 0;
    int elapsedPsgSamples = 0;

    int prevSeconds = 0;

    final starttedAt = DateTime.now();

    while (running) {
      final wait = execCommands();

      waitAccum += wait;
      elapsedSamples += wait;
      if (waitAccum < loopDurationUs * rateHz ~/ million) {
        continue;
      }

      //print("waitAccum: $waitAccum");
      waitAccum -= loopDurationUs * rateHz ~/ million;

      final fmSamples =
          elapsedSamples * fm.sampleHz ~/ rateHz - elapsedFmSamples;
      final fmOut = fm.render(fmSamples);
      elapsedFmSamples += fmSamples;

      final psgSamples =
          elapsedSamples * psg.sampleHz ~/ rateHz - elapsedPsgSamples;
      final psgOut = psg.render(psgSamples);
      elapsedPsgSamples += psgSamples;

      final outSamples = elapsedSamples - elapsedOutSamples;
      final buf = Float32List(outSamples * 2);
      elapsedOutSamples = elapsedSamples;

      // mix resampled psgOut + fmOut
      for (int i = 0; i < buf.length; i += 2) {
        final psgIndex = (i >> 1) * psg.sampleHz ~/ rateHz;
        final psgVal =
            psgSamples > 0 ? psgOut[psgIndex.clip(0, psgOut.length - 1)] : 0.0;

        final fmIndex = ((i >> 1) * fm.sampleHz ~/ rateHz) << 1;
        final fmValL =
            fmSamples > 0 ? fmOut[fmIndex.clip(0, fmOut.length - 2) + 0] : 0.0;
        final fmValR =
            fmSamples > 0 ? fmOut[fmIndex.clip(0, fmOut.length - 2) + 1] : 0.0;

        final mixL = psgVal * 0.3 + fmValL * 2;
        final mixR = psgVal * 0.3 + fmValR * 2;
        buf[i + 0] = mixL.clip(-1, 1);
        buf[i + 1] = mixR.clip(-1, 1);
      }

      player.push(buf);

      if (DateTime.now().difference(starttedAt).inMilliseconds <
          150 + elapsedSamples * 1000 ~/ rateHz) {
        await Future<void>.delayed(Duration(milliseconds: 100));
      }

      final elapsedSeconds = DateTime.now().difference(starttedAt).inSeconds;
      if (elapsedSeconds > prevSeconds) {
        //print(fm.dump());
        prevSeconds = elapsedSeconds;
      }
    }
  }
}

//
// dart lib\tools\vgmplayer.dart <vgmfile>
//
// before running this script, set the dynamic library path:
// - windows: $env:Path += ";build\windows\x64\plugins\mp_audio_stream\shared\Debug"
// - Linux: export LD_LIBRARY_PATH=build/linux/x64/plugins/mp_audio_stream/shared
// - MacOS: export DYLD_LIBRARY_PATH=build/macos/Debug
//
void main(List<String> args) {
  final vgmPlayer = VgmPlayer();
  if (args.isEmpty) {
    print('Usage: dart lib\tools\vgmplayer.dart <path_to_vgm_file>');
    return;
  }

  final filePath = args[0];
  final vgmData = File(filePath).readAsBytesSync();
  if (vgmData.isEmpty) {
    print('File not found: $filePath');
    return;
  }

  if (vgmData.getUInt32BE(0) != 0x56676d20) {
    print('Not a VGM file: $filePath');
    return;
  }

  final vgmFile = VgmFile(vgmData);
  print("start playback: $filePath $vgmFile");

  vgmPlayer.init(vgmFile);
  vgmPlayer.playback();
}

class VgmFile {
  int fmClock = 0;
  int psgClock = 0;
  int version = 0;
  int rate = 0;

  int index = 0;

  Uint8List data = Uint8List(0);

  VgmFile(this.data) {
    index = data.getUInt32LE(0x34);
    if (index == 0) {
      index = 0x40;
    } else {
      index += 0x34;
    }

    fmClock = data.getUInt32LE(0x2c);
    psgClock = data.getUInt32LE(0x0c);
    version = data.getUInt32LE(0x08);
    rate = data.getUInt32LE(0x24);
  }

  @override
  String toString() {
    return "VgmFile: version:${version.hex32} rate:$rate fmClock:$fmClock psgClock:$psgClock";
  }

  int fetch8() {
    return data[index++];
  }

  int fetch32() {
    final val = data.getUInt32LE(index);
    index += 4;
    return val;
  }

  int fetch16() {
    final val = data.getUInt16LE(index);
    index += 2;
    return val;
  }
}
