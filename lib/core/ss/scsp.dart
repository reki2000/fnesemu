import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../md/bus_m68.dart';
import '../md/m68/m68.dart';

/// 68000 bus of the sound subsystem
class ScspBus extends BusM68 {
  final Scsp scsp;
  ScspBus(this.scsp);

  @override
  void onReset() => cpu.reset();

  @override
  int read8(int addr) {
    final a = addr & 0xffffff;
    if (a < 0x100000) {
      return scsp.ram[a & 0x7ffff];
    }
    if (a < 0x100f00) {
      final d = scsp.readReg16(a & 0xffe);
      return a.bit0 ? d & 0xff : d >> 8;
    }
    return 0;
  }

  @override
  int read16(int addr) {
    final a = addr & 0xffffff;
    if (a < 0x100000) {
      return scsp.ramData.getUint16(a & 0x7fffe);
    }
    if (a < 0x100f00) {
      return scsp.readReg16(a & 0xffe);
    }
    return 0;
  }

  @override
  void write8(int addr, int data) {
    final a = addr & 0xffffff;
    if (a < 0x100000) {
      scsp.ram[a & 0x7ffff] = data;
      return;
    }
    if (a < 0x100f00) {
      scsp.writeReg8(a & 0xfff, data);
    }
  }

  @override
  void write16(int addr, int data) {
    final a = addr & 0xffffff;
    if (a < 0x100000) {
      scsp.ramData.setUint16(a & 0x7fffe, data);
      return;
    }
    if (a < 0x100f00) {
      scsp.writeReg16(a & 0xffe, data, 0xffff);
    }
  }
}

class _Slot {
  bool active = false;
  bool keyOn = false;

  int pos = 0; // sample position in 16.16
  int eg = 0x3ff; // attenuation 0: max, 0x3ff: silent (10.16 fixed in egFrac)
  int egFrac = 0;
  int egState = _release;

  int lfsr = 1;

  static const _attack = 0;
  static const _decay1 = 1;
  static const _decay2 = 2;
  static const _release = 3;
}

/// SS sound processor (SCSP)
class Scsp {
  late final ScspBus bus;
  late final M68 cpu;

  final ram = Uint8List(0x80000);
  late final ramData = ByteData.sublistView(ram);

  // slot and common registers (0x000 - 0xeff) as 16-bit words
  final _regs = Uint16List(0x800);

  final _slots = List.generate(32, (_) => _Slot());

  void Function() onMainInterrupt = () {};

  static const sampleHz = 44100;
  static const cpuClockHz = 11289600;
  static const clocksPerSample = 256;

  Scsp() {
    bus = ScspBus(this);
    cpu = M68(bus);
    bus.cpu = cpu;
    _buildTables();
  }

  bool cpuEnabled = false;

  void reset() {
    ram.fillRange(0, ram.length, 0);
    _regs.fillRange(0, _regs.length, 0);
    for (final s in _slots) {
      s.active = false;
      s.keyOn = false;
      s.eg = 0x3ff;
      s.egState = _Slot._release;
    }
    _timer.fillRange(0, 3, 0);
    _timerSub.fillRange(0, 3, 0);
    cpuEnabled = false;
    _ringPtr = 0;
    _ring.fillRange(0, _ring.length, 0);
  }

  void setCpuEnabled(bool on) {
    if (on && !cpuEnabled) {
      cpu.reset();
    }
    cpuEnabled = on;
  }

  // ---- main CPU access ----

  int readRam16(int addr) => ramData.getUint16(addr & 0x7fffe);

  void writeRam8(int addr, int data) => ram[addr & 0x7ffff] = data;

  void writeRam16(int addr, int data, int mask) {
    final a = addr & 0x7fffe;
    ramData.setUint16(a, ramData.getUint16(a) & ~mask | data & mask);
  }

  // ---- registers ----

  int _slotReg(int slot, int reg) => _regs[slot * 0x10 + reg];

  int get _scieb => _regs[0x41e >> 1];
  int get _scipd => _regs[0x420 >> 1];
  int get _mcieb => _regs[0x42a >> 1];
  int get _mcipd => _regs[0x42c >> 1];

