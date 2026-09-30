import 'dart:typed_data';

import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

import '../disc.dart';
import 'package:fnesemu/disc/empty.dart';

class _Block {
  final Uint8List raw;
  final int fad;
  final int fn, cn, sm, ci;

  // mode 1 sectors have no subheader: treated as all zero
  _Block(this.raw, this.fad)
      : fn = raw[15] == 2 ? raw[16] : 0,
        cn = raw[15] == 2 ? raw[17] : 0,
        sm = raw[15] == 2 ? raw[18] : 0,
        ci = raw[15] == 2 ? raw[19] : 0;

  bool get isMode2 => raw[15] == 2;
}

class _Filter {
  int fad = 0, range = 0;
  int mode = 0;
  int fn = 0, cn = 0;
  int smMask = 0, smVal = 0, ciMask = 0, ciVal = 0;
  int trueConn = 0;
  int falseConn = 0xff;

  _Filter(int no) {
    init(no);
  }

  void init(int no) {
    fad = 0;
    range = 0;
    mode = 0;
    fn = cn = smMask = smVal = ciMask = ciVal = 0;
    trueConn = no;
    falseConn = 0xff;
  }

  bool pass(_Block b) {
    if (mode.bit6 && !(fad <= b.fad && b.fad < fad + range)) {
      return false;
    }

    bool ok = true;
    if (mode.bit0) ok = ok && b.fn == fn;
    if (mode.bit1) ok = ok && b.cn == cn;
    if (mode.bit2) ok = ok && (b.sm & smMask) == smVal;
    if (mode.bit3) ok = ok && (b.ci & ciMask) == ciVal;
    if (mode.bit4 && mode & 0x0f != 0) ok = !ok;
    return ok;
  }
}

class _FileEntry {
  final int fad;
  final int size;
  final int unitSize;
  final int gapSize;
  final int fileNo;
  final int attr;
  final String name;

  const _FileEntry(this.fad, this.size, this.unitSize, this.gapSize,
      this.fileNo, this.attr, this.name);

  bool get isDir => attr.bit1;
}

/// CD block (high level emulation of the SH-1 firmware)
class CdBlock {
  Disc disc = EmptyDisc();

  void Function() onInterrupt = () {};

  /// debug: logs commands and responses
  bool log = false;

  // HIRQ bits
  static const _cmok = 0x0001;
  static const _drdy = 0x0002;
  static const _csct = 0x0004;
  static const _bful = 0x0008;
  static const _pend = 0x0010;
  static const _dchg = 0x0020;
  static const _esel = 0x0040;
  static const _ehst = 0x0080;
  static const _ecpy = 0x0100;
  static const _efls = 0x0200;
  static const _scdq = 0x0400;

  // status codes
  static const _stPause = 0x01;
  static const _stStandby = 0x02;
  static const _stPlay = 0x03;
  static const _stOpen = 0x06;
  static const _stNoDisc = 0x07;
  static const _stPeriodic = 0x20;
  static const _stReject = 0xff;

  int hirq = 0;
  int hirqMask = 0;
  final cr = [0, 0, 0, 0];
  final _cmd = [0, 0, 0, 0];

  int _status = _stNoDisc;
  bool _started = false;
  bool _responseRead = true;

  static const _maxBlocks = 200;
  final _partitions = List.generate(24, (_) => <_Block>[]);
  final _filters = List.generate(24, (i) => _Filter(i));
  int _cdConn = 0xff;
  int _lastDest = 0xff;

  int _getLength = 2048;

  // play state
  int _fad = 150;
  int _playStart = 0;
  int _playEnd = 0;
  bool _playing = false;
  bool _readingFile = false;
  int _repeat = 0;
  int _sectorWait = 0;
  bool _standardSpeed = false;

  static const _clockHz = 28636360;
  static const _periodicClocks = _clockHz ~/ 60;
  int _periodicWait = _periodicClocks;

  // data transfer
  Uint8List _xfer = Uint8List(0);
  int _xferPos = 0;
  bool _xferActive = false;
  int _lastXferWords = 0xffffff;

