import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fnesemu/core/md/m68/m68_debug.dart';
import 'package:fnesemu/util/int.dart';

import '../bus_m68.dart';
import 'm68.dart';

class BusM68Test extends BusM68 {
  final ram_ = List<int>.filled(0x1000000, 0);

  late M68 cpu;

  BusM68Test();

  @override
  int read(int addr) {
    return ram_[addr.mask24];
  }

  @override
  void write(int addr, int data) {
    ram_[addr.mask24] = data;
  }
}

void loadTest(json, M68 cpu) {
  for (int i = 0; i < 8; i++) {
    if (i < 7) cpu.a[i] = json["a$i"];
    cpu.d[i] = json["d$i"];
  }
  cpu.pc = json['pc'];
  cpu.sr = json['sr'];
  cpu.usp = json['usp'];
  cpu.ssp = json['ssp'];
}

String showDiff(String a1, String a2) {
  String dump1 = a1.padRight(a2.length, " ");
  final dump2 = a2.padRight(dump1.length, " ");
  dump1 = dump1.padRight(dump2.length, " ");
  return List.generate(dump1.length, (i) => dump1[i] == dump2[i] ? " " : "^")
      .join();
}

loadMap() {
  final mapFile =
      File('assets/680x0/map/68000.official.json').readAsBytesSync();
  return json.decode(utf8.decode(mapFile)).cast<String, String>();
}

int main() {
  final bus = BusM68Test();
  final cpu = M68(bus);
  cpu.bus = bus;

  final cpu2 = M68(bus);

  final directory = Directory('assets/680x0/68000/v1');
  final jsonGzFiles = directory
      .listSync()
      .where((file) => file is File && file.path.endsWith('.json.gz'))
      .cast<File>();

  for (final file in jsonGzFiles) {
    final compressedData = file.readAsBytesSync();
    final uncompressedData = GZipDecoder().decodeBytes(compressedData);
    final tests = json.decode(utf8.decode(uncompressedData));

    //final opMap = loadMap();

    const target = "5ca0";

    for (final test in tests) {
      loadTest(test['initial'], cpu);
      loadTest(test['final'], cpu2);
      cpu2.clocks = test['length'];

      for (final mem in test['initial']['ram']) {
        bus.ram_[mem[0]] = mem[1];
        if (test['name'].startsWith(target)) {
          print("ram[${(mem[0] as int).hex24}] = ${(mem[1] as int).hex8}");
        }
      }
      int i = 0;
      for (final val in test['initial']['prefetch']) {
        bus.ram_[cpu.pc + i++] = val >> 8;
        bus.ram_[cpu.pc + i++] = val & 0xff;
      }

      if (test['name'].startsWith(target)) {
        print(List.generate(16, (i) => bus.ram_[cpu.pc + i].hex8).join(' '));
      }
      // print(cpu.debug());

      cpu.clocks = 0;
      if (!cpu.exec()) {
        print('test ${test['name']} failed: not implemented');
        return 1;
      }

      final expected = cpu2.debug();
      final actual = cpu.debug();

      if (expected != actual) {
        print('test ${test['name']} failed');
        print('$expected\n$actual');
        print(showDiff(expected, actual));
        return 1;
      }

      for (final mem in test['final']['ram']) {
        if (mem[1] != bus.ram_[mem[0]]) {
          print('test ${test['name']} failed');
          print(
              '$actual\nram[${(mem[0] as int).hex24}] = ${(mem[1] as int).hex8} != ${bus.ram_[mem[0] as int].hex8}');
          return 1;
        }
      }
    }
  }

  return 0;
}
