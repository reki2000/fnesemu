import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

import 'pad.dart';

/// System Manager & Peripheral Control
class Smpc {
  final Pad pad;

  Smpc(this.pad);

  // callbacks wired by the core
  void Function(bool on) onSlaveCpu = (_) {};
  void Function(bool on) onSoundCpu = (_) {};
  void Function() onSystemReset = () {};
  void Function() onNmi = () {};
  void Function(bool is352) onClockChange = (_) {};
  void Function() onInterrupt = () {}; // SCU system manager interrupt

  /// area code: 1 = Japan, 4 = North America, 0xc = Europe
  int areaCode = 0x01;

  final ireg = List<int>.filled(7, 0);
  final oreg = List<int>.filled(32, 0);
  int comreg = 0;
  int sr = 0;
  int sf = 0;

  final pdr = [0, 0];
  final ddr = [0, 0];
  int iosel = 0;
  int exle = 0;

  final smem = [0, 0, 0, 0];
  bool resetDisabled = true;
  bool is352 = false;

  // pending command and clocks until completion
  int _pendingCommand = -1;
  int _commandWait = 0;

  // intback continuation state
  bool _intbackPeripheralPending = false;

  void reset() {
    ireg.fillRange(0, ireg.length, 0);
    oreg.fillRange(0, oreg.length, 0);
    comreg = 0;
    sr = 0;
    sf = 0;
    _pendingCommand = -1;
    _commandWait = 0;
    _intbackPeripheralPending = false;
    resetDisabled = true;
  }

  // register index = (address >> 1) & 0x3f
  int read(int reg) {
    return switch (reg) {
      >= 0x10 && < 0x30 => oreg[reg - 0x10],
      0x30 => sr,
      0x31 => sf,
      0x3a => _readPdr(0),
      0x3b => _readPdr(1),
      _ => 0xff,
    };
  }

  void write(int reg, int data) {
    switch (reg) {
      case >= 0x00 && < 0x07:
        ireg[reg] = data;
        if (reg == 0 && _intbackPeripheralPending) {
          _intbackContinue(data);
        }
        break;
      case 0x0f:
        comreg = data;
        _pendingCommand = data;
        _commandWait = 200; // execution time in SH-2 clocks (approx.)
        break;
      case 0x30:
        sr = data;
        break;
      case 0x31:
        sf = data;
        break;
      case 0x3a:
        pdr[0] = data;
        break;
      case 0x3b:
        pdr[1] = data;
        break;
      case 0x3c:
        ddr[0] = data;
        break;
      case 0x3d:
        ddr[1] = data;
        break;
      case 0x3e:
        iosel = data;
        break;
      case 0x3f:
        exle = data;
        break;
    }
  }

  // advances the SMPC internal clock
  void exec(int clocks) {
    if (_pendingCommand < 0) {
      return;
    }

    _commandWait -= clocks;
    if (_commandWait > 0) {
      return;
    }

    final command = _pendingCommand;
    _pendingCommand = -1;
    _execCommand(command);
  }

  void _execCommand(int command) {
    switch (command) {
      case 0x00: // MSHON
        break;
      case 0x02: // SSHON
        onSlaveCpu(true);
        break;
      case 0x03: // SSHOFF
        onSlaveCpu(false);
        break;
      case 0x06: // SNDON
        onSoundCpu(true);
        break;
      case 0x07: // SNDOFF
        onSoundCpu(false);
        break;
      case 0x08: // CDON
      case 0x09: // CDOFF
        break;
      case 0x0d: // SYSRES
        onSystemReset();
        break;
      case 0x0e: // CKCHG352
      case 0x0f: // CKCHG320
        is352 = command == 0x0e;
        onSlaveCpu(false);
        onClockChange(is352);
        onNmi();
        break;
      case 0x10: // INTBACK
        _intback();
        oreg[31] = command;
        sf = 0;
        return;
      case 0x16: // SETTIME
        break;
      case 0x17: // SETSMEM
        for (int i = 0; i < 4; i++) {
          smem[i] = ireg[i];
        }
        break;
      case 0x18: // NMIREQ
        onNmi();
        break;
      case 0x19: // RESENAB
        resetDisabled = false;
        break;
      case 0x1a: // RESDISA
        resetDisabled = true;
        break;
      default:
        debugLog("smpc: unknown command ${command.x2}");
    }

    oreg[31] = command;
    sf = 0;
  }

