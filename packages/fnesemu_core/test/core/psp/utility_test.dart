import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/memstick.dart';
import 'package:fnesemu_core/src/core/psp/utility.dart';
import 'package:test/test.dart';

const _param = 0x08900000;
const _data = 0x08910000;
const _list = 0x08920000;

void main() {
  late PspMemory mem;
  late PspMemStick stick;
  late PspSavedataDialog dialog;
  var now = 100;

  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      mem.write8(at + i, s.codeUnitAt(i));
    }
    mem.write8(at + s.length, 0);
  }

  String read(int at) => mem.readString(at, 64);

  /// Fills a parameter block for [mode] on the save [name] with [bytes] of
  /// data, and runs the dialog to its end; returns the result.
  int run(int mode, String name,
      {List<int> bytes = const [],
      int focus = 0,
      List<String>? list,
      int msFree = 0}) {
    for (var i = 0; i < 0x600; i += 4) {
      mem.write32(_param + i, 0);
    }
    mem.write32(_param, 0x600);
    mem.write32(_param + 0x30, mode);
    text(_param + 0x3c, 'GAME00000');
    text(_param + 0x4c, name);
    text(_param + 0x64, 'DATA.BIN');
    mem.write32(_param + 0x74, _data);
    mem.write32(_param + 0x78, 0x100);
    mem.write32(_param + 0x7c, bytes.length);
    mem.writeBytes(_data, bytes);
    text(_param + 0x100, 'save title');
    mem.write32(_param + 0x5c8, focus);
    mem.write32(_param + 0x5d0, msFree);
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        text(_list + i * 20, list[i]);
      }
      text(_list + list.length * 20, '');
      mem.write32(_param + 0x60, _list);
    }
    expect(dialog.initStart(_param), 0);
    expect(dialog.getStatus(), PspSavedataDialog.statusInit);
    expect(dialog.getStatus(), PspSavedataDialog.statusVisible);
    expect(dialog.getStatus(), PspSavedataDialog.statusQuit);
    expect(dialog.shutdownStart(), 0);
    expect(dialog.getStatus(), PspSavedataDialog.statusFinished);
    expect(dialog.getStatus(), PspSavedataDialog.statusNone);
    now += 10;
    return mem.read32(_param + 0x1c);
  }

  setUp(() {
    mem = PspMemory();
    stick = PspMemStick()..clock = () => now;
    dialog = PspSavedataDialog(mem, () => stick);
  });

  test('a save loads back with its title', () {
    expect(run(3, 'SLOT1', bytes: [1, 2, 3, 4, 5]), 0);
    expect(stick.lookup('PSP/SAVEDATA/GAME00000SLOT1/DATA.BIN')!.content,
        [1, 2, 3, 4, 5]);
    expect(run(2, 'SLOT1'), 0);
    expect(mem.readBytes(_data, 5), [1, 2, 3, 4, 5]);
    expect(mem.read32(_param + 0x7c), 5);
    expect(read(_param + 0x100), 'save title');
  });

  test('loading a missing save reports no data', () {
    expect(run(0, 'SLOT1'), PspSavedataDialog.errorLoadNoData);
    expect(run(4, '', list: ['SLOT1', 'SLOT2']),
        PspSavedataDialog.errorLoadNoData);
  });

  test('a list load takes the latest save', () {
    run(3, 'SLOT2', bytes: [2]);
    run(3, 'SLOT1', bytes: [1]);
    expect(run(4, '', list: ['SLOT1', 'SLOT2', 'SLOT3']), 0);
    expect(read(_param + 0x4c), 'SLOT1');
    expect(mem.read8(_data), 1);
  });

  test('a list save takes the first empty entry when focused on it', () {
    run(3, 'SLOT1', bytes: [1]);
    expect(run(5, '', bytes: [9], focus: 7, list: ['SLOT1', 'SLOT2']), 0);
    expect(read(_param + 0x4c), 'SLOT2');
    expect(stick.lookup('PSP/SAVEDATA/GAME00000SLOT2/DATA.BIN')!.content, [9]);
  });

  test('a size query succeeds and a plain read loads', () {
    expect(run(22, 'SLOT1'), 0);
    run(18, 'SLOT1', bytes: [7, 8]);
    expect(run(16, 'SLOT1'), 0);
    expect(mem.readBytes(_data, 2), [7, 8]);
    expect(run(20, 'SLOT1'), 0);
    expect(run(16, 'SLOT1'), PspSavedataDialog.errorLoadNoData);
  });

  test('the sizes mode reports free space', () {
    const info = _list;
    expect(run(8, 'SLOT1', msFree: info), 0);
    expect(mem.read32(info), 0x8000);
    expect(mem.read32(info + 4) * mem.read32(info), 1 << 30);
    expect(mem.read32(info + 8), 1 << 20);
    expect(read(info + 12), '1024 MB');
  });

  test('a second dialog cannot start before the first ends', () {
    expect(dialog.initStart(_param), 0);
    expect(dialog.initStart(_param), isNot(0));
  });

  test('a system file object keeps its values', () {
    final values = readSfo(writeSfo({'TITLE': 'a game', 'PARENTAL_LEVEL': 3}));
    expect(values, {'TITLE': 'a game', 'PARENTAL_LEVEL': 3});
  });

  test('the keyboard returns the initial text or a default name', () {
    const params = 0x09000000, field = 0x09000100;
    const inText = 0x09000200, outText = 0x09000300;
    final keyboard = PspKeyboardDialog(mem);
    String run(String initial, int limit) {
      for (var i = 0; i < 0x400; i += 4) {
        mem.write32(params + i, 0);
      }
      mem.write32(params, 0x40);
      mem.write32(params + 0x30, 1);
      mem.write32(params + 0x34, field);
      for (var i = 0; i < initial.length; i++) {
        mem.write16(inText + i * 2, initial.codeUnitAt(i));
      }
      mem.write16(inText + initial.length * 2, 0);
      mem.write32(field + 0x20, inText);
      mem.write32(field + 0x24, 0x200);
      mem.write32(field + 0x28, outText);
      mem.write32(field + 0x30, limit);
      expect(keyboard.initStart(params), 0);
      expect(keyboard.getStatus(), PspSavedataDialog.statusInit);
      expect(keyboard.getStatus(), PspSavedataDialog.statusVisible);
      expect(keyboard.getStatus(), PspSavedataDialog.statusQuit);
      expect(keyboard.shutdownStart(), 0);
      expect(keyboard.getStatus(), PspSavedataDialog.statusFinished);
      expect(keyboard.getStatus(), PspSavedataDialog.statusNone);
      expect(mem.read32(field + 0x2c), 2);
      final units = <int>[];
      for (var at = outText; mem.read16(at) != 0; at += 2) {
        units.add(mem.read16(at));
      }
      return String.fromCharCodes(units);
    }

    expect(run('', 15), PspKeyboardDialog.defaultText);
    expect(run('ABCDEFGH', 4), 'ABCD');
  });
}
