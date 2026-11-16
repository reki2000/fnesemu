import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core/psp/module.dart';
import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';
import 'fixture.dart';

const _io = 'IoFileMgrForUser';
const _nidOpen = 0x109f50bc;
const _nidOpenAsync = 0x89aa9906;
const _nidRead = 0x6a638d83;
const _nidWrite = 0x42ec03ac;
const _nidPollAsync = 0x3251ea56;
const _nidClose = 0x810c4bc3;
const _nidLseek = 0x27eb27b8;
const _nidLseek32 = 0x68963324;
const _nidGetstat = 0xace946e8;
const _nidDopen = 0xb29ddf9c;
const _nidDread = 0xe3eb004c;
const _nidDclose = 0xeb092469;
const _nidGetDriveStat = 0x6b4a146c;
const _nidExitGame = 0x05572a5f;

const _hello = 'Hello, disc!\n';
const _bigSize = 5000;
int _bigByte(int i) => (i * 7 + 3) & 0xff;

/// A synthetic ISO 9660 image held as user-data sectors, with a game
/// directory layout: a boot executable, a small text file and a large
/// data file spanning several sectors.
class _Iso {
  final user = <int, Uint8List>{};

  Uint8List at(int lba) => user.putIfAbsent(lba, () => Uint8List(2048));

  void data(int lba, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      at(lba + i ~/ 2048)[i % 2048] = bytes[i];
    }
  }

  /// Writes one directory record into the directory at [dirLba] and
  /// returns its length. The recording date is 2026-11-16 13:14:00.
  int record(int dirLba, int at, int lba, int size, bool dir, List<int> name) {
    final sector = this.at(dirLba);
    final view = ByteData.sublistView(sector);
    final length = 33 + name.length + (name.length.isEven ? 1 : 0);
    sector[at] = length;
    view.setUint32(at + 2, lba, Endian.little);
    view.setUint32(at + 6, lba, Endian.big);
    view.setUint32(at + 10, size, Endian.little);
    view.setUint32(at + 14, size, Endian.big);
    sector.setRange(at + 18, at + 25, [126, 11, 16, 13, 14, 0, 0]);
    sector[at + 25] = dir ? 2 : 0;
    view.setUint16(at + 28, 1, Endian.little);
    view.setUint16(at + 30, 1, Endian.big);
    sector[at + 32] = name.length;
    sector.setRange(at + 33, at + 33 + name.length, name);
    return length;
  }

  void directory(int lba, List<(int, int, bool, List<int>)> entries) {
    var at = 0;
    at += record(lba, at, lba, 2048, true, [0]);
    at += record(lba, at, lba, 2048, true, [1]);
    for (final (entryLba, size, isDir, name) in entries) {
      at += record(lba, at, entryLba, size, isDir, name);
    }
  }

  void pvd(int rootLba) {
    final sector = at(16);
    sector[0] = 1;
    sector.setRange(1, 6, 'CD001'.codeUnits);
    sector[6] = 1;
    record(16, 156, rootLba, 2048, true, [0]);
  }

  List<Uint8List> rawSectors() {
    final maxLba = user.keys.reduce((a, b) => a > b ? a : b);
    final sectors = <Uint8List>[];
    for (var lba = 0; lba <= maxLba; lba++) {
      final raw = Uint8List(2352);
      raw[15] = 1;
      final data = user[lba];
      if (data != null) raw.setRange(16, 16 + 2048, data);
      sectors.add(raw);
    }
    return sectors;
  }

  FakeCdromDrive drive() => FakeCdromDrive(rawSectors());
}

/// A drive that reports one sector as still loading for the first
/// [hold] reads of it and delivers it afterwards.
class _SlowDrive extends FakeCdromDrive {
  final int heldLba;
  int hold;

  _SlowDrive(super.sectors, this.heldLba, this.hold);

  @override
  Uint8List? read(int lba) {
    if (lba == heldLba && hold > 0) {
      hold--;
      return null;
    }
    return super.read(lba);
  }
}

