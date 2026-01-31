import 'package:fnesemu/util/int.dart';

class Dma {
  final int ioAddr;
  final int ch;

  final int clocks;

  int _startAddr = 0;
  int get startAddr => _startAddr;
  set startAddr(int value) {
    _startAddr = value;
    addr = value & 0x7ffffc;
  }

  int get blockCtrl => size | amount << 16;
  set blockCtrl(int value) {
    size = value & 0xffff;
    if (size == 0) {
      size = 0x10000;
    }
    initialSize = size;
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

    // if (running && (ch == 0 || ch == 1 || ch == 3)) {
    //   debugLog("DMA$ch: started   ${dump()}");
    // }
  }

  int syncMode = 0;
  int size = 0;
  int initialSize = 0;
  int amount = 0;
  int addr = 0;

  bool enabled = false;

  bool running = false;

  bool useInterrupt = false;
  bool intterruptOnChunks = false;

  bool toRam = false;
  int incr = 0;

  Dma(this.ch, this.ioAddr, this.clocks);

  void reset() {
    _startAddr = 0;
    _channelCtrl = 0;
    size = 0;
    initialSize = 0;
    amount = 0;
    addr = 0;
    enabled = false;
    running = false;
    useInterrupt = false;
    intterruptOnChunks = false;
    toRam = false;
    incr = 0;
  }

  String dump() => "DMA$ch: ${running ? "R" : "-"} "
      "${enabled ? "E" : "-"} "
      "${useInterrupt ? "I" : "-"}${intterruptOnChunks ? "C" : "-"}  "
      "${toRam ? "->${addr.hex32}" : "${addr.hex32}->"} "
      "mode:$syncMode sz:${size.hex24} am:${amount.hex16} incr:$incr "
      "c:${channelCtrl.hex32} bl:${blockCtrl.hex32} sa:${startAddr.hex32}";
}
