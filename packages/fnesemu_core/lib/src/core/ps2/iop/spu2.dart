import 'dart:typed_data';

import '../../../components/spu/adpcm.dart';
import '../state.dart';

/// The sound processor (SPU2) at 0x1f900000..0x1f9007ff: two cores of 24
/// voices that share 2MB of sound memory.
///
/// The register layout follows the libsd header of the open PS2 SDK and the
/// ps2tek AutoDMA page. The voices work like the PS1 SPU: 16-byte ADPCM
/// blocks of 28 samples, the ADSR envelope and the 4-point gaussian
/// interpolation.
///
/// Not modelled: reverb, noise, volume sweeps (a sweep jumps to its end
/// value), the MMIX switches and the core input volumes. Core 0 always mixes
/// into core 1 and the AutoDMA input always mixes into its core. The read
/// side effects of IRQINFO and the order of the STATX bits are unverified.
class Spu2 {
  static const base = 0x1f900000, end = 0x1f900800;
  static const sampleHz = 48000;

  /// IOP clocks per output sample: 36.864MHz / 48kHz
  static const clocksPerSample = 768;

  static bool handles(int address) => address >= base && address < end;

  /// sound memory in halfwords; the registers address it in halfwords
  final ram = Uint16List(0x100000);
  final cores = [Spu2Core(0), Spu2Core(1)];

  /// called when a core reaches its interrupt address
  void Function()? onInterrupt;

  /// called with the stereo samples when [output] is full
  void Function(Float32List)? onAudio;

  final output = Float32List(1024 * 2);
  int _outputIndex = 0;
  int _clocks = 0;

  /// bit 2 + core: the core reached its interrupt address
  int irqInfo = 0;
  final _common = Uint16List(0x50);

  void saveState(StateWriter w) {
    w.section('spu2');
    w.typed(ram);
    w.typed(_common);
    w.typed(output);
    w.ints([irqInfo, _outputIndex, _clocks]);
    for (final c in cores) {
      c.saveState(w);
    }
  }

  void loadState(StateReader s) {
    s.section('spu2');
    s.typed(ram);
    s.typed(_common);
    s.typed(output);
    final v = s.fields(3, 'spu2');
    irqInfo = v[0];
    _outputIndex = v[1];
    _clocks = v[2];
    for (final c in cores) {
      c.loadState(s);
    }
  }

  void reset() {
    ram.fillRange(0, ram.length, 0);
    for (final c in cores) {
      c.reset();
    }
    irqInfo = 0;
    _common.fillRange(0, _common.length, 0);
    _outputIndex = _clocks = 0;
  }

  // ---- registers ----

  int read(int address, int size) {
    if (size == 4) return read16(address) | read16(address + 2) << 16;
    return read16(address & ~1);
  }

  void write(int address, int size, int value) {
    if (size == 4) {
      write16(address, value & 0xffff);
      write16(address + 2, (value >> 16) & 0xffff);
    } else {
      write16(address & ~1, value & 0xffff);
    }
  }

  int read16(int address) {
    final o = address - base;
    if (o >= 0x760) {
      if (o == 0x7c2) return irqInfo;
      if (o < 0x7b0) {
        final c = cores[(o - 0x760) ~/ 0x28];
        final r = (o - 0x760) % 0x28;
        if (r == 0x10) return c.mvolxL;
        if (r == 0x12) return c.mvolxR;
      }
      return _common[(o - 0x760) >> 1];
    }
    final core = cores[o >> 10];
    final r = o & 0x3ff;
    if (r < 0x180) return core.voices[r >> 4].read((r >> 1) & 7);
    if (r >= 0x1c0 && r < 0x2e0) {
      final v = core.voices[(r - 0x1c0) ~/ 12];
      final addr = switch (((r - 0x1c0) % 12) >> 2) {
        0 => v.ssa,
        1 => v.lsa,
        _ => v.nax,
      };
      return r & 2 == 0 ? addr >> 16 : addr & 0xffff;
    }
    switch (r) {
      case 0x19a:
        return core.attr;
      case 0x19c:
        return core.irqa >> 16;
      case 0x19e:
        return core.irqa & 0xffff;
      case 0x1a8:
        return core.tsa >> 16;
      case 0x1aa:
        return core.tsa & 0xffff;
      case 0x1ac:
        final v = _readRam(core.tsa);
        core.tsa = (core.tsa + 1) & 0xfffff;
        return v;
      case 0x1b0:
        return core.admaCtrl;
      case 0x340:
        return core.endx & 0xffff;
      case 0x342:
        return core.endx >> 16;
      case 0x344:
        // STATX: bit 7 reports that the core takes data (observed from BIOS
        // polling; unverified)
        return 0x80;
    }
    return core.regs[r >> 1];
  }