_Iso _gameIso(Uint8List bootElf) {
  final iso = _Iso();
  iso.pvd(20);
  iso.directory(20, [
    (21, 2048, true, 'PSP_GAME'.codeUnits),
    (50, 10, false, 'TOP.TXT;1'.codeUnits),
  ]);
  iso.directory(21, [
    (22, 2048, true, 'SYSDIR'.codeUnits),
    (23, 2048, true, 'DATA'.codeUnits),
  ]);
  iso.directory(22, [
    (30, bootElf.length, false, 'BOOT.BIN;1'.codeUnits),
  ]);
  iso.directory(23, [
    (40, _hello.length, false, 'HELLO.TXT;1'.codeUnits),
    (41, _bigSize, false, 'BIG.BIN;1'.codeUnits),
  ]);
  iso.data(30, bootElf);
  iso.data(40, _hello.codeUnits);
  iso.data(41, [for (var i = 0; i < _bigSize; i++) _bigByte(i)]);
  iso.data(50, 'top-level\n'.codeUnits);
  return iso;
}

/// The boot program: opens the path the test wrote at 0x09100000, reads
/// the file into 0x09100100 and writes what it read to the standard
/// output, so the kernel log shows the file contents.
Uint8List _bootProgram() {
  const imports = [
    (_io, [_nidOpen, _nidRead, _nidWrite, _nidClose]),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(int nid) => stubs['$_io/$nid'] ?? 0;
    final a = Asm(0x08800000);
    a.li(Reg.a0, 0x09100000);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0x09100100);
    a.li(Reg.a2, 64);
    a.jal(stub(_nidRead));
    a.nop();
    a.addiu(Reg.s1, Reg.v0, 0);
    a.li(Reg.a0, 1);
    a.li(Reg.a1, 0x09100100);
    a.addiu(Reg.a2, Reg.s1, 0);
    a.jal(stub(_nidWrite));
    a.nop();
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_nidClose));
    a.nop();
    a.jal(stubs['LoadExecForUser/$_nidExitGame'] ?? 0);
    a.nop();
    return a.finish();
  }

  final probe = buildTestElf(code: assemble(const {}), imports: imports);
  return buildTestElf(code: assemble(probe.$2.stubOf), imports: imports).$1;
}