  int readReg16(int addr) {
    addr &= 0xffe;
    switch (addr) {
      case 0x404:
        return 0x0100; // MIDI: input buffer empty
      case 0x408:
        // monitor: call address of MSLC slot
        final slot = (_regs[0x408 >> 1] >> 11) & 0x1f;
        final s = _slots[slot];
        final ca = ((s.pos >> 16) >> 12) & 0xf;
        final sgc = s.active ? s.egState : 3;
        return (_regs[0x408 >> 1] & 0xf800) | ca << 7 | sgc << 5 | (s.eg >> 5);
      case 0x418 || 0x41a || 0x41c:
        final t = (addr - 0x418) >> 1;
        return (_regs[addr >> 1] & 0x0700) | _timer[t] & 0xff;
      default:
        return _regs[addr >> 1];
    }
  }

  void writeReg8(int addr, int data) {
    final a = addr & 0xffe;
    if (addr.bit0) {
      writeReg16(a, data & 0xff, 0x00ff);
    } else {
      writeReg16(a, (data & 0xff) << 8, 0xff00);
    }
  }

  void writeReg16(int addr, int data, int mask) {
    addr &= 0xffe;
    final i = addr >> 1;
    final old = _regs[i];
    final v = old & ~mask | data & mask;

    switch (addr) {
      case 0x418 || 0x41a || 0x41c:
        final t = (addr - 0x418) >> 1;
        _regs[i] = v & 0x0700;
        if (mask & 0xff != 0) {
          _timer[t] = v & 0xff;
        }
        return;
      case 0x420: // SCIPD: only bit 5 can be set by writing
        if (v.bit5) {
          _regs[i] |= 0x20;
          _updateInterrupts();
        }
        return;
      case 0x422: // SCIRE
        _regs[0x420 >> 1] &= ~v;
        _updateInterrupts();
        return;
      case 0x42c: // MCIPD
        if (v.bit5) {
          _regs[i] |= 0x20;
          _updateInterrupts();
        }
        return;
      case 0x42e: // MCIRE
        _regs[0x42c >> 1] &= ~v;
        return;
      case 0x41e || 0x42a:
        _regs[i] = v;
        _updateInterrupts();
        return;
    }

    _regs[i] = v;

    // slot register 0: key on execute
    if (addr < 0x400 && addr & 0x1f == 0 && v.bit12) {
      _regs[i] &= ~0x1000;
      _keyOnExecute();
    }
  }

  void _keyOnExecute() {
    for (int n = 0; n < 32; n++) {
      final s = _slots[n];
      final kyonb = _slotReg(n, 0).bit11;
      if (kyonb && !s.keyOn) {
        s.keyOn = true;
        s.active = true;
        s.pos = 0;
        s.eg = 0x3ff;
        s.egFrac = 0;
        s.egState = _Slot._attack;
      } else if (!kyonb && s.keyOn) {
        s.keyOn = false;
        s.egState = _Slot._release;
      }
    }
  }

  // ---- interrupts ----

  bool _prevMainIrq = false;

  void _raise(int bit) {
    _regs[0x420 >> 1] |= 1 << bit;
    _regs[0x42c >> 1] |= 1 << bit;
    _updateInterrupts();
  }

  void _updateInterrupts() {
    final mainIrq = _mcipd & _mcieb != 0;
    if (mainIrq && !_prevMainIrq) {
      onMainInterrupt();
    }
    _prevMainIrq = mainIrq;
  }

  int _cpuIrqLevel() {
    final pending = _scipd & _scieb;
    if (pending == 0) {
      return 0;
    }
    int level = 0;
    for (int bit = 0; bit < 11; bit++) {
      if (pending & (1 << bit) == 0) continue;
      final b = bit > 7 ? 7 : bit;
      final l = (_regs[0x424 >> 1] >> b & 1) |
          (_regs[0x426 >> 1] >> b & 1) << 1 |
          (_regs[0x428 >> 1] >> b & 1) << 2;
      if (l > level) level = l;
    }
    return level;
  }

  // ---- timers ----

  final _timer = [0, 0, 0];
  final _timerSub = [0, 0, 0];

  void _tickTimers() {
    for (int t = 0; t < 3; t++) {
      final ctl = (_regs[(0x418 >> 1) + t] >> 8) & 7;
      if (++_timerSub[t] < (1 << ctl)) continue;
      _timerSub[t] = 0;
      _timer[t]++;
      if (_timer[t] >= 0x100) {
        _timer[t] = 0;
        _raise(6 + t);
      }
    }
  }

