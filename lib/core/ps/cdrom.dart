import 'dart:collection';
import 'dart:typed_data';

import '../../util/debug.dart';
import '../../util/int.dart';
import '../disc.dart';
import 'bus.dart';
import 'interrupt.dart';

part 'cdrom_xa.dart';

class CmdResult {
  int delay = 0;
  int intNo = 0;
  bool ack = false;
  bool triggered = false;
  Queue<int> fifo = Queue<int>();
}

extension IntBcd on int {
  int get asBcd => (this & 0x0f) + ((this & 0xf0) >> 4) * 10;
  int get toBcd => ((this ~/ 10) << 4) | (this % 10);
}

class Toc {
  int firstTrackBcd = 1;
  int lastTrackBcd = 1;
  int diskType = 0x20; // 00h=CD-DA or CD-ROM, 10h=CD-I, 20h=CD-ROM-XA
}

class Cdrom {
  Bus bus;
  Toc toc = Toc();

  Cdrom(this.bus) {
    reset();
  }

  late Disc disc;

  int bank = 0;

  int data = 0;
  int result = 0;

  bool isPlaying = false;
  bool isSeeking = false;
  bool isReading = false;
  bool isShellOpen = false;
  bool isIdError = false;
  bool isSeekError = false;
  bool isSpindleMotorOn = true;
  bool isError = false;

  static const sectorBufferSize = 2352; // 0x930 bytes

  Uint8List rawSector = Uint8List(sectorBufferSize);
  final sectorBuffer = List.filled(sectorBufferSize, 0); // 0x930 bytes
  int sectorBufferIndex = 0;
  bool sectorBufferEmpty = true;

  int seekSector = 0; // target sector for seek
  int readingSector = 0; // current sector
  int sectorReadDelay = 0; // next read clock

  int mode = 0;
  int file = 0;
  int channel = 0;

  bool get isHighSpeed => mode.bit7;
  bool get isXaAdpcmEnabled => mode.bit6;
  bool get isSectorSize924 => mode.bit5;
  bool get isXaFilterEnabled => mode.bit3;
  bool get isCddaEnabled => mode.bit0;

  get sectorSize => isSectorSize924 ? 0x924 : 0x800;

  bool isXaAdpcmBusy = false;
  bool isMuted = false;

  int xaSampleRate = 37800;
  final audioBufferL = ListQueue<int>();
  final audioBufferR = ListQueue<int>();
  final audioLastSample = [0, 0];
  final List<int> xaOld = [0, 0, 0]; // mono, left, right
  final List<int> xaOldest = [0, 0, 0]; // mono, left, right
  final resampler = XaResampler();

  final List<int> atv = [0, 0, 0, 0];
  int adpCtrl = 0;

  int intMask = 0;

  int cmdDelay = 0;
  bool isCmdBusy = false;
  final paramFifo = ListQueue<int>();
  final cmdResults = Queue<CmdResult>();
  final resultFifo = Queue<int>();
  int currentIntNo = 0;

  void reset() {
    mode = 0;

    isCmdBusy = false;

    isXaAdpcmBusy = false;

    xaSampleRate = 37800;
    audioBufferL.clear();
    audioBufferR.clear();
    audioLastSample.setAll(0, [0, 0]);
    xaOld.setAll(0, [0, 0, 0]);
    xaOldest.setAll(0, [0, 0, 0]);
    resampler.reset();

    atv.setAll(0, [0, 0, 0, 0]);
    adpCtrl = 0;

    cmdDelay = 0;
    intMask = 0;
    bank = 0;
    data = 0;
    result = 0;
    currentIntNo = 0;

    isPlaying = false;
    isReading = false;
    isSeeking = false;
    isShellOpen = false;
    isIdError = false;
    isSeekError = false;
    isSpindleMotorOn = true;
    isError = false;

    readingSector = 0;
    seekSector = 0;
    sectorBufferIndex = 0;
    sectorBufferEmpty = true;

    cmdResults.clear();
    paramFifo.clear();
    resultFifo.clear();
  }

  bool isBufferNotReadable() =>
      sectorBufferEmpty || sectorBufferIndex >= sectorSize;