/// The file operations program: it runs a fixed sequence of calls and
/// stores every result in the array at 0x09100000, whose layout the
/// test asserts. Paths are written by the test at 0x09101000 and on.
Uint8List _opsProgram() {
  const imports = [
    (
      _io,
      [
        _nidOpen,
        _nidOpenAsync,
        _nidRead,
        _nidWrite,
        _nidPollAsync,
        _nidClose,
        _nidLseek,
        _nidLseek32,
        _nidGetstat,
        _nidDopen,
        _nidDread,
        _nidDclose,
      ]
    ),
    ('sceUmdUser', [_nidGetDriveStat]),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(String lib, int nid) => stubs['$lib/$nid'] ?? 0;
    final a = Asm(0x08800000);
    const r = 0x09100000; // results
    const stat = 0x09102000;
    const dirent = 0x09102100;
    const buf = 0x09102200;
    const poll = 0x09102300;
    void store(int offset) => a.sw(Reg.v0, offset, Reg.s7);
    a.li(Reg.s7, r);

    // 1. Getstat of the text file: result, size, mode, attribute, date.
    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, stat);
    a.jal(stub(_io, _nidGetstat));
    a.nop();
    store(0);
    a.li(Reg.t0, stat);
    a.lw(Reg.v0, 8, Reg.t0);
    store(4);
    a.lw(Reg.v0, 0, Reg.t0);
    store(8);
    a.lw(Reg.v0, 4, Reg.t0);
    store(12);
    a.lw(Reg.v0, 16, Reg.t0);
    store(16);

    // 2. Directory listing of the data directory: the descriptor, the
    // entry count and the name of the third entry.
    a.li(Reg.a0, 0x09101100);
    a.jal(stub(_io, _nidDopen));
    a.nop();
    store(20);
    a.addiu(Reg.s0, Reg.v0, 0);
    a.li(Reg.s1, 0); // count
    a.label('dloop');
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, dirent);
    a.jal(stub(_io, _nidDread));
    a.nop();
    a.beq(Reg.v0, Reg.zero, 'ddone');
    a.nop();
    a.li(Reg.t0, 2);
    a.bne(Reg.s1, Reg.t0, 'dnext');
    a.nop();
    // Copy the name (at dirent + 88) to the results at +32.
    a.li(Reg.t0, dirent + 88);
    a.li(Reg.t1, r + 32);
    a.li(Reg.t2, 12);
    a.label('dcopy');
    a.lb(Reg.t3, 0, Reg.t0);
    a.sb(Reg.t3, 0, Reg.t1);
    a.addiu(Reg.t0, Reg.t0, 1);
    a.addiu(Reg.t1, Reg.t1, 1);
    a.addiu(Reg.t2, Reg.t2, -1);
    a.bne(Reg.t2, Reg.zero, 'dcopy');
    a.nop();
    a.label('dnext');
    a.addiu(Reg.s1, Reg.s1, 1);
    a.jTo('dloop');
    a.nop();
    a.label('ddone');
    a.sw(Reg.s1, 24, Reg.s7);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_io, _nidDclose));
    a.nop();

    // 3. Seeks and reads on the large file.
    a.li(Reg.a0, 0x09101200);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidOpen));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 4090);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidLseek32));
    a.nop();
    store(48);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, buf);
    a.li(Reg.a2, 20);
    a.jal(stub(_io, _nidRead));
    a.nop();
    store(52);
    a.li(Reg.t0, buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(56);
    a.lw(Reg.v0, 4, Reg.t0);
    store(60);
    // Seek to ten bytes before the end with the 64-bit form.
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0);
    a.li(Reg.a2, -10);
    a.li(Reg.a3, -1);
    a.li(Reg.t0, 2);
    a.jal(stub(_io, _nidLseek));
    a.nop();
    store(64);
    a.addiu(Reg.v0, Reg.v1, 0);
    store(68);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, buf);
    a.li(Reg.a2, 10);
    a.jal(stub(_io, _nidRead));
    a.nop();
    a.li(Reg.t0, buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(72);
    a.lw(Reg.v0, 4, Reg.t0);
    store(76);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_io, _nidClose));
    a.nop();

    // 4. A missing file and a write-mode open both fail.
    a.li(Reg.a0, 0x09101300);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidOpen));
    a.nop();
    store(84);
    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 2);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidOpen));
    a.nop();
    store(88);

    // 5. The asynchronous open completes at once; polling collects the
    // descriptor as its result.
    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidOpenAsync));
    a.nop();
    store(92);
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, poll);
    a.jal(stub(_io, _nidPollAsync));
    a.nop();
    store(96);
    a.li(Reg.t0, poll);
    a.lw(Reg.v0, 0, Reg.t0);
    store(100);

    // 6. The drive reports a present, ready disc.
    a.jal(stub('sceUmdUser', _nidGetDriveStat));
    a.nop();
    store(104);

    // 7. Reading the text file through the asynchronous descriptor.
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, buf);
    a.li(Reg.a2, 64);
    a.jal(stub(_io, _nidRead));
    a.nop();
    store(108);
    a.li(Reg.t0, buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(112);
    a.lw(Reg.v0, 4, Reg.t0);
    store(116);
    a.lw(Reg.v0, 8, Reg.t0);
    store(120);
    a.lb(Reg.v0, 12, Reg.t0);
    store(124);

    // 8. A memory stick file round-trips (the relative path resolves
    // against the stick root, the default current directory).
    a.li(Reg.a0, 0x09101400);
    a.li(Reg.a1, 0x0203);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidOpen));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0x09101500);
    a.li(Reg.a2, 2);
    a.jal(stub(_io, _nidWrite));
    a.nop();
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0);
    a.li(Reg.a2, 0);
    a.jal(stub(_io, _nidLseek32));
    a.nop();
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, buf);
    a.li(Reg.a2, 8);
    a.jal(stub(_io, _nidRead));
    a.nop();
    store(128);
    a.li(Reg.t0, buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(132);

    a.jal(stub('LoadExecForUser', _nidExitGame));
    a.nop();
    return a.finish();
  }

  final probe = buildTestElf(code: assemble(const {}), imports: imports);
  return buildTestElf(code: assemble(probe.$2.stubOf), imports: imports).$1;
}

void _runToEnd(Psp core) {
  var result = core.runFrame(286);
  var frames = 1;
  while (!result.stopped && frames < 300) {
    result = core.runFrame(286);
    frames++;
  }
  expect(result.stopped, isTrue);
}

