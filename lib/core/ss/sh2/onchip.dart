import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../cpu.dart';

/// SH7604 on-chip peripheral modules (0xfffffe00 - 0xffffffff):
/// SCI (stub), FRT, WDT, INTC, DIVU, DMAC, BSC and cache control.
class Sh2OnChip {
  final bool master;

  /// bus seen by the DMAC (the CPU address space)
  late SsCpuBus bus;

  Sh2OnChip(this.master);

  // raw storage for registers without special behavior
  final _raw = Uint8List(0x200);

  // INTC
  int ipra = 0, iprb = 0;
  int vcra = 0, vcrb = 0, vcrc = 0, vcrd = 0;
  int vcrwdt = 0;
  int icr = 0;

  // FRT
  int tier = 0x01;
  int ftcsr = 0;
  int frc = 0;
  int ocra = 0xffff, ocrb = 0xffff;
  int tcr = 0;
  int tocr = 0xe0;
  int icrFrt = 0;
  int _frtTemp = 0;
  int _frtSub = 0;

  // WDT
  int wtcsr = 0x18;
  int wtcnt = 0;
  int rstcsr = 0x1f;
  int _wdtSub = 0;

  // DIVU
  int dvsr = 0;
  int dvcr = 0;
  int vcrdiv = 0;
  int dvdnth = 0;
  int dvdntl = 0;

  // DMAC
  final sar = [0, 0];
  final dar = [0, 0];
  final tcrDma = [0, 0];
  final chcr = [0, 0];
  final vcrdma = [0, 0];
  final drcr = [0, 0];
  int dmaor = 0;

  // BSC
  int bcr1 = 0x03f0, bcr2 = 0xfc, wcr = 0xaaff, mcr = 0, rtcsr = 0, rtcnt = 0;
  int rtcor = 0;

  // cache
  int ccr = 0;
  final cacheData = Uint8List(0x1000);

  void reset() {
    _raw.fillRange(0, _raw.length, 0);
    ipra = iprb = vcra = vcrb = vcrc = vcrd = vcrwdt = icr = 0;
    tier = 0x01;
    ftcsr = 0;
    frc = 0;
    ocra = ocrb = 0xffff;
    tcr = 0;
    tocr = 0xe0;
    icrFrt = 0;
    _frtTemp = 0;
    _frtSub = 0;
    wtcsr = 0x18;
    wtcnt = 0;
    rstcsr = 0x1f;
    _wdtSub = 0;
    dvsr = dvcr = vcrdiv = dvdnth = dvdntl = 0;
    for (int i = 0; i < 2; i++) {
      sar[i] = dar[i] = tcrDma[i] = chcr[i] = vcrdma[i] = drcr[i] = 0;
    }
    dmaor = 0;
    bcr1 = 0x03f0;
    bcr2 = 0xfc;
    wcr = 0xaaff;
    mcr = rtcsr = rtcnt = rtcor = 0;
    ccr = 0;
    _updatePending();
  }

  // ---- interrupts ----

  /// true when any on-chip interrupt source may be pending.
  /// updated whenever a flag or an enable bit changes.
  bool anyPending = false;

  void _updatePending() {
    anyPending = ftcsr & tier & 0x8e != 0 ||
        dvcr & 3 == 3 ||
        chcr[0] & 6 == 6 ||
        chcr[1] & 6 == 6 ||
        wtcsr & 0xc0 == 0x80;
  }

