import 'dart:typed_data';

import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';

import 'fixture.dart';

const _io = 'IoFileMgrForUser';
const _nidOpen = 0x109f50bc;
const _nidRead = 0x6a638d83;
const _nidWrite = 0x42ec03ac;
const _nidClose = 0x810c4bc3;
const _nidLseek32 = 0x68963324;
const _nidGetstat = 0xace946e8;
const _nidDopen = 0xb29ddf9c;
const _nidDread = 0xe3eb004c;
const _nidDclose = 0xeb092469;
const _nidMkdir = 0x06a70004;
const _nidRemove = 0xf27a9c51;
const _nidRename = 0x779103a0;
const _nidChdir = 0x55f4717d;
const _nidExitGame = 0x05572a5f;

const _data = '0123456789ABCDEF';
const _results = 0x09100000;
const _buf = 0x09102100;
const _stat = 0x09103000;
const _dirent = 0x09103100;

/// A guest that creates ms0:/SAVE.BIN, writes the pattern the test
/// placed at 0x09102000, closes it, and reads it back through a fresh
/// descriptor, storing every result at [_results].
Uint8List _roundTripProgram() {
  const imports = [
    (_io, [_nidOpen, _nidRead, _nidWrite, _nidClose, _nidLseek32, _nidGetstat]),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(int nid) => stubs['$_io/$nid'] ?? 0;
    final a = Asm(0x08800000);
    void store(int offset) => a.sw(Reg.v0, offset, Reg.s7);
    a.li(Reg.s7, _results);

    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 0x0203); // create, read/write
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    store(0);
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0x09102000);
    a.li(Reg.a2, 16);
    a.jal(stub(_nidWrite));
    a.nop();
    store(4);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_nidClose));
    a.nop();
    store(8);

    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 1); // read only
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    store(12);
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, _buf);
    a.li(Reg.a2, 64);
    a.jal(stub(_nidRead));
    a.nop();
    store(16);
    a.li(Reg.t0, _buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(20);
    a.lw(Reg.v0, 4, Reg.t0);
    store(24);
    a.lw(Reg.v0, 8, Reg.t0);
    store(28);
    a.lw(Reg.v0, 12, Reg.t0);
    store(32);
    // A read-only descriptor refuses writes.
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0x09102000);
    a.li(Reg.a2, 4);
    a.jal(stub(_nidWrite));
    a.nop();
    store(36);
    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, _stat);
    a.jal(stub(_nidGetstat));
    a.nop();
    store(40);
    // A missing file without the creation flag fails.
    a.li(Reg.a0, 0x09101100);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    store(44);
    // Seeking into the file reads from there.
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 4);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidLseek32));
    a.nop();
    store(48);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, _buf);
    a.li(Reg.a2, 4);
    a.jal(stub(_nidRead));
    a.nop();
    store(52);
    a.li(Reg.t0, _buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(56);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_nidClose));
    a.nop();
    store(60);

    a.jal(stubs['LoadExecForUser/$_nidExitGame'] ?? 0);
    a.nop();
    return a.finish();
  }

  final probe = buildTestElf(code: assemble(const {}), imports: imports);
  return buildTestElf(code: assemble(probe.$2.stubOf), imports: imports).$1;
}

/// A guest that only reads ms0:/SAVE.BIN back, storing the read count
/// and the first four words at [_results].
Uint8List _readerProgram() {
  const imports = [
    (_io, [_nidOpen, _nidRead, _nidClose]),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(int nid) => stubs['$_io/$nid'] ?? 0;
    final a = Asm(0x08800000);
    void store(int offset) => a.sw(Reg.v0, offset, Reg.s7);
    a.li(Reg.s7, _results);
    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    store(0);
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, _buf);
    a.li(Reg.a2, 64);
    a.jal(stub(_nidRead));
    a.nop();
    store(4);
    a.li(Reg.t0, _buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(8);
    a.lw(Reg.v0, 4, Reg.t0);
    store(12);
    a.lw(Reg.v0, 8, Reg.t0);
    store(16);
    a.lw(Reg.v0, 12, Reg.t0);
    store(20);
    a.jal(stubs['LoadExecForUser/$_nidExitGame'] ?? 0);
    a.nop();
    return a.finish();
  }

  final probe = buildTestElf(code: assemble(const {}), imports: imports);
  return buildTestElf(code: assemble(probe.$2.stubOf), imports: imports).$1;
}

