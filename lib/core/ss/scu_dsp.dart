import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'scu.dart';

int _sx32(int v) => (v & 0xffffffff).rel32;
int _sx48(int v) => (v << 16) >> 16;
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
      pc = d & 0xff; // LE: load program counter
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
    pc = (pc + 1) & 0xff;
  }

  void writeDataAddr(int d) => _dataAddr = d & 0xff;

  int readData() {
    if (executing) {
      return 0xffffffff;
    }
    final r = data[_dataAddr.shr6 & 3][_dataAddr & 0x3f];
    _dataAddr = (_dataAddr & 0xc0) | (_dataAddr + 1) & 0x3f;
    return r;
  }

  void writeData(int d) {
    if (executing) {
      return;
    }
    data[_dataAddr.shr6 & 3][_dataAddr & 0x3f] = d;
    _dataAddr = (_dataAddr & 0xc0) | (_dataAddr + 1) & 0x3f;
  }

  // execution

  // CT post-increment requests of the current instruction
  final _inc = [false, false, false, false];
  final _ctWritten = [false, false, false, false];

  int _readSrc(int src) {
    final bank = src & 3;
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
        rx = _sx32(val);
        break;
      case 5:
        p = _sx32(val);
        break;
      case 6:
        ra0 = val & 0x1ffffff;
        break;
      case 7:
        wa0 = val & 0x1ffffff;
        break;
      case 10:
        lop = val & 0xfff;
        break;
      case 11:
        top = val & 0xff;
        break;
      case 12 || 13 || 14 || 15:
        ct[dst - 12] = val & 0x3f;
        _ctWritten[dst - 12] = true;
        break;
    }
  }

  void _commitCt() {
    for (int i = 0; i < 4; i++) {
      if (_inc[i] && !_ctWritten[i]) {
        ct[i] = (ct[i] + 1) & 0x3f;
      }
      _inc[i] = false;
      _ctWritten[i] = false;
    }
  }

  bool _cond(int cond) {
    if (cond & 0x1f == 0) {
      return true;
    }
    final r = (cond.bit0 && z) ||
        (cond.bit1 && s) ||
        (cond.bit2 && c) ||
        (cond.bit4 && t0);
    return cond.bit5 ? r : !r;
  }

  void _jump(int target) {
    _jumpTarget = target & 0xff;
    _jumpDelay = 2;
  }

  void exec(int steps) {
    for (int i = 0; i < steps && executing; i++) {
      final instPc = pc;
      final op = prog[pc];
      pc = (pc + 1) & 0xff;

      _execOne(op);
      _commitCt();

      if (_loopPc >= 0 && instPc == _loopPc) {
        if (lop != 0) {
          lop = (lop - 1) & 0xfff;
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
    final acl = a & 0xffffffff;
    final pl = p & 0xffffffff;
    final mul = _sx48(rx * ry);

    // ALU
    switch ((op >> 26) & 0xf) {
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
        v = v || ((~(acl ^ pl) & (acl ^ r)) & 0x80000000 != 0);
        _set32(r);
        break;
      case 0x5: // SUB
        final r = acl - pl;
        c = r < 0;
        v = v || (((acl ^ pl) & (acl ^ r)) & 0x80000000 != 0);
        _set32(r);
        break;
      case 0x6: // AD2
        final a48 = a & _mask48;
        final p48 = p & _mask48;
        final r = a48 + p48;
        c = r > _mask48;
        v = v || ((~(a48 ^ p48) & (a48 ^ r)) & 0x800000000000 != 0);
        alu = _sx48(r);
        s = alu < 0;
        z = alu == 0;
        break;
      case 0x8: // SR
        c = acl.bit0;
        _set32((acl.rel32 >> 1));
        break;
      case 0x9: // RR
        c = acl.bit0;
        _set32(acl >> 1 | (acl & 1) << 31);
        break;
      case 0xa: // SL
        c = acl.bit31;
        _set32(acl << 1);
        break;
      case 0xb: // RL
        c = acl.bit31;
        _set32(acl << 1 | acl >> 31);
        break;
      case 0xf: // RL8
        c = acl.bit24;
        _set32(acl << 8 | acl >> 24);
        break;
    }

    // X-bus
    final xop = (op >> 23) & 7;
    final xsrc = (op >> 20) & 7;
    int? xval;
    if (xop.bit2 || xop & 3 == 3) {
      xval = _readSrc(xsrc);
    }
    if (xop.bit2) {
      rx = _sx32(xval!);
    }
    if (xop & 3 == 2) {
      p = mul;
    } else if (xop & 3 == 3) {
      p = _sx32(xval!);
    }

    // Y-bus
    final yop = (op >> 17) & 7;
    final ysrc = (op >> 14) & 7;
    int? yval;
    if (yop.bit2 || yop & 3 == 3) {
      yval = _readSrc(ysrc);
    }
    if (yop.bit2) {
      ry = _sx32(yval!);
    }
    switch (yop & 3) {
      case 1:
        a = 0;
        break;
      case 2:
        a = alu;
        break;
      case 3:
        a = _sx32(yval!);
        break;
    }

    // D1-bus
    final dst = (op >> 8) & 0xf;
    switch ((op >> 12) & 3) {
      case 1:
        _writeDst(dst, (op & 0xff).rel8);
        break;
      case 3:
        final src = op & 0xf;
        final val = switch (src) {
          < 8 => _readSrc(src),
          9 => alu & 0xffffffff,
          10 => (alu >> 16) & 0xffffffff,
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
    alu = _sx48(alu);
    s = r.bit31;
    z = r == 0;
  }

  void _execMvi(int op) {
    final dst = (op >> 26) & 0xf;
    int imm;
    if (op.bit25) {
      if (!_cond((op >> 19) & 0x3f)) {
        return;
      }
      imm = (op & 0x7ffff) - ((op & 0x40000) << 1);
    } else {
      imm = (op & 0x1ffffff) - ((op & 0x1000000) << 1);
    }

    if (dst == 12) {
      _jump(imm);
    } else {
      _writeDst(dst, imm);
    }
  }

  void _execSpecial(int op) {
    switch ((op >> 28) & 3) {
      case 0:
        _execDma(op);
        return;
      case 1: // JMP
        if (_cond((op >> 19) & 0x3f)) {
          _jump(op & 0xff);
        }
        return;
      case 2:
        if (op.bit27) {
          // LPS: repeat the next instruction
          _loopPc = pc;
        } else if (lop != 0) {
          // BTM
          lop = (lop - 1) & 0xfff;
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
    final addShift = (op >> 15) & 7;
    final add = addShift == 0 ? 0 : (1 << (addShift - 1)) * 4;
    final hold = op.bit14;
    final toExternal = op.bit12;
    final ram = (op >> 8) & 7;

    int count;
    if (op.bit13) {
      count = _readSrc(op & 7);
    } else {
      count = op & 0xff;
    }
    count &= 0xff;
    if (count == 0) {
      count = 0x100;
    }

    t0 = true;
    final bus = scu.bus;

    if (toExternal) {
      int addr = wa0 << 2;
      final bank = ram & 3;
      for (int i = 0; i < count; i++) {
        final d = data[bank][ct[bank]];
        ct[bank] = (ct[bank] + 1) & 0x3f;
        bus.write32(addr, d);
        addr += add;
      }
      if (!hold) {
        wa0 = (addr >> 2) & 0x1ffffff;
      }
    } else {
      int addr = ra0 << 2;
      final readAdd = add == 0 ? 0 : 4;
      for (int i = 0; i < count; i++) {
        final d = bus.read32(addr);
        addr += readAdd;
        if (ram < 4) {
          data[ram][ct[ram]] = d;
          ct[ram] = (ct[ram] + 1) & 0x3f;
        } else {
          prog[i & 0xff] = d;
        }
      }
      if (!hold) {
        ra0 = (addr >> 2) & 0x1ffffff;
      }
    }

    t0 = false;
  }

  String dump() =>
      "dsp: ${executing ? "run" : "stop"} pc:${pc.x2} ct:${ct.map((e) => e.x2).join(",")}";
}
