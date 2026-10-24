import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';

import 'scu.dart';

const _mask48 = 0xffffffffffff;

/// SCU DSP: 32-bit VLIW fixed-point processor
class ScuDsp {
  final Scu scu;
  ScuDsp(this.scu);

  final prog = Uint32List(256);
  final data = List.generate(4, (_) => Uint32List(64));
  final ct = [0, 0, 0, 0];

  int pc = 0;
  int rx = 0, ry = 0; // 32 bit signed
  int p = 0, a = 0, alu = 0; // 48 bit signed
  int ra0 = 0, wa0 = 0;
  int lop = 0, top = 0;

  bool s = false, z = false, c = false, v = false, e = false, t0 = false;
  bool executing = false;

  int _jumpTarget = -1;
  int _jumpDelay = 0;
  int _loopPc = -1;

  int _dataAddr = 0;

  List<bool> get _flags => [s, z, c, v, e, t0, executing];

  void saveState(StateWriter w) {
    w.section('scu-dsp');
    w.ints(prog);
    data.forEach(w.ints);
    w.ints(ct);
    w.ints([pc, rx, ry, p, a, alu, ra0, wa0, lop, top]);
    w.ints([_jumpTarget, _jumpDelay, _loopPc, _dataAddr]);
    for (final b in [..._flags, ..._inc, ..._ctWritten]) {
      w.boolean(b);
    }
  }

  void loadState(StateReader r) {
    r.section('scu-dsp');
    r.intsInto(prog);
    for (final bank in data) {
      r.intsInto(bank);
    }
    r.intsInto(ct);
    final v = r.ints(), j = r.ints();
    if (v.length != 10 || j.length != 4) {
      throw const StateMismatch('scu dsp state layout');
    }
    pc = v[0];
    rx = v[1];
    ry = v[2];
    p = v[3];
    a = v[4];
    alu = v[5];
    ra0 = v[6];
    wa0 = v[7];
    lop = v[8];
    top = v[9];
    _jumpTarget = j[0];
    _jumpDelay = j[1];
    _loopPc = j[2];
    _dataAddr = j[3];
    s = r.boolean();
    z = r.boolean();
    c = r.boolean();
    this.v = r.boolean();
    e = r.boolean();
    t0 = r.boolean();
    executing = r.boolean();
    for (var i = 0; i < 4; i++) {
      _inc[i] = r.boolean();
    }
    for (var i = 0; i < 4; i++) {
      _ctWritten[i] = r.boolean();
    }
  }

  void reset() {
    pc = 0;
    rx = ry = p = a = alu = 0;
    ra0 = wa0 = lop = top = 0;
    s = z = c = v = e = t0 = false;
    executing = false;
    _jumpTarget = -1;
    _jumpDelay = 0;
    _loopPc = -1;
    _dataAddr = 0;
    ct.fillRange(0, 4, 0);
  }

  // registers

  int readControl() {
    final r = (t0 ? 1 << 23 : 0) |
        (s ? 1 << 22 : 0) |
        (z ? 1 << 21 : 0) |
        (c ? 1 << 20 : 0) |
        (v ? 1 << 19 : 0) |
        (e ? 1 << 18 : 0) |
        (executing ? 1 << 16 : 0) |
        pc;
    v = false;
    e = false;
    return r;
  }

  void writeControl(int d) {
    if (d.bit15) {
      pc = d.mask8; // LE: load program counter
    }

    if (d.bit25) {
      // PR: pause reset
    } else if (d.bit26) {
      // EP: pause
      executing = false;
      return;
    }

    if (d.bit16) {
      executing = true;
    } else if (d.bit17) {
      executing = true;
      exec(1); // step
      executing = false;
    } else {
      executing = false;
    }
  }

  void writeProgram(int d) {
    prog[pc] = d;
    pc = (pc + 1).mask8;
  }

  void writeDataAddr(int d) => _dataAddr = d.mask8;

  int readData() {
    if (executing) {
      return 0xffffffff;
    }
    final r = data[_dataAddr.shr6.mask2][_dataAddr.mask6];
    _dataAddr = (_dataAddr & 0xc0) | (_dataAddr + 1).mask6;
    return r;
  }

  void writeData(int d) {
    if (executing) {
      return;
    }
    data[_dataAddr.shr6.mask2][_dataAddr.mask6] = d;
    _dataAddr = (_dataAddr & 0xc0) | (_dataAddr + 1).mask6;
  }

