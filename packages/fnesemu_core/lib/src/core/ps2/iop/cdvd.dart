import 'dart:collection';
import 'dart:typed_data';

import '../../../cdrom_drive.dart';

/// The CDVD drive controller registers as seen by the IOP (0x1f402000..).
///
/// N commands run asynchronously and signal completion through I_STAT and
/// the CDVD interrupt. S commands answer through a result FIFO. Register
/// layouts follow public hardware documentation. Timing is coarse, and the
/// BIOS handshake that precedes a disc boot is not fully known. The format of
/// a sector delivered by ReadCd for block sizes other than 2048 is a guess.
class Cdvd {
  static const base = 0x1f402000, end = 0x1f402040;

  static const _nCommand = 0x1f402004, _nStatus = 0x1f402005;
  static const _error = 0x1f402006, _break = 0x1f402007;
  static const _istat = 0x1f402008;
  static const _driveStatus = 0x1f40200a, _stickyStatus = 0x1f40200b;
  static const _discType = 0x1f40200f;
  static const _sCommand = 0x1f402016, _sStatus = 0x1f402017;
  static const _sResult = 0x1f402018;
  static const _key = 0x1f402020, _keyFlags = 0x1f402038, _keyXor = 0x1f402039;

  static const noDisc = 0x00;
  static const ps2Cd = 0x12, ps2Dvd = 0x14;

  /// the idle value 0x4e is what the BIOS driver waits for at start; bit 3
  /// is not described by the documentation I found
  static const _ready = 0x4e, _busy = 0xce;
  static const _sResultEmpty = 0x40;

  static const _statusSpinning = 0x02,
      _statusReading = 0x04,
      _statusPaused = 0x08,
      _statusSeeking = 0x10;

  static const _dvdBlockSize = 2064;

  static const _seekCycles = 200000, _sectorCycles = 20000;

  /// called when the CDVD interrupt is raised
  void Function()? onInterrupt;

  /// the inserted disc, or null
  CdromDrive? drive;

  int istat = 0;

  /// the game ID of the inserted disc, such as `ABCD_123.45`, taken from the
  /// BOOT2 line of SYSTEM.CNF. ReadKey encodes it into the disc key.
  String? discId;

  /// true if the inserted disc is a DVD
  bool dvd = false;

  /// the disc key bytes 0-14 and the flags of the valid key groups
  final _keyBytes = Uint8List(15);
  int _keyValid = 0;

  final _nParams = <int>[];
  final _sParams = <int>[];
  final _results = ListQueue<int>();
  int _lastCommand = 0;
  int _tick = 0;

  int _drive = 0, _sticky = 0;
  int _error6 = 0;

  // the N command in progress
  int _busyCycles = 0;
  bool _reading = false;
  int _lba = 0, _sectorsLeft = 0, _blockSize = 2048;
  int _wait = 0;

  // sector data waiting for the DMA channel
  Uint8List _data = Uint8List(0);
  int _dataPos = 0;

  static bool handles(int address) => address >= base && address < end;

  /// true if the drive has a disc to read
  bool get hasDisc => drive?.status.isReady ?? false;

  /// the disc type byte; 0 reports an empty tray. A disc handed to this core
  /// is a PS2 CD or a PS2 DVD.
  int get discType => hasDisc ? (dvd ? ps2Dvd : ps2Cd) : noDisc;

  /// true while sector bytes are waiting for the DMA channel
  bool get dataAvailable => _dataPos < _data.length;

  void reset() {
    _results.clear();
    _nParams.clear();
    _sParams.clear();
    _lastCommand = 0;
    istat = _busyCycles = _wait = 0;
    _reading = false;
    _data = Uint8List(0);
    _dataPos = 0;
    _drive = _sticky = 0;
  }

