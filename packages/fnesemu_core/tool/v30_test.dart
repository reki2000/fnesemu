// Diagnostic tools intentionally inspect core internals.
// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ws/v30mz/v30mz.dart';

/// runs the V30MZ against the 8088 tests of SingleStepTests
/// (https://github.com/SingleStepTests/8088) for the instructions which
/// behave the same on both CPUs.
///
/// usage: dart run tool/v30_test.dart metadata.json XX.json.gz ...
class _Bus implements V30Bus {
  final mem = Uint8List(0x100000);
  @override
  int read8(int addr) => mem[addr];
  @override
  void write8(int addr, int data) => mem[addr] = data;
  @override
  int input8(int port) => 0xff;
  @override
  void output8(int port, int data) {}
}

const _regs = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"];
const _segs = ["es", "cs", "ss", "ds"];

void main(List<String> args) {
  final metadata =
      jsonDecode(File(args[0]).readAsStringSync())['opcodes'] as Map;
  var failedFiles = 0;
  for (final path in args.skip(1)) {
    final name = path.split('/').last.replaceAll('.json.gz', '');
    final parts = name.split('.');
    var meta = metadata[parts[0]] as Map;
    if (parts.length > 1) meta = (meta['reg'] as Map)[parts[1]] as Map;
    final mask = meta['flags-mask'] as int? ?? 0xffff;
    final tests =
        jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())))
            as List;

    var failures = 0;
    String? first;
    for (final test in tests) {
      final bus = _Bus();
      final cpu = V30mz(bus);
      final initial = test['initial'] as Map;
      final regs = initial['regs'] as Map;
      for (var i = 0; i < 8; i++) {
        cpu.r[i] = regs[_regs[i]] as int;
      }
      for (var i = 0; i < 4; i++) {
        cpu.s[i] = regs[_segs[i]] as int;
      }
      cpu.ip = regs['ip'] as int;
      cpu.flags = regs['flags'] as int;
      for (final e in initial['ram'] as List) {
        bus.mem[e[0] as int] = e[1] as int;
      }

      cpu.exec();

      final expected = test['final'] as Map;
      final errors = <String>[];
      final finalRegs = expected['regs'] as Map;
      for (final MapEntry(:key, :value) in finalRegs.entries) {
        final int actual;
        var m = 0xffff;
        if (key == 'ip') {
          actual = cpu.ip;
        } else if (key == 'flags') {
          actual = cpu.flags;
          m = mask;
        } else if (_regs.contains(key)) {
          actual = cpu.r[_regs.indexOf(key)];
        } else {
          actual = cpu.s[_segs.indexOf(key)];
        }
        if (actual & m != (value as int) & m) {
          errors.add(
              "$key:${actual.toRadixString(16)}!=${value.toRadixString(16)}");
        }
      }
      // registers which are not listed must not change
      for (var i = 0; i < 8; i++) {
        if (!finalRegs.containsKey(_regs[i]) && cpu.r[i] != regs[_regs[i]]) {
          errors.add("${_regs[i]} changed");
        }
      }
      for (final e in expected['ram'] as List) {
        if (bus.mem[e[0] as int] != e[1]) {
          errors.add("[${(e[0] as int).toRadixString(16)}]:"
              "${bus.mem[e[0] as int].toRadixString(16)}!=${(e[1] as int).toRadixString(16)}");
        }
      }
      if (errors.isNotEmpty) {
        failures++;
        first ??= "${test['name']} ${errors.join(' ')}";
      }
    }
    if (failures > 0) failedFiles++;
    print(
        "$name: ${failures == 0 ? "ok" : "$failures/${tests.length} failed: $first"}");
  }
  exit(failedFiles == 0 ? 0 : 1);
}