  void write16(int address, int value) {
    final o = address - base;
    if (o >= 0x760) {
      _common[(o - 0x760) >> 1] = value;
      if (o < 0x7b0) {
        final c = cores[(o - 0x760) ~/ 0x28];
        final r = (o - 0x760) % 0x28;
        if (r == 0) c.mvolxL = Spu2Voice.volume(value, c.mvolxL);
        if (r == 2) c.mvolxR = Spu2Voice.volume(value, c.mvolxR);
      }
      return;
    }
    final core = cores[o >> 10];
    final r = o & 0x3ff;
    core.regs[r >> 1] = value;
    if (r < 0x180) {
      core.voices[r >> 4].write((r >> 1) & 7, value);
      return;
    }
    if (r >= 0x1c0 && r < 0x2e0) {
      final v = core.voices[(r - 0x1c0) ~/ 12];
      int set(int old) => r & 2 == 0
          ? (value & 0xf) << 16 | (old & 0xffff)
          : (old & 0xf0000) | value;
      switch (((r - 0x1c0) % 12) >> 2) {
        case 0:
          v.ssa = set(v.ssa);
        case 1:
          v.lsa = set(v.lsa);
          v.lsaSet = true;
        case 2:
          v.nax = set(v.nax);
      }
      return;
    }
    switch (r) {
      case 0x180:
        core.pmon = (core.pmon & 0xff0000) | value;
      case 0x182:
        core.pmon = (core.pmon & 0xffff) | (value & 0xff) << 16;
      case 0x188:
        core.vmixl = (core.vmixl & 0xff0000) | value;
      case 0x18a:
        core.vmixl = (core.vmixl & 0xffff) | (value & 0xff) << 16;
      case 0x190:
        core.vmixr = (core.vmixr & 0xff0000) | value;
      case 0x192:
        core.vmixr = (core.vmixr & 0xffff) | (value & 0xff) << 16;
      case 0x19a:
        core.attr = value;
        // clearing the interrupt enable acknowledges the interrupt
        if (value & 0x40 == 0) irqInfo &= ~(4 << core.index);
      case 0x19c:
        core.irqa = (value & 0xf) << 16 | (core.irqa & 0xffff);
      case 0x19e:
        core.irqa = (core.irqa & 0xf0000) | value;
      case 0x1a0:
        _keyOn(core, value);
      case 0x1a2:
        _keyOn(core, (value & 0xff) << 16);
      case 0x1a4:
        core.keyOff(value);
      case 0x1a6:
        core.keyOff((value & 0xff) << 16);
      case 0x1a8:
        core.tsa = (value & 0xf) << 16 | (core.tsa & 0xffff);
      case 0x1aa:
        core.tsa = (core.tsa & 0xf0000) | value;
      case 0x1ac:
        writeTransfer(core.index, value);
      case 0x1b0:
        core.setAdmaCtrl(value);
      case 0x340:
      case 0x342:
        core.endx = 0; // unverified
    }
  }

  void _keyOn(Spu2Core core, int bits) {
    for (var i = 0; i < 24; i++) {
      if (bits & (1 << i) != 0) {
        core.voices[i].keyOn();
        core.voicesIdle = false;
        core.endx &= ~(1 << i);
      }
    }
  }

  // ---- transfers ----

  /// true when DMA to [core] goes to the AutoDMA input buffer
  bool autoDma(int core) => cores[core].admaActive;

  /// true when the AutoDMA input of [core] has room for a block
  bool admaWants(int core) => cores[core].admaFree > 0;

  /// stores an AutoDMA block of 256 left samples and 256 right samples
  void admaBlock(int core, List<int> halfwords) {
    final c = cores[core];
    final at = 0x2000 + core * 0x400 + c.admaWriteHalf * 0x100;
    for (var i = 0; i < 256; i++) {
      ram[at + i] = halfwords[i];
      ram[at + 0x200 + i] = halfwords[256 + i];
    }
    c.admaWriteHalf ^= 1;
    c.admaFree--;
  }

  /// writes a halfword at the transfer address of [core]
  void writeTransfer(int core, int value) {
    final c = cores[core];
    _checkIrq(c.tsa, 1);
    ram[c.tsa] = value;
    c.tsa = (c.tsa + 1) & 0xfffff;
  }

