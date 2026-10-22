// runs the single-step tests of SingleStepTests/r3000 (the v1/*.json.bin files)
//
// each test runs one instruction from the initial state and compares the
// registers, the branch and load delay slots and the memory writes with the
// final state. the cycle counts are not compared.

import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/r3000/disasm.dart';
import 'package:fnesemu_core/src/core/ps/r3000/r3000.dart';
import 'package:fnesemu_core/src/util/int.dart';

import '../logging.dart';

class _State {
  final r = List<int>.filled(32, 0);
  int hi = 0, lo = 0, epc = 0, tar = 0, cause = 0, pc = 0;
  bool branchSlot = false, branchTake = false;
  int branchTarget = 0;
  int loadTarget = -1, loadVal = 0;
}

class _Access {
  static const write = 2; // 1: read, 4: fetch
  final int action, addr, val, size;
  _Access(this.action, this.addr, this.val, this.size);
}

class _Test {
  final String name;
  final int opcode, opcodeAddr;
  final _State initial, expected;
  final List<_Access> accesses;
  _Test(this.name, this.opcode, this.opcodeAddr, this.initial, this.expected,
      this.accesses);
}

class _Reader {
  final ByteData data;
  int pos = 0;
  _Reader(Uint8List bytes) : data = ByteData.sublistView(bytes);

  int u32() => data.getUint32((pos += 4) - 4, Endian.little);
  int i32() => data.getInt32((pos += 4) - 4, Endian.little);
  int i64() => data.getInt64((pos += 8) - 8, Endian.little);

  String pascal(int size) {
    final len = data.getUint8(pos);
    final s = String.fromCharCodes(
        data.buffer.asUint8List(data.offsetInBytes + pos + 1, len));
    pos += size;
    return s;
  }

  _State state() {
    final s = _State();
    for (int i = 0; i < 32; i++) {
      s.r[i] = u32();
    }
    s.hi = u32();
    s.lo = u32();
    s.epc = u32();
    s.tar = u32();
    s.cause = u32();
    s.pc = u32();
    s.branchTarget = u32();
    s.branchSlot = u32() != 0;
    s.branchTake = u32() != 0;
    s.loadTarget = i32();
    s.loadVal = u32();
    return s;
  }

  _Test test() {
    final name = pascal(51);
    final opcode = u32();
    final opcodeAddr = u32();
    final initial = state();
    final expected = state();
    final accesses = List.generate(u32(), (_) {
      final val = i64();
      final action = u32();
      final addr = i64();
      final size = u32();
      return _Access(action, addr.mask32, val.mask32, size);
    });
    return _Test(name, opcode, opcodeAddr, initial, expected, accesses);
  }
}

/// A flat little-endian memory that holds the values the test reads, and
/// records the bytes the instruction writes with the values they replace.
class _TestBus implements BusR3000 {
  final mem = <int, int>{};
  final written = <int, int>{};
  final replaced = <int, int>{};

  int _get(int addr) => mem[addr.mask32] ?? 0;

  void put(int addr, int val, int size) {
    for (int i = 0; i < size; i++) {
      mem[(addr + i).mask32] = (val >> (i * 8)).mask8;
    }
  }

  void _set(int addr, int val, int size) {
    for (int i = 0; i < size; i++) {
      final a = (addr + i).mask32;
      replaced.putIfAbsent(a, () => _get(a));
      written[a] = (val >> (i * 8)).mask8;
      mem[a] = (val >> (i * 8)).mask8;
    }
  }

  @override
  int read8(int addr) => _get(addr);

  @override
  int read16(int addr) => _get(addr) | _get(addr + 1) << 8;

  @override
  int read32(int addr) => read16(addr) | read16(addr + 2) << 16;

  @override
  void write8(int addr, int value) => _set(addr, value, 1);

  @override
  void write16(int addr, int value) => _set(addr, value, 2);

  @override
  void write32(int addr, int value) => _set(addr, value, 4);
}

String _x(int v) => v.mask32.x8;

// the access size of the loads and stores that raise an address error when
// misaligned; the core does not emulate the address error exceptions
const _alignedAccess = {0x21: 2, 0x25: 2, 0x23: 4, 0x29: 2, 0x2b: 4};

bool _misaligned(_Test t) {
  final size = _alignedAccess[t.opcode.shr26];
  if (size == null) {
    return false;
  }
  final addr = t.initial.r[t.opcode.shr21.mask5] + t.opcode.rel16;
  return addr & (size - 1) != 0;
}

