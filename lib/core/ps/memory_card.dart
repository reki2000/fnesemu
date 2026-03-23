import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../../util/debug.dart';
import 'serial.dart' show SioResponse, SioDevice;

class MemoryCard extends SioDevice {
  static const int waitIgnore = -1;
  static const int waitAddr = 0; //
  static const int waitCommand = 1; //
  static const int waitRwAddrMsb = 2; //
  static const int waitRwAddrLsb = 3; //
  static const int waitWrite = 4; //
  static const int waitRead = 13; //
  static const int waitId0 = 5; //
  static const int waitId1 = 6; //
  static const int waitCmdAck0 = 7; //
  static const int waitCmdAck1 = 8; //
  static const int waitAddrAck0 = 9; //
  static const int waitAddrAck1 = 10; //
  static const int waitReadCheckSum = 11; //
  static const int waitEnd = 12; //
  static const int waitWriteCheckSum = 14; //

  int step = waitAddr;

  Uint8List mem = Uint8List(128 * 1024); // 128KB
  int addr = 0;
  int count = 0;

  bool writeMode = false;
  bool firstReadDone = false;
  int checkSum = 0;
  int _pre = 0;

  int Function(int)? _readEx;
  void Function(int, int)? _writeEx;

  get flag => firstReadDone ? 0 : 0x08;

  static final Uint8List blankImage = _initBlankImage();

  static Uint8List _initBlankImage() {
    final image = Uint8List(128 * 1024);
    image.setRange(0, 2, "MC".codeUnits); // ID0, ID1
    for (int i = 1 * 128; i < 15 * 128; i += 128) {
      image[i] = 0xa0; // free block
    }
    for (int i = 0; i < 64 * 128; i += 128) {
      int checkSum = 0;
      for (int j = 0; j < 127; j++) {
        checkSum ^= image[i + j];
      }
      image[i + 127] = checkSum;
    }
    return image;
  }

  @override
  void reset() {
    step = waitAddr;
    count = 0;
    addr = 0;
  }

  @override
  void resetStep() {
    step = waitAddr;
    count = 0;
    addr = 0;
  }

  void setRw(int Function(int) read, void Function(int, int) write) {
    this._readEx = read;
    this._writeEx = write;
  }

  SioResponse ack(int data, {int delayCycles = 600}) {
    _pre = data;
    return SioResponse(data, ack: step != waitAddr, delayCycles: delayCycles);
  }

  @override
  SioResponse notify(int txData) {
    // if (step != waitAddr) {
    //   debugLog(
    //       "memcard: notify txData:${txData.hex8} pre:${_pre.hex8} dump:${dump()}");
    // }

    switch (step) {
      case waitAddr:
        if (txData == 0x81) {
          step = waitCommand;
          return ack(0xff);
        }

      case waitCommand:
        if (txData == 0x52) {
          // 'R'
          writeMode = false;
        } else if (txData == 0x57) {
          // 'W'
          writeMode = true;
        } else {
          // unknown command
          step = waitAddr;
          return ack(0xff);
        }

        step = waitId0;
        return ack(flag);

      case waitId0:
        step = waitId1;
        return ack(0x5a);

      case waitId1:
        step = waitRwAddrMsb;
        return ack(0x5d);

      case waitRwAddrMsb:
        addr = txData & 0x03 << 15;
        checkSum = txData & 0x03;
        step = waitRwAddrLsb;
        return ack(0);

      case waitRwAddrLsb:
        addr = txData << 7 | addr;
        step = writeMode ? waitWrite : waitCmdAck0;
        checkSum ^= txData;
        count = 128;
        return ack(_pre, delayCycles: 1200);

      case waitCmdAck0:
        step = waitCmdAck1;
        return ack(0x5c, delayCycles: 1200);

      case waitCmdAck1:
        step = writeMode ? waitEnd : waitAddrAck0;
        return ack(0x5d);

      case waitAddrAck0:
        step = waitAddrAck1;
        return ack(addr >> 15);

      case waitAddrAck1:
        step = waitRead;
        return ack(addr >> 7 & 0xff);

      case waitRead:
        final readData = _readEx?.call(addr) ?? 0;
        checkSum ^= readData;
        addr = addr.inc & 0x1ffff;
        count--;
        if (count == 0) {
          step = waitReadCheckSum;
        }
        // debugLog("memcard: read from ${addr.hex16} data:${readData.hex8} "
        //     "checkSum:${checkSum.hex8} count:$count");
        return ack(readData);

      case waitReadCheckSum:
        step = waitEnd;
        return ack(checkSum);

      case waitWrite:
        firstReadDone =
            true; // in some reason, this flag is set on write instead of read
        _writeEx?.call(addr, txData);
        checkSum ^= txData;
        addr = addr.inc & 0x1ffff;
        count--;
        if (count == 0) {
          step = waitWriteCheckSum;
        }
        return ack(_pre);

      case waitWriteCheckSum:
        if (txData != checkSum) {
          debugLog(
              "memcard: write checksum error: got:${txData.hex8} expected:${checkSum.hex8}");
        }
        step = waitCmdAck0;
        return ack(_pre);

      case waitEnd:
        step = waitAddr;
        return ack(0x47); // 'G' for Good
    }

    step = waitIgnore;
    return SioResponse(0xff, ignored: true, ack: false);
  }

  @override
  String dump() => "state:$step addr:${addr.hex16} count:$count";
}