  /// reads a halfword at the transfer address of [core]
  int readTransfer(int core) {
    final c = cores[core];
    final v = _readRam(c.tsa);
    c.tsa = (c.tsa + 1) & 0xfffff;
    return v;
  }

  int _readRam(int address) {
    _checkIrq(address, 1);
    return ram[address];
  }

  /// raises the interrupt of a core whose address is in [address] ..
  /// [address] + [length]
  void _checkIrq(int address, int length) {
    for (final c in cores) {
      if (c.attr & 0x40 == 0) continue;
      if (c.irqa >= address && c.irqa < address + length) {
        if (irqInfo & (4 << c.index) == 0) {
          irqInfo |= 4 << c.index;
          onInterrupt?.call();
        }
      }
    }
  }

  // ---- output ----

  /// advances by [clocks] IOP clocks
  void advance(int clocks) {
    _clocks += clocks;
    while (_clocks >= clocksPerSample) {
      _clocks -= clocksPerSample;
      _sample();
    }
  }

  void _sample() {
    var left = 0, right = 0;
    for (final c in cores) {
      var l = left, r = right;
      left = right = 0;
      if (c.voicesIdle && !c.admaActive) {
        left = l * c.mvolxL >> 15;
        right = r * c.mvolxR >> 15;
        continue;
      }
      var prev = 0;
      var sounding = 0;
      final voices = c.voices;
      for (var i = 0; i < 24; i++) {
        final v = voices[i];
        if (v.phase == Spu2Voice.off) {
          prev = 0;
          continue;
        }
        final s = v.clock(this, c.pmon & (1 << i) != 0 && i > 0, prev);
        if (v.phase != Spu2Voice.off) sounding++;
        if (v.endReached) {
          v.endReached = false;
          c.endx |= 1 << i;
        }
        prev = s;
        if (c.vmixl & (1 << i) != 0) l += s * v.volxL >> 15;
        if (c.vmixr & (1 << i) != 0) r += s * v.volxR >> 15;
      }
      if (sounding == 0) c.voicesIdle = true;
      if (c.admaActive) {
        final at = 0x2000 + c.index * 0x400 + c.admaPlayHalf * 0x100;
        l += ram[at + c.admaPos].toSigned(16);
        r += ram[at + 0x200 + c.admaPos].toSigned(16);
        if (++c.admaPos == 0x100) {
          c.admaPos = 0;
          c.admaPlayHalf ^= 1;
          if (c.admaFree < 2) c.admaFree++;
        }
      }
      left = l * c.mvolxL >> 15;
      right = r * c.mvolxR >> 15;
    }
    final out = output;
    out[_outputIndex] = _clip(left) / 0x8000;
    out[_outputIndex + 1] = _clip(right) / 0x8000;
    _outputIndex += 2;
    if (_outputIndex == out.length) {
      _outputIndex = 0;
      onAudio?.call(Float32List.fromList(out));
    }
  }

  static int _clip(int v) => v < -0x8000 ? -0x8000 : (v > 0x7fff ? 0x7fff : v);
}

/// A core of the SPU2.
class Spu2Core {
  final int index;
  final voices = List.generate(24, (_) => Spu2Voice());

  /// the other registers of the core read back as written
  final regs = Uint16List(0x200);
  int attr = 0, irqa = 0, tsa = 0, admaCtrl = 0, endx = 0;
  int pmon = 0, vmixl = 0, vmixr = 0;
  int mvolxL = 0, mvolxR = 0;

  /// whether every voice is off, kept by the key-on path and by the
  /// sample loop, so an idle core costs only its master volume scaling
  bool voicesIdle = true;

  // the AutoDMA input: two halves of 256 samples per side, one plays while
  // the DMA fills the other
  bool admaActive = false;
  int admaPos = 0, admaPlayHalf = 0, admaWriteHalf = 0, admaFree = 0;

  Spu2Core(this.index);

  void saveState(StateWriter w) {
    w.typed(regs);
    w.ints([
      attr, irqa, tsa, admaCtrl, endx, pmon, vmixl, vmixr, mvolxL, //
      mvolxR, admaPos, admaPlayHalf, admaWriteHalf, admaFree
    ]);
    w.boolean(admaActive);
    for (final v in voices) {
      v.saveState(w);
    }
  }

