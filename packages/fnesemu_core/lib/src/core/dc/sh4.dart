import 'dart:math' as math;
import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';
import 'bus.dart';
import 'cache.dart';
import 'fault.dart';
import 'float.dart';

part 'sh4_integer.dart';
part 'sh4_fpu.dart';

/// SH-4 bring-up interpreter.
/// One step executes an instruction, a separately stepped delay slot, or an interrupt entry.
/// Timing is not modeled; unsupported operations remain development stops rather than guest illegal instructions.
class Sh4 {
  Sh4(this.bus) {
    reset();
  }

  final DcBus bus;
  final r = Uint32List(16);
  final bank = Uint32List(8);
  int pc = 0, pr = 0, vbr = 0, gbr = 0, ssr = 0, spc = 0, sgr = 0, dbr = 0;
  int mach = 0, macl = 0;
  final fr = Uint32List(16), xf = Uint32List(16);
  int fpul = 0;
  int _fpscr = 0;
  int get fpscr => _fpscr;
  set fpscr(int value) {
    final swap = (_fpscr ^ value) & 0x200000 != 0;
    _fpscr = value & 0x003fffff;
    if (swap) {
      for (var i = 0; i < 16; i++) {
        final saved = fr[i];
        fr[i] = xf[i];
        xf[i] = saved;
      }
    }
  }

  int _irlPins = 15;
  int get irlPins => _irlPins & bus.systemBus.irlPins;

  /// Encoded IRL3-IRL0 input (IRLM=0): 0 is priority 15, 15 is inactive.
  /// The device driving these pins must deassert them after acknowledgment.
  set irlPins(int value) {
    if (value < 0 || value > 15) throw RangeError.range(value, 0, 15);
    _irlPins = value;
  }

  bool sleeping = false;
  bool _instructionExecuted = false;
  bool get instructionExecuted => _instructionExecuted;
  int _sr = 0;
  int get sr => _sr;
  bool get privileged => _sr.bit30;
  bool get _bank1 => privileged && _sr.bit29;
  set sr(int value) {
    final oldBank = _bank1;
    _sr = value & 0x700083f3;
    if (_bank1 != oldBank) {
      for (var i = 0; i < 8; i++) {
        final saved = r[i];
        r[i] = bank[i];
        bank[i] = saved;
      }
    }
  }

  int? _delayedTarget;
  int? _delayedPr;
  bool? _slotFetchPrivileged;
  bool get inDelaySlot => _delayedTarget != null;
  bool get t => sr.bit0;
  // Updating T cannot select a different register bank.
  set t(bool value) => _sr = _sr.setBit(0, value);

  void reset({bool manual = false, bool preserveClockControl = false}) {
    sleeping = false;
    r.fillRange(0, r.length, 0);
    bank.fillRange(0, bank.length, 0);
    _sr = 0;
    pc = 0xa0000000;
    // Defined reset bits; undefined register values use deterministic zero.
    sr = 0x700000f0;
    pr = vbr = gbr = ssr = spc = sgr = dbr = 0;
    mach = macl = 0;
    fr.fillRange(0, 16, 0);
    xf.fillRange(0, 16, 0);
    _fpscr = 0x00040001;
    fpul = 0;
    _instructionExecuted = false;
    _delayedTarget = null;
    _delayedPr = null;
    _slotFetchPrivileged = null;
    bus.resetCpuRegisters(
        manual: manual, preserveClockControl: preserveClockControl);
  }

  /// CPU-only snapshot; memory and on-chip devices belong to the bus owner.
  void saveState(StateWriter writer) {
    writer.section('dc.sh4');
    for (final buffer in [r, bank, fr, xf]) {
      writer.ints(buffer);
    }
    writer.ints([
      pc,
      pr,
      vbr,
      gbr,
      ssr,
      spc,
      sgr,
      dbr,
      mach,
      macl,
      fpul,
      _sr,
      _fpscr,
      _irlPins
    ]);
    writer.boolean(sleeping);
    writer.boolean(_instructionExecuted);
    writer.ints([
      _delayedTarget ?? -1,
      _delayedPr ?? -1,
      _slotFetchPrivileged == null
          ? -1
          : _slotFetchPrivileged!
              ? 1
              : 0
    ]);
  }