  int read(int address) {
    switch (address) {
      case _nStatus:
        return _busyCycles > 0 || _reading ? _busy : _ready;
      case _error:
        return _error6;
      case _istat:
        return istat;
      case _driveStatus:
        return _driveStatusValue;
      case _stickyStatus:
        return _sticky;
      case _discType:
        return discType;
      case _sStatus:
        return _results.isEmpty ? _sResultEmpty : 0;
      case _sResult:
        return _results.isEmpty ? 0 : _results.removeFirst();
      case _sCommand:
        return _lastCommand;
      case _keyFlags:
        return _keyValid;
      case _keyXor:
        return 0;
    }
    if (address >= _key && address < _keyFlags) {
      final o = address - _key;
      // three groups of five bytes at 0x20, 0x28 and 0x30
      if ((o & 7) < 5) return _keyBytes[(o >> 3) * 5 + (o & 7)];
    }
    return 0;
  }

  int get _driveStatusValue {
    if (!hasDisc) return _drive;
    if (_busyCycles > 0) return _statusSpinning | _statusSeeking;
    if (_reading) return _statusSpinning | _statusReading;
    return _statusSpinning | _statusPaused;
  }

  void write(int address, int value) {
    value &= 0xff;
    switch (address) {
      case 0x1f402005:
        _nParams.add(value);
      case _nCommand:
        _nCommandWrite(value);
      case _break:
        _reading = false;
        _busyCycles = 0;
      case _istat:
        istat &= ~value;
      case _sStatus: // S command parameter
        _sParams.add(value);
      case _sCommand:
        _sCommandWrite(value);
    }
  }

  static int _int32(List<int> bytes, int offset) {
    var v = 0;
    for (var i = 3; i >= 0; i--) {
      v = v << 8 | (offset + i < bytes.length ? bytes[offset + i] : 0);
    }
    return v;
  }

  void _nCommandWrite(int command) {
    final params = List<int>.of(_nParams);
    _nParams.clear();
    _reading = false;
    _error6 = 0;
    switch (command) {
      case 0x06: // ReadCd: sector, count, block size selector at byte 10
        if (!hasDisc) {
          _error6 = 1;
          _complete();
          return;
        }
        _lba = _int32(params, 0);
        _sectorsLeft = _int32(params, 4);
        final selector = params.length > 10 ? params[10] : 0;
        _blockSize = switch (selector) { 1 => 2328, 2 => 2340, _ => 2048 };
        _startRead();
      case 0x08: // ReadDvd: sector, count; blocks of 2064 bytes
        if (!hasDisc) {
          _error6 = 1;
          _complete();
          return;
        }
        _lba = _int32(params, 0);
        _sectorsLeft = _int32(params, 4);
        _blockSize = _dvdBlockSize;
        _startRead();
      case 0x05: // Seek
        _lba = _int32(params, 0);
        _busyCycles = _seekCycles;
      case 0x0c: // ReadKey
        _readKey();
        _busyCycles = _seekCycles;
      default: // NOP, NOPsync, Standby, Stop, Pause and the unknown ones
        _busyCycles = 1000;
    }
  }

  void _startRead() {
    _data = Uint8List(0);
    _dataPos = 0;
    _busyCycles = _seekCycles;
    _reading = true;
    _wait = 0;
  }

  /// Fills the disc key from [discId].
  ///
  /// The real drive reads the key from the disc. Its encoding is not
  /// documented, so this produces the bytes that the BIOS browser decodes
  /// back into the game ID: four 7-bit letters packed from bit 7 of byte 0
  /// to bit 2 of byte 4, and a 17-bit number made of byte 4 bits 3-7 (bits
  /// 0-4), byte 14 bits 3-7 (bits 5-9) and byte 0 bits 0-6 (bits 10-16). The
  /// browser compares the ID with the BOOT2 file name before it starts the
  /// game.
  void _readKey() {
    _keyBytes.fillRange(0, _keyBytes.length, 0);
    _keyValid = 0;
    final id = discId;
    if (id == null) return;
    final match = RegExp(r'^([A-Z]{4})_(\d{3})\.(\d{2})').firstMatch(id);
    if (match == null) return;
    final c = match[1]!.codeUnits;
    final n = int.parse('${match[2]}${match[3]}');
    _keyBytes
      ..[0] = (n >> 10) & 0x7f | (c[3] & 1) << 7
      ..[1] = (c[3] >> 1) & 0x3f | (c[2] & 3) << 6
      ..[2] = (c[2] >> 2) & 0x1f | (c[1] & 7) << 5
      ..[3] = (c[1] >> 3) & 0x0f | (c[0] & 0xf) << 4
      ..[4] = (c[0] >> 4) & 0x07 | (n & 0x1f) << 3
      ..[14] = ((n >> 5) & 0x1f) << 3;
    _keyValid = 7;
  }

