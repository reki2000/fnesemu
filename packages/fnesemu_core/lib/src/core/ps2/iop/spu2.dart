import 'dart:typed_data';

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
      var prev = 0;
      final voices = c.voices;
      for (var i = 0; i < 24; i++) {
        final v = voices[i];
        if (v.phase == Spu2Voice.off) {
          prev = 0;
          continue;
        }
        final s = v.clock(this, c.pmon & (1 << i) != 0 && i > 0, prev);
        if (v.endReached) {
          v.endReached = false;
          c.endx |= 1 << i;
        }
        prev = s;
        if (c.vmixl & (1 << i) != 0) l += s * v.volxL >> 15;
        if (c.vmixr & (1 << i) != 0) r += s * v.volxR >> 15;
      }
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

  // the AutoDMA input: two halves of 256 samples per side, one plays while
  // the DMA fills the other
  bool admaActive = false;
  int admaPos = 0, admaPlayHalf = 0, admaWriteHalf = 0, admaFree = 0;

  Spu2Core(this.index);

  void reset() {
    for (final v in voices) {
      v.reset();
    }
    regs.fillRange(0, regs.length, 0);
    attr = irqa = tsa = admaCtrl = endx = 0;
    pmon = vmixl = vmixr = mvolxL = mvolxR = 0;
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
    final s = (_gauss[0xff - g] * _samples[i - 3] +
            _gauss[0x1ff - g] * _samples[i - 2] +
            _gauss[0x100 + g] * _samples[i - 1] +
            _gauss[g] * _samples[i]) >>
        15;
    _envelope();
    return s * envx >> 15;
  }

  static const _filter1 = [0, 60, 115, 98, 122];
  static const _filter2 = [0, 0, -52, -55, -60];

  void _decode(Spu2 spu) {
    final ram = spu.ram;
    spu._checkIrq(nax, 8);
    final header = ram[nax];
    final flags = header >> 8;
    if (flags & 4 != 0 && !lsaSet) lsa = nax;
    var shift = header & 0xf;
    if (shift > 12) shift = 9;
    final f = (header >> 4) & 7;
    final c1 = _filter1[f > 4 ? 4 : f], c2 = _filter2[f > 4 ? 4 : f];
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

  // the gaussian interpolation table of the PS1 SPU (psx-spx); a copy of the
  // one in the PS1 core, since cores do not import each other
  static const _gauss = <int>[
    -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, //
    -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, //
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0001, //
    0x0001, 0x0001, 0x0001, 0x0002, 0x0002, 0x0002, 0x0003, 0x0003, //
    0x0003, 0x0004, 0x0004, 0x0005, 0x0005, 0x0006, 0x0007, 0x0007, //
    0x0008, 0x0009, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, //
    0x000F, 0x0010, 0x0011, 0x0012, 0x0013, 0x0015, 0x0016, 0x0018, //
    0x0019, 0x001B, 0x001C, 0x001E, 0x0020, 0x0021, 0x0023, 0x0025, //
    0x0027, 0x0029, 0x002C, 0x002E, 0x0030, 0x0033, 0x0035, 0x0038, //
    0x003A, 0x003D, 0x0040, 0x0043, 0x0046, 0x0049, 0x004D, 0x0050, //
    0x0054, 0x0057, 0x005B, 0x005F, 0x0063, 0x0067, 0x006B, 0x006F, //
    0x0074, 0x0078, 0x007D, 0x0082, 0x0087, 0x008C, 0x0091, 0x0096, //
    0x009C, 0x00A1, 0x00A7, 0x00AD, 0x00B3, 0x00BA, 0x00C0, 0x00C7, //
    0x00CD, 0x00D4, 0x00DB, 0x00E3, 0x00EA, 0x00F2, 0x00FA, 0x0101, //
    0x010A, 0x0112, 0x011B, 0x0123, 0x012C, 0x0135, 0x013F, 0x0148, //
    0x0152, 0x015C, 0x0166, 0x0171, 0x017B, 0x0186, 0x0191, 0x019C, //
    0x01A8, 0x01B4, 0x01C0, 0x01CC, 0x01D9, 0x01E5, 0x01F2, 0x0200, // 0x080
    0x020D, 0x021B, 0x0229, 0x0237, 0x0246, 0x0255, 0x0264, 0x0273, //
    0x0283, 0x0293, 0x02A3, 0x02B4, 0x02C4, 0x02D6, 0x02E7, 0x02F9, //
    0x030B, 0x031D, 0x0330, 0x0343, 0x0356, 0x036A, 0x037E, 0x0392, //
    0x03A7, 0x03BC, 0x03D1, 0x03E7, 0x03FC, 0x0413, 0x042A, 0x0441, //
    0x0458, 0x0470, 0x0488, 0x04A0, 0x04B9, 0x04D2, 0x04EC, 0x0506, //
    0x0520, 0x053B, 0x0556, 0x0572, 0x058E, 0x05AA, 0x05C7, 0x05E4, //
    0x0601, 0x061F, 0x063E, 0x065C, 0x067C, 0x069B, 0x06BB, 0x06DC, //
    0x06FD, 0x071E, 0x0740, 0x0762, 0x0784, 0x07A7, 0x07CB, 0x07EF, //
    0x0813, 0x0838, 0x085D, 0x0883, 0x08A9, 0x08D0, 0x08F7, 0x091E, //
    0x0946, 0x096F, 0x0998, 0x09C1, 0x09EB, 0x0A16, 0x0A40, 0x0A6C, //
    0x0A98, 0x0AC4, 0x0AF1, 0x0B1E, 0x0B4C, 0x0B7A, 0x0BA9, 0x0BD8, //
    0x0C07, 0x0C38, 0x0C68, 0x0C99, 0x0CCB, 0x0CFD, 0x0D30, 0x0D63, //
    0x0D97, 0x0DCB, 0x0E00, 0x0E35, 0x0E6B, 0x0EA1, 0x0ED7, 0x0F0F, //
    0x0F46, 0x0F7F, 0x0FB7, 0x0FF1, 0x102A, 0x1065, 0x109F, 0x10DB, //
    0x1116, 0x1153, 0x118F, 0x11CD, 0x120B, 0x1249, 0x1288, 0x12C7, //
    0x1307, 0x1347, 0x1388, 0x13C9, 0x140B, 0x144D, 0x1490, 0x14D4, // 0x100
    0x1517, 0x155C, 0x15A0, 0x15E6, 0x162C, 0x1672, 0x16B9, 0x1700, //
    0x1747, 0x1790, 0x17D8, 0x1821, 0x186B, 0x18B5, 0x1900, 0x194B, //
    0x1996, 0x19E2, 0x1A2E, 0x1A7B, 0x1AC8, 0x1B16, 0x1B64, 0x1BB3, //
    0x1C02, 0x1C51, 0x1CA1, 0x1CF1, 0x1D42, 0x1D93, 0x1DE5, 0x1E37, //
    0x1E89, 0x1EDC, 0x1F2F, 0x1F82, 0x1FD6, 0x202A, 0x207F, 0x20D4, //
    0x2129, 0x217F, 0x21D5, 0x222C, 0x2282, 0x22DA, 0x2331, 0x2389, //
    0x23E1, 0x2439, 0x2492, 0x24EB, 0x2545, 0x259E, 0x25F8, 0x2653, //
    0x26AD, 0x2708, 0x2763, 0x27BE, 0x281A, 0x2876, 0x28D2, 0x292E, //
    0x298B, 0x29E7, 0x2A44, 0x2AA1, 0x2AFF, 0x2B5C, 0x2BBA, 0x2C18, //
    0x2C76, 0x2CD4, 0x2D33, 0x2D91, 0x2DF0, 0x2E4F, 0x2EAE, 0x2F0D, //
    0x2F6C, 0x2FCC, 0x302B, 0x308B, 0x30EA, 0x314A, 0x31AA, 0x3209, //
    0x3269, 0x32C9, 0x3329, 0x3389, 0x33E9, 0x3449, 0x34A9, 0x3509, //
    0x3569, 0x35C9, 0x3629, 0x3689, 0x36E8, 0x3748, 0x37A8, 0x3807, //
    0x3867, 0x38C6, 0x3926, 0x3985, 0x39E4, 0x3A43, 0x3AA2, 0x3B00, //
    0x3B5F, 0x3BBD, 0x3C1B, 0x3C79, 0x3CD7, 0x3D35, 0x3D92, 0x3DEF, //
    0x3E4C, 0x3EA9, 0x3F05, 0x3F62, 0x3FBD, 0x4019, 0x4074, 0x40D0, // 0x180
    0x412A, 0x4185, 0x41DF, 0x4239, 0x4292, 0x42EB, 0x4344, 0x439C, //
    0x43F4, 0x444C, 0x44A3, 0x44FA, 0x4550, 0x45A6, 0x45FC, 0x4651, //
    0x46A6, 0x46FA, 0x474E, 0x47A1, 0x47F4, 0x4846, 0x4898, 0x48E9, //
    0x493A, 0x498A, 0x49D9, 0x4A29, 0x4A77, 0x4AC5, 0x4B13, 0x4B5F, //
    0x4BAC, 0x4BF7, 0x4C42, 0x4C8D, 0x4CD7, 0x4D20, 0x4D68, 0x4DB0, //
    0x4DF7, 0x4E3E, 0x4E84, 0x4EC9, 0x4F0E, 0x4F52, 0x4F95, 0x4FD7, //
    0x5019, 0x505A, 0x509A, 0x50DA, 0x5118, 0x5156, 0x5194, 0x51D0, //
    0x520C, 0x5247, 0x5281, 0x52BA, 0x52F3, 0x532A, 0x5361, 0x5397, //
    0x53CC, 0x5401, 0x5434, 0x5467, 0x5499, 0x54CA, 0x54FA, 0x5529, //
    0x5558, 0x5585, 0x55B2, 0x55DE, 0x5609, 0x5632, 0x565B, 0x5684, //
    0x56AB, 0x56D1, 0x56F6, 0x571B, 0x573E, 0x5761, 0x5782, 0x57A3, //
    0x57C3, 0x57E2, 0x57FF, 0x581C, 0x5838, 0x5853, 0x586D, 0x5886, //
    0x589E, 0x58B5, 0x58CB, 0x58E0, 0x58F4, 0x5907, 0x5919, 0x592A, //
    0x593A, 0x5949, 0x5958, 0x5965, 0x5971, 0x597C, 0x5986, 0x598F, //
    0x5997, 0x599E, 0x59A4, 0x59A9, 0x59AD, 0x59B0, 0x59B2, 0x59B3, //
  ];
}