  // execution

  // CT post-increment requests of the current instruction
  final _inc = [false, false, false, false];
  final _ctWritten = [false, false, false, false];

  int _readSrc(int src) {
    final bank = src.mask2;
    if (src >= 4) {
      _inc[bank] = true;
    }
    return data[bank][ct[bank]];
  }

  void _writeDst(int dst, int val) {
    val &= 0xffffffff;
    switch (dst) {
      case 0 || 1 || 2 || 3:
        data[dst][ct[dst]] = val;
        _inc[dst] = true;
        break;
      case 4:
        rx = val.rel32;
        break;
      case 5:
        p = val.rel32;
        break;
      case 6:
        ra0 = val & 0x1ffffff;
        break;
      case 7:
        wa0 = val & 0x1ffffff;
        break;
      case 10:
        lop = val.mask12;
        break;
      case 11:
        top = val.mask8;
        break;
      case 12 || 13 || 14 || 15:
        ct[dst - 12] = val.mask6;
        _ctWritten[dst - 12] = true;
        break;
    }
  }

  void _commitCt() {
    for (int i = 0; i < 4; i++) {
      if (_inc[i] && !_ctWritten[i]) {
        ct[i] = (ct[i] + 1).mask6;
      }
      _inc[i] = false;
      _ctWritten[i] = false;
    }
  }

  bool _cond(int cond) {
    if (cond.mask5 == 0) {
      return true;
    }
    final r = (cond.bit0 && z) ||
        (cond.bit1 && s) ||
        (cond.bit2 && c) ||
        (cond.bit4 && t0);
    return cond.bit5 ? r : !r;
  }

  void _jump(int target) {
    _jumpTarget = target.mask8;
    _jumpDelay = 2;
  }

  void exec(int steps) {
    for (int i = 0; i < steps && executing; i++) {
      final instPc = pc;
      final op = prog[pc];
      pc = (pc + 1).mask8;

      _execOne(op);
      _commitCt();

      if (_loopPc >= 0 && instPc == _loopPc) {
        if (lop != 0) {
          lop = (lop - 1).mask12;
          pc = _loopPc;
        } else {
          _loopPc = -1;
        }
      }

      if (_jumpDelay > 0 && --_jumpDelay == 0) {
        pc = _jumpTarget;
      }
    }
  }

  void _execOne(int op) {
    switch (op >>> 30) {
      case 0:
        _execOperation(op);
        return;
      case 1:
        return; // undefined
      case 2:
        _execMvi(op);
        return;
      case 3:
        _execSpecial(op);
        return;
    }
  }

  void _execOperation(int op) {
    // values latched at the beginning of the instruction
    final acl = a.mask32;
    final pl = p.mask32;
    final mul = (rx * ry).rel48;

    // ALU
    switch (op.shr26.mask4) {
      case 0x0: // NOP
        break;
      case 0x1: // AND
        _logic(acl & pl);
        break;
      case 0x2: // OR
        _logic(acl | pl);
        break;
      case 0x3: // XOR
        _logic(acl ^ pl);
        break;
      case 0x4: // ADD
        final r = acl + pl;
        c = r > 0xffffffff;
        v = v || (~(acl ^ pl) & (acl ^ r)).bit31;
        _set32(r);
        break;
      case 0x5: // SUB
        final r = acl - pl;
        c = r < 0;
        v = v || ((acl ^ pl) & (acl ^ r)).bit31;
        _set32(r);
        break;
      case 0x6: // AD2
        final a48 = a & _mask48;
        final p48 = p & _mask48;
        final r = a48 + p48;
        c = r > _mask48;
        v = v || ((~(a48 ^ p48) & (a48 ^ r)) & 0x800000000000 != 0);
        alu = r.rel48;
        s = alu < 0;
        z = alu == 0;
        break;
      case 0x8: // SR
        c = acl.bit0;
        _set32(acl.rel32.shr1);
        break;
      case 0x9: // RR
        c = acl.bit0;
        _set32(acl.shr1 | acl.mask1.shl31);
        break;
      case 0xa: // SL
        c = acl.bit31;
        _set32(acl.shl1);
        break;
      case 0xb: // RL
        c = acl.bit31;
        _set32(acl.shl1 | acl.shr31);
        break;
      case 0xf: // RL8
        c = acl.bit24;
        _set32(acl.shl8 | acl.shr24);
        break;
    }

    // X-bus
    final xop = op.shr23.mask3;
    final xsrc = op.shr20.mask3;
    int? xval;
    if (xop.bit2 || xop.mask2 == 3) {
      xval = _readSrc(xsrc);
    }
    if (xop.bit2) {
      rx = xval!.rel32;
    }
    if (xop.mask2 == 2) {
      p = mul;
    } else if (xop.mask2 == 3) {
      p = xval!.rel32;
    }

    // Y-bus
    final yop = op.shr17.mask3;
    final ysrc = op.shr14.mask3;
    int? yval;
    if (yop.bit2 || yop.mask2 == 3) {
      yval = _readSrc(ysrc);
    }
    if (yop.bit2) {
      ry = yval!.rel32;
    }
    switch (yop.mask2) {
      case 1:
        a = 0;
        break;
      case 2:
        a = alu;
        break;
      case 3:
        a = yval!.rel32;
        break;
    }

    // D1-bus
    final dst = op.shr8.mask4;
    switch (op.shr12.mask2) {
      case 1:
        _writeDst(dst, op.rel8);
        break;
      case 3:
        final src = op.mask4;
        final val = switch (src) {
          < 8 => _readSrc(src),
          9 => alu.mask32,
          10 => alu.shr16.mask32,
          _ => 0,
        };
        _writeDst(dst, val);
        break;
    }
  }

