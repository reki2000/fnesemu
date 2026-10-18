import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/src/components/m68k/bus.dart';
import 'package:fnesemu_core/src/components/m68k/cpu.dart';
import 'package:fnesemu_core/src/components/m68k/debug.dart';
import 'package:fnesemu_core/src/util/int.dart';

import 'logging.dart';

class BusM68Test implements M68Bus {
  final ram_ = List<int>.filled(0x1000000, 0xff);

  BusM68Test();

  @override
  int read8(int addr) {
    return ram_[addr.mask24];
  }

  @override
  int read16(int addr) {
    return read8(addr).shl8 | read8(addr.inc);
  }

  @override
  void write8(int addr, int data) {
    ram_[addr.mask24] = data.mask8;
  }

  @override
  void write16(int addr, int data) {
    write8(addr, data.shr8);
    write8(addr.inc, data);
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

// ASR by a register count larger than the operand size, on a negative operand:
// the vectors clear X and C, while the 68000 sets them to the last bit shifted out (the sign bit),
// as the manual describes and as a run of the vectors on hardware shows (transistorfet/68k-test-runner)
bool _asrBeyondSize(Map test) {
  final initial = test['initial'];
  final int op = initial['prefetch'][0];
  final size = op.shr6.mask2;
  if (op & 0xf138 != 0xe020 || size == 3) {
    return false;
  }
  final bits = 8 << size;
  final int count = initial['d${op.shr9.mask3}'];
  final int value = initial['d${op.mask3}'];
  return count.mask6 > bits && (value >> (bits - 1)) & 1 == 1;
}

// args[0]: the 68000/v1 directory of SingleStepTests/680x0
int main(List<String> args) {
  configureLogging();
  final bus = BusM68Test();
  final cpu = M68(bus);
  cpu.bus = bus;

  final cpu2 = M68(bus);

  final directory = Directory(args[0]);
  final failures = <String, (int, int)>{};
  final jsonGzFiles = directory
      .listSync()
      .where((file) => file is File && file.path.endsWith('.json.gz'))
      .cast<File>();

  final skipFiles = [];
  final selectFiles = [];
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

    stdout.writeln('${file.path}: running...');

    final uncompressedData = GZipDecoder().decodeBytes(file.readAsBytesSync());
    final tests = json.decode(utf8.decode(uncompressedData));
    int failed = 0;

    for (final test in tests) {
      debugLog = "";

      if ([...knownBugs, ...skipTests].contains(test['name'].substring(0, 4)) ||
          _asrBeyondSize(test)) {
        continue;
      }

      loadTest(test['initial'], cpu);
      // stdout.writeln(cpu.debug());
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
        final addrStr = addr == (prevAddr + 1) ? "" : "${addr.x6}: ";
        prevAddr = addr;
        memStr += "$addrStr${val.x2} ";
      }
      debug(memStr);

      // set memory at pc
      int i = 0;
      for (final int val in test['initial']['prefetch']) {
        bus.ram_[cpu.pc + i++] = val.shr8;
        bus.ram_[cpu.pc + i++] = val & 0xff;
      }

      // dump memory at pc
      debug(
          "${cpu.pc.x6}: ${List.generate(16, (i) => bus.ram_[cpu.pc + i].x2).join(' ')}");

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
      // final expected = cpu2.debug();
      // final actual = cpu.debug();
      // stdout.writeln(expected);

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
        final addrStr = addr == (prevAddr + 1) ? "" : "${addr.x6}:";
        prevAddr = addr;
        memExpect += '$addrStr${val.x2} ';
        memActual += '$addrStr${bus.ram_[addr].x2} ';

        if (!matched) {
          error = true;
        }
      }

      if (error) {
        debug(memExpect);
        debug(memActual);
        debug(showDiff(memExpect, memActual));
      }

      // show the first failure of each file and keep running the rest
      if (error) {
        if (failed++ == 0) {
          stdout.writeln('\ntest ${test['name']} failed');
          stdout.writeln(debugLog);
          stdout.writeln(convertIntegersToHex(test));
        }
      }
    }

    if (failed > 0) {
      failures[file.uri.pathSegments.last] = (failed, tests.length);
    }
  }

  if (failures.isEmpty) {
    stdout.writeln('all tests passed');
    return 0;
  }
  stdout.writeln('\nfailed tests:');
  for (final MapEntry(:key, :value) in failures.entries) {
    stdout.writeln('  $key: ${value.$1}/${value.$2}');
  }
  exitCode = 1;
  return 1;
}

dynamic convertIntegersToHex(dynamic input) {
  if (input is Map) {
    return input
        .map((key, value) => MapEntry(key, convertIntegersToHex(value)));
  } else if (input is List) {
    return input.map(convertIntegersToHex).toList();
  } else if (input is int) {
    return input.x8;
  } else {
    return input;
  }
}

class Mem {
  final int addr;
  final int val;
  Mem(this.addr, this.val);
}

String debugLog = "";
void debug(args) => debugLog += "$args\n";