  int readBuffer8() {
    if (sectorBufferEmpty) {
      return 0;
    }
    if (sectorBufferIndex >= sectorSize) {
      sectorBufferIndex++;
      return 0;
    }

    final startIndex = isSectorSize924 ? 12 : 24;

    final data = sectorBuffer[startIndex + sectorBufferIndex++];
    if (isBufferNotReadable()) {
      sectorBufferEmpty = true;
    }
    return data;
  }

  int readBuffer16() {
    final data = readBuffer8() | (readBuffer8() << 8);

    // debugLog(
    //     "cdrom: readBuffer16 ${sectorBufferIndex.hex16} ${data.hex16} ${dump()}");
    return data;
  }

  int readCmdResult() {
    // debugLog("cdrom: readFifo ${dump()}");
    if (resultFifo.isEmpty) {
      return 0;
    }

    return resultFifo.removeFirst();
  }

  int readPort8(int reg) {
    final result = switch (reg) {
      0 => bank
          .setBit(2, isXaAdpcmBusy)
          .setBit(3, paramFifo.isEmpty)
          .setBit(4, paramFifo.length < 16)
          .setBit(5, resultFifo.isNotEmpty)
          .setBit(6, !sectorBufferEmpty)
          .setBit(7, isCmdBusy),
      1 => readCmdResult(),
      2 => readBuffer8(),
      3 => 0xe0 | (bank.bit0 ? currentIntNo : intMask) & 0x1f,
      _ => 0,
    };
    // if (reg != 2) {
    //   debugLog("cdrom: read8 $bank-$reg => ${result.hex8} ${dump()}");
    // }
    return result;
  }

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
        if (value.bit7) {
          if (isBufferNotReadable()) {
            sectorBuffer.setAll(0, rawSector);
            sectorBufferEmpty = false;
            sectorBufferIndex = 0;
          }
        } else {
          sectorBufferEmpty = true;
          sectorBufferIndex = 0;
        }

      case (1, 1): // wrdata
        break;

      case (1, 2): // hintmsk
        intMask = value & 0x1f;
        // Re-evaluate pending interrupt when mask is updated.
        _raisePendingIrqIfEnabled();

      case (1, 3): // hclrctl
        if (value.bit6) {
          paramFifo.clear();
        }
        if (value.bit7) {
          // reset decoder
          isXaAdpcmBusy = false;
        }
        if (value & 0x7 != 0) {
          // irq ack
          currentIntNo = 0;
        }

      case (2, 2): // atv0
      case (2, 3): // atv1
      case (3, 1): // atv2
      case (3, 2): // atv3
        atv[reg - 2] = value;

      case (3, 3): // ADPCTL
        adpCtrl = value;