  void loadState(StateReader s) {
    s.typed(regs);
    final v = s.fields(14, 'spu2 core');
    attr = v[0];
    irqa = v[1];
    tsa = v[2];
    admaCtrl = v[3];
    endx = v[4];
    pmon = v[5];
    vmixl = v[6];
    vmixr = v[7];
    mvolxL = v[8];
    mvolxR = v[9];
    admaPos = v[10];
    admaPlayHalf = v[11];
    admaWriteHalf = v[12];
    admaFree = v[13];
    admaActive = s.boolean();
    for (final voice in voices) {
      voice.loadState(s);
    }
    voicesIdle = voices.every((v) => v.phase == Spu2Voice.off);
  }

  void reset() {
    for (final v in voices) {
      v.reset();
    }
    regs.fillRange(0, regs.length, 0);
    attr = irqa = tsa = admaCtrl = endx = 0;
    pmon = vmixl = vmixr = mvolxL = mvolxR = 0;
    voicesIdle = true;
    setAdmaCtrl(0);
  }

  /// bit 0 starts the AutoDMA of core 0 and bit 1 that of core 1
  void setAdmaCtrl(int value) {
    final active = value & (1 << index) != 0;
    if (active && !admaActive) {
      admaPos = admaPlayHalf = admaWriteHalf = 0;
      admaFree = 2;
    }
    admaCtrl = value;
    admaActive = active;
  }

  void keyOff(int bits) {
    for (var i = 0; i < 24; i++) {
      if (bits & (1 << i) != 0) voices[i].keyOff();
    }
  }
}

/// A voice of a SPU2 core. Addresses are in halfwords.
class Spu2Voice {
  static const off = 0, attack = 1, decay = 2, sustain = 3, release = 4;

  int volL = 0, volR = 0, pitch = 0, adsr1 = 0, adsr2 = 0;
  int envx = 0, volxL = 0, volxR = 0;
  int ssa = 0, lsa = 0, nax = 0;

  /// LSA was written after the key on, so the start flags do not set it
  bool lsaSet = false;
  int phase = off;

  /// set when the voice passed a block with the end flag
  bool endReached = false;

  int _envCycles = 0;
  int _counter = 0, _index = 0;
  int _hist1 = 0, _hist2 = 0;

  // 4 samples of the previous block, then the 28 samples of this block
  final _samples = Int32List(32);

  void saveState(StateWriter w) {
    w.ints([
      volL, volR, pitch, adsr1, adsr2, envx, volxL, volxR, ssa, lsa, //
      nax, phase, _envCycles, _counter, _index, _hist1, _hist2, _flags
    ]);
    for (final b in [lsaSet, endReached, _pendingDecode]) {
      w.boolean(b);
    }
    w.typed(_samples);
  }

  void loadState(StateReader s) {
    final v = s.fields(18, 'spu2 voice');
    volL = v[0];
    volR = v[1];
    pitch = v[2];
    adsr1 = v[3];
    adsr2 = v[4];
    envx = v[5];
    volxL = v[6];
    volxR = v[7];
    ssa = v[8];
    lsa = v[9];
    nax = v[10];
    phase = v[11];
    _envCycles = v[12];
    _counter = v[13];
    _index = v[14];
    _hist1 = v[15];
    _hist2 = v[16];
    _flags = v[17];
    lsaSet = s.boolean();
    endReached = s.boolean();
    _pendingDecode = s.boolean();
    s.typed(_samples);
  }

  void reset() {
    volL = volR = pitch = adsr1 = adsr2 = envx = volxL = volxR = 0;
    ssa = lsa = nax = 0;
    lsaSet = false;
    phase = off;
    endReached = false;
    _envCycles = _counter = _index = _hist1 = _hist2 = 0;
    _samples.fillRange(0, 32, 0);
  }

  int read(int reg) => switch (reg) {
        0 => volL,
        1 => volR,
        2 => pitch,
        3 => adsr1,
        4 => adsr2,
        5 => envx,
        6 => volxL,
        _ => volxR,
      };

  void write(int reg, int value) {
    switch (reg) {
      case 0:
        volL = value;
        volxL = volume(value, volxL);
      case 1:
        volR = value;
        volxR = volume(value, volxR);
      case 2:
        pitch = value;
      case 3:
        adsr1 = value;
      case 4:
        adsr2 = value;
      case 5:
        envx = value & 0x7fff;
      case 6:
        volxL = value;
      case 7:
        volxR = value;
    }
  }

  /// The current volume after a write of [value] to a volume register. A
  /// fixed volume holds 15 bits; a sweep jumps to its end value.
  static int volume(int value, int current) {
    if (value & 0x8000 == 0) return ((value << 1) & 0xffff).toSigned(16);
    final decrease = value & 0x2000 != 0;
    final negative = value & 0x1000 != 0;
    if (decrease) return 0;
    return negative ? -0x8000 : 0x7fff;
  }