  void loadState(StateReader reader) {
    reader.section('dc.sh4');
    final buffers = [r, bank, fr, xf];
    final saved = [for (final _ in buffers) reader.ints()];
    final values = reader.ints();
    final sleep = reader.boolean(), executed = reader.boolean();
    final delay = reader.ints();
    for (var i = 0; i < buffers.length; i++) {
      if (saved[i].length != buffers[i].length ||
          saved[i].any((value) => value < 0 || value > 0xffffffff)) {
        throw const StateMismatch('SH4 register bank');
      }
    }
    if (values.length != 14 ||
        values.any((value) => value < 0 || value > 0xffffffff) ||
        values[11] & ~0x700083f3 != 0 ||
        values[12] & ~0x003fffff != 0 ||
        values[13] > 15 ||
        delay.length != 3 ||
        delay[0] < -1 ||
        delay[0] > 0xffffffff ||
        delay[1] < -1 ||
        delay[1] > 0xffffffff ||
        delay[2] < -1 ||
        delay[2] > 1 ||
        (delay[0] == -1 && (delay[1] != -1 || delay[2] != -1))) {
      throw const StateMismatch('SH4 control or delay state');
    }
    for (var i = 0; i < buffers.length; i++) {
      buffers[i].setAll(0, saved[i]);
    }
    var i = 0;
    pc = values[i++];
    pr = values[i++];
    vbr = values[i++];
    gbr = values[i++];
    ssr = values[i++];
    spc = values[i++];
    sgr = values[i++];
    dbr = values[i++];
    mach = values[i++];
    macl = values[i++];
    fpul = values[i++];
    // The setters swap register banks; restored buffers already have their saved layout.
    _sr = values[i++];
    _fpscr = values[i++];
    _irlPins = values[i++];
    sleeping = sleep;
    _instructionExecuted = executed;
    _delayedTarget = delay[0] == -1 ? null : delay[0];
    _delayedPr = delay[1] == -1 ? null : delay[1];
    _slotFetchPrivileged = delay[2] == -1 ? null : delay[2] == 1;
  }

  void step() {
    _instructionExecuted = false;
    final watchdogReset = bus.cpg.takeReset();
    if (watchdogReset != null) {
      reset(manual: watchdogReset, preserveClockControl: true);
      bus.expevt = watchdogReset ? 0x20 : 0;
      return;
    }
    if (bus.cpg.stabilizing) return;
    if (_acceptInterrupt()) return;
    if (sleeping) return;
    try {
      _checkAccess(pc, 2, false,
          privileged: _slotFetchPrivileged, instruction: true);
      _step();
      _instructionExecuted = true;
    } on DcCpuException catch (error) {
      if (sr.bit28 || error.reset) {
        // A general exception with BL set causes a CPU/on-chip manual reset.
        // External RAM and ROM remain connected and retain their contents.
        reset(manual: true);
        bus.expevt = error.reset ? error.event : 0x20;
        if (error.reset && error.address != null) bus.tea = error.address!;
        return;
      }
      final inSlot = inDelaySlot;
      if (inSlot && _delayedPr != null) pr = _delayedPr!;
      ssr = sr;
      spc = (error.completed ? pc + 2 : (inSlot ? pc - 2 : pc)).mask32;
      sgr = r[15];
      if (error.address != null) {
        bus.tea = error.address!;
        bus.pteh = (bus.pteh & 0xff) | (error.address! & 0xfffffc00);
      }
      if (error.trap != null) bus.tra = error.trap! * 4;
      bus.expevt = error.event;
      sr |= 0x70000000;
      pc = (vbr + error.vector).mask32;
      _delayedTarget = null;
      _delayedPr = null;
      _slotFetchPrivileged = null;
      _instructionExecuted = error.completed;
    }
  }