  int _actualSize = 0;

  // file system
  final _dirEntries = <_FileEntry>[];
  int _rootFad = 0;
  int _rootSize = 0;

  // CD-DA output: interleaved 16-bit stereo samples at 44.1kHz
  final cdda = Int16List(588 * 2 * 16);
  int cddaWrite = 0;
  int cddaRead = 0;

  void reset() {
    hirq = _cmok | _dchg | _esel | _ehst | _ecpy | _efls;
    hirqMask = 0;
    // "CDBLOCK" signature
    cr[0] = 0x0043;
    cr[1] = 0x4442;
    cr[2] = 0x4c4f;
    cr[3] = 0x434b;
    _started = false;
    _responseRead = true;
    _status = disc.isEmpty ? _stNoDisc : _stPause;
    _fad = 150;
    _playing = false;
    _readingFile = false;
    _xferActive = false;
    _cdConn = 0xff;
    _lastDest = 0xff;
    _getLength = 2048;
    for (int i = 0; i < 24; i++) {
      _partitions[i].clear();
      _filters[i].init(i);
    }
    cddaRead = cddaWrite = 0;
    _loadRootDir();
  }

  void setDisc(Disc d) {
    disc = d;
    reset();
  }

  // ---- register access ----

  int read16(int addr) {
    if (addr >= 0x18000 && addr < 0x20000 || addr >= 0x98000) {
      return _readData();
    }

    return switch (addr & 0x3f) {
      0x08 => hirq,
      0x0c => hirqMask,
      0x18 => cr[0],
      0x1c => cr[1],
      0x20 => cr[2],
      0x24 => _readCr4(),
      _ => 0,
    };
  }

  int _readCr4() {
    _responseRead = true;
    return cr[3];
  }

  void write16(int addr, int data) {
    if (addr >= 0x18000 && addr < 0x20000 || addr >= 0x98000) {
      return; // put sector data: not supported
    }

    switch (addr & 0x3f) {
      case 0x08:
        hirq &= data;
        break;
      case 0x0c:
        hirqMask = data;
        break;
      case 0x18:
        _cmd[0] = data;
        break;
      case 0x1c:
        _cmd[1] = data;
        break;
      case 0x20:
        _cmd[2] = data;
        break;
      case 0x24:
        _cmd[3] = data;
        _started = true;
        _execCommand();
        break;
    }
  }

  int _readData() {
    if (!_xferActive || _xferPos + 1 >= _xfer.length) {
      if (_xferActive && _xferPos < _xfer.length) {
        return _xfer[_xferPos++] << 8;
      }
      return 0;
    }
    final d = _xfer[_xferPos] << 8 | _xfer[_xferPos + 1];
    _xferPos += 2;
    return d;
  }

  void _setIrq(int bits) {
    hirq |= bits;
    if (hirq & hirqMask != 0) {
      onInterrupt();
    }
  }

  // ---- status ----

  int get _track {
    if (disc.isEmpty) return 0;
    int t = 1;
    for (int i = 1; i <= disc.trackCount; i++) {
      if (_fad >= disc.startLba(i) + 150) t = i;
    }
    return t;
  }

  int _ctrlAdr(int track) =>
      track == 0 ? 0xff : (disc.isAudio(track) ? 0x01 : 0x41);

  void _report({int flags = 0}) {
    if (disc.isEmpty) {
      cr[0] = (_status | flags) << 8;
      cr[1] = 0xffff;
      cr[2] = 0xffff;
      cr[3] = 0xffff;
      return;
    }
    final t = _track;
    cr[0] = (_status | flags) << 8 | (_repeat & 0xf);
    cr[1] = _ctrlAdr(t) << 8 | t;
    cr[2] = 0x01 << 8 | (_fad >> 16) & 0xff;
    cr[3] = _fad & 0xffff;
  }

  void _respond(int c0, int c1, int c2, int c3) {
    cr[0] = c0;
    cr[1] = c1;
    cr[2] = c2;
    cr[3] = c3;
  }