  /// returns (level, vector) of the highest pending on-chip interrupt
  (int, int) pendingInterrupt() {
    int level = 0, vector = 0;

    void check(bool pending, int l, int v) {
      if (pending && l > level) {
        level = l;
        vector = v;
      }
    }

    check(dvcr & 3 == 3, ipra >> 12 & 0xf, vcrdiv & 0x7f);
    check(chcr[0] & 6 == 6, ipra >> 8 & 0xf, vcrdma[0] & 0x7f);
    check(chcr[1] & 6 == 6, ipra >> 8 & 0xf, vcrdma[1] & 0x7f);
    check(wtcsr & 0xc0 == 0x80, ipra >> 4 & 0xf, vcrwdt >> 8 & 0x7f);

    final frtLevel = iprb >> 8 & 0xf;
    check(ftcsr & tier & 0x80 != 0, frtLevel, vcrc >> 8 & 0x7f);
    check(ftcsr & tier & 0x0c != 0, frtLevel, vcrc & 0x7f);
    check(ftcsr & tier & 0x02 != 0, frtLevel, vcrd >> 8 & 0x7f);

    return (level, vector);
  }

  /// true when external interrupts use vectors supplied from outside (VECMD)
  bool get externalVector => icr.bit0;

  // ---- timers ----

  static const _frtDivs = [8, 32, 128, 0];
  static const _wdtDivs = [2, 64, 128, 256, 512, 1024, 4096, 8192];

  void tick(int clocks) {
    _tickTimers(clocks);
    _updatePending();
  }

  void _tickTimers(int clocks) {
    final frtDiv = _frtDivs[tcr & 3];
    if (frtDiv != 0) {
      _frtSub += clocks;
      while (_frtSub >= frtDiv) {
        _frtSub -= frtDiv;
        _frcIncrement();
      }
    }

    if (wtcsr.bit5) {
      final wdtDiv = _wdtDivs[wtcsr & 7];
      _wdtSub += clocks;
      while (_wdtSub >= wdtDiv) {
        _wdtSub -= wdtDiv;
        wtcnt = (wtcnt + 1) & 0xff;
        if (wtcnt == 0) {
          wtcsr |= 0x80; // OVF (interval timer mode)
        }
      }
    }
  }

  void _frcIncrement() {
    frc = (frc + 1) & 0xffff;
    if (frc == 0) {
      ftcsr |= 0x02; // OVF
    }
    if (frc == ocra) {
      ftcsr |= 0x08; // OCFA
      if (ftcsr.bit0) {
        frc = 0; // CCLRA
      }
    }
    if (frc == ocrb) {
      ftcsr |= 0x04; // OCFB
    }
  }

  /// FRT input capture (triggered by MINIT/SINIT)
  void inputCapture() {
    icrFrt = frc;
    ftcsr |= 0x80;
    _updatePending();
  }

  // ---- register access ----

  int read8(int addr) {
    final a = addr & 0x1ff;
    if (a >= 0x100) {
      return _read32(a & ~3) >> ((3 - (a & 3)) * 8) & 0xff;
    }
    if (_is16(a)) {
      final d = _read16(a & ~1);
      return a.bit0 ? d & 0xff : d >> 8;
    }
    return _read8(a);
  }

  int read16(int addr) {
    final a = addr & 0x1fe;
    if (a >= 0x100) {
      return _read32(a & ~3) >> (a.bit1 ? 0 : 16) & 0xffff;
    }
    if (_is16(a)) {
      return _read16(a);
    }
    return _read8(a) << 8 | _read8(a + 1);
  }

  int read32(int addr) {
    final a = addr & 0x1fc;
    if (a >= 0x100) {
      return _read32(a);
    }
    return read16(a) << 16 | read16(a + 2);
  }

  void write8(int addr, int data) {
    _write8Impl(addr, data);
    _updatePending();
  }

  void _write8Impl(int addr, int data) {
    final a = addr & 0x1ff;
    data &= 0xff;
    if (a >= 0x100) {
      final shift = (3 - (a & 3)) * 8;
      final old = _read32(a & ~3);
      _write32(a & ~3, old & ~(0xff << shift) | data << shift);
      return;
    }
    if (_is16(a)) {
      final old = _read16(a & ~1);
      _write16(a & ~1, a.bit0 ? old & 0xff00 | data : old & 0xff | data << 8);
      return;
    }
    _write8(a, data);
  }

  void write16(int addr, int data) {
    _write16Impl(addr, data);
    _updatePending();
  }