      default:
        debugLog(
            "cdrom: unknown write8: $bank-$reg <= ${value.hex8}, ${dump()}");
    }
  }

  void exec(int clocks) {
    if (cmdResults.isNotEmpty) {
      final result = cmdResults.first;
      result.delay -= clocks;

      if (result.delay <= 0 && currentIntNo == 0) {
        isCmdBusy = false;
        currentIntNo = result.intNo;
        resultFifo.clear();
        resultFifo.addAll(result.fifo);
        cmdResults.removeFirst();
        _raisePendingIrqIfEnabled();
        // debugLog("cdrom: irq ${result.intNo} ${dump()}");
      }
    }

    cmdDelay -= clocks;
    if (cmdDelay < 0) {
      isCmdBusy = false;
    }

    // sector read
    if (isReading || isCddaEnabled) {
      sectorReadDelay -= clocks;

      if (sectorReadDelay <= 0) {
        sectorReadDelay += 33868800 ~/ (isHighSpeed ? 150 : 75);

        rawSector = disc.read(readingSector);

        final isAudioSector = disc.isAudioSector(readingSector);

        if (isPlaying || (isCddaEnabled && isAudioSector)) {
          debugLog(
              "cdrom: read audio sector ${Disc.dumpSector(readingSector)}");
          for (int i = 0; i < rawSector.length; i += 4) {
            final l = rawSector[i + 0] | rawSector[i + 1].shl8;
            final r = rawSector[i + 2] | rawSector[i + 3].shl8;
            audioBufferL.add(l.rel16);
            audioBufferR.add(r.rel16);
          }
        } else if (isXaAdpcmEnabled && !isAudioSector && !adpCtrl.bit0) {
          decodeXa();
        }

        // debugLog(
        //     "cdrom: read sector $sector(${sector ~/ (60 * 75)}:${(sector ~/ 75) % 60}:${sector % 75}) ${dump()} [${rawSector.sublist(12, 28).map((e) => e.hex8).join(" ")} ..]");

        irq(1, [status()], delay: 0);

        readingSector++;
      }
    }
  }

  List<int> popAudioSample() {
    if (audioBufferL.isNotEmpty && audioBufferR.isNotEmpty) {
      final l = audioBufferL.removeFirst();
      final r = audioBufferR.removeFirst();
      if (adpCtrl.bit5) {
        audioLastSample[0] = l;
        audioLastSample[1] = r;
      } else {
        audioLastSample[0] =
            (l * atv[0] ~/ 0x80 + r * atv[3] ~/ 0x80).clip(-0x8000, 0x7fff);
        audioLastSample[1] =
            (r * atv[2] ~/ 0x80 + l * atv[1] ~/ 0x80).clip(-0x8000, 0x7fff);
      }
    }
    return audioLastSample;
  }

  void _raisePendingIrqIfEnabled() {
    if (currentIntNo != 0 && (intMask & currentIntNo & 0x07) != 0) {
      bus.setIrq(Interrupt.cdrom);
    }
  }

  void irq(int no, List<int> data, {int delay = 50000}) {
    // INT1 is level-like in practice for sector delivery; do not enqueue
    // duplicates while one is already pending/active and waiting for ACK.
    if (no == 1 && (currentIntNo == 1 || cmdResults.any((r) => r.intNo == 1))) {
      return;
    }

    final result = CmdResult()
      ..delay = delay
      ..intNo = no
      ..fifo.addAll(data);
    cmdResults.add(result);
  }

  int status() {
    return 0
        .setBit(7, isCddaEnabled)
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
        "cdrom: ${cmd.hex8}:${commandNames[cmd & 0x1f]}(${paramFifo.map((e) => "0x${e.hex8}").join(",")}) ${dump()}");

    switch (cmd) {
      case 0x01: // GetStat
        irq(3, [status()]);

      case 0x02: // SetLoc
        isReading = false;
        seekSector = paramFifo.elementAt(0).asBcd * 60 * 75 +
            paramFifo.elementAt(1).asBcd * 75 +
            paramFifo.elementAt(2).asBcd;
        irq(3, [status()], delay: 5000);

      case 0x03: // Play
        isPlaying = true;
        readingSector = seekSector;
        irq(3, [status()]);

      case 0x04: // Forward
        // todo
        irq(3, [status()]);

      case 0x05: // Backward
        // todo
        irq(3, [status()]);

      case 0x06: // ReadN
        isReading = true;
        readingSector = seekSector;
        sectorReadDelay = 33868800 ~/ (isHighSpeed ? 150 : 75);
        irq(3, [status()], delay: 1000);

      case 0x07: // Standby
        isReading = false;
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x08: // Stop
        isReading = false;
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x09: // Pause
        irq(3, [status()]);
        isReading = false;
        irq(2, [status()]);

      case 0x0a: // Init
        isMuted = false;
        isReading = false;
        mode = 0;
        // paramFifo.clear();
        // cmdResults.clear();
        irq(3, [status()], delay: 5000);
        irq(2, [status()]);

      case 0x0b: // Mute
        isMuted = true;
        irq(3, [status()]);

      case 0x0c: // Demute
        isMuted = false;
        irq(3, [status()]);

      case 0x0d: // SetFilter
        file = paramFifo.elementAt(0);
        channel = paramFifo.elementAt(1);
        irq(3, [status()]);

      case 0x0e: // SetMode
        mode = paramFifo.elementAt(0);
        irq(3, [status()]);

      case 0x0f: // GetParam
        irq(3, [status(), mode, 0x00, file, channel]);

      case 0x10: // GetLocl
        irq(3, rawSector.sublist(12, 20));

      case 0x11: // GetLocp
        final currentSector = isReading ? readingSector : seekSector;
        int trackNo = 0;
        while (trackNo < disc.trackCount) {
          if (currentSector < disc.startLba(trackNo + 1)) {
            break;
          }
          trackNo++;
        }
        final (rm, rs, rf) = Disc.lbaToMsf(
            currentSector - disc.startLba(trackNo),
            addLeadIn: false);
        final (am, as_, af) = Disc.lbaToMsf(currentSector);
        irq(3, [
          trackNo,
          1,
          rm.toBcd,
          rs.toBcd,
          rf.toBcd,
          am.toBcd,
          as_.toBcd,
          af.toBcd,
        ]);

      case 0x13: // GetTN
        final first = toc.firstTrackBcd;
        final last = toc.lastTrackBcd;
        irq(3, [status(), first, last]);

      case 0x14: // GetTD
        final track = paramFifo.elementAt(0).asBcd;
        if (track == 0) {
          final (mm, ss, _) = Disc.lbaToMsf(disc.totalSectors);
          irq(3, [status(), mm.toBcd, ss.toBcd]);
        } else {
          final (mm, ss, _) = Disc.lbaToMsf(disc.startLba(track));
          irq(3, [status(), mm.toBcd, ss.toBcd]);
        }

      case 0x15: // SeekL
        readingSector = seekSector;
        irq(3, [status()], delay: 5000);
        irq(2, [status()], delay: 500000);

      case 0x16: // SeekP
        readingSector = seekSector;
        irq(3, [status()], delay: 5000);
        irq(2, [status()], delay: 500000);

      case 0x1a: // GetId
        irq(3, [status()]);
        irq(2, [0x02, 0x00, 0x20, 0x00, 0x53, 0x43, 0x45, 0x41],
            delay: 50000); // Liscensed, SCEA

      case 0x1b: // ReadS (no retry)
        isReading = true;
        readingSector = seekSector;
        sectorReadDelay = 33868800 ~/ (isHighSpeed ? 150 : 75);
        irq(3, [status()], delay: 1000);

      case 0x1c: // Reset
        isReading = false;
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x1e: // ReadTOC
        toc.firstTrackBcd = disc.isEmpty ? 0 : 1.toBcd;
        toc.lastTrackBcd = disc.isEmpty ? 0 : disc.trackCount.toBcd;
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x19: // test
        if (paramFifo.isEmpty) {
          debugLog("cdrom: test no params");
        } else {
          switch (paramFifo.elementAt(0)) {
            case 0x04:
              irq(3, [status()]);
            case 0x05:
              irq(3, [0x01, 0x01]); // SCEx data cd
            case 0x20:
              irq(3, [0x94, 0x09, 0x19, 0xc0]);
            case 0x21:
              irq(3, [0x00]);
            case 0x22:
              irq(3, Uint8List.fromList("for U/C".codeUnits));
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

  String dump() => "status:${status().hex8} bank:$bank "
      "cmd:[${paramFifo.map((e) => e.hex8).join(" ")}] "
      "result:[${resultFifo.map((e) => e.hex8).join(" ")}] "
      "pend:${cmdResults.map((r) => "[${r.intNo} ${r.delay} [${r.fifo.map((e) => e.hex8).join(" ")}]]").join(" ")} "
      "${isXaAdpcmBusy ? "Adpcm" : "DRQ"} ${sectorBufferEmpty ? "empty" : "ready"} ${isHighSpeed ? "x2" : "x1"} ${isSectorSize924 ? "924" : "800"} "
      "mask:${intMask.hex8} mode:${mode.hex8} seek:${Disc.dumpSector(seekSector)} read:${Disc.dumpSector(readingSector)}";

  static List<String> commandNames = [
    "", "GetStat", "SetLoc", "SetMode", "Forward", "Backward", "ReadN",
    "Standby", // 0x00-0x07
    "Stop", "Pause", "Init", "Mute", "Demute", "SetFilter", "SetMode",
    "GetParam", // 0x08-0x0f
    "GetLocl", "GetLocp", "", "GetTN", "GetTD", "SeekL", "SeekP", "",
    "", // 0x10-0x17
    "Test", "GetId", "ReadS", "Reset", "", "ReadTOC", "", // 0x18-0x1f
  ];
}