  void keyOn() {
    nax = ssa;
    lsaSet = false;
    _counter = _index = _hist1 = _hist2 = 0;
    _samples.fillRange(0, 32, 0);
    envx = 0;
    _envCycles = 0;
    phase = attack;
    endReached = false;
    _pendingDecode = true;
  }

  void keyOff() {
    if (phase != off) phase = release;
  }

  bool _pendingDecode = false;

  /// the next sample before the volume
  int clock(Spu2 spu, bool modulated, int previous) {
    if (_pendingDecode) {
      _pendingDecode = false;
      _decode(spu);
    }
    var step = pitch;
    if (modulated) {
      step = (step.toSigned(16) * (previous + 0x8000)) >> 15 & 0xffff;
    }
    if (step > 0x3fff) step = 0x3fff;
    _counter += step;
    _index += _counter >> 12;
    _counter &= 0xfff;
    while (_index >= 28) {
      _index -= 28;
      _endBlock();
      _decode(spu);
    }
    final i = _index + 4;
    final g = _counter >> 4 & 0xff;
    final s = spuGaussian(
        _samples[i], _samples[i - 1], _samples[i - 2], _samples[i - 3], g);
    _envelope();
    return s * envx >> 15;
  }

  void _decode(Spu2 spu) {
    final ram = spu.ram;
    spu._checkIrq(nax, 8);
    final header = ram[nax];
    final flags = header >> 8;
    if (flags & 4 != 0 && !lsaSet) lsa = nax;
    var shift = header & 0xf;
    if (shift > 12) shift = 9;
    final f = (header >> 4) & 7;
    final c1 = spuAdpcmFilter1[f > 4 ? 4 : f], c2 = spuAdpcmFilter2[f > 4 ? 4 : f];
    final samples = _samples;
    for (var i = 0; i < 4; i++) {
      samples[i] = samples[28 + i];
    }
    var h1 = _hist1, h2 = _hist2;
    for (var i = 0; i < 28; i++) {
      final word = ram[(nax + 1 + (i >> 2)) & 0xfffff];
      final nibble = ((word >> ((i & 3) * 4)) & 0xf) << 28 >> 28;
      var v = (nibble << 12 >> shift) + ((c1 * h1 + c2 * h2 + 32) >> 6);
      v = v < -0x8000 ? -0x8000 : (v > 0x7fff ? 0x7fff : v);
      samples[4 + i] = v;
      h2 = h1;
      h1 = v;
    }
    _hist1 = h1;
    _hist2 = h2;
    nax = (nax + 8) & 0xfffff;
    _flags = flags;
  }

  // the flags of the playing block
  int _flags = 0;

  /// The end flag of a block takes effect after its samples: the voice goes
  /// on at the loop address, and without the repeat flag it goes silent.
  void _endBlock() {
    if (_flags & 1 == 0) return;
    endReached = true;
    nax = lsa;
    if (_flags & 2 == 0) {
      phase = release;
      envx = 0;
    }
  }

  void _envelope() {
    switch (phase) {
      case attack:
        _step((adsr1 >> 8) & 0x7f, false, adsr1 & 0x8000 != 0);
        if (envx >= 0x7fff) {
          envx = 0x7fff;
          phase = decay;
        }
      case decay:
        _step(((adsr1 >> 4) & 0xf) << 2, true, true);
        final level = ((adsr1 & 0xf) + 1) << 11;
        if (envx <= level) phase = sustain;
      case sustain:
        _step((adsr2 >> 6) & 0x7f, adsr2 & 0x4000 != 0, adsr2 & 0x8000 != 0);
      case release:
        _step((adsr2 & 0x1f) << 2, true, adsr2 & 0x20 != 0);
        if (envx == 0) phase = off;
    }
  }

  /// one envelope clock at [rate] as described for the PS1 SPU ADSR
  void _step(int rate, bool decrease, bool exponential) {
    final shift = rate >> 2;
    var step = decrease ? -8 + (rate & 3) : 7 - (rate & 3);
    var cycles = 1 << (shift > 11 ? shift - 11 : 0);
    if (shift < 11) step <<= 11 - shift;
    if (exponential) {
      if (!decrease && envx > 0x6000) cycles <<= 2;
      if (decrease) step = step * envx >> 15;
    }
    if (++_envCycles < cycles) return;
    _envCycles = 0;
    var v = envx + step;
    if (v < 0) v = 0;
    if (v > 0x7fff) v = 0x7fff;
    envx = v;
  }

}