  // ---- periodic processing ----

  void exec(int clocks) {
    if (_playing) {
      _sectorWait -= clocks;
      while (_sectorWait <= 0 && _playing) {
        _sectorWait += _clockHz ~/ (_standardSpeed || _isAudioFad(_fad) ? 75 : 150);
        _readSector();
      }
    }

    _periodicWait -= clocks;
    if (_periodicWait <= 0) {
      _periodicWait += _periodicClocks;
      if (_started && _responseRead && hirq & _cmok != 0) {
        _report(flags: _stPeriodic);
        _setIrq(_scdq);
      }
    }
  }

  bool _isAudioFad(int fad) => disc.isAudioSector(fad);

  int get _usedBlocks => _partitions.fold(0, (s, p) => s + p.length);

  void _readSector() {
    if (_fad >= _playEnd) {
      _playing = false;
      _status = _stPause;
      _setIrq(_pend | (_readingFile ? _efls : 0));
      _readingFile = false;
      return;
    }

    if (_isAudioFad(_fad)) {
      final raw = disc.read(_fad);
      _pushCdda(raw);
      _fad++;
      return;
    }

    if (_cdConn == 0xff) {
      _fad++;
      return;
    }

    if (_usedBlocks >= _maxBlocks) {
      _setIrq(_bful);
      return; // wait until buffer becomes free
    }

    final raw = disc.read(_fad);
    if (raw.length < Disc.sectorSize) {
      _fad++;
      return;
    }

    final block = _Block(raw, _fad);
    _fad++;

    int f = _cdConn;
    for (int i = 0; i < 24 && f != 0xff; i++) {
      final filter = _filters[f];
      if (filter.pass(block)) {
        if (filter.trueConn != 0xff) {
          _partitions[filter.trueConn].add(block);
          _lastDest = filter.trueConn;
          _setIrq(_csct);
          if (_usedBlocks >= _maxBlocks) {
            _setIrq(_bful);
          }
        }
        return;
      }
      f = filter.falseConn;
    }
  }

  void _pushCdda(Uint8List raw) {
    if (raw.length < Disc.sectorSize) return;
    final data = ByteData.sublistView(raw);
    for (int i = 0; i < 588 * 2; i++) {
      final next = (cddaWrite + 1) % cdda.length;
      if (next == cddaRead) return; // overflow
      cdda[cddaWrite] = data.getInt16(i * 2, Endian.little);
      cddaWrite = next;
    }
  }

  // ---- commands ----

