import 'dart:typed_data';

import 'package:fnesemu/util/double.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import 'bus.dart';
import 'spu_voice.dart';

class Spu {
  static const clockHz = 44100;

  final Bus bus;
  final ram = Uint8List(512 * 1024);
  late final List<Voice> voices;

  Spu(this.bus) {
    voices = List.generate(24, (i) => Voice(this, i));
  }

  int counter = 0;

  void reset() {
    counter = 0;
    for (int i = 0; i < voices.length; i++) {
      voices[i].reset();
    }
    mainVolumeLeft = 0;
    mainVolumeRight = 0;
    enabled = false;
    muted = false;
    fifoMode = 0;
    fifoType = 0;
    fifoAddr = 0;
    _fifoAddr = 0;
    irqAddr = 0;
    _irqAddr = 0;
    fifoWriteCount = 0;
  }

  (double, double) render() {
    double sumL = 0;
    double sumR = 0;
    for (int i = 0; i < voices.length; i++) {
      final (l, r) = voices[i].clock();
      sumL += l / 4;
      sumR += r / 4;
    }

    return (sumL.clip(-1.0, 1.0), sumR.clip(-1.0, 1.0));
  }

  int _status = 0;
  int get status => _status;

  int mainVolumeLeft = 0;
  int mainVolumeRight = 0;

  bool enabled = false;
  bool muted = false;

  int fifoMode = 0;
  int fifoType = 0;
  int fifoAddr = 0;
  int _fifoAddr = 0;

  int irqAddr = 0;
  int _irqAddr = 0;

  void setIrqAddr(int value) {
    irqAddr = value;
    _irqAddr = value << 3;
  }

  setFifoAddr(int value) {
    fifoAddr = value;
    _fifoAddr = value << 3;
  }

  int readRam16() {
    final result = ram.getUInt16LE(_fifoAddr);
    _fifoAddr = _fifoAddr.inc2 & 0x7ffff;
    return result;
  }

  int fifoWriteCount = 0;

  void writeFifo16(int value) {
    // if (0x1030 <= _fifoAddr && _fifoAddr < 0x1050) {
    //   debugLog(
    //       "SPU: writeFifo ${_fifoAddr.hex32} ${value.hex32} ${bus.cpu.dump()}");
    // }
    if (value != 0) fifoWriteCount++;
    ram.setUInt16LE(_fifoAddr, value);
    _fifoAddr = _fifoAddr.inc2 & 0x7ffff;
  }

  void writeCtrl(int value) {
    enabled = value.bit0;
    muted = value.bit1;
    fifoMode =
        value >> 4 & 0x03; // 0=Stop, 1=ManualWrite, 2=DMAwrite, 3=DMAread
    _status = _status.masked(0x1f, value);
  }

  int readVoice(int port, int ch) => switch (port) {
        0x00 => voices[ch].volume(0),
        0x02 => voices[ch].volume(1),
        0x04 => voices[ch].pitch,
        0x06 => voices[ch].startAddr >> 3,
        0x08 => voices[ch].adsr.mask16,
        0x0a => voices[ch].adsr >> 16,
        0x0c => voices[ch].adsrVolume,
        0x0e => voices[ch].repeatAddr >> 3,
        _ => throw "readVoice unreachable",
      };

  void writeVoice(int port, int ch, int v) => switch (port) {
        0x00 => voices[ch].setVolume(0, v),
        0x02 => voices[ch].setVolume(1, v),
        0x04 => voices[ch].pitch = v,
        0x06 => voices[ch].startAddr = v << 3,
        0x08 => voices[ch].setAttackDecay(v),
        0x0a => voices[ch].setSustainRelease(v),
        0x0c => voices[ch].adsrVolume = v,
        0x0e => voices[ch].repeatAddr = v << 3,
        _ => throw "writeVoice unreachable",
      };

  void keyOn(int value) {
    for (int i = 0; i < voices.length; i++, value >>= 1) {
      if (value.bit0) {
        voices[i].keyOn();
        logEvents("keyOn", i);
      }
    }
    // if (voices[0].pitch == 0x400 && voices[0].startAddress == 0x6140) {
    //   debugLog("SPU: dump ram into file..");
    //   File("docs/spu_ram.bin").writeAsBytesSync(ram);
    // }
  }

  void logEvents(String name, int ch) {
    // File("spu_events.txt").writeAsStringSync(
    //     "${bus.cpu.clocks},$name,$ch,0x${voices[ch].startAddr.hex24},"
    //     "0x${voices[ch].pitch.hex24},0x${voices[ch].volume(0).hex16},0x${voices[ch].volume(1).hex16},"
    //     "0x${voices[ch].adsr.hex32}\n",
    //     mode: FileMode.append);
  }

  void keyOff(int value) {
    for (int i = 0; i < voices.length; i++, value >>= 1) {
      if (value.bit0) {
        voices[i].keyOff();
        logEvents("keyOff", i);
      }
    }
  }

  int get endx {
    int result = 0;
    for (int i = 0; i < voices.length; i++) {
      if (voices[i].ended) {
        result |= 1 << i;
      }
    }
    // debugLog("SPU: endx ${result.hex32}");
    return result;
  }

  String dump() =>
      "SPU: $fifoWriteCount ${enabled ? "*" : " "}${muted ? "M" : " "} "
      "$fifoMode ${fifoAddr.hex24} ${irqAddr.hex24}\n"
      "${voices.sublist(0, 8).map((v) => v.dump()).join(" ")}\n"
      "${voices.sublist(8, 16).map((v) => v.dump()).join(" ")}\n"
      "${voices.sublist(16, 24).map((v) => v.dump()).join(" ")}";
}