  void _write16Impl(int addr, int data) {
    final a = addr & 0x1fe;
    data &= 0xffff;
    if (a >= 0x100) {
      final shift = a.bit1 ? 0 : 16;
      final old = _read32(a & ~3);
      _write32(a & ~3, old & ~(0xffff << shift) | data << shift);
      return;
    }
    if (_is16(a) || a == 0x80 || a == 0x82) {
      _write16(a, data);
      return;
    }
    _write8(a, data >> 8);
    _write8(a + 1, data & 0xff);
  }

  void write32(int addr, int data) {
    _write32Impl(addr, data);
    _updatePending();
  }

  void _write32Impl(int addr, int data) {
    final a = addr & 0x1fc;
    data &= 0xffffffff;
    if (a >= 0x100) {
      _write32(a, data);
      return;
    }
    write16(a, data >> 16);
    write16(a + 2, data & 0xffff);
  }

  // 16-bit registers in the 8-bit area
  static bool _is16(int a) =>
      (a >= 0x60 && a < 0x6a) || (a >= 0xe0 && a < 0xe6);

  int _read8(int a) {
    switch (a) {
      case 0x04:
        return 0x84; // SCI SSR: TDRE | TEND
      case 0x10:
        return tier;
      case 0x11:
        return ftcsr;
      case 0x12:
        _frtTemp = frc & 0xff;
        return frc >> 8;
      case 0x13:
        return _frtTemp;
      case 0x14:
        return (tocr.bit4 ? ocrb : ocra) >> 8;
      case 0x15:
        return (tocr.bit4 ? ocrb : ocra) & 0xff;
      case 0x16:
        return tcr;
      case 0x17:
        return tocr;
      case 0x18:
        _frtTemp = icrFrt & 0xff;
        return icrFrt >> 8;
      case 0x19:
        return _frtTemp;
      case 0x71:
        return drcr[0];
      case 0x72:
        return drcr[1];
      case 0x80:
        return wtcsr;
      case 0x81:
        return wtcnt;
      case 0x83:
        return rstcsr;
      case 0x92:
        return ccr;
      default:
        return _raw[a];
    }
  }

  void _write8(int a, int d) {
    switch (a) {
      case 0x10:
        tier = d | 0x01;
        break;
      case 0x11:
        // flags are cleared by writing 0, CCLRA is writable
        ftcsr = ftcsr & (d | 0x01) & 0x8e | d & 0x01;
        break;
      case 0x12:
        _frtTemp = d;
        break;
      case 0x13:
        frc = _frtTemp << 8 | d;
        break;
      case 0x14:
        _frtTemp = d;
        break;
      case 0x15:
        if (tocr.bit4) {
          ocrb = _frtTemp << 8 | d;
        } else {
          ocra = _frtTemp << 8 | d;
        }
        break;
      case 0x16:
        tcr = d;
        break;
      case 0x17:
        tocr = d | 0xe0;
        break;
      case 0x71:
        drcr[0] = d & 3;
        break;
      case 0x72:
        drcr[1] = d & 3;
        break;
      case 0x92:
        ccr = d & ~0x10; // CP (cache purge) always reads 0
        if (d.bit4) {
          cacheData.fillRange(0, cacheData.length, 0);
        }
        break;
      default:
        _raw[a] = d;
    }
  }

  int _read16(int a) {
    return switch (a) {
      0x60 => iprb,
      0x62 => vcra,
      0x64 => vcrb,
      0x66 => vcrc,
      0x68 => vcrd,
      0xe0 => icr | 0x8000, // NMIL: NMI pin is high
      0xe2 => ipra,
      0xe4 => vcrwdt,
      _ => 0,
    };
  }