  void _execCommand() {
    final c = _cmd;
    final op = c[0] >> 8;
    _responseRead = false;

    switch (op) {
      case 0x00: // get status
        _report();
        break;
      case 0x01: // get hardware info
        _respond(_status << 8, 0x0201, 0x0000, 0x0400);
        break;
      case 0x02: // get TOC
        _startTransfer(_toc());
        _respond(_status << 8, 0xcc, 0, 0);
        _setIrq(_drdy);
        break;
      case 0x03: // get session info
        final leadout = disc.isEmpty ? 0 : disc.totalSectors + 150;
        if (c[0] & 0xff == 0) {
          _respond(_status << 8, 0, 0x0100 | (leadout >> 16) & 0xff,
              leadout & 0xffff);
        } else {
          _respond(_status << 8, 0, 0x0100, 0x0000);
        }
        break;
      case 0x04: // initialize CD system
        _standardSpeed = c[0].bit4;
        if (c[0].bit0) {
          _resetSelectors();
        }
        _playing = false;
        _status = disc.isEmpty ? _stNoDisc : _stPause;
        _fad = 150;
        _report();
        _setIrq(_esel | _ehst | _ecpy | _efls);
        break;
      case 0x05: // open tray
        _status = _stOpen;
        _report();
        break;
      case 0x06: // end data transfer
        final words = _xferActive ? _xferPos >> 1 : _lastXferWords;
        _xferActive = false;
        _lastXferWords = 0xffffff;
        _respond(_status << 8 | (words >> 16) & 0xff, words & 0xffff, 0, 0);
        _setIrq(_ehst);
        break;
      case 0x10: // play disc
        _play(c);
        break;
      case 0x11: // seek
        _seek(c);
        break;
      case 0x20: // get subcode
        _subcode(c);
        break;
      case 0x30: // set CD device connection
        _cdConn = c[2] >> 8;
        _report();
        _setIrq(_esel);
        break;
      case 0x31: // get CD device connection
        _respond(_status << 8, 0, _cdConn << 8, 0);
        break;
      case 0x32: // get last buffer destination
        _respond(_status << 8, 0, _lastDest << 8, 0);
        break;
      case 0x40: // set filter range
        final f = _filters[(c[2] >> 8) % 24];
        f.fad = (c[0] & 0xff) << 16 | c[1];
        f.range = (c[2] & 0xff) << 16 | c[3];
        _report();
        _setIrq(_esel);
        break;
      case 0x41: // get filter range
        final f = _filters[(c[2] >> 8) % 24];
        _respond(_status << 8 | (f.fad >> 16) & 0xff, f.fad & 0xffff,
            (c[2] & 0xff00) | (f.range >> 16) & 0xff, f.range & 0xffff);
        break;
      case 0x42: // set filter subheader conditions
        final f = _filters[(c[2] >> 8) % 24];
        f.cn = c[0] & 0xff;
        f.smMask = c[1] >> 8;
        f.ciMask = c[1] & 0xff;
        f.fn = c[2] & 0xff;
        f.smVal = c[3] >> 8;
        f.ciVal = c[3] & 0xff;
        _report();
        _setIrq(_esel);
        break;
      case 0x43: // get filter subheader conditions
        final f = _filters[(c[2] >> 8) % 24];
        _respond(_status << 8 | f.cn, f.smMask << 8 | f.ciMask,
            (c[2] & 0xff00) | f.fn, f.smVal << 8 | f.ciVal);
        break;
      case 0x44: // set filter mode
        final f = _filters[(c[2] >> 8) % 24];
        final mode = c[0] & 0xff;
        if (mode.bit7) {
          f.init((c[2] >> 8) % 24);
        } else {
          f.mode = mode;
        }
        _report();
        _setIrq(_esel);
        break;
      case 0x45: // get filter mode
        final f = _filters[(c[2] >> 8) % 24];
        _respond(_status << 8 | f.mode, 0, c[2] & 0xff00, 0);
        break;
      case 0x46: // set filter connection
        final f = _filters[(c[2] >> 8) % 24];
        if (c[0].bit0) f.trueConn = c[1] >> 8;
        if (c[0].bit1) f.falseConn = c[1] & 0xff;
        _report();
        _setIrq(_esel);
        break;
      case 0x47: // get filter connection
        final f = _filters[(c[2] >> 8) % 24];
        _respond(_status << 8, f.trueConn << 8 | f.falseConn, 0, 0);
        break;
      case 0x48: // reset selector
        _resetSelector(c[0] & 0xff, c[2] >> 8);
        _report();
        _setIrq(_esel);
        break;
      case 0x50: // get buffer size
        _respond(_status << 8, _maxBlocks - _usedBlocks, 0x1800, _maxBlocks);
        break;
      case 0x51: // get sector number
        final p = _partitions[(c[2] >> 8) % 24];
        _respond(_status << 8, 0, 0, p.length);
        break;
      case 0x52: // calculate actual size
        final blocks = _selectBlocks(c[1], c[2] >> 8, c[3]);
        _actualSize = blocks.length * _getLength ~/ 2;
        _report();
        _setIrq(_esel);
        break;
      case 0x53: // get actual size
        _respond(_status << 8 | (_actualSize >> 16) & 0xff,
            _actualSize & 0xffff, 0, 0);
        break;
      case 0x54: // get sector info
        final p = _partitions[(c[2] >> 8) % 24];
        final i = c[1] & 0xff;
        if (i < p.length) {
          final b = p[i];
          _respond(_status << 8 | (b.fad >> 16) & 0xff, b.fad & 0xffff,
              b.fn << 8 | b.cn, b.sm << 8 | b.ci);
        } else {
          _respond(_stReject << 8, 0, 0, 0);
        }
        break;
      case 0x60: // set sector length
        const lengths = [2048, 2336, 2340, 2352];
        if (c[0] & 0xff != 0xff) _getLength = lengths[c[0] & 3];
        _report();
        _setIrq(_esel);
        break;
      case 0x61: // get sector data
      case 0x62: // delete sector data
      case 0x63: // get then delete sector data
        _getDeleteSectors(op, c);
        break;
      case 0x67: // get copy error
        _respond(_status << 8, 0, 0, 0);
        break;
      case 0x70: // change directory
      case 0x71: // read directory
        _changeDir(c);
        break;
      case 0x72: // get file system scope
        _respond(_status << 8, _dirEntries.length - 2, 0x0100, 0x0002);
        break;
      case 0x73: // get file info
        _fileInfo(c);
        break;
      case 0x74: // read file
        _readFile(c);
        break;
      case 0x75: // abort file
        _playing = false;
        _readingFile = false;
        _status = _stPause;
        _report();
        _setIrq(_efls);
        break;
      case 0xe0: // authenticate device
        _report();
        _setIrq(_efls | _csct);
        break;
      case 0xe1: // is device authenticated
        _respond(_status << 8, disc.isEmpty ? 0 : 4, 0, 0);
        break;
      case 0xe2: // get MPEG ROM
        _report();
        _setIrq(0x800 /* MPED */);
        break;
      default:
        debugLog("cdblock: unsupported command ${op.x2}");
        _report();
    }

    _setIrq(_cmok);

    if (log) {
      debugLog("cdblock: cmd ${c.map((e) => e.x4).join(" ")} -> "
          "${cr.map((e) => e.x4).join(" ")} hirq:${hirq.x4}");
    }
  }

