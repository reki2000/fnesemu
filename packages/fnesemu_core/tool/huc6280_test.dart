// runs the single-step tests of SingleStepTests/huc6280 (the v1/*.json.bin files)
//
// each test runs one instruction from the initial state and compares the
// registers, the MPRs and the memory with the final state. the cycle counts
// are not compared.

import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/component/bus.dart';
import 'package:fnesemu_core/src/core/pce/component/cpu.dart';
import 'package:fnesemu_core/src/util/int.dart';

import 'logging.dart';

class _State {
  int a = 0, x = 0, y = 0, s = 0, p = 0, pc = 0;
  final mpr = List<int>.filled(8, 0);
  final ram = <int, int>{};
}

class _Test {
  final String name;
  final int opcode;
  final _State initial, expected;
  _Test(this.name, this.opcode, this.initial, this.expected);
}

class _Reader {
  final ByteData data;
  int pos = 0;
  _Reader(Uint8List bytes) : data = ByteData.sublistView(bytes);

  int u8() => data.getUint8(pos++);
  int u16() => data.getUint16((pos += 2) - 2, Endian.little);
  int u32() => data.getUint32((pos += 4) - 4, Endian.little);

  _State state() {
    final start = pos;
    final size = u32();
    final s = _State()
      ..a = u8()
      ..x = u8()
      ..y = u8()
      ..s = u8()
      ..p = u8()
      ..pc = u16();
    for (int i = 0; i < 8; i++) {
      s.mpr[i] = u8();
    }
    final count = u32();
    for (int i = 0; i < count; i++) {
      final addr = u32();
      s.ram[addr] = u8();
    }
    pos = start + size;
    return s;
  }

  _Test test() {
    final start = pos;
    final size = u32();
    final name = String.fromCharCodes(
            data.buffer.asUint8List(data.offsetInBytes + pos, 50))
        .replaceAll("\x00", "")
        .trim();
    pos += 50;
    final opcode = u32();
    final initial = state();
    final expected = state();
    pos = start + size; // the cycle records are not used
    return _Test(name, opcode, initial, expected);
  }
}

/// A flat 2MB memory addressed by the 21-bit physical address, as the tests
/// treat the memory.
class _TestBus extends Bus {
  final mem = <int, int>{};

  @override
  int read(int addr) => mem[addr] ?? 0;

  @override
  void write(int addr, int data) => mem[addr] = data.mask8;
}

// ST0/ST1/ST2 write the VDC, which is not a part of the CPU
const _skippedOpcodes = {0x03, 0x13, 0x23};

// the tests record at most 500 cycles, so the final state of a block
// transfer longer than this (17 + 6 * length cycles) is cut in the middle
const _blockTransfers = {0x73, 0xc3, 0xd3, 0xe3, 0xf3};
const _maxBlockLength = (500 - 17) ~/ 6;

int _read(_State s, int addr) =>
    s.ram[(s.mpr[addr.mask16 >> 13] << 13) | (addr & 0x1fff)] ?? 0;

/// The reason to skip a test, or null.
String? _skip(_Test t) {
  final i = t.initial;
  if (_skippedOpcodes.contains(t.opcode)) {
    return "ST0/ST1/ST2";
  }
  if (_blockTransfers.contains(t.opcode)) {
    final length = _read(i, i.pc + 5) | _read(i, i.pc + 6) << 8;
    // the length may also be overwritten when the registers are saved, so a
    // test that reached the limit of 500 recorded writes is cut as well
    if (length == 0 ||
        length > _maxBlockLength ||
        t.expected.ram.length >= 499) {
      return "block transfers longer than $_maxBlockLength bytes";
    }
  }
  // TMA without a selected MPR returns an internal value of the generator
  if (t.opcode == 0x43 && _read(i, i.pc + 1) == 0) {
    return "TMA #0";
  }
  return null;
}

List<String> _run(_Test t) {
  final bus = _TestBus();
  final cpu = Cpu2(bus);
  final i = t.initial;
  bus.mem.addAll(i.ram);
  cpu.regs
    ..a = i.a
    ..x = i.x
    ..y = i.y
    ..s = i.s
    ..p = i.p
    ..pc = i.pc;
  for (int n = 0; n < 8; n++) {
    cpu.regs.mpr[n] = i.mpr[n];
    cpu.regs.mprAddress[n] = i.mpr[n] << 13;
  }
  cpu.exec();

  final e = t.expected;
  final diffs = <String>[];
  void check(String what, int actual, int expected) {
    if (actual != expected) {
      diffs.add("$what: ${actual.x2}, expected ${expected.x2}");
    }
  }

  final r = cpu.regs;
  check("a", r.a, e.a);
  check("x", r.x, e.x);
  check("y", r.y, e.y);
  check("s", r.s, e.s);
  check("p", r.p, e.p);
  if (r.pc != e.pc) {
    diffs.add("pc: ${r.pc.x4}, expected ${e.pc.x4}");
  }
  for (int n = 0; n < 8; n++) {
    check("mpr$n", r.mpr[n], e.mpr[n]);
  }
  for (final MapEntry(key: addr, value: val) in e.ram.entries) {
    final actual = bus.mem[addr] ?? 0;
    if (actual != val) {
      diffs.add("ram ${addr.toRadixString(16)}: ${actual.x2}, "
          "expected ${val.x2}");
    }
  }
  return diffs;
}

// args[0]: the v1 directory of SingleStepTests/huc6280
void main(List<String> args) {
  configureLogging();
  final files = Directory(args[0])
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith(".json.bin"))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final failures = <String, (int, int)>{};
  final skipped = <String, int>{};
  for (final file in files) {
    final reader = _Reader(file.readAsBytesSync());
    final count = reader.u32();
    int failed = 0;
    for (int n = 0; n < count; n++) {
      final t = reader.test();
      final reason = _skip(t);
      if (reason != null) {
        skipped[reason] = (skipped[reason] ?? 0) + 1;
        continue;
      }
      final diffs = _run(t);
      if (diffs.isNotEmpty && failed++ == 0) {
        stdout.writeln("${t.name}:");
        for (final d in diffs) {
          stdout.writeln("  $d");
        }
      }
    }
    if (failed > 0) {
      failures[file.uri.pathSegments.last] = (failed, count);
    }
  }

  for (final MapEntry(:key, :value) in skipped.entries) {
    stdout.writeln("skipped $value tests: $key");
  }
  if (failures.isEmpty) {
    stdout.writeln("all tests passed (${files.length} files)");
    return;
  }
  stdout.writeln("\nfailed tests:");
  for (final MapEntry(:key, :value) in failures.entries) {
    stdout.writeln("  $key: ${value.$1}/${value.$2}");
  }
  stdout.writeln("${failures.length} of ${files.length} files failed");
  exitCode = 1;
}