/// A guest that exercises directories on the stick: creation, a file
/// inside, listing, renaming, a relative open after changing the
/// current directory, and removal, storing every result at
/// [_results].
Uint8List _directoryProgram() {
  const imports = [
    (
      _io,
      [
        _nidOpen,
        _nidRead,
        _nidWrite,
        _nidClose,
        _nidGetstat,
        _nidDopen,
        _nidDread,
        _nidDclose,
        _nidMkdir,
        _nidRemove,
        _nidRename,
        _nidChdir,
      ]
    ),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(int nid) => stubs['$_io/$nid'] ?? 0;
    final a = Asm(0x08800000);
    void store(int offset) => a.sw(Reg.v0, offset, Reg.s7);
    a.li(Reg.s7, _results);

    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 0x1ff);
    a.jal(stub(_nidMkdir));
    a.nop();
    store(0);
    a.li(Reg.a0, 0x09101000);
    a.li(Reg.a1, 0x1ff);
    a.jal(stub(_nidMkdir));
    a.nop();
    store(4); // already there
    a.li(Reg.a0, 0x09101100);
    a.li(Reg.a1, 0x1ff);
    a.jal(stub(_nidMkdir));
    a.nop();
    store(8);
    a.li(Reg.a0, 0x09101200);
    a.li(Reg.a1, 0x0203);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0x09102000);
    a.li(Reg.a2, 4);
    a.jal(stub(_nidWrite));
    a.nop();
    store(12);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_nidClose));
    a.nop();
    store(16);

    a.li(Reg.a0, 0x09101100);
    a.jal(stub(_nidDopen));
    a.nop();
    store(20);
    a.addiu(Reg.s1, Reg.v0, 0);
    for (final offset in [24, 28, 32]) {
      a.addiu(Reg.a0, Reg.s1, 0);
      a.li(Reg.a1, _dirent);
      a.jal(stub(_nidDread));
      a.nop();
      store(offset);
    }
    // The third entry is the file: its name and size.
    a.li(Reg.t0, _dirent);
    a.lw(Reg.v0, 88, Reg.t0);
    store(36);
    a.lw(Reg.v0, 92, Reg.t0);
    store(40);
    a.lw(Reg.v0, 8, Reg.t0);
    store(44);
    a.addiu(Reg.a0, Reg.s1, 0);
    a.li(Reg.a1, _dirent);
    a.jal(stub(_nidDread));
    a.nop();
    store(48); // the listing is over
    a.addiu(Reg.a0, Reg.s1, 0);
    a.jal(stub(_nidDclose));
    a.nop();
    store(52);

    a.li(Reg.a0, 0x09101200);
    a.li(Reg.a1, 0x09101300);
    a.jal(stub(_nidRename));
    a.nop();
    store(56);
    a.li(Reg.a0, 0x09101200);
    a.li(Reg.a1, _stat);
    a.jal(stub(_nidGetstat));
    a.nop();
    store(60); // the old name is gone
    a.li(Reg.a0, 0x09101300);
    a.li(Reg.a1, _stat);
    a.jal(stub(_nidGetstat));
    a.nop();
    store(64);
    a.li(Reg.a0, 0x09101100);
    a.jal(stub(_nidChdir));
    a.nop();
    store(68);
    // A relative path now resolves inside the directory.
    a.li(Reg.a0, 0x09101400);
    a.li(Reg.a1, 1);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidOpen));
    a.nop();
    store(72);
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, _buf);
    a.li(Reg.a2, 4);
    a.jal(stub(_nidRead));
    a.nop();
    store(76);
    a.li(Reg.t0, _buf);
    a.lw(Reg.v0, 0, Reg.t0);
    store(80);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.jal(stub(_nidClose));
    a.nop();

    a.li(Reg.a0, 0x09101300);
    a.jal(stub(_nidRemove));
    a.nop();
    store(84);
    a.li(Reg.a0, 0x09101000);
    a.jal(stub(_nidRemove));
    a.nop();
    store(88); // still holds the subdirectory
    a.li(Reg.a0, 0x09101100);
    a.jal(stub(_nidRemove));
    a.nop();
    store(92);
    a.li(Reg.a0, 0x09101000);
    a.jal(stub(_nidRemove));
    a.nop();
    store(96);

    a.jal(stubs['LoadExecForUser/$_nidExitGame'] ?? 0);
    a.nop();
    return a.finish();
  }

  final probe = buildTestElf(code: assemble(const {}), imports: imports);
  return buildTestElf(code: assemble(probe.$2.stubOf), imports: imports).$1;
}

/// Storage with the host's semantics: entries are preloaded into a
/// cache, and init serves the cached bytes for a key when they exist.
class _FakeStorage extends Sram {
  final Map<String, Uint8List> cache;
  _FakeStorage(this.cache);

  @override
  void init(String id, Uint8List initialData) {
    if (this.id.isNotEmpty) {
      cache[this.id] = Uint8List.fromList(data);
    }
    super.init(id, cache[id] ?? initialData);
  }

