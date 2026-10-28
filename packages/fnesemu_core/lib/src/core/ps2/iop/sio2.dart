import 'dart:collection';

import 'pad.dart';

/// The serial controller for pads and memory cards (SIO2), 0x1f808200..
///
/// A transfer is described by up to 16 port control words (SEND3). Every
/// word gives the byte counts sent to and received from one port. Port 0 has
/// a pad and other ports read as 0xff. The register layout is from memory and
/// unverified.
class Sio2 {
  static const base = 0x1f808200, end = 0x1f808300;

  /// called when a transfer completes
  void Function()? onInterrupt;

  final _send3 = List<int>.filled(16, 0);
  final _send1 = List<int>.filled(4, 0);
  final _send2 = List<int>.filled(4, 0);
  final _out = ListQueue<int>();
  final _in = ListQueue<int>();
  Ps2Pad pad = Ps2Pad();
  int control = 0, stat6c = 0;
  final _regs = <int, int>{};

  static bool handles(int address) => address >= base && address < end;

  void reset() {
    _send3.fillRange(0, 16, 0);
    _out.clear();
    _in.clear();
    control = stat6c = 0;
  }

  /// bytes that the CPU or DMA channel 11 sends are queued here
  void send(int byte) => _out.add(byte & 0xff);

  /// the next received byte
  int receive() => _in.isEmpty ? 0xff : _in.removeFirst();

  int read(int address, int size) {
    final o = address - base;
    if (o < 0x40) return _send3[o >> 2];
    if (o >= 0x40 && o < 0x50) return _send1[(o - 0x40) >> 2];
    if (o >= 0x50 && o < 0x60) return _send2[(o - 0x50) >> 2];
    switch (o) {
      case 0x64:
        return receive();
      case 0x68:
        return control;
      case 0x6c:
        return stat6c;
    }
    return _regs[address] ?? 0;
  }

  void write(int address, int size, int value) {
    final o = address - base;
    if (o < 0x40) {
      _send3[o >> 2] = value;
    } else if (o < 0x50) {
      _send1[(o - 0x40) >> 2] = value;
    } else if (o < 0x60) {
      _send2[(o - 0x50) >> 2] = value;
    } else if (o == 0x60) {
      send(value);
    } else if (o == 0x68) {
      control = value & ~1;
      if (value & 1 != 0) _transfer();
    } else {
      _regs[address] = value;
    }
  }

  void _transfer() {
    for (final word in _send3) {
      if (word == 0) break;
      final port = word & 3;
      final sent = (word >> 8) & 0x1ff;
      final received = (word >> 18) & 0x1ff;
      // a pad is selected by the address byte 0x01
      final isPad = port == 0 && sent > 0 && _out.isNotEmpty && _out.first == 1;
      for (var i = 0; i < sent && _out.isNotEmpty; i++) {
        _out.removeFirst();
      }
      for (var i = 0; i < received; i++) {
        _in.add(isPad ? pad.reply(i) : 0xff);
      }
    }
    _out.clear();
    stat6c = 0;
    onInterrupt?.call();
  }
}
