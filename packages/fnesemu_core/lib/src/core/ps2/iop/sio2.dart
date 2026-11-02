import 'dart:collection';

import '../state.dart';
import 'memory_card.dart';
import 'pad.dart';

/// The serial controller for pads and memory cards (SIO2), 0x1f808200..
///
/// A transfer is described by up to 16 port control words (SEND3). Every
/// word gives the port in bits 0..1 and the length of the command in bits
/// 18..26; bits 8..16 hold a length that SIO2 ignores. Port 0 has a pad,
/// port 2 a memory card, and other ports read as 0xff. RECV1 reports 0x1100
/// when a device answered a command of the transfer and 0x1d100 otherwise. What RECV1 reports for a
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

  /// the card in the first memory card slot, or null when it is empty
  Ps2MemoryCard? card;

  // the command blocks of DMA channel 11 and the replies of the last
  // transfer, one per command
  final _blocks = <List<int>>[];
  final replies = <List<int>>[];
  int control = 0, stat6c = 0;

  /// The replies of the last transfer wait in the receive FIFO. The driver
  /// starts the receive DMA before the transfer, so the DMA waits for this.
  bool replyReady = false;
  final _regs = <int, int>{};

  static bool handles(int address) => address >= base && address < end;

  /// Saves the registers, the queues, the pad and the card.
  void saveState(StateWriter w) {
    w.section('sio2');
    for (final list in [_send3, _send1, _send2]) {
      w.ints(list);
    }
    w.ints(_out.toList());
    w.ints(_in.toList());
    w.int32(_blocks.length);
    _blocks.forEach(w.ints);
    w.int32(replies.length);
    replies.forEach(w.ints);
    w.ints([control, stat6c]);
    w.boolean(replyReady);
    w.ints([
      for (final e in _regs.entries) ...[e.key, e.value]
    ]);
    pad.saveState(w);
    w.boolean(card != null);
    card?.saveState(w);
  }

  void loadState(StateReader s) {
    s.section('sio2');
    for (final list in [_send3, _send1, _send2]) {
      s.intsInto(list);
    }
    _out
      ..clear()
      ..addAll(s.ints());
    _in
      ..clear()
      ..addAll(s.ints());
    _blocks
      ..clear()
      ..addAll(List.generate(s.int32(), (_) => s.ints()));
    replies
      ..clear()
      ..addAll(List.generate(s.int32(), (_) => s.ints()));
    final v = s.fields(2, 'sio2');
    control = v[0];
    stat6c = v[1];
    replyReady = s.boolean();
    final r = s.ints();
    _regs.clear();
    for (var i = 0; i + 1 < r.length; i += 2) {
      _regs[r[i]] = r[i + 1];
    }
    pad.loadState(s);
    if (s.boolean() != (card != null)) {
      throw const StateMismatch('memory card inserted or removed');
    }
    card?.loadState(s);
  }

  void reset() {
    _send3.fillRange(0, 16, 0);
    _out.clear();
    _in.clear();
    _blocks.clear();
    replies.clear();
    control = stat6c = 0;
    replyReady = false;
  }

  /// bytes that the CPU sends are queued here
  void send(int byte) => _out.add(byte & 0xff);

  /// a block of DMA channel 11
  void sendBlock(List<int> block) => _blocks.add(block);

  /// the DMA took the replies
  void clearReplies() {
    replies.clear();
    _in.clear();
    replyReady = false;
  }

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
    replies.clear();
    var commands = 0;
    while (commands < 16 && _send3[commands] != 0) {
      commands++;
    }
    // the DMA blocks hold one command each; otherwise they feed the queue
    final perBlock = _blocks.length == commands;
    if (!perBlock) {
      for (final block in _blocks) {
        _out.addAll(block);
      }
    }
    var answered = false;
    for (var k = 0; k < commands; k++) {
      final word = _send3[k];
      final port = word & 3;
      final length = (word >> 18) & 0x1ff;
      final sent = perBlock
          ? _blocks[k].take(length).toList()
          : [
              for (var i = 0; i < length && _out.isNotEmpty; i++)
                _out.removeFirst(),
            ];
      final card = this.card;
      List<int>? reply;
      // a pad is selected by the address byte 0x01 and a card by 0x81
      if (port == 0 && sent.isNotEmpty && sent.first == 1) {
        reply = pad.transfer(sent, length);
      } else if (port == 2 && card != null && sent.isNotEmpty) {
        if (sent.first == 0x81) reply = card.transfer(sent, length);
      }
      answered |= reply != null;
      reply ??= List<int>.filled(length, 0xff);
      replies.add(reply);
      _in.addAll(reply);
    }
    _blocks.clear();
    _out.clear();
    stat6c = answered ? 0x1100 : 0x1d100;
    replyReady = _in.isNotEmpty;
    onInterrupt?.call();
  }
}