  void _complete() {
    istat |= 2;
    onInterrupt?.call();
  }

  /// advances the drive by [cycles] IOP clocks
  void advance(int cycles) {
    if (_busyCycles > 0) {
      _busyCycles -= cycles;
      if (_busyCycles > 0) return;
      _busyCycles = 0;
      if (!_reading) _complete();
      return;
    }
    if (!_reading) return;
    if (dataAvailable) return;
    if (_sectorsLeft == 0) {
      _reading = false;
      istat |= 1;
      _complete();
      return;
    }
    _wait += cycles;
    if (_wait < _sectorCycles) return;
    final raw = drive?.read(_lba);
    if (raw == null) return; // not read by the drive yet
    _wait = 0;
    if (raw.length < 2352) {
      _reading = false;
      _error6 = 1;
      _complete();
      return;
    }
    _data = _userBytes(raw);
    _dataPos = 0;
    _lba++;
    _sectorsLeft--;
  }

  Uint8List _userBytes(Uint8List raw) {
    if (_blockSize == _dvdBlockSize) return _dvdBlock(raw);
    final start = switch (_blockSize) {
      2328 => 24,
      2340 => 12,
      _ => raw[15] == 2 ? 24 : 16,
    };
    return Uint8List.sublistView(raw, start, start + _blockSize);
  }

  /// a ReadDvd block: the layer number plus 0x20, the sector number plus
  /// 0x30000 (big endian), 8 bytes of zero, the user data and 4 bytes of
  /// zero. The zero fields hold the error detection and copy protection
  /// bytes of a real DVD sector; their values are not documented.
  Uint8List _dvdBlock(Uint8List raw) {
    final sector = _lba + 0x30000;
    final offset = raw[15] == 2 ? 24 : 16;
    return Uint8List(_dvdBlockSize)
      ..[0] = 0x20
      ..[1] = sector >> 16
      ..[2] = sector >> 8
      ..[3] = sector
      ..setRange(12, 12 + 2048, raw, offset);
  }

  /// takes up to [count] bytes of sector data
  Uint8List takeData(int count) {
    final n = count < _data.length - _dataPos ? count : _data.length - _dataPos;
    final out = Uint8List.sublistView(_data, _dataPos, _dataPos + n);
    _dataPos += n;
    return out;
  }

  void _sCommandWrite(int command) {
    _lastCommand = command;
    final params = List<int>.of(_sParams);
    _sParams.clear();
    _results
      ..clear()
      ..add(0); // every S command answers with a zero status byte
    switch (command) {
      case 0x03: // prefix; subcommand 0 is the mechacon version
        if (params.isNotEmpty && params[0] == 0) {
          _results
            ..clear()
            ..addAll([0x03, 0x06, 0x02, 0x00]);
        }
      case 0x05: // update the sticky drive status
        _sticky = _driveStatusValue;
      case 0x84: // card authentication: the mechacon's challenges
      case 0x85:
        _results.addAll(List.filled(12, 0));
      case 0x41: // read configuration block: 15 more bytes
        _results.addAll(List.filled(15, 0));
      case 0x08: // read clock: second, minute, hour, pad, day, month, year
        final second = (_tick++ ~/ 3) % 60;
        _results.addAll([
          second ~/ 10 << 4 | second % 10,
          0x00,
          0x12,
          0x00,
          0x01,
          0x01,
          0x24
        ]);
    }
  }
}