  // ---- execution ----

  int _cpuClocks = 0;

  /// runs the sound CPU and generates samples for `cycles` sound clocks.
  /// generated stereo samples are appended to `out` from `index`.
  int exec(int cycles, Float32List out, int index) {
    _cpuClocks += cycles;

    while (_cpuClocks >= clocksPerSample) {
      _cpuClocks -= clocksPerSample;

      if (cpuEnabled) {
        final target = cpu.clocks + clocksPerSample;
        while (cpu.clocks < target) {
          final level = _cpuIrqLevel();
          if (level > 0) {
            cpu.interrupt(level);
          }
          if (!cpu.exec()) {
            cpu.clocks += 4;
          }
        }
      }

      _tickTimers();
      _raise(10); // sample interval

      final (l, r) = _renderSample();
      if (index + 1 < out.length) {
        out[index++] = l;
        out[index++] = r;
      }
    }

    return index;
  }

  // ---- sound generation ----

  // 0.375dB per TL step, eg: 0x3ff = about 96dB
  final _tlGain = Float64List(256);
  final _egGain = Float64List(0x400);
  final _egStep = Int32List(64); // eg attenuation step per sample in 10.16

  void _buildTables() {
    for (int i = 0; i < 256; i++) {
      _tlGain[i] = pow(10, -(i * 0.375) / 20).toDouble();
    }
    for (int i = 0; i < 0x400; i++) {
      _egGain[i] = i >= 0x3f0 ? 0 : pow(10, -(i * 0.09375) / 20).toDouble();
    }
    // time for full range (0x3ff) is about 118 seconds at rate 0 and halves every 2 rates
    for (int r = 0; r < 64; r++) {
      if (r < 2) {
        _egStep[r] = 0;
        continue;
      }
      final seconds = 118.2 / pow(2, (r - 2) / 4);
      final samples = seconds * sampleHz / 10; // approx decay time scale
      final step = 0x3ff * 65536 / samples;
      _egStep[r] = step.round().clamp(1, 0x3ff * 65536);
    }
  }

  final _ring = Int32List(64);
  int _ringPtr = 0;

  int _effRate(int rate, int n) {
    if (rate == 0) return 0;
    final krs = (_slotReg(n, 5) >> 10) & 0xf;
    int r = rate * 2;
    if (krs != 0xf) {
      final oct = ((_slotReg(n, 8) >> 11) & 0xf).rel4;
      final fns = _slotReg(n, 8) & 0x3ff;
      r += (krs + oct) * 2 + (fns >> 9);
    }
    return r < 0 ? 0 : (r > 63 ? 63 : r);
  }

  void _updateEg(_Slot s, int n) {
    final r4 = _slotReg(n, 4);
    final r5 = _slotReg(n, 5);

    switch (s.egState) {
      case _Slot._attack:
        final ar = _effRate(r4 & 0x1f, n);
        if (ar >= 62) {
          s.eg = 0;
        } else {
          // attack is exponential: faster near max
          final step = _egStep[ar] * 8;
          s.egFrac -= step;
          while (s.egFrac < 0 && s.eg > 0) {
            s.egFrac += 65536;
            s.eg--;
          }
        }
        if (s.eg <= 0) {
          s.eg = 0;
          s.egFrac = 0;
          s.egState = _Slot._decay1;
        }
        break;
      case _Slot._decay1:
        final dl = ((r5 >> 5) & 0x1f) << 5;
        _decay(s, _effRate((r4 >> 6) & 0x1f, n));
        if (s.eg >= dl) {
          s.egState = _Slot._decay2;
        }
        break;
      case _Slot._decay2:
        _decay(s, _effRate((r4 >> 11) & 0x1f, n));
        break;
      default:
        _decay(s, _effRate(r5 & 0x1f, n));
        if (s.eg >= 0x3ff) {
          s.active = false;
        }
    }
  }

  void _decay(_Slot s, int rate) {
    s.egFrac += _egStep[rate];
    s.eg += s.egFrac >> 16;
    s.egFrac &= 0xffff;
    if (s.eg > 0x3ff) s.eg = 0x3ff;
  }

