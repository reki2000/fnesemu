import 'dart:collection';
import 'dart:typed_data';

import '../../cdrom.dart';
import '../../util/debug.dart';
import '../../util/int.dart';
import 'bus.dart';
import 'interrupt.dart';
import 'log.dart';

part 'cdrom_async.dart';
part 'cdrom_xa.dart';

final _log = DebugLog('ps.cdrom');

class CmdResult {
  int delay = 0;
  int intNo = 0;
  bool ack = false;
  bool triggered = false;
  Queue<int> fifo = Queue<int>();
}

extension IntBcd on int {
  int get asBcd => this.mask4 + (this & 0xf0).shr4 * 10;
  int get toBcd => (this ~/ 10).shl4 | (this % 10);
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

  /// connection to [CdromDrive]
  late final _port = _DrivePort(this);

  void attachDrive(CdromDrive drive) => _port.attach(drive);

  int _clock = 0; // elapsed clocks, for seek timing

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
  bool isSeekPending = false; // SetLoc is issued but not used by Read/Play/Seek
  int playTrack = 0; // track being played, for auto pause
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

  final List<int> atv = [0, 0, 0, 0]; // written values
  final List<int> atvApplied = [0x80, 0, 0x80, 0]; // L->L, L->R, R->R, R->L
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
    atvApplied.setAll(0, [0x80, 0, 0x80, 0]);
    adpCtrl = 0;
    isMuted = false;

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
    isSeekPending = false;
    sectorBufferIndex = 0;
    sectorBufferEmpty = true;

    cmdResults.clear();
    paramFifo.clear();
    resultFifo.clear();