  // ---- selectors ----

  void _resetSelectors() {
    for (int i = 0; i < 24; i++) {
      _partitions[i].clear();
      _filters[i].init(i);
    }
    _cdConn = 0xff;
    _lastDest = 0xff;
  }

  void _resetSelector(int flags, int pn) {
    if (flags == 0) {
      if (pn < 24) _partitions[pn].clear();
      return;
    }
    for (int i = 0; i < 24; i++) {
      final f = _filters[i];
      if (flags.bit2) _partitions[i].clear();
      if (flags.bit3) f.trueConn = i;
      if (flags.bit4) {
        f.fad = f.range = f.mode = 0;
        f.fn = f.cn = f.smMask = f.smVal = f.ciMask = f.ciVal = 0;
      }
      if (flags.bit6) f.trueConn = i;
      if (flags.bit7) f.falseConn = 0xff;
    }
    if (flags.bit5) _cdConn = 0xff;
  }

  List<_Block> _selectBlocks(int offset, int pn, int count) {
    final p = _partitions[pn % 24];
    if (p.isEmpty) return [];
    if (offset == 0xffff) offset = p.length - 1;
    if (count == 0xffff) count = p.length - offset;
    final end = offset + count > p.length ? p.length : offset + count;
    if (offset >= end) return [];
    return p.sublist(offset, end);
  }

  Uint8List _sectorData(_Block b, int length) {
    final start = switch (length) {
      2048 => b.isMode2 ? 24 : 16,
      2336 => 16,
      2340 => 12,
      _ => 0,
    };
    return Uint8List.sublistView(b.raw, start, start + length);
  }

  void _getDeleteSectors(int op, List<int> c) {
    final pn = (c[2] >> 8) % 24;
    final offset = c[1];
    final count = c[3];
    final blocks = _selectBlocks(offset, pn, count);

    if (blocks.isEmpty && op != 0x62) {
      _respond(_stReject << 8, 0, 0, 0);
      return;
    }

    if (op != 0x62) {
      final data = BytesBuilder(copy: false);
      for (final b in blocks) {
        data.add(_sectorData(b, _getLength));
      }
      _startTransfer(data.toBytes());
    }

    if (op != 0x61) {
      final p = _partitions[pn];
      for (final b in blocks) {
        p.remove(b);
      }
    }

    _report();
    _setIrq(op == 0x62 ? _ehst : _drdy | (op == 0x63 ? _ehst : 0));
  }

