import 'dart:typed_data';

import '../../../util/debug.dart';
import '../../../util/double.dart';
import '../../../util/int.dart';
import '../../../util/uint8list.dart';
import '../bus.dart';
import 'reverb.dart';
import 'voice.dart';

class Spu {
  static const clockHz = 44100;

  final Bus bus;
  final ram = Uint8List(512 * 1024);
  late final List<Voice> voices;
  late final Reverb reverb;

  Spu(this.bus) {
    voices = List.generate(24, (i) => Voice(this, i));
    reverb = Reverb(this);
  }

  int counter = 0;
  int captureIndex = 0;

  void reset() {
    counter = 0;
    for (int i = 0; i < voices.length; i++) {
      voices[i].reset();
    }
    reverb.reset();

    mainVolumeLeft = 0;
    mainVolumeRight = 0;
    enabled = false;
    muted = false;
    fifoMode = 0;
    fifoType = 0;
    fifoAddr = 0;
    _fifoAddr = 0;
    _irqAddr = 0;
    fifoWriteCount = 0;
  }

  (double, double) render() {
    if (!enabled) {
      return (0.0, 0.0);
    }

    int outL = 0;
    int outR = 0;

    int reverbInputL = 0;
    int reverbInputR = 0;

    for (int i = 0; i < voices.length; i++) {
      final (l, r, sample) = voices[i].clock();
      outL += l;
      outR += r;

      if (reverb.reverbEnabled[i]) {
        reverbInputL += l;
        reverbInputR += r;
      }

      if (i == 1) {
        writeRam16(0x800 + captureIndex, sample);
      } else if (i == 3) {
        writeRam16(0xc00 + captureIndex, sample);
      }
    }

    final [cdL, cdR] = bus.cdrom.popAudioSample();
    writeRam16(0x000 + captureIndex, cdL);
    writeRam16(0x400 + captureIndex, cdR);
    outL += cdL * cdAudioInputLeft ~/ 0x8000;
    outR += cdR * cdAudioInputRight ~/ 0x8000;

    captureIndex = (captureIndex + 2) & 0x3fe;

    final (reverbL, reverbR) = reverb.render(
        reverbInputL.clip(-0x8000, 0x7fff), reverbInputR.clip(-0x8000, 0x7fff));
    outL += reverbL;
    outR += reverbR;

    // todo: apply master volume
    return ((outL / 0x8000).clip(-1.0, 1.0), (outR / 0x8000).clip(-1.0, 1.0));
  }

  int _status = 0;
  int get status => _status;
  int _control = 0;
  int get control {
    // debugLog("spu: readControl ${_control.hex32}");
    return _control;
  }

  int mainVolumeLeft = 0;
  int mainVolumeRight = 0;

  int cdAudioInputLeft = 0;
  int cdAudioInputRight = 0;
  int externalInputLeft = 0;
  int externalInputRight = 0;

  bool enabled = false;
  bool muted = false;

  int noiseFreqShift = 0; // 0-15, low = high freq
  int noiseFreqStep = 0; // 0-3, step = [4,5,6,7]

  int fifoMode = 0;
  int fifoType = 0;
  int fifoAddr = 0;
  int _fifoAddr = 0;

  bool irqEnabled = false;
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

  int get noiseFlags => voices.asMap().entries.fold(
        0,
        (acc, entry) => (acc << 1) | (entry.value.noise ? 1 : 0),
      );
  setNoiseFlags(int v) {
    for (int i = 0; i < voices.length; i++) {
      voices[i].noise = v.bit(i);
    }
  }

  int get pitchModulation => voices.asMap().entries.fold(
        0,
        (acc, entry) => (acc << 1) | (entry.value.pitchModulation ? 1 : 0),
      );
  setPitchModulation(int v) {
    for (int i = 0; i < voices.length; i++) {
      voices[i].pitchModulation = v.bit(i);
    }
  }

  int readRam16(int addr) {
    if (irqEnabled && addr == _irqAddr) {
      _status = _status.setBit(6, true); // set irq flag
      bus.setIrq(9);
      // debugLog("spu: IRQ triggered at ${_fifoAddr.hex24}");
    }

    return ram.getUint16LE(addr);
  }

  int readFifo16() {
    final result = readRam16(_fifoAddr);
    _fifoAddr = _fifoAddr.inc2 & 0x7ffff;
    return result;
  }

  void writeRam16(int addr, int value) {
    if (irqEnabled && addr == _irqAddr) {
      _status = _status.setBit(6, true); // set irq flag
      bus.setIrq(9);
      debugLog("spu: IRQ triggered at ${addr.hex24}");
    }

    ram[addr] = value.mask8;
    ram[addr + 1] = value >> 8 & 0xff;
  }

  int fifoWriteCount = 0;

  void writeFifo16(int value) {
    // if (0x1030 <= _fifoAddr && _fifoAddr < 0x1050) {
    //   debugLog(
    //       "SPU: writeFifo ${_fifoAddr.hex32} ${value.hex32} ${bus.cpu.dump()}");
    // }
    if (value != 0) fifoWriteCount++;
    writeRam16(_fifoAddr, value);
    _fifoAddr = _fifoAddr.inc2 & 0x7ffff;
  }

  void writeCtrl(int value) {
    // debugLog(
    //     "spu: writeCtrl ${value.hex32} irq:${irqEnabled ? "E" : "e"}:${_irqAddr.hex24}");
    _control = value;
    enabled = value.bit15;
    muted = !value.bit14;
    fifoMode =
        value >> 4 & 0x03; // 0=Stop, 1=ManualWrite, 2=DMAwrite, 3=DMAread
    reverb.writeEnabled = value.bit7;
    noiseFreqShift = (value >> 10) & 0x0f;
    noiseFreqStep = (value >> 8) & 0x03;

    if (value.bit6) {
      if (enabled) irqEnabled = true;
    } else {
      irqEnabled = false;
      _status = _status.setBit(6, false); // clear irq flag
    }

    _status = _status.masked(0x3f, value);
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
        _ => throw "illegal readVoice port:${port.hex8} ch:$ch",
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
        _ =>
          throw "illegal writeVoice port:${port.hex8} ch:$ch value:${v.hex32}",
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
      if (voices[i].endx) {
        result |= 1 << i;
      }
    }
    // debugLog("SPU: endx ${result.hex32}");
    return result;
  }

  String dump() =>
      "SPU: $fifoWriteCount ${enabled ? "*" : " "}${muted ? "M" : " "} "
      "$fifoMode ${fifoAddr.hex24} ${irqEnabled ? "I" : "i"}${_irqAddr.hex24}\n"
      "${voices.sublist(0, 8).map((v) => v.dump()).join(" ")}\n"
      "${voices.sublist(8, 16).map((v) => v.dump()).join(" ")}\n"
      "${voices.sublist(16, 24).map((v) => v.dump()).join(" ")}";
}