  static int _bcd(int v) => (v ~/ 10) << 4 | (v % 10);

  // SR bits 3-0: port modes requested by IREG1 (P2MD, P1MD).
  // software skips ports whose mode is 3 (0 byte mode)
  int get _portModes => (ireg[1] >> 4) & 0x0f;

  void _intback() {
    final getStatus = ireg[0].bit0;
    final getPeripheral = ireg[1].bit3;

    if (getStatus) {
      final now = DateTime.now();

      oreg[0] = 0x80 | (resetDisabled ? 0x40 : 0); // STE | RESD
      oreg[1] = _bcd(now.year ~/ 100);
      oreg[2] = _bcd(now.year % 100);
      oreg[3] = (now.weekday % 7) << 4 | now.month;
      oreg[4] = _bcd(now.day);
      oreg[5] = _bcd(now.hour);
      oreg[6] = _bcd(now.minute);
      oreg[7] = _bcd(now.second);
      oreg[8] = 0x00; // cartridge code
      oreg[9] = areaCode;
      oreg[10] = 0x34 | (is352 ? 0x40 : 0); // system status 1 (DOTSEL etc.)
      oreg[11] = 0x00; // system status 2
      for (int i = 0; i < 4; i++) {
        oreg[12 + i] = smem[i];
      }

      _intbackPeripheralPending = getPeripheral;
      sr = 0x40 | _portModes | (getPeripheral ? 0x20 : 0);
      onInterrupt();
      return;
    }

    if (getPeripheral) {
      _setPeripheralData();
      onInterrupt();
    }
  }

  void _intbackContinue(int data) {
    if (data.bit6) {
      // break
      _intbackPeripheralPending = false;
      sr &= ~0x20;
      return;
    }

    if (data.bit7) {
      // continue
      _setPeripheralData();
      _intbackPeripheralPending = false;
      oreg[31] = 0x10;
      onInterrupt();
    }
  }

  void _setPeripheralData() {
    int i = 0;
    for (int port = 0; port < 2; port++) {
      if (port < Pad.controllerNum) {
        final (d0, d1) = pad.data(port);
        oreg[i++] = 0xf1; // direct connection, 1 peripheral
        oreg[i++] = 0x02; // standard digital pad, 2 bytes
        oreg[i++] = d0;
        oreg[i++] = d1;
      } else {
        oreg[i++] = 0xf0; // nothing connected
      }
    }
    for (; i < 32; i++) {
      oreg[i] = 0x00;
    }

    sr = 0xc0 | _portModes; // PDL (first data), no remaining data
    _intbackPeripheralPending = false;
  }

  // direct peripheral access (SMPC port mode, TH/TR protocol for digital pad)
  int _readPdr(int port) {
    if (port >= Pad.controllerNum) {
      return 0x7f;
    }

    final (d0, d1) = pad.data(port);
    final sel = pdr[port] & 0x60;

    // TH: bit6, TR: bit5
    final nibble = switch (sel) {
      0x60 => 0x04 | (d1 >> 3) & 0x08, // L
      0x20 => d0 >> 4, // right, left, down, up
      0x40 => d0 & 0x0f, // start, A, C, B
      _ => d1 >> 4, // R, X, Y, Z
    };

    return 0x10 | sel | nibble & 0x0f;
  }

  String dump() =>
      "smpc: com:${comreg.x2} sr:${sr.x2} sf:${sf.x2} ireg:${ireg.map((e) => e.x2).join(" ")}";
}