  void _startTransfer(Uint8List data) {
    _xfer = data;
    _xferPos = 0;
    _xferActive = true;
  }

  // ---- play / seek ----

  // converts a position parameter to FAD
  int _positionToFad(int pos, {bool end = false}) {
    if (pos.bit23) {
      return pos & 0x7fffff;
    }
    final track = (pos >> 8) & 0xff;
    if (track == 0 || disc.isEmpty) {
      return end ? disc.totalSectors + 150 : 150;
    }
    if (end) {
      return track >= disc.trackCount
          ? disc.totalSectors + 150
          : disc.startLba(track + 1) + 150;
    }
    return disc.startLba(track.clamp(1, disc.trackCount)) + 150;
  }

  void _play(List<int> c) {
    if (disc.isEmpty) {
      _report();
      return;
    }

    final start = (c[0] & 0xff) << 16 | c[1];
    final mode = c[2] >> 8;
    final end = (c[2] & 0xff) << 16 | c[3];

    if (start != 0xffffff) {
      _playStart = _positionToFad(start);
      _fad = _playStart;
    }

    if (end != 0xffffff) {
      if (end.bit23) {
        _playEnd = _playStart + (end & 0x7fffff);
      } else if (end == 0) {
        _playEnd = disc.totalSectors + 150;
      } else {
        _playEnd = _positionToFad(end, end: true);
      }
    }

    _repeat = mode & 0xf;
    _playing = true;
    _readingFile = false;
    _status = _stPlay;
    _sectorWait = _clockHz ~/ 150;
    _report();
  }

  void _seek(List<int> c) {
    final pos = (c[0] & 0xff) << 16 | c[1];
    _playing = false;
    if (pos == 0xffffff) {
      _status = _stPause;
    } else if (pos == 0) {
      _status = _stStandby;
      _fad = 150;
    } else {
      _fad = _positionToFad(pos);
      _status = _stPause;
    }
    _report();
  }

  void _subcode(List<int> c) {
    final type = c[0] & 0xff;
    if (type == 0) {
      final t = _track;
      final rel = disc.isEmpty ? 0 : _fad - (disc.startLba(t) + 150);
      final (rm, rs, rf) = Disc.lbaToMsf(rel < 0 ? 0 : rel);
      final (am, as_, af) = Disc.lbaToMsf(_fad);
      int bcd(int v) => (v ~/ 10) << 4 | v % 10;
      final q = Uint8List.fromList([
        _ctrlAdr(t), bcd(t), 1, bcd(rm), bcd(rs), bcd(rf), 0, //
        bcd(am), bcd(as_), bcd(af),
      ]);
      _startTransfer(q);
      _respond(_status << 8, 5, 0, 0);
    } else {
      _startTransfer(Uint8List(24));
      _respond(_status << 8, 12, 0, 0);
    }
    _setIrq(_drdy);
  }

  Uint8List _toc() {
    final toc = Uint8List(102 * 4);
    final d = ByteData.sublistView(toc);
    for (int i = 0; i < 102; i++) {
      d.setUint32(i * 4, 0xffffffff);
    }
    if (disc.isEmpty) {
      return toc;
    }

    final n = disc.trackCount;
    for (int t = 1; t <= n && t <= 99; t++) {
      d.setUint32((t - 1) * 4, _ctrlAdr(t) << 24 | disc.startLba(t) + 150);
    }
    d.setUint32(99 * 4, _ctrlAdr(1) << 24 | 1 << 16);
    d.setUint32(100 * 4, _ctrlAdr(n) << 24 | n << 16);
    d.setUint32(101 * 4, _ctrlAdr(n) << 24 | disc.totalSectors + 150);
    return toc;
  }

  // ---- file system (ISO9660) ----