  bool _acceptInterrupt() {
    final (priority, event) = bus.intc.pending(irlPins, bus.tmu,
        dma: bus.dma,
        scif: bus.scif,
        cpg: bus.cpg,
        sci: bus.sci,
        bsc: bus.bsc,
        gpio: bus.gpio);
    if (inDelaySlot ||
        (sr.bit28 &&
            !sleeping &&
            !(priority == 16 && bus.intc.nmiIgnoresBlock)) ||
        priority <= ((sr >> 4) & 15)) {
      return false;
    }
    sleeping = false;
    bus.cpg.deepSleeping = false;
    ssr = sr;
    spc = pc;
    sgr = r[15];
    bus.intevt = event;
    if (priority == 16) bus.intc.acknowledgeNmi();
    sr |= 0x70000000;
    pc = (vbr + 0x600).mask32;
    return true;
  }

  void _checkAccess(int address, int size, bool write,
      {bool? privileged, bool instruction = false}) {
    address = address.mask32;
    final userStoreQueue =
        !instruction && DcBus.isStoreQueue(address) && bus.mmucr & 0x200 == 0;
    final userCacheRam = !instruction &&
        DcCache.isRamArea(address) &&
        bus.cache.ccr & 0x21 == 0x21;
    if (address & (size - 1) != 0 ||
        (!(privileged ?? this.privileged) &&
            !userStoreQueue &&
            !userCacheRam &&
            (address >= 0x80000000 ||
                (!bus.mmu.enabled && address & 0x1c000000 == 0x1c000000)))) {
      throw DcCpuException(write ? 0x100 : 0x0e0, address: address);
    }
  }

  int _read(int address, int size) {
    _checkAccess(address, size, false);
    return bus.cpuRead(address, size, privileged: privileged);
  }

  void _write(int address, int size, int value) {
    _checkAccess(address, size, true);
    bus.cpuWrite(address, size, value, privileged: privileged);
  }

  Never _illegal() => throw DcCpuException(inDelaySlot ? 0x1a0 : 0x180);