void main() {
  test('identifies a game disc and rejects other discs', () async {
    final iso = _gameIso(_bootProgram());
    final module = PspModule();
    expect((await module.identifyDisc(iso.drive()))?.id, 'psp');
    expect((await CoreFactory.systemOfDisc(iso.drive()))?.id, 'psp');

    final other = _Iso();
    other.pvd(20);
    other.directory(20, [
      (30, 5, false, 'SYSTEM.CNF;1'.codeUnits),
    ]);
    other.data(30, 'BOOT2'.codeUnits);
    expect(await module.identifyDisc(other.drive()), isNull);
  });

  test('boots the disc boot file and reads through it', () async {
    final core = Psp();
    addTearDown(core.dispose);
    core.setCdromDrive(_gameIso(_bootProgram()).drive());
    for (var i = 0; i < 400 && core.dump().startsWith('psp: no media'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(core.dump().startsWith('psp: no media'), isFalse);
    core.mem.writeBytes(
        0x09100000, [...'disc0:/PSP_GAME/DATA/HELLO.TXT'.codeUnits, 0]);
    _runToEnd(core);
    expect(core.kernelLog, contains(_hello));
  });

  test('a read waits for a sector the drive is still loading', () async {
    final core = Psp();
    addTearDown(core.dispose);
    // The text file's data sector (LBA 40) reports as loading for its
    // first five reads; the mount never touches it, only the guest's
    // read does, and that read must wait instead of coming back empty.
    final drive = _SlowDrive(_gameIso(_bootProgram()).rawSectors(), 40, 5);
    core.setCdromDrive(drive);
    for (var i = 0; i < 400 && core.dump().startsWith('psp: no media'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(core.dump().startsWith('psp: no media'), isFalse);
    core.mem.writeBytes(
        0x09100000, [...'disc0:/PSP_GAME/DATA/HELLO.TXT'.codeUnits, 0]);
    _runToEnd(core);
    expect(drive.hold, 0);
    expect(core.kernelLog, contains(_hello));
  });

  test('file operations on the mounted disc', () async {
    final core = Psp();
    addTearDown(core.dispose);
    core.setRom(_opsProgram());
    core.setCdromDrive(_gameIso(_bootProgram()).drive());
    // The mount attaches the drive to the already created kernel; it
    // completes on its own because the fake drive answers at once.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    void putString(int at, String text) =>
        core.mem.writeBytes(at, [...text.codeUnits, 0]);
    putString(0x09101000, 'disc0:/PSP_GAME/DATA/HELLO.TXT');
    putString(0x09101100, 'disc0:/PSP_GAME/DATA');
    putString(0x09101200, 'disc0:/PSP_GAME/DATA/BIG.BIN');
    putString(0x09101300, 'disc0:/PSP_GAME/DATA/NOPE.TXT');
    putString(0x09101400, 'report.txt');
    core.mem.writeBytes(0x09101500, 'AB'.codeUnits);
    _runToEnd(core);

    int at(int offset) => core.mem.read32(0x09100000 + offset);
    // 1. Getstat: the size, a regular read-only mode, the file
    // attribute and the recording date (2026-11-16 in the low fields).
    expect(at(0), 0);
    expect(at(4), _hello.length);
    expect(at(8), 0x2000 | 0x124);
    expect(at(12), 0x20);
    expect(at(16), 2026 | (11 << 16) | (16 << 24));
    // 2. Directory listing: four entries, the third is the text file.
    expect(at(20), greaterThan(0));
    expect(at(24), 4);
    final name = String.fromCharCodes(
        [for (var i = 0; i < 9; i++) core.mem.read8(0x09100020 + i)]);
    expect(name, 'HELLO.TXT');
    // 3. Seeks and reads on the large file.
    expect(at(48), 4090);
    expect(at(52), 20);
    expect(at(56), _bigWord(4090));
    expect(at(60), _bigWord(4094));
    expect(at(64), _bigSize - 10);
    expect(at(68), 0);
    expect(at(72), _bigWord(_bigSize - 10));
    expect(at(76), _bigWord(_bigSize - 6));
    // 4. Failures.
    expect(at(84), 0x80010002);
    expect(at(88), 0x80010002);
    // 5. Asynchronous open and poll.
    expect(at(92), greaterThan(0));
    expect(at(96), 0);
    expect(at(100), at(92));
    // 6. Drive status.
    expect(at(104), 0x22);
    // 7. The text file contents, word by word.
    expect(at(108), _hello.length);
    expect(at(112), 0x6c6c6548); // 'Hell'
    expect(at(116), 0x64202c6f); // 'o', ',', ' ', 'd'
    expect(at(120), 0x21637369); // 'i', 's', 'c', '!'
    expect(at(124), 0x0a); // '\n'
    // 8. The in-memory file round-trip.
    expect(at(128), 2);
    expect(at(132) & 0xffff, 0x4241); // 'AB'
  });
}

int _bigWord(int at) =>
    _bigByte(at) |
    _bigByte(at + 1) << 8 |
    _bigByte(at + 2) << 16 |
    _bigByte(at + 3) << 24;