  void _write16(int a, int d) {
    switch (a) {
      case 0x60:
        iprb = d & 0xff00;
        break;
      case 0x62:
        vcra = d & 0x7f7f;
        break;
      case 0x64:
        vcrb = d & 0x7f7f;
        break;
      case 0x66:
        vcrc = d & 0x7f7f;
        break;
      case 0x68:
        vcrd = d & 0x7f00;
        break;
      case 0xe0:
        icr = d & 0x0101;
        break;
      case 0xe2:
        ipra = d & 0xfff0;
        break;
      case 0xe4:
        vcrwdt = d & 0x7f7f;
        break;
      case 0x80:
        // WDT: 0xa5xx writes WTCSR, 0x5axx writes WTCNT
        if (d >> 8 == 0xa5) {
          wtcsr = wtcsr & (d | 0x7f) & 0x80 | d & 0x67 | 0x18;
        } else if (d >> 8 == 0x5a) {
          wtcnt = d & 0xff;
        }
        break;
      case 0x82:
        if (d >> 8 == 0xa5) {
          rstcsr = rstcsr & (d | 0x7f) & 0x80 | d & 0x60 | 0x1f;
        }
        break;
    }
  }

  int _read32(int a) {
    if (a >= 0x100 && a < 0x140) {
      // DIVU (0x20-0x3f are mirrors)
      return switch (a & 0x11c) {
        0x100 => dvsr,
        0x104 => dvdntl,
        0x108 => dvcr,
        0x10c => vcrdiv,
        0x110 || 0x118 => dvdnth,
        _ => dvdntl,
      };
    }

    return switch (a) {
      0x180 => sar[0],
      0x184 => dar[0],
      0x188 => tcrDma[0],
      0x18c => chcr[0],
      0x190 => sar[1],
      0x194 => dar[1],
      0x198 => tcrDma[1],
      0x19c => chcr[1],
      0x1a0 => vcrdma[0],
      0x1a8 => vcrdma[1],
      0x1b0 => dmaor,
      0x1e0 => (master ? 0 : 0x8000) | bcr1 & 0x7fff,
      0x1e4 => bcr2,
      0x1e8 => wcr,
      0x1ec => mcr,
      0x1f0 => rtcsr,
      0x1f4 => rtcnt,
      0x1f8 => rtcor,
      _ => 0,
    };
  }

  void _write32(int a, int d) {
    if (a >= 0x100 && a < 0x140) {
      switch (a & 0x11c) {
        case 0x100:
          dvsr = d;
          break;
        case 0x104:
          _div32(d);
          break;
        case 0x108:
          dvcr = d & 3;
          break;
        case 0x10c:
          vcrdiv = d & 0x7f;
          break;
        case 0x110 || 0x118:
          dvdnth = d;
          break;
        case 0x114 || 0x11c:
          _div64(d);
          break;
      }
      return;
    }

    switch (a) {
      case 0x180:
        sar[0] = d;
        break;
      case 0x184:
        dar[0] = d;
        break;
      case 0x188:
        tcrDma[0] = d & 0xffffff;
        break;
      case 0x18c:
        chcr[0] = _chcrWrite(chcr[0], d);
        _dmaStart(0);
        break;
      case 0x190:
        sar[1] = d;
        break;
      case 0x194:
        dar[1] = d;
        break;
      case 0x198:
        tcrDma[1] = d & 0xffffff;
        break;
      case 0x19c:
        chcr[1] = _chcrWrite(chcr[1], d);
        _dmaStart(1);
        break;
      case 0x1a0:
        vcrdma[0] = d & 0x7f;
        break;
      case 0x1a8:
        vcrdma[1] = d & 0x7f;
        break;
      case 0x1b0:
        // NMIF and AE are cleared by writing 0
        dmaor = d & 0x9 | dmaor & d & 0x6;
        _dmaStart(0);
        _dmaStart(1);
        break;
      // BSC registers are written with 0xa55a in the upper half
      case 0x1e0:
        if (d >> 16 == 0xa55a) bcr1 = d & 0x1ff7;
        break;
      case 0x1e4:
        if (d >> 16 == 0xa55a) bcr2 = d & 0xfc;
        break;
      case 0x1e8:
        if (d >> 16 == 0xa55a) wcr = d & 0xffff;
        break;
      case 0x1ec:
        if (d >> 16 == 0xa55a) mcr = d & 0xfefc;
        break;
      case 0x1f0:
        if (d >> 16 == 0xa55a) rtcsr = d & 0xf8;
        break;
      case 0x1f4:
        if (d >> 16 == 0xa55a) rtcnt = d & 0xff;
        break;
      case 0x1f8:
        if (d >> 16 == 0xa55a) rtcor = d & 0xff;
        break;
    }
  }