/// Runs one test and returns the differences.
List<String> _run(_Test t) {
  final bus = _TestBus();
  for (final a in t.accesses) {
    if (a.action != _Access.write) {
      bus.put(a.addr, a.val, a.size);
    }
  }
  bus.put(t.opcodeAddr, t.opcode, 4);

  final i = t.initial;
  final cpu = R3000(bus);
  for (int n = 0; n < 32; n++) {
    cpu.r[n] = i.r[n];
  }
  cpu.hi = i.hi;
  cpu.lo = i.lo;
  cpu.epc = i.epc;
  cpu.tar = i.tar;
  cpu.cause = i.cause;
  cpu.pc = i.pc;
  cpu.nextPc =
      (i.branchSlot && i.branchTake ? i.branchTarget : i.pc + 4).mask32;
  // the previous instruction was a branch: this one is in its delay slot
  cpu.inBranchDelay = i.branchSlot;
  cpu.inBranchTaken = i.branchSlot && i.branchTake;
  // a load of the previous instruction lands after this one
  if (i.loadTarget >= 0) {
    cpu.nextDelayReg = i.loadTarget;
    cpu.nextDelayVal = i.loadVal;
  }

  cpu.step();

  final e = t.expected;
  final diffs = <String>[];
  void check(String what, int actual, int expected) {
    if (actual.mask32 != expected.mask32) {
      diffs.add("$what: ${_x(actual)}, expected ${_x(expected)}");
    }
  }

  for (int n = 0; n < 32; n++) {
    check("r$n", cpu.r[n], e.r[n]);
  }
  check("hi", cpu.hi, e.hi);
  check("lo", cpu.lo, e.lo);
  check("epc", cpu.epc, e.epc);
  check("cause", cpu.cause, e.cause);
  check("tar", cpu.tar, e.tar);
  check("pc", cpu.pc, e.pc);
  if (cpu.inBranchDelay != e.branchSlot || cpu.inBranchTaken != e.branchTake) {
    diffs.add("branch slot/take: ${cpu.inBranchDelay}/${cpu.inBranchTaken}, "
        "expected ${e.branchSlot}/${e.branchTake}");
  } else if (e.branchTake) {
    check("branch target", cpu.nextPc, e.branchTarget);
  }
  final loadReg = cpu.nextDelayReg == 0 ? -1 : cpu.nextDelayReg;
  final expectedReg = e.loadTarget == 0 ? -1 : e.loadTarget;
  if (loadReg != expectedReg ||
      (loadReg >= 0 && cpu.nextDelayVal.mask32 != e.loadVal.mask32)) {
    diffs.add("load slot: r$loadReg=${_x(cpu.nextDelayVal)}, "
        "expected r$expectedReg=${_x(e.loadVal)}");
  }

  final expectedWrites = <int, int>{};
  for (final a in t.accesses.where((a) => a.action == _Access.write)) {
    for (int n = 0; n < a.size; n++) {
      expectedWrites[(a.addr + n).mask32] = (a.val >> (n * 8)).mask8;
    }
  }
  // a byte written back with its own value (a read-modify-write of a whole
  // word for SWL/SWR) does not change the memory
  for (final addr in {...expectedWrites.keys, ...bus.written.keys}) {
    if (!expectedWrites.containsKey(addr) &&
        bus.written[addr] == bus.replaced[addr]) {
      continue;
    }
    if (expectedWrites[addr] != bus.written[addr]) {
      diffs.add("write ${_x(addr)}: ${bus.written[addr]?.x2 ?? "none"}, "
          "expected ${expectedWrites[addr]?.x2 ?? "none"}");
    }
  }
  return diffs;
}

// args[0]: the v1 directory of SingleStepTests/r3000
void main(List<String> args) {
  configureLogging();
  final files = Directory(args[0])
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith(".json.bin"))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final failures = <String, (int, int)>{};
  int skipped = 0;
  final kinds = <String, Map<String, int>>{};
  for (final file in files) {
    final reader = _Reader(file.readAsBytesSync());
    final count = reader.i32();
    int failed = 0;
    for (int n = 0; n < count; n++) {
      final t = reader.test();
      if (_misaligned(t)) {
        skipped++;
        continue;
      }
      final diffs = _run(t);
      if (diffs.isNotEmpty) {
        // the kinds of differences, such as "epc+cause+pc", to see the causes
        final kind =
            {for (final d in diffs) d.split(RegExp(r"[: ]"))[0]}.join("+");
        final k = kinds.putIfAbsent(file.uri.pathSegments.last, () => {});
        k[kind] = (k[kind] ?? 0) + 1;
      }
      if (diffs.isNotEmpty && failed++ == 0) {
        stdout.writeln("${t.name}: ${_x(t.opcodeAddr)}: ${_x(t.opcode)} "
            "${DisasmR3000.disasm(t.opcode)}");
        for (final d in diffs) {
          stdout.writeln("  $d");
        }
      }
    }
    if (failed > 0) {
      failures[file.uri.pathSegments.last] = (failed, count);
    }
  }

  stdout.writeln("skipped $skipped misaligned loads and stores");
  if (failures.isEmpty) {
    stdout.writeln("all tests passed (${files.length} files)");
    return;
  }
  stdout.writeln("\nfailed tests:");
  for (final MapEntry(:key, :value) in failures.entries) {
    stdout.writeln("  $key: ${value.$1}/${value.$2} "
        "${kinds[key]!.entries.map((e) => "${e.key}:${e.value}").join(" ")}");
  }
  exitCode = 1;
}