  void _step() {
    final op = bus.cpuRead(pc, 2,
        instruction: true, privileged: _slotFetchPrivileged ?? privileged);
    final n = (op >> 8) & 15, m = (op >> 4) & 15;
    final imm = op & 255;
    final target = _delayedTarget;
    if (target != null) {
      final branch = op >> 12 == 0xa ||
          op >> 12 == 0xb ||
          op & 0xf900 == 0x8900 ||
          switch (op & 0xf0ff) {
            0x0003 || 0x0023 || 0x400b || 0x402b => true,
            _ => false,
          } ||
          op == 0x000b ||
          op == 0x002b ||
          op & 0xff00 == 0xc300 ||
          op & 0xf0ff == 0x400e ||
          op & 0xf0ff == 0x4007;
      final pcRelative =
          op >> 12 == 9 || op >> 12 == 0xd || op & 0xff00 == 0xc700;
      if (branch || pcRelative) _illegal();
    }
    var next = (pc + 2).mask32;
    int? delayed;
    int? previousPr;
    bool? slotFetchPrivileged;
    if (!privileged && (op == 0x0038 || op == 0x001b)) _illegal();
    if (op == 0xfffd) {
      _illegal();
    } else if (op & 0xff00 == 0xc300) {
      throw DcCpuException(0x160, completed: true, trap: imm);
    } else if (op == 0x002b) {
      if (!privileged) _illegal();
      delayed = spc;
      slotFetchPrivileged = privileged;
      sr = ssr;
    } else if (op == 0x0038) {
      bus.mmu.load();
    } else if (_controlOp(op, n)) {
      // The control transfer has already completed.
    } else if (_fpuOp(op, n, m)) {
      // Floating-point instructions share the ordinary delay-slot exit path.
    } else if (op & 0xf0ff == 0x0083) {
      if (DcBus.isStoreQueue(r[n])) {
        // SQ PREF has read-type exception checks, unlike SQ stores.
        _checkAccess(r[n], 1, false);
        bus.transferStoreQueue(r[n], privileged: privileged);
      } else if (privileged || r[n] < 0x80000000) {
        bus.cpuPrefetch(r[n], privileged: privileged);
      }
    } else if ((op & 0xf0ff == 0x0093 ||
        op & 0xf0ff == 0x00a3 ||
        op & 0xf0ff == 0x00b3)) {
      final operation = ((op >> 4) & 15) - 9;
      _checkAccess(r[n], 1, operation == 0);
      bus.cpuCacheOperation(r[n], operation, privileged: privileged);
    } else if (op & 0xf0ff == 0x00c3) {
      _checkAccess(r[n], 4, true);
      bus.cpuWrite(r[n], 4, r[0], allocate: true, privileged: privileged);
    } else if (op == 0x001b) {
      bus.onDeviceAccess?.call();
      if (bus.cpg.standby & 0x80 != 0) {
        throw DcUnsupported('SH7750 standby entry is unimplemented');
      }
      if (bus.cpg.standby2 & 0x80 != 0) {
        if (bus.dma.hasEnabledTransfers) {
          throw const DcUnsupported(
              'SH7750 deep sleep requires terminated DMA');
        }
        if (bus.bsc.read(20, 4) & 6 != 6) {
          throw const DcUnsupported(
              'SH7750 deep sleep requires SDRAM self-refresh');
        }
        bus.cpg.deepSleeping = true;
      }
      sleeping = true;
    } else if (op == 0x0009) {
      // NOP.
    } else if (op == 0x0008) {
      t = false;
    } else if (op == 0x0018) {
      t = true;
    } else if (op == 0x000b) {
      delayed = pr;
    } else if (op & 0xf0ff == 0x0029) {
      r[n] = t ? 1 : 0;
    } else if (op & 0xf0ff == 0x400b || op & 0xf0ff == 0x402b) {
      delayed = r[n];
      if (op & 0xf0ff == 0x400b) {
        previousPr = pr;
        pr = (pc + 4).mask32;
      }
    } else if (op & 0xf0ff == 0x0003 || op & 0xf0ff == 0x0023) {
      delayed = (pc + 4 + r[n]).mask32;
      if (op & 0xf0ff == 0x0003) {
        previousPr = pr;
        pr = (pc + 4).mask32;
      }
    } else if (op >> 12 == 0xe) {
      r[n] = imm.rel8;
    } else if (op >> 12 == 7) {
      r[n] = (r[n] + imm.rel8).mask32;
    } else if (op >> 12 == 9) {
      r[n] = _read((pc + 4 + imm * 2).mask32, 2).rel16;
    } else if (op >> 12 == 0xd) {
      r[n] = _read(((pc & ~3) + 4 + imm * 4).mask32, 4);
    } else if (op >> 12 == 0xa || op >> 12 == 0xb) {
      final disp = ((op & 0xfff) ^ 0x800) - 0x800;
      delayed = (pc + 4 + disp * 2).mask32;
      if (op >> 12 == 0xb) {
        previousPr = pr;
        pr = (pc + 4).mask32;
      }
    } else if (op & 0xf900 == 0x8900) {
      final taken = t == (op & 0x0200 == 0);
      final destination = (pc + 4 + imm.rel8 * 2).mask32;
      if (op & 0x0400 != 0) {
        delayed = taken ? destination : (pc + 4).mask32;
      } else if (taken) {
        next = destination;
      }
    } else if (op & 0xff00 == 0x8800) {
      t = r[0] == imm.rel8.mask32;
    } else if (op & 0xff00 == 0xc700) {
      r[0] = ((pc & ~3) + 4 + imm * 4).mask32;
    } else if (op & 0xff00 == 0xc800) {
      t = r[0] & imm == 0;
    } else if (op & 0xff00 == 0xc900) {
      r[0] &= imm;
    } else if (op & 0xff00 == 0xca00) {
      r[0] ^= imm;
    } else if (op & 0xff00 == 0xcb00) {
      r[0] |= imm;
    } else if (op >> 12 == 1) {
      _write((r[n] + (op & 15) * 4).mask32, 4, r[m]);
    } else if (op >> 12 == 5) {
      r[n] = _read((r[m] + (op & 15) * 4).mask32, 4);
    } else {
      _registerOp(op, n, m);
    }
    pc = target ?? next;
    _delayedTarget = delayed;
    _delayedPr = previousPr;
    _slotFetchPrivileged = slotFetchPrivileged;
  }

  int _controlRead(int index) => switch (index) {
        0 => sr,
        1 => gbr,
        2 => vbr,
        3 => ssr,
        4 => spc,
        16 => sgr,
        17 => dbr,
        _ => bank[index - 8],
      };

