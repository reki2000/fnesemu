import 'package:fnesemu/util/int.dart';

class Dma {
  final int ioAddr;
  final int ch;

  int _startAddr = 0;
  int get startAddr => _startAddr;
  set startAddr(int value) {
    _startAddr = value;
    addr = value & 0x7ffffc;
  }

  int get blockCtrl => size | amount << 16;
  set blockCtrl(int value) {
    size = value & 0xffff;
    amount = value >> 16;
  }

  int _channelCtrl = 0;
  int get channelCtrl => _channelCtrl.setBit(24, running);
  set channelCtrl(int value) {
    _channelCtrl = value;
    syncMode = value >> 9 & 0x03;
    toRam = !value.bit0;
    incr = value.bit1 ? -4 : 4;
    running = value.bit24;
  }

  int syncMode = 0;
  int size = 0;
  int amount = 0;
  int addr = 0;

  bool enabled = false;

  bool running = false;

  bool useInterrupt = false;
  bool intterruptOnChunks = false;

  bool toRam = false;
  int incr = 0;

  Dma(this.ch, this.ioAddr);

  String dump() => "${running ? "R" : "-"} "
      "${enabled ? "E" : "-"} "
      "${useInterrupt ? "I" : "-"}${intterruptOnChunks ? "C" : "-"}  "
      "${toRam ? "->${addr.hex32}" : "${addr.hex32}->"} "
      "mode:$syncMode sz:${size.hex24} am:${amount.hex16} incr:$incr "
      "c:${channelCtrl.hex32} bl:${blockCtrl.hex32} sa:${startAddr.hex32}";
}