  static const _panTable = [
    1.0, 0.707, 0.5, 0.354, 0.25, 0.177, 0.125, 0.088, //
    0.0625, 0.044, 0.031, 0.022, 0.016, 0.011, 0.008, 0.0,
  ];

  (double, double) _renderSample() {
    double left = 0, right = 0;

    for (int n = 0; n < 32; n++) {
      final s = _slots[n];

      if (!s.active) {
        _ring[_ringPtr] = 0;
        _ringPtr = (_ringPtr + 1) & 63;
        continue;
      }

      final r0 = _slotReg(n, 0);
      final sa = (r0 & 0xf) << 16 | _slotReg(n, 1);
      final lsa = _slotReg(n, 2);
      final lea = _slotReg(n, 3);
      final pcm8 = r0.bit4;
      final lpctl = (r0 >> 5) & 3;
      final ssctl = (r0 >> 7) & 3;
      final sbctl = (r0 >> 9) & 3;

      // modulation
      final r7 = _slotReg(n, 7);
      final mdl = (r7 >> 12) & 0xf;
      int modOffset = 0;
      if (mdl > 4) {
        final mx = _ring[(_ringPtr + ((r7 >> 6) & 0x3f)) & 63];
        final my = _ring[(_ringPtr + (r7 & 0x3f)) & 63];
        modOffset = ((mx + my) >> 1) >> (16 - mdl);
      }

      final sampleIndex = (s.pos >> 16) + modOffset;

      int smp;
      switch (ssctl) {
        case 0:
          final idx = sampleIndex & 0xffff;
          if (pcm8) {
            smp = ram[(sa + idx) & 0x7ffff].rel8 << 8;
          } else {
            smp = ramData.getUint16((sa + idx * 2) & 0x7fffe).rel16;
          }
          break;
        case 1:
          s.lfsr = (s.lfsr >> 1) ^ (-(s.lfsr & 1) & 0xb400);
          smp = (s.lfsr & 0xffff).rel16;
          break;
        default:
          smp = 0;
      }

      if (sbctl != 0) {
        smp = ((smp & 0xffff) ^ (sbctl.bit0 ? 0x7fff : 0) ^ (sbctl.bit1 ? 0x8000 : 0))
            .rel16;
      }

      // pitch
      final r8 = _slotReg(n, 8);
      final oct = ((r8 >> 11) & 0xf).rel4;
      int step = (0x400 + (r8 & 0x3ff)) << 6;
      step = oct >= 0 ? step << oct : step >> -oct;

      s.pos += step;
      final ipos = s.pos >> 16;
      if (ipos > lea) {
        if (lpctl == 0) {
          s.active = false;
          s.pos = 0;
        } else {
          final len = lea - lsa;
          s.pos -= (len <= 0 ? ipos - lsa : len) << 16;
          if ((s.pos >> 16) > lea) s.pos = lsa << 16;
        }
      }

      _updateEg(s, n);

      final tl = _slotReg(n, 6) & 0xff;
      final out = smp * _tlGain[tl] * _egGain[s.eg];

      _ring[_ringPtr] = out.toInt();
      _ringPtr = (_ringPtr + 1) & 63;

      // direct output
      final rb = _slotReg(n, 0xb);
      final disdl = (rb >> 13) & 7;
      if (disdl == 0) continue;
      final dipan = (rb >> 8) & 0x1f;
      final level = out * _panTable[(7 - disdl) * 2] / 32768.0;
      final panAtt = _panTable[dipan & 0xf];
      if (dipan.bit4) {
        left += level;
        right += level * panAtt;
      } else {
        left += level * panAtt;
        right += level;
      }
    }

    final mvol = _regs[0x400 >> 1] & 0xf;
    final master = mvol == 0 ? 0.0 : _panTable[(15 - mvol)] * 0.5;
    return ((left * master).clamp(-1.0, 1.0), (right * master).clamp(-1.0, 1.0));
  }

  String dump() {
    final active = [
      for (int i = 0; i < 32; i++)
        if (_slots[i].active) i
    ];
    return "scsp: 68k:${cpuEnabled ? "on" : "off"} pc:${cpu.pc.x6} scipd:${_scipd.x4} mcipd:${_mcipd.x4} slots:$active";
  }
}
