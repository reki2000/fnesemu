import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'package:fnesemu/util/debug.dart';
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
  static const int waitIdEnd0 = 15; //
  static const int waitIdEnd1 = 16; //
  static const int waitIdEnd2 = 17; //
  static const int waitIdEnd3 = 18; //

  int step = waitAddr;

  int addr = 0;
  int count = 0;

  int command = commandRead;
  static const int commandNone = 0;
  static const int commandRead = 0x52; // 'R'
  static const int commandWrite = 0x57; // 'W'
  static const int commandId = 0x53; // 'S'

  bool firstReadDone = false;
  int checkSum = 0;
  int _pre = 0;

  int Function(int)? _readEx;
  void Function(int, int)? _writeEx;

  get flag => firstReadDone ? 0 : 0x08;

  static final Uint8List blankImage = _buildBlankImage();

  static Uint8List _buildBlankImage() {
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

    command = commandNone;
  }

  @override
  void resetStep() {
    reset();
  }

  void setRw(int Function(int) read, void Function(int, int) write) {
    _readEx = read;
    _writeEx = write;
  }

  SioResponse ack(int data, {int delay = 300}) {
    _pre = data;
    return SioResponse(data, ack: step != waitAddr, delay: delay);
  }

  @override
  SioResponse notify(int txData) {
    // if (step != waitAddr) {
    //   debugLog(
    //       "memcard: notify txData:${txData.x2} pre:${_pre.x2} dump:${dump()}");
    // }

    switch (step) {
      case waitAddr:
        if (txData == 0x81) {
          step = waitCommand;
          return ack(0xff);
        }

      case waitCommand:
        if (txData == commandRead) {
          // 'R'
          command = commandRead;
        } else if (txData == commandWrite) {
          // 'W'
          command = commandWrite;
        } else if (txData == commandId) {
          // 'S'
          command = commandId;
        } else {
          // unknown command
          debugLog("memcard: unknown command ${txData.x2}");
          step = waitAddr;
          return ack(flag);
        }

        step = waitId0;
        return ack(flag);

      case waitId0:
        step = waitId1;
        return ack(0x5a);

      case waitId1:
        step = command == commandId ? waitCmdAck0 : waitRwAddrMsb;
        return ack(0x5d);

      case waitRwAddrMsb:
        addr = txData & 0x03.shl15;
        checkSum = txData & 0x03;
        step = waitRwAddrLsb;
        return ack(0);

      case waitRwAddrLsb:
        addr = txData.shl7 | addr;
        step = command == commandWrite ? waitWrite : waitCmdAck0;
        checkSum ^= txData;
        count = 128;
        return ack(_pre, delay: 1200);

      case waitCmdAck0:
        step = waitCmdAck1;
        return ack(0x5c, delay: 1200);

      case waitCmdAck1:
        step = command == commandId
            ? waitIdEnd0
            : command == commandWrite
                ? waitEnd
                : waitAddrAck0;
        return ack(0x5d);

      case waitAddrAck0:
        step = waitAddrAck1;
        return ack(addr.shr15);

      case waitAddrAck1:
        step = waitRead;
        return ack(addr.shr7 & 0xff);

      case waitRead:
        final readData = _readEx?.call(addr) ?? 0;
        checkSum ^= readData;
        addr = addr.inc & 0x1ffff;
        count--;
        if (count == 0) {
          step = waitReadCheckSum;
        }
        // debugLog("memcard: read from ${addr.x4} data:${readData.x2} "
        //     "checkSum:${checkSum.x2} count:$count");
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
              "memcard: write checksum error: got:${txData.x2} expected:${checkSum.x2}");
        }
        step = waitCmdAck0;
        return ack(_pre);

      case waitEnd:
        step = waitAddr;
        return ack(0x47); // 'G' for Good

      case waitIdEnd0:
        step = waitIdEnd1;
        return ack(0x04);

      case waitIdEnd1:
        step = waitIdEnd2;
        return ack(0x00);

      case waitIdEnd2:
        step = waitIdEnd3;
        return ack(0x00);

      case waitIdEnd3:
        step = waitAddr;
        return ack(0x80);
    }

    step = waitIgnore;
    return SioResponse(0xff, ignored: true, ack: false);
  }

  @override
  String dump() => "state:$step addr:${addr.x4} count:$count";
}
