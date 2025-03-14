import 'dart:io';
import 'dart:typed_data';
import 'package:fnesemu/util/uint8list.dart';
import 'package:test/test.dart';
import 'package:fnesemu/core/ps/r3000/r3000.dart';
import 'package:fnesemu/util/int.dart';

import '../../../util/debug.dart';
import 'r3000_disasm.dart';

/// A dummy BusR3000 implementation for tests.
class _TestBus implements BusR3000 {
  final Uint8List ram;

  _TestBus(int size) : ram = Uint8List(size);

  @override
  int read8(int addr) => addr < ram.length ? ram[addr] : 0xff;

  @override
  int read16(int addr) {
    return addr < ram.length ? ram.getUInt16BE(addr) : 0xffff;
  }

  @override
  int read32(int addr) =>
      addr < ram.length ? ram.getUInt32BE(addr) : 0xffffffff;

  @override
  void write8(int addr, int value) {
    if (addr < ram.length) {
      ram[addr] = value.mask8;
    }
  }

  @override
  void write16(int addr, int value) {
    if (addr < ram.length) {
      ram.setUInt16BE(addr, value.mask16);
    }
  }

  @override
  void write32(int addr, int value) {
    if (addr < ram.length) {
      ram.setUInt32BE(addr, value.mask32);
    }
  }
}

void main() {
  const baseDir = "assets/MIPS-R3000-CPU-Simulator/tests/test_dataset";

  for (final testgroup in Directory(baseDir).listSync()) {
    if (File("${testgroup.path}/dimage.bin").existsSync() == false) {
      continue;
    }

    final snapshot = File("${testgroup.path}/snapshot.rpt").readAsLinesSync();
    int snapshotIndex = 0;

    final bus = _TestBus(1024 * 1024);

    final iimage = File("${testgroup.path}/iimage.bin").readAsBytesSync();
    final base = iimage.getUInt32BE(0);
    final idata = iimage.sublist(8);
    for (int i = 0; i < idata.length; i += 4) {
      bus.write32(i + base, idata.getUInt32BE(i));
    }

    final dimage = File("${testgroup.path}/dimage.bin").readAsBytesSync();
    final ddata = dimage.sublist(8);
    for (int i = 0; i < ddata.length; i += 4) {
      bus.write32(i, ddata.getUInt32BE(i));
    }

    final cpu = R3000(bus);
    cpu.r[29] = dimage.getUInt32BE(0);
    cpu.pc = base;

    test("test ${testgroup.path}", () {
      void check(String s) => expect(s, equals(snapshot[snapshotIndex++]));

      while (snapshotIndex < snapshot.length) {
        final inst32 = bus.read32(cpu.pc);
        final log =
            "cycle ${cpu.clocks} ${cpu.pc.hex32}: ${inst32.hex32} ${DisasmR3000.disasm(inst32)}";

        check("cycle ${cpu.clocks}");
        for (int i = 0; i < 32; i++) {
          check(
              "\$${i.toString().padLeft(2, "0")}: 0x${cpu.r[i].hex32.toUpperCase()}");
        }
        check("PC: 0x${cpu.pc.hex32.toUpperCase()}");
        check("");
        check("");

        if (inst32 == 0xffffffff) {
          break;
        }

        try {
          cpu.step();
        } catch (e) {
          debugLog(log);
          rethrow;
        }
      }
    });
  }
}