  /// What the host's periodic save would persist right now.
  void snapshot() {
    if (id.isNotEmpty) cache[id] = Uint8List.fromList(data);
  }
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

void _putString(Psp core, int at, String text) =>
    core.mem.writeBytes(at, [...text.codeUnits, 0]);

void main() {
  int at(Psp core, int offset) => core.mem.read32(_results + offset);

  test('a file on the stick survives closing and reopening', () {
    final core = Psp();
    core.setRom(_roundTripProgram());
    _putString(core, 0x09101000, 'ms0:/SAVE.BIN');
    _putString(core, 0x09101100, 'ms0:/NOPE.BIN');
    core.mem.writeBytes(0x09102000, _data.codeUnits);
    _runToEnd(core);
    expect(at(core, 0), greaterThanOrEqualTo(3));
    expect(at(core, 4), 16);
    expect(at(core, 8), 0);
    expect(at(core, 12), greaterThanOrEqualTo(3));
    expect(at(core, 16), 16);
    expect(at(core, 20), 0x33323130);
    expect(at(core, 24), 0x37363534);
    expect(at(core, 28), 0x42413938);
    expect(at(core, 32), 0x46454443);
    expect(at(core, 36), 0x80010002);
    expect(at(core, 40), 0);
    expect(core.mem.read32(_stat), 0x2000 | 0x1a4);
    expect(core.mem.read32(_stat + 8), 16);
    expect(at(core, 44), 0x80010002);
    expect(at(core, 48), 4);
    expect(at(core, 52), 4);
    expect(at(core, 56), 0x37363534);
    expect(at(core, 60), 0);
  });

  test('directories list, rename, and resolve relative paths', () {
    final core = Psp();
    core.setRom(_directoryProgram());
    _putString(core, 0x09101000, 'ms0:/PSP');
    _putString(core, 0x09101100, 'ms0:/PSP/SAVEDATA');
    _putString(core, 0x09101200, 'ms0:/PSP/SAVEDATA/DATA.BIN');
    _putString(core, 0x09101300, 'ms0:/PSP/SAVEDATA/RENAMED.BIN');
    _putString(core, 0x09101400, 'RENAMED.BIN');
    core.mem.writeBytes(0x09102000, 'WXYZ'.codeUnits);
    _runToEnd(core);
    expect(at(core, 0), 0);
    expect(at(core, 4), 0x80010002);
    expect(at(core, 8), 0);
    expect(at(core, 12), 4);
    expect(at(core, 16), 0);
    expect(at(core, 20), greaterThanOrEqualTo(3));
    expect(at(core, 24), 1);
    expect(at(core, 28), 1);
    expect(at(core, 32), 1);
    expect(at(core, 36), 0x41544144); // 'DATA'
    expect(at(core, 40), 0x4e49422e); // '.BIN'
    expect(at(core, 44), 4);
    expect(at(core, 48), 0);
    expect(at(core, 52), 0);
    expect(at(core, 56), 0);
    expect(at(core, 60), 0x80010002);
    expect(at(core, 64), 0);
    expect(at(core, 68), 0);
    expect(at(core, 72), greaterThanOrEqualTo(3));
    expect(at(core, 76), 4);
    expect(at(core, 80), 0x5a595857); // 'WXYZ'
    expect(at(core, 84), 0);
    expect(at(core, 88), 0x80010002);
    expect(at(core, 92), 0);
    expect(at(core, 96), 0);
  });

  test('the stick persists through the shared storage', () {
    final cache = <String, Uint8List>{};
    final storage = _FakeStorage(cache);
    final core = Psp();
    core.setSram(storage);
    core.setRom(_roundTripProgram());
    _putString(core, 0x09101000, 'ms0:/SAVE.BIN');
    _putString(core, 0x09101100, 'ms0:/NOPE.BIN');
    core.mem.writeBytes(0x09102000, _data.codeUnits);
    _runToEnd(core);
    expect(at(core, 16), 16);
    storage.snapshot();
    expect(cache.keys, contains('psp/sram/memorystick'));
    expect(cache['psp/sram/memorystick']!.sublist(0, 4), 'MSFS'.codeUnits);

    // A fresh core over the same storage reads the file back.
    final restored = Psp();
    restored.setSram(_FakeStorage(cache));
    restored.setRom(_readerProgram());
    _putString(restored, 0x09101000, 'ms0:/SAVE.BIN');
    _runToEnd(restored);
    expect(at(restored, 0), greaterThanOrEqualTo(3));
    expect(at(restored, 4), 16);
    expect(at(restored, 8), 0x33323130);
    expect(at(restored, 12), 0x37363534);
    expect(at(restored, 16), 0x42413938);
    expect(at(restored, 20), 0x46454443);
  });
}