  void _controlWrite(int index, int value) {
    value = value.mask32;
    switch (index) {
      case 0:
        sr = value;
      case 1:
        gbr = value;
      case 2:
        vbr = value;
      case 3:
        ssr = value;
      case 4:
        spc = value;
      case 17:
        dbr = value;
      default:
        bank[index - 8] = value;
    }
  }

  bool _controlOp(int op, int n) {
    final code = op & 0xf0ff;
    final low = op & 15;
    var index = (op >> 4) & 15;
    final directStore = op & 0xf00f == 0x0002;
    final memoryStore = op & 0xf00f == 0x4003;
    final directLoad = op & 0xf00f == 0x400e;
    final memoryLoad = op & 0xf00f == 0x4007;
    final specialStore =
        code == 0x003a || code == 0x00fa || code == 0x4032 || code == 0x40f2;
    final specialLoad = code == 0x40fa || code == 0x40f6;
    if (specialStore || specialLoad) {
      index = (op & 0x00f0) == 0x0030 ? 16 : 17;
    } else if (!(directStore || memoryStore || directLoad || memoryLoad) ||
        (index > 4 && index < 8)) {
      return false;
    }
    if (index != 1 && !privileged) _illegal();
    final load = directLoad || memoryLoad || specialLoad;
    final memory = memoryStore ||
        memoryLoad ||
        (specialStore && low == 2) ||
        (specialLoad && low == 6);
    if (load) {
      var value = r[n];
      if (memory) {
        value = _read(r[n], 4);
        // Complete the source-bank postincrement before changing SR and banks.
        r[n] = (r[n] + 4).mask32;
      }
      _controlWrite(index, value);
    } else {
      final value = _controlRead(index);
      if (memory) {
        final address = (r[n] - 4).mask32;
        _write(address, 4, value);
        r[n] = address;
      } else {
        r[n] = value;
      }
    }
    return true;
  }

  void _registerOp(int op, int n, int m) {
    switch (op & 0xf00f) {
      case 0x6003:
        r[n] = r[m];
      case 0x300c:
        r[n] = (r[n] + r[m]).mask32;
      case 0x3008:
        r[n] = (r[n] - r[m]).mask32;
      case 0x3000:
        t = r[n] == r[m];
      case 0x3002:
        t = r[n] >= r[m];
      case 0x3003:
        t = r[n].rel32 >= r[m].rel32;
      case 0x3006:
        t = r[n] > r[m];
      case 0x3007:
        t = r[n].rel32 > r[m].rel32;
      case 0x2008:
        t = r[n] & r[m] == 0;
      case 0x2009:
        r[n] &= r[m];
      case 0x200a:
        r[n] ^= r[m];
      case 0x200b:
        r[n] |= r[m];
      case 0x6007:
        r[n] = (~r[m]).mask32;
      case 0x600b:
        r[n] = (-r[m]).mask32;
      case 0x600c:
        r[n] = r[m] & 255;
      case 0x600d:
        r[n] = r[m] & 65535;
      case 0x600e:
        r[n] = r[m].rel8;
      case 0x600f:
        r[n] = r[m].rel16;
      case 0x2000:
      case 0x2001:
      case 0x2002:
      case 0x2004:
      case 0x2005:
      case 0x2006:
        final size = 1 << (op & 3);
        final address = (r[n] - (op & 4 != 0 ? size : 0)).mask32;
        // Read the source before predecrement, including when m == n.
        final value = r[m];
        _write(address, size, value);
        if (op & 4 != 0) r[n] = address;
      case 0x6000:
      case 0x6001:
      case 0x6002:
      case 0x6004:
      case 0x6005:
      case 0x6006:
        final size = 1 << (op & 3);
        final address = r[m];
        r[n] = switch (size) {
          1 => _read(address, 1).rel8,
          2 => _read(address, 2).rel16,
          _ => _read(address, 4),
        };
        if (op & 4 != 0 && n != m) r[m] = (address + size).mask32;
      default:
        if (op & 0xf0ff == 0x4010) {
          r[n] = (r[n] - 1).mask32;
          t = r[n] == 0;
        } else if (!_integerOp(op, n, m)) {
          throw DcUnsupported('instruction ${op.x4} at ${pc.x8}');
        }
    }
  }
}
