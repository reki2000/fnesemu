import 'dart:collection';

import 'package:fnesemu/util/int.dart';

import '../../util/debug.dart';
import 'bus.dart';
import 'interrupt.dart';

class Cdrom {
  Bus bus;

  Cdrom(this.bus) {
    reset();
  }

  int bank = 0;

  int data = 0;
  int result = 0;

  final sectorBuffer = List.filled(2352, 0);
  int sectorBufferIndex = 0;

  bool isAdpcmBusy = false;
  bool isDataReq = false;
  bool isSectorBufferReadReq = false;
  bool isSectorBufferWriteReq = false;

  int intMask = 0;
  int intStatus = 0;

  final paramFifo = ListQueue<int>();
  final resultFifo = Queue<int>();

  void reset() {
    isAdpcmBusy = false;
    isDataReq = false;
  }

  int readBuffer8() {
    final data = sectorBuffer[sectorBufferIndex++];
    if (sectorBufferIndex >= sectorBuffer.length) {
      sectorBufferIndex -= 4;
    }
    return data;
  }

  int readBuffer16() {
    final data = (sectorBuffer[sectorBufferIndex] << 8) |
        sectorBuffer[sectorBufferIndex + 1];
    sectorBufferIndex += 2;
    if (sectorBufferIndex >= sectorBuffer.length) {
      sectorBufferIndex -= 4;
      isDataReq = false;
    }
    return data;
  }

  int readResultFifo() {
    // debugLog("cdrom: readFifo ${dump()}");
    if (resultFifo.isEmpty) {
      return 0;
    }
    return resultFifo.removeFirst();
  }

  int readPort8(int reg) {
    final result = switch (reg) {
      0 => bank
          .setBit(2, isAdpcmBusy)
          .setBit(3, paramFifo.isEmpty)
          .setBit(4, paramFifo.length < 16)
          .setBit(5, resultFifo.isNotEmpty)
          .setBit(6, isDataReq)
          .setBit(7, false),
      1 => readResultFifo(),
      2 => readBuffer8(),
      3 => (bank.bit0 ? intStatus : intMask) & 0x1f | 0xe0,
      _ => 0,
    };
    // debugLog("cdrom: read8 $bank-$reg => ${result.hex8} ${dump()}");
    return result;
  }

  int readPort16(int reg) => switch (reg) {
        2 => readBuffer16(),
        _ => readPort8(reg),
      };

  void writePort8(int reg, int value) {
    if (reg == 0) {
      bank = value & 0x03;
      return;
    }

    switch ((bank, reg)) {
      case (0, 1): // command
        execCommand(value);

      case (0, 2): // params
        if (paramFifo.length < 16) {
          paramFifo.add(value);
        }

      case (0, 3): // hchpctl
        isSectorBufferReadReq = value.bit7;
        isSectorBufferWriteReq = value.bit6;
        sectorBufferIndex = 0;
        isDataReq = true;

      case (1, 1): // wrdata
        break;

      case (1, 2): // hintmsk
        intMask = value & 0x1f;

      case (1, 3): // hclrctl
        intStatus &= ~(value & 0x1f);
        if (value.bit6) {
          paramFifo.clear();
        }
        if (value.bit7) {
          // reset decoder
        }

      default:
        debugLog(
            "cdrom: unknown write8: $bank-$reg <= ${value.hex8}, ${dump()}");
    }
  }

  void irq(int no, List<int> data) {
    resultFifo.addAll(data);

    if (intMask & no != 0) {
      intStatus = intStatus.masked(0x07, no);
      bus.setIrq(Interrupt.cdrom);
      debugLog("cdrom: irq $no ${dump()}");
    }
  }

  bool isPlayCDDA = false;
  bool isSeeking = false;
  bool isReading = false;
  bool isShellOpen = false;
  bool isIdError = false;
  bool isSeekError = false;
  bool isSpindleMotorOn = false;
  bool isError = false;

  int status() {
    return 0
        .setBit(7, isPlayCDDA)
        .setBit(6, isSeeking)
        .setBit(5, isReading)
        .setBit(4, isShellOpen)
        .setBit(3, isIdError)
        .setBit(2, isSeekError)
        .setBit(1, isSpindleMotorOn)
        .setBit(0, isError);
  }

  void execCommand(int cmd) {
    resultFifo.clear();

    debugLog(
        "cdrom: command pc:${bus.cpu.pc.hex32} cmd:${cmd.hex8} params:[${paramFifo.map((e) => e.hex8).join(" ")}]");
    switch (cmd) {
      case 0x01: // nop
        irq(3, [status()]);

      case 0x19: // test
        if (paramFifo.isEmpty) {
          debugLog("cdrom: test no params");
        } else {
          switch (paramFifo.elementAt(0)) {
            case 0x20:
              irq(3, [0x99, 0x02, 0x01, 0xc3]);
            default:
              debugLog(
                  "cdrom: unknown test command ${paramFifo.map((e) => e.hex8).join(" ")}");
          }
        }
      default:
        debugLog(
            "cdrom: unknown command ${cmd.hex8} params:${paramFifo.map((e) => e.hex8).join(" ")}");
    }

    paramFifo.clear();
  }

  void openShell() {
    isSpindleMotorOn = false;
    isShellOpen = true;
  }

  void closeShell() {
    isSpindleMotorOn = true;
    isShellOpen = false;
  }

  void readSector(int sector) {}

  String dump() =>
      "bank:$bank params:[${paramFifo.map((e) => e.hex8).join(" ")}] results:[${resultFifo.map((e) => e.hex8).join(" ")}] "
      "${isAdpcmBusy ? "Adpcm" : "Data"} ${isDataReq ? "Req" : "NoReq"} "
      "mask:${intMask.hex8} int:${intStatus.hex8}";
}
