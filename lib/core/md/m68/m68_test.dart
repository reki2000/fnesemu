import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fnesemu/core/md/m68/m68_debug.dart';
import 'package:fnesemu/core/md/m68/op.dart';
import 'package:fnesemu/util/int.dart';

import '../bus_m68.dart';
import 'm68.dart';

class BusM68Test extends BusM68 {
  final ram_ = List<int>.filled(0x1000000, 0xff);

  late M68 cpu;

  BusM68Test();

  @override
  int read(int addr) {
    return ram_[addr.mask24];
  }

  @override
  void write(int addr, int data) {
    ram_[addr.mask24] = data.mask8;
  }
}

void loadTest(json, M68 cpu) {
  for (int i = 0; i < 8; i++) {
    if (i < 7) cpu.a[i] = json["a$i"];
    cpu.d[i] = json["d$i"];
  }
  cpu.ssp = json['ssp'];
  cpu.sf = true; // set a7 as ssp
  cpu.usp = json['usp'];
  cpu.sf = false; // set a7 as usp

  cpu.pc = json['pc'];
  cpu.sr = json['sr'];
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

  //final opMap = loadMap();

  final directory = Directory('assets/680x0/68000/v1');
  final jsonGzFiles = directory
      .listSync()
      .where((file) => file is File && file.path.endsWith('.json.gz'))
      .cast<File>();

  final skipFiles = [
    "A", "B", "C", "D", "E", "J", "L", "M", "N", "O", "P", "R", "S" //
  ];
  final selectFiles = []; //"Bcc", "BSR", "JMP"];
  final skipTests = [];

  // https://github.com/SingleStepTests/ProcessorTests/issues/21
  final knownBugs = ["e502"];

  for (final file in jsonGzFiles) {
    final isSkipFile = skipFiles
        .any((element) => file.uri.pathSegments.last.startsWith(element));
    final isNotSelected = selectFiles.isEmpty ||
        !selectFiles
            .any((element) => file.uri.pathSegments.last.startsWith(element));

    if (isSkipFile && isNotSelected) {
      continue;
    }

    print('${file.path}: running...');

    final uncompressedData = GZipDecoder().decodeBytes(file.readAsBytesSync());
    final tests = json.decode(utf8.decode(uncompressedData));

    for (final test in tests) {
      debugLog = "";

      if ([...knownBugs, ...skipTests].contains(test['name'].substring(0, 4))) {
        continue;
      }

      loadTest(test['initial'], cpu);
      // print(cpu.debug());
      loadTest(test['final'], cpu2);
      cpu2.clocks = test['length'];

      int prevAddr = 0;
      bool error = false;

      String memStr = "";
      for (final mem in test['initial']['ram'].toList()
        ..sort((a, b) => (a[0] as int) - (b[0] as int))) {
        final addr = mem[0] as int;
        final val = mem[1] as int;
        bus.ram_[addr] = val;
        final addrStr = addr == (prevAddr + 1) ? "" : "${addr.hex24}: ";
        prevAddr = addr;
        memStr += "$addrStr${val.hex8} ";
      }
      debug(memStr);

      // set memory at pc
      int i = 0;
      for (final val in test['initial']['prefetch']) {
        bus.ram_[cpu.pc + i++] = val >> 8;
        bus.ram_[cpu.pc + i++] = val & 0xff;
      }

      // dump memory at pc
      debug(
          "${cpu.pc.hex24}: ${List.generate(16, (i) => bus.ram_[cpu.pc + i].hex8).join(' ')}");

      // check executed result
      cpu.clocks = 0;
      if (!cpu.exec()) {
        debug('test ${test['name']} failed: not implemented');
        error = true;
      }

      if (cpu.pc == 0x1400) {
        continue; // skip bus error
      }

      final expected = cpu2.debug().substring(0, 207);
      final actual = cpu.debug().substring(0, 207);

      if (expected != actual) {
        debug('$expected\n$actual');
        debug(showDiff(expected, actual));
        error = true;
      }

      // check memory
      String memExpect = "";
      String memActual = "";
      for (final mem in test['final']['ram'].toList()
        ..sort((a, b) => (a[0] as int) - (b[0] as int))) {
        final addr = mem[0] as int;
        final val = mem[1] as int;
        final matched = val == bus.ram_[addr];
        final addrStr = addr == (prevAddr + 1) ? "" : "${addr.hex24}:";
        prevAddr = addr;
        memExpect += '$addrStr${val.hex8} ';
        memActual += '$addrStr${bus.ram_[addr].hex8} ';

        if (!matched) {
          error = true;
        }
      }

      if (error) {
        debug(memExpect);
        debug(memActual);
        debug(showDiff(memExpect, memActual));
      }

      // show result
      if (error) {
        print('\ntest ${test['name']} failed');
        print(debugLog);
        print(convertIntegersToHex(test));
        return 1;
      }
    }
  }

  return 0;
}

dynamic convertIntegersToHex(dynamic input) {
  if (input is Map) {
    return input
        .map((key, value) => MapEntry(key, convertIntegersToHex(value)));
  } else if (input is List) {
    return input.map(convertIntegersToHex).toList();
  } else if (input is int) {
    return input.hex32;
  } else {
    return input;
  }
}

class Mem {
  final int addr;
  final int val;
  Mem(this.addr, this.val);
}