  void _logic(int r) {
    c = false;
    _set32(r);
  }

  void _set32(int r) {
    r &= 0xffffffff;
    alu = (alu & ~0xffffffff) | r;
    alu = alu.rel48;
    s = r.bit31;
    z = r == 0;
  }

  void _execMvi(int op) {
    final dst = op.shr26.mask4;
    int imm;
    if (op.bit25) {
      if (!_cond(op.shr19.mask6)) {
        return;
      }
      imm = (op & 0x7ffff) - (op & 0x40000).shl1;
    } else {
      imm = (op & 0x1ffffff) - (op & 0x1000000).shl1;
    }

    if (dst == 12) {
      _jump(imm);
    } else {
      _writeDst(dst, imm);
    }
  }

  void _execSpecial(int op) {
    switch (op.shr28.mask2) {
      case 0:
        _execDma(op);
        return;
      case 1: // JMP
        if (_cond(op.shr19.mask6)) {
          _jump(op.mask8);
        }
        return;
      case 2:
        if (op.bit27) {
          // LPS: repeat the next instruction
          _loopPc = pc;
        } else if (lop != 0) {
          // BTM
          lop = (lop - 1).mask12;
          _jump(top);
        }
        return;
      case 3:
        executing = false;
        if (op.bit27) {
          e = true;
          scu.onDspEnd();
        }
        return;
    }
  }

  void _execDma(int op) {
    final addShift = op.shr15.mask3;
    final add = addShift == 0 ? 0 : (1 << (addShift - 1)) * 4;
    final hold = op.bit14;
    final toExternal = op.bit12;
    final ram = op.shr8.mask3;

    int count;
    if (op.bit13) {
      count = _readSrc(op.mask3);
    } else {
      count = op.mask8;
    }
    count &= 0xff;
    if (count == 0) {
      count = 0x100;
    }

    t0 = true;
    final bus = scu.bus;

    if (toExternal) {
      int addr = wa0.shl2;
      final bank = ram.mask2;
      for (int i = 0; i < count; i++) {
        final d = data[bank][ct[bank]];
        ct[bank] = (ct[bank] + 1).mask6;
        bus.write32(addr, d);
        addr += add;
      }
      if (!hold) {
        wa0 = addr.shr2 & 0x1ffffff;
      }
    } else {
      int addr = ra0.shl2;
      final readAdd = add == 0 ? 0 : 4;
      for (int i = 0; i < count; i++) {
        final d = bus.read32(addr);
        addr += readAdd;
        if (ram < 4) {
          data[ram][ct[ram]] = d;
          ct[ram] = (ct[ram] + 1).mask6;
        } else {
          prog[i.mask8] = d;
        }
      }
      if (!hold) {
        ra0 = addr.shr2 & 0x1ffffff;
      }
    }

    t0 = false;
  }

  String dump() =>
      "dsp: ${executing ? "run" : "stop"} pc:${pc.x2} ct:${ct.map((e) => e.x2).join(",")}";
}
