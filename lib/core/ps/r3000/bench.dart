import 'dart:typed_data';

import 'package:fnesemu/core/ps/r3000/r3000.dart';
import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

/// A dummy BusR3000 implementation for tests.
class _TestBus implements BusR3000 {
  final ByteData ram;
  late final Uint32List ram32;

  _TestBus(int size) : ram = ByteData(size) {
    ram32 = ram.buffer.asUint32List();
  }

  @override
  int read8(int addr) => ram.getUint8(addr);

  @override
  int read16(int addr) => ram.getUint16(addr); // BE

  @override
  int read32(int addr) => ram.getUint32(addr); // BE

  @override
  void write8(int addr, int value) => ram.setUint8(addr, value);

  @override
  void write16(int addr, int value) => ram.setUint16(addr, value); // BE

  @override
  void write32(int addr, int value) => ram.setUint32(addr, value); // BE
}

void main() {
  final bus = _TestBus(1024 * 1024);

  final idata = [0x3c030001, 0x00002021, 0x24638610, 0];
  final base = 0x0;
  for (int i = 0; i < idata.length; i++) {
    bus.write32(i * 4 + base, idata[i]);
  }
  debugLog("idata: ${range(0, 16).map((e) => bus.read8(e).hex8).join(" ")}");

  final cpu = R3000(bus);
  const count = 4; //50 * 1000 * 1000;

  final startAt = DateTime.now().millisecondsSinceEpoch;
  cpu.pc = base;
  cpu.nextPc = base + 4;
  for (int i = 0; i < count; i++) {
    debugLog(cpu.dump());
    cpu.step();
  }
  final elapsedMs = DateTime.now().millisecondsSinceEpoch - startAt;

  debugLog(
      "elapsed time: ${elapsedMs}ms , ${count / elapsedMs / 1000} Mcycles/sec");
}