  Uint8List _userData(int fad) {
    final raw = disc.read(fad);
    if (raw.length < Disc.sectorSize) return Uint8List(2048);
    final start = raw[15] == 2 ? 24 : 16;
    return Uint8List.sublistView(raw, start, start + 2048);
  }

  void _loadRootDir() {
    _dirEntries.clear();
    if (disc.isEmpty) {
      return;
    }
    try {
      final pvd = _userData(16 + 150);
      if (String.fromCharCodes(pvd.sublist(1, 6)) != "CD001") {
        return;
      }
      final root = ByteData.sublistView(pvd, 156, 156 + 34);
      _rootFad = root.getUint32(6) + 150; // big-endian copy
      _rootSize = root.getUint32(14);
      _loadDir(_rootFad, _rootSize);
    } catch (e) {
      debugLog("cdblock: failed to read file system: $e");
    }
  }

  void _loadDir(int fad, int size) {
    _dirEntries.clear();
    final sectors = (size + 2047) ~/ 2048;
    for (int s = 0; s < sectors; s++) {
      final data = _userData(fad + s);
      int i = 0;
      while (i < 2048) {
        final len = data[i];
        if (len == 0) break;
        final r = ByteData.sublistView(data, i, i + len);
        final nameLen = data[i + 32];
        final name = String.fromCharCodes(data.sublist(i + 33, i + 33 + nameLen));
        _dirEntries.add(_FileEntry(
          r.getUint32(6) + 150,
          r.getUint32(14),
          data[i + 26],
          data[i + 27],
          0,
          data[i + 25],
          name,
        ));
        i += len;
      }
    }
  }

  _FileEntry? _entry(int id) =>
      id < _dirEntries.length ? _dirEntries[id] : null;

  void _changeDir(List<int> c) {
    final id = (c[2] & 0xff) << 16 | c[3];
    if (id == 0xffffff) {
      _loadDir(_rootFad, _rootSize);
    } else {
      final e = _entry(id);
      if (e != null && e.isDir) {
        _loadDir(e.fad, e.size);
      }
    }
    _report();
    _setIrq(_efls);
  }

  void _fileInfo(List<int> c) {
    final id = (c[2] & 0xff) << 16 | c[3];
    final entries = id == 0xffffff
        ? _dirEntries.skip(2).take(254).toList()
        : [if (_entry(id) != null) _entry(id)!];

    final data = Uint8List(entries.length * 12);
    final d = ByteData.sublistView(data);
    for (int i = 0; i < entries.length; i++) {
      final e = entries[i];
      d.setUint32(i * 12, e.fad);
      d.setUint32(i * 12 + 4, e.size);
      data[i * 12 + 8] = e.unitSize;
      data[i * 12 + 9] = e.gapSize;
      data[i * 12 + 10] = e.fileNo;
      data[i * 12 + 11] = e.attr;
    }
    _startTransfer(data);
    _respond(_status << 8, entries.length * 6, 0, 0);
    _setIrq(_drdy);
  }

  void _readFile(List<int> c) {
    final fn = (c[2] >> 8) % 24;
    final id = (c[2] & 0xff) << 16 | c[3];
    final offset = (c[0] & 0xff) << 16 | c[1];
    final e = _entry(id);

    if (e == null) {
      _respond(_stReject << 8, 0, 0, 0);
      return;
    }

    final sectors = (e.size + 2047) ~/ 2048;
    final f = _filters[fn];
    f.fad = e.fad + offset;
    f.range = sectors - offset;
    f.mode = 0x40;
    _cdConn = fn;

    _playStart = e.fad + offset;
    _playEnd = e.fad + sectors;
    _fad = _playStart;
    _playing = true;
    _readingFile = true;
    _status = _stPlay;
    _sectorWait = _clockHz ~/ 150;
    _report();
  }

  String dump() =>
      "cd: st:${_status.x2} hirq:${hirq.x4} mask:${hirqMask.x4} cr:${cr.map((e) => e.x4).join(" ")} fad:$_fad play:$_playing blocks:$_usedBlocks";
}