  // TE is cleared by writing 0
  static int _chcrWrite(int old, int d) => d & 0xfffd & 0xffff | old & d & 2;

  // ---- DIVU ----

  void _divOverflow(int dividendSign, int divisorSign) {
    dvcr |= 1;
    dvdntl = (dividendSign ^ divisorSign) != 0 ? 0x80000000 : 0x7fffffff;
  }

  void _div32(int d) {
    final dividend = d.rel32;
    final divisor = dvsr.rel32;
    dvdnth = dividend < 0 ? 0xffffffff : 0;

    if (divisor == 0) {
      _divOverflow(dividend < 0 ? 1 : 0, 0);
      return;
    }
    if (dividend == -0x80000000 && divisor == -1) {
      dvdntl = 0x80000000;
      dvdnth = 0;
      return;
    }

    dvdntl = (dividend ~/ divisor) & 0xffffffff;
    dvdnth = dividend.remainder(divisor) & 0xffffffff;
  }

  void _div64(int low) {
    final dividend = (dvdnth.rel32 << 32) | (low & 0xffffffff);
    final divisor = dvsr.rel32;

    if (divisor == 0) {
      _divOverflow(dividend < 0 ? 1 : 0, 0);
      return;
    }

    final q = divisor == -1 ? -dividend : dividend ~/ divisor;
    if (q > 0x7fffffff || q < -0x80000000) {
      _divOverflow(dividend < 0 ? 1 : 0, divisor < 0 ? 1 : 0);
      return;
    }

    dvdntl = q & 0xffffffff;
    dvdnth = (divisor == -1 ? 0 : dividend.remainder(divisor)) & 0xffffffff;
  }

  // ---- DMAC ----

  static const _unitSizes = [1, 2, 4, 16];

  void _dmaStart(int ch) {
    final c = chcr[ch];
    if (c & 3 != 1 || dmaor & 7 != 1) {
      return; // not enabled, already ended, or DMAC stopped
    }
    if (!c.bit9) {
      return; // only auto request is supported
    }

    final ts = (c >> 10) & 3;
    final unit = _unitSizes[ts];
    int count = tcrDma[ch] == 0 ? 0x1000000 : tcrDma[ch];

    int srcStep(int mode) => switch (mode) { 1 => unit, 2 => -unit, _ => 0 };
    final ss = srcStep((c >> 12) & 3);
    final ds = srcStep((c >> 14) & 3);

    int src = sar[ch];
    int dst = dar[ch];

    while (count > 0) {
      switch (ts) {
        case 0:
          bus.write8(dst, bus.read8(src));
          count--;
          break;
        case 1:
          bus.write16(dst, bus.read16(src));
          count--;
          break;
        case 2:
          bus.write32(dst, bus.read32(src));
          count--;
          break;
        default:
          for (int i = 0; i < 16; i += 4) {
            bus.write32(dst + i, bus.read32(src + i));
          }
          count -= 4;
          break;
      }
      src = (src + ss) & 0xffffffff;
      dst = (dst + ds) & 0xffffffff;
    }

    sar[ch] = src;
    dar[ch] = dst;
    tcrDma[ch] = 0;
    chcr[ch] |= 2; // TE
  }

  String dump() =>
      "frc:${frc.x4} ftcsr:${ftcsr.x2} tier:${tier.x2} ipra:${ipra.x4} iprb:${iprb.x4} "
      "dvcr:${dvcr.x2} dmaor:${dmaor.x2} chcr:${chcr[0].x4},${chcr[1].x4}";
}