    _port.clear();
  }

  /// the sector fetched by the drive, waiting to be processed
  Uint8List? _fetched;

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
    final data = readBuffer8() | readBuffer8().shl8;

    // _log.debugc(() =>
    //     "readBuffer16 ${sectorBufferIndex.x4} ${data.x4} ${dump()}");
    return data;
  }

  int readCmdResult() {
    // _log.debugc(() => "readFifo ${dump()}", id: 'fifo');
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
      3 => 0xe0 | (bank.bit0 ? currentIntNo : intMask).mask5,
      _ => 0,
    };
    // if (reg != 2) {
    //   _log.debugc(() => "read8 $bank-$reg => ${result.x2} ${dump()}");
    // }
    return result;
  }

  void writePort8(int reg, int value) {
    // _log.debugc(() => "write8 $bank-$reg <= ${value.x2} ${dump()}");
    if (reg == 0) {
      bank = value.mask2;
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
        intMask = value.mask5;
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
        if (value.mask3 != 0) {
          // irq ack
          currentIntNo = 0;
        }

      case (2, 2): // atv0
        atv[0] = value;

      case (2, 3): // atv1
        atv[1] = value;

      case (3, 1): // atv2
        atv[2] = value;

      case (3, 2): // atv3
        atv[3] = value;

      case (3, 3): // ADPCTL
        adpCtrl = value;
        if (value.bit5) {
          // apply audio volume changes
          atvApplied.setAll(0, atv);
        }

      default:
        _log.warnc(
            () => "unknown write8: $bank-$reg <= ${value.x2}, ${dump()}");
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
        // _log.debugc(() => "irq ${result.intNo} ${dump()}");
      }
    }

    cmdDelay -= clocks;
    if (cmdDelay < 0) {
      isCmdBusy = false;
    }

    _clock += clocks;
    _port.poll();

    // sector read
    if (isReading || isPlaying) {
      sectorReadDelay -= clocks;

      if (sectorReadDelay <= 0) {
        _fetched = _port.read(readingSector);
        if (_fetched == null) {
          // the drive has not read the sector yet: wait for it
          sectorReadDelay += 33868800 ~/ 150 ~/ 8;
          return;
        }

        sectorReadDelay += 33868800 ~/ (isHighSpeed ? 150 : 75);
        isSeeking = false;

        if (isPlaying) {
          _playSector();
        } else {
          _readSector();
        }

        readingSector++;
      }
    }
  }

  /// reads [sector] (includes 2 seconds of lead-in) from the disc
  Uint8List _fetchSector(int sector) => _fetched!;

  // disc information, from the TOC of the drive
  bool get _isDiscEmpty => !_port.isReady;
  int get _trackCount => _port.toc.trackCount;
  int get _totalSectors => _port.toc.totalSectors;
  int _startLba(int trackNo) => _port.toc.startLba(trackNo);
  bool _isAudioSector(int sector) =>
      _port.isReady && _port.toc.isAudioLba(sector - 2 * 75);

  void _readSector() {
    rawSector = _fetchSector(readingSector);

    if (_isAudioSector(readingSector)) {
      if (isCddaEnabled) {
        _pushCdda();
      }
    } else if (isXaAdpcmEnabled &&
        rawSector.length > 18 &&
        rawSector[18] & 0x44 == 0x44) {
      // XA-ADPCM sectors are sent to the decoder, not to the data buffer
      if (!adpCtrl.bit0) {
        decodeXa();
      }
      return;
    }

    irq(1, [status()], delay: 0);
  }

  void _playSector() {
    // auto pause at the end of the track or the disc
    final track = _trackOf(readingSector);
    if (playTrack == 0) {
      playTrack = track;
    }
    if ((mode.bit1 && track != playTrack) ||
        readingSector >= _totalSectors + 2 * 75) {
      isPlaying = false;
      irq(4, [status()], delay: 0);
      return;
    }

    rawSector = _fetchSector(readingSector);
    if (_isAudioSector(readingSector)) {
      _pushCdda();
    }

    // report mode: position report every 10 sectors
    if (mode.bit2 && readingSector % 10 == 0) {
      final (am, as_, af) = Msf.ofFrames(readingSector).bcd();
      final isRelative = af.shr4.isOdd;
      final (rm, rs, rf) =
          Msf.ofFrames((readingSector - _trackStart(track)).max(0)).bcd();
      irq(
          1,
          [
            status(),
            track.toBcd,
            1,
            isRelative ? rm : am,
            isRelative ? rs | 0x80 : as_,
            isRelative ? rf : af,
            0,
            0,
          ],
          delay: 0);
    }
  }

  void _pushCdda() {
    for (int i = 0; i < rawSector.length; i += 4) {
      final l = rawSector[i + 0] | rawSector[i + 1].shl8;
      final r = rawSector[i + 2] | rawSector[i + 3].shl8;
      audioBufferL.add(l.rel16);
      audioBufferR.add(r.rel16);
    }
  }

  /// start sector of the track, including 2 seconds of lead-in
  int _trackStart(int trackNo) => _startLba(trackNo) + 2 * 75;

  /// returns the track number (1..) which contains the sector, 0 if none
  int _trackOf(int sector) {
    if (_isDiscEmpty) {
      return 0;
    }
    int trackNo = 1;
    while (trackNo < _trackCount && sector >= _trackStart(trackNo + 1)) {
      trackNo++;
    }
    return trackNo; // sectors before track 1 are in the pregap of track 1
  }

  List<int> popAudioSample() {
    if (audioBufferL.isNotEmpty && audioBufferR.isNotEmpty) {
      final l = audioBufferL.removeFirst();
      final r = audioBufferR.removeFirst();
      if (isMuted) {
        audioLastSample[0] = 0;
        audioLastSample[1] = 0;
      } else {
        final v = atvApplied;
        audioLastSample[0] =
            (l * v[0] ~/ 0x80 + r * v[3] ~/ 0x80).clip(-0x8000, 0x7fff);
        audioLastSample[1] =
            (r * v[2] ~/ 0x80 + l * v[1] ~/ 0x80).clip(-0x8000, 0x7fff);
      }
    }
    return audioLastSample;
  }

  void _raisePendingIrqIfEnabled() {
    if (currentIntNo != 0 && (intMask & currentIntNo).mask3 != 0) {
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
        .setBit(7, isPlaying)
        .setBit(6, isSeeking)
        .setBit(5, isReading)
        .setBit(4, isShellOpen)
        .setBit(3, isIdError)
        .setBit(2, isSeekError)
        .setBit(1, isSpindleMotorOn)
        .setBit(0, isError);
  }

  int _param(int i) => i < paramFifo.length ? paramFifo.elementAt(i) : 0;

  /// starts reading/playing from SetLoc position, or continues from the
  /// current position if SetLoc is not issued after the last read
  void _startFromSeekPosition() {
    sectorReadDelay = 33868800 ~/ (isHighSpeed ? 150 : 75);

    // the first sector arrives after spinning up and seeking
    sectorReadDelay += _spinUp();
    if (isSeekPending) {
      final distance = (seekSector - readingSector).abs();
      if (distance >= 32) {
        // 30ms to 180ms depending on the distance
        sectorReadDelay +=
            33868800 * (30 + 150 * distance.min(300000) ~/ 300000) ~/ 1000;
        isSeeking = true;
      }
      readingSector = seekSector;
      isSeekPending = false;
    }
  }

  /// turns the spindle motor on, returns the clocks for spinning up
  int _spinUp() {
    if (isSpindleMotorOn) {
      return 0;
    }
    isSpindleMotorOn = true;
    return 33868800; // about 1 second
  }

  void _stop() {
    isReading = false;
    isPlaying = false;
  }

  void execCommand(int cmd) {
    resultFifo.clear();
    if (psTrace) {
      _log.debugc(
          () =>
              "${cmd.x2}:${commandNames[cmd.mask5]}(${paramFifo.map((e) => "0x${e.x2}").join(",")}) ${dump()}",
          id: 'command');
    }

    switch (cmd) {
      case 0x01: // GetStat
        irq(3, [status()]);

      case 0x02: // SetLoc
        seekSector = Msf.ofBcd(_param(0), _param(1), _param(2)).frames();
        isSeekPending = true;
        irq(3, [status()], delay: 5000);

      case 0x03: // Play
        final track = _param(0).asBcd;
        if (track > 0 && !_isDiscEmpty && track <= _trackCount) {
          seekSector = _trackStart(track);
          isSeekPending = true;
        }
        isReading = false;
        _startFromSeekPosition();
        isPlaying = true;
        playTrack = 0;
        irq(3, [status()]);

      case 0x04: // Forward
        // todo
        irq(3, [status()]);

      case 0x05: // Backward
        // todo
        irq(3, [status()]);

      case 0x06: // ReadN
        isPlaying = false;
        _startFromSeekPosition();
        isReading = true;
        irq(3, [status()], delay: 1000);

      case 0x07: // Standby
        _stop();
        _spinUp();
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x08: // Stop
        _stop();
        irq(3, [status()]);
        isSpindleMotorOn = false;
        irq(2, [status()]);

      case 0x09: // Pause
        irq(3, [status()]);
        _stop();
        irq(2, [status()]);

      case 0x0a: // Init
        isMuted = false;
        _stop();
        _spinUp();
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
        file = _param(0);
        channel = _param(1);
        irq(3, [status()]);

      case 0x0e: // SetMode
        mode = _param(0);
        irq(3, [status()]);

      case 0x0f: // GetParam
        irq(3, [status(), mode, 0x00, file, channel]);

      case 0x10: // GetLocl
        irq(3, rawSector.sublist(12, 20));

      case 0x11: // GetLocp
        final currentSector = isReading || isPlaying
            ? readingSector
            : isSeekPending
                ? seekSector
                : readingSector;
        final trackNo = _trackOf(currentSector);
        final relative =
            trackNo == 0 ? 0 : currentSector - _trackStart(trackNo);
        final (rm, rs, rf) = Msf.ofFrames(relative.abs()).bcd();
        final (am, as_, af) = Msf.ofFrames(currentSector).bcd();
        irq(3, [
          trackNo.toBcd,
          relative < 0 ? 0 : 1, // index 0 for pregap
          rm,
          rs,
          rf,
          am,
          as_,
          af,
        ]);

      case 0x13: // GetTN
        if (_isDiscEmpty) {
          irq(3, [status(), 0, 0]);
        } else {
          irq(3, [status(), 1.toBcd, _trackCount.toBcd]);
        }

      case 0x14: // GetTD
        final track = _param(0).asBcd;
        if (_isDiscEmpty || track > _trackCount) {
          irq(5, [status() | 0x01, 0x10]); // error: invalid parameter
        } else {
          final sector =
              track == 0 ? _totalSectors + 2 * 75 : _trackStart(track);
          final (mm, ss, _) = Msf.ofFrames(sector).bcd();
          irq(3, [status(), mm, ss]);
        }

      case 0x15: // SeekL
        _seek();

      case 0x16: // SeekP
        _seek();

      case 0x1a: // GetId
        irq(3, [status()]);
        irq(2, [0x02, 0x00, 0x20, 0x00, 0x53, 0x43, 0x45, 0x41],
            delay: 50000); // Liscensed, SCEA

      case 0x1b: // ReadS (no retry)
        isPlaying = false;
        _startFromSeekPosition();
        isReading = true;
        irq(3, [status()], delay: 1000);

      case 0x1c: // Reset
        _stop();
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x1e: // ReadTOC
        toc.firstTrackBcd = _isDiscEmpty ? 0 : 1.toBcd;
        toc.lastTrackBcd = _isDiscEmpty ? 0 : _trackCount.toBcd;
        irq(3, [status()]);
        irq(2, [status()]);

      case 0x19: // test
        if (paramFifo.isEmpty) {
          _log.debug("test no params");
        } else {
          switch (_param(0)) {
            case 0x04:
              irq(3, [status()]);
            case 0x05:
              // SCEx counters (total, ...): while playing audio the drive reads
              // no SCEx strings. games use it as a mod chip check, which
              // fails when the second counter is not 0
              irq(3, [0x00, 0x00]);
            case 0x20:
              irq(3, [0x94, 0x09, 0x19, 0xc0]);
            case 0x21:
              irq(3, [0x00]);
            case 0x22:
              irq(3, Uint8List.fromList("for U/C".codeUnits));
            default:
              _log.warnc(() =>
                  "unknown test command ${paramFifo.map((e) => e.x2).join(" ")}");
          }
        }
      default:
        _log.warnc(() =>
            "unknown command ${cmd.x2} params:${paramFifo.map((e) => e.x2).join(" ")}");
    }

    paramFifo.clear();
    isCmdBusy = true;
    cmdDelay = 1000;
  }

  static const _seekClocks = 500000;

  void _seek() {
    _stop();
    _spinUp();
    readingSector = seekSector;
    isSeekPending = false;
    irq(3, [status()], delay: 5000);

    // INT2 is raised when the drive completes the seek
    isSeeking = true;
    _port.seek(seekSector, _clock);
  }

  /// called when the seek is completed by the drive
  void _onSeekComplete(bool ok, int issuedAt) {
    isSeeking = false;
    final delay = (_seekClocks - (_clock - issuedAt)).clamp(0, _seekClocks);
    if (ok) {
      irq(2, [status()], delay: delay);
    } else {
      isSeekError = true;
      irq(5, [status() | 0x01, 0x04], delay: delay); // seek failed
      isSeekError = false;
    }
  }

  /// called when the tray is opened or closed, with or without a disc
  void _onTray({required bool open, required bool hasDisc}) {
    if (open || !hasDisc) {
      _stop();
      isSeeking = false;
    }
    if (open) {
      openShell();
    } else if (hasDisc) {
      closeShell();
    } else {
      isSpindleMotorOn = false; // closed without a disc
      isShellOpen = false;
    }
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

  String dump() => "status:${status().x2} bank:$bank "
      "cmd:[${paramFifo.map((e) => e.x2).join(" ")}] "
      "result:[${resultFifo.map((e) => e.x2).join(" ")}] "
      "pend:${cmdResults.map((r) => "[${r.intNo} ${r.delay} [${r.fifo.map((e) => e.x2).join(" ")}]]").join(" ")} "
      "${isXaAdpcmBusy ? "Adpcm" : "DRQ"} ${sectorBufferEmpty ? "empty" : "ready"} ${isHighSpeed ? "x2" : "x1"} ${isSectorSize924 ? "924" : "800"} "
      "mask:${intMask.x2} mode:${mode.x2} seek:$seekSector (${Msf.ofFrames(seekSector).format()}) read:$readingSector (${Msf.ofFrames(readingSector).format()})";

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
