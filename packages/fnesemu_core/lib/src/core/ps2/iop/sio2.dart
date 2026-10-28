import 'dart:collection';

import 'pad.dart';

/// The serial controller for pads and memory cards (SIO2), 0x1f808200..
///
/// A transfer is described by up to 16 port control words (SEND3). Every
/// word gives the port in bits 0..1 and the length of the command in bits
/// 18..24; bits 8..16 hold a length that SIO2 ignores. Port 0 has a pad and
/// other ports read as 0xff. RECV1 reports 0x1100 when the pad answered a
/// command of the transfer and 0x1d100 otherwise. What RECV1 reports for a
/// transfer to several ports is unverified; the pad driver polls both pad
/// ports in one transfer and takes the replies only when it reads 0x1100.
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

  /// The replies of the last transfer wait in the receive FIFO. The driver
  /// starts the receive DMA before the transfer, so the DMA waits for this.
  bool replyReady = false;
  final _regs = <int, int>{};

  static bool handles(int address) => address >= base && address < end;

  void reset() {
    _send3.fillRange(0, 16, 0);
    _out.clear();
    _in.clear();
    control = stat6c = 0;
    replyReady = false;
  }

  /// bytes that the CPU or DMA channel 11 sends are queued here
  void send(int byte) => _out.add(byte & 0xff);

  /// the next received byte
  int receive() {
    if (_in.isEmpty) return 0xff;
    final byte = _in.removeFirst();
    if (_in.isEmpty) replyReady = false;
    return byte;
  }

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
      case 0x70:
        return 0xf; // RECV2: the high nibble is always set
      case 0x74:
        return 0; // RECV3
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
    _in.clear();
    var answered = false;
    for (final word in _send3) {
      if (word == 0) break;
      final port = word & 3;
      final length = (word >> 18) & 0x7f;
      final sent = [
        for (var i = 0; i < length && _out.isNotEmpty; i++) _out.removeFirst(),
      ];
      // a pad is selected by the address byte 0x01
      final present = port == 0 && sent.isNotEmpty && sent.first == 1;
      answered |= present;
      if (present) {
        _in.addAll(pad.transfer(sent, length));
      } else {
        for (var i = 0; i < length; i++) {
          _in.add(0xff);
        }
      }
    }
    _out.clear();
    stat6c = answered ? 0x1100 : 0x1d100;
    replyReady = _in.isNotEmpty;
    onInterrupt?.call();
  }
}
