import 'dart:collection';

import 'package:fnesemu/util/int.dart';

import '../../util/debug.dart';
import 'bus.dart';
import 'interrupt.dart';

class CmdResult {
  int delay = 0;
  int intNo = 0;
  Queue<int> fifo = Queue<int>();
}

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
  bool isCmdBusy = false;
  bool isSectorBufferReadReq = false;
  bool isSectorBufferWriteReq = false;

  int cmdDelay = 0;

  int intMask = 0;
  int intStatus = 0;

  final paramFifo = ListQueue<int>();
  final cmdResults = Queue<CmdResult>();

  void reset() {
    isAdpcmBusy = false;
    isDataReq = false;
    isCmdBusy = false;
    isSectorBufferReadReq = false;

    cmdResults.clear();
    paramFifo.clear();
  }

  int readBuffer8() {
    final data = sectorBuffer[sectorBufferIndex++];
    if (sectorBufferIndex >= sectorBuffer.length) {
      sectorBufferIndex -= 4;
      isDataReq = false;
    }
    return data;
  }

  int readBuffer16() {
    final data = sectorBuffer[sectorBufferIndex] |
        sectorBuffer[sectorBufferIndex + 1] << 8;
    sectorBufferIndex += 2;
    if (sectorBufferIndex >= sectorBuffer.length) {
      sectorBufferIndex -= 4;
      isDataReq = false;
    }

    // debugLog(
    //     "cdrom: readBuffer16 ${sectorBufferIndex.hex16} ${data.hex16} ${dump()}");
    return data;
  }

  int readCmdResult() {
    // debugLog("cdrom: readFifo ${dump()}");
    if (cmdResults.isEmpty) {
      return 0;
    }

    final result = cmdResults.first.fifo.removeFirst();
    if (cmdResults.first.fifo.isEmpty) {
      cmdResults.removeFirst();
    }

    return result;
  }

  int readPort8(int reg) {
    final result = switch (reg) {
      0 => bank
          .setBit(2, isAdpcmBusy)
          .setBit(3, paramFifo.isEmpty)
          .setBit(4, paramFifo.length < 16)
          .setBit(5, cmdResults.isNotEmpty)
          .setBit(6, isDataReq)
          .setBit(7, isCmdBusy),
      1 => readCmdResult(),
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
    // debugLog("cdrom: write8 $bank-$reg <= ${value.hex8} ${dump()}");
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

  void exec(int clocks) {
    if (cmdResults.isNotEmpty) {
      final result = cmdResults.first;
      if (result.delay > 0) {
        result.delay -= clocks;

        if (result.delay <= 0) {
          isCmdBusy = false;
          intStatus = intStatus.masked(0x07, result.intNo);

          if (intMask & result.intNo != 0) {
            bus.setIrq(Interrupt.cdrom);
            // debugLog("cdrom: irq ${result.intNo} ${dump()}");
          }
        }
      }
    }

    if (cmdDelay >= 0) {
      cmdDelay -= clocks;
      if (cmdDelay < 0) {
        isCmdBusy = false;
      }
    }

    // sector read
    if (isReading) {
      sectorReadDelay -= clocks;

      if (sectorReadDelay <= 0) {
        sectorReadDelay += 33868800 ~/ 150;

        // read sector
        sectorBuffer.setAll(0, bus.readDisc(sector));
        // debugLog(
        //     "cdrom: read sector $sector ${dump()} [${sectorBuffer.sublist(0, 10).map((e) => e.hex8).join(" ")}]");

        irq(1, [status()]);
        isDataReq = true;
        sectorBufferIndex = 0;

        sector++;
      }
    }
  }

  void irq(int no, List<int> data, {int delay = 50000}) {
    final result = CmdResult()
      ..delay = delay
      ..intNo = no
      ..fifo.addAll(data);
    cmdResults.add(result);
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

  int sector = 0; // current sector
  int sectorReadDelay = 0; // next read clock

  void execCommand(int cmd) {
    cmdResults.clear();

    debugLog(
        "cdrom: command cmd:${cmd.hex8} params:[${paramFifo.map((e) => e.hex8).join(" ")}] ${dump()}");
    switch (cmd) {
      case 0x01: // GetStat
        irq(3, [status()]);

      case 0x02: // SetLoc
        sector = paramFifo.elementAt(0) * 60 * 75 +
            paramFifo.elementAt(1) * 75 +
            paramFifo.elementAt(2);
        irq(3, [status()], delay: 5000);

      case 0x06: // ReadN
        isReading = true;
        sectorReadDelay = 33868800 ~/ 150;
        irq(3, [status()], delay: 1000);

      case 0x09: // Pause
        isReading = false;
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x0a: // Init
        isReading = false;
        paramFifo.clear();
        cmdResults.clear();
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x0e: // SetMode
        irq(3, [status()]);

      case 0x15: // SeekL
        irq(3, [status()], delay: 5000);
        irq(2, [status()], delay: 500000);

      case 0x1a: // GetId
        irq(3, [status()]);
        irq(2, [0x02, 0x00, 0x20, 0x00, 0x53, 0x43, 0x45, 0x41],
            delay: 50000); // Liscensed, SECA

      case 0x1e: // ReadTOC
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x19: // test
        if (paramFifo.isEmpty) {
          debugLog("cdrom: test no params");
        } else {
          switch (paramFifo.elementAt(0)) {
            case 0x20:
              irq(3, [0x94, 0x09, 0x19, 0xc0]);
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
    isCmdBusy = true;
    cmdDelay = 1000;
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

  String dump() => "bank:$bank "
      "params:[${paramFifo.map((e) => e.hex8).join(" ")}] "
      "results:${cmdResults.map((r) => "[${r.intNo} ${r.delay} ${r.fifo.map((e) => e.hex8).join(" ")}]")} "
      "${isAdpcmBusy ? "Adpcm" : "Data"} ${isDataReq ? "Req" : "NoReq"} "
      "mask:${intMask.hex8} int:${intStatus.hex8}";
}
