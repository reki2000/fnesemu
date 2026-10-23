import 'dart:typed_data';

import 'package:fnesemu_core/src/components/sh2/jit/translator.dart';
import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/ss/sh2/sh2.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

Iterable<JitRuntime> jitRuntimes(Core core) sync* {
  if (core is Ps && core.jit != null) yield core.jit!.rt;
  if (core is N64 && core.jit != null) yield core.jit!.rt;
  if (core is Ss) {
    for (final cpu in [core.master, core.slave]) {
      if (cpu is Sh2 && cpu.jit != null) yield cpu.jit!.rt;
    }
  }
  if (core is Md && core.expansion != null) {
    for (final cpu in core.expansion!.cpus) {
      if (cpu.jit != null) yield cpu.jit!.rt;
    }
  }
}

/// Guest-clock coverage and native round-trip size over one measured interval.
final class JitCounters {
  final int cpuClocks, jitClocks, nativeEntries;
  JitCounters(Core core)
      : cpuClocks = core.cpuClocks,
        jitClocks = core.jitClocks,
        nativeEntries =
            jitRuntimes(core).fold(0, (total, rt) => total + rt.nativeEntries);

  Map<String, Object?> since(JitCounters start) {
    final cpu = cpuClocks - start.cpuClocks;
    final native = jitClocks - start.jitClocks;
    final entries = nativeEntries - start.nativeEntries;
    return {
      'cpuClocks': cpu,
      'jitClocks': native,
      'jitCyclePercent': cpu > 0 ? 100 * native / cpu : null,
      'nativeEntries': entries,
      'meanNativeExitCycles': entries > 0 ? native / entries : null,
    };
  }
}

/// Bounded return-level diagnostics; use separately from throughput benchmarks.
final class NativeExitStats {
  final JitRuntime rt;
  final bool sh2;
  final bool n64;
  final bool macLong;
  final sites = <(int, int, String, int?, int?), _ExitCounts>{};
  final reasons = <String, _ExitCounts>{};
  final total = _ExitCounts();
  int overflow = 0;
  NativeExitStats(this.rt, {required Core core})
      : sh2 = core is Ss || core is Md,
        n64 = core is N64,
        macLong = core is Ss &&
            [core.master, core.slave].whereType<Sh2>().any((cpu) =>
                identical(cpu.jit?.rt, rt) && cpu.jit?.macLong == true) {
    rt.onNativeExit = record;
  }

  String classify(int pc, int reason, int stop, int? fault) {
    if (reason == JitReason.budget) return stop != 0 ? 'stopYield' : 'budget';
    if (reason == JitReason.invalid) return 'codeGuard';
    if (reason == JitReason.miss) return 'linkMiss';
    if (sh2 && reason == Sh2Translator.profileMiss) return 'profileGuard';
    if (sh2 && reason == Sh2Translator.idleDetected) return 'idleSkip';
    if (fault != null) {
      final page = (fault & rt.addrMask) >>> rt.pageShift;
      if (rt.readPages[page] == null) return 'unmappedOrDevice';
      if (rt.writePages[page] == null) return 'protectedOrReadOnly';
      return 'memoryExit';
    }
    if (sh2 && reason == Sh2Translator.interpret) {
      final masked = pc & rt.addrMask;
      final page = rt.readPages[masked >>> rt.pageShift];
      if (page != null) {
        final offset = page.$2 + (masked & (rt.pageBytes - 1));
        final opcode = ByteData.sublistView(page.$1).getUint16(offset);
        if (!Sh2Translator.supported(opcode, macLong: macLong))
          return 'unsupportedInstructionOrSlot';
      }
    }
    return 'guestExit';
  }

  // Read mapped instruction bytes only; diagnostics must not perform MMIO.
  int? opcodeAt(int pc) {
    final address = pc & rt.addrMask;
    final page = rt.readPages[address >>> rt.pageShift];
    final size = sh2 ? 2 : 4;
    final offset = address & (rt.pageBytes - 1);
    if (page == null || offset + size > rt.pageBytes) return null;
    final bytes = ByteData.sublistView(page.$1);
    return sh2
        ? bytes.getUint16(page.$2 + offset)
        : bytes.getUint32(page.$2 + offset, n64 ? Endian.big : Endian.little);
  }

  void record(int entryPc, int exitPc, int reason, int budget, int cycles,
      int stop, int? fault) {
    final kind = classify(exitPc, reason, stop, fault);
    total.add(budget, cycles);
    (reasons[kind] ??= _ExitCounts()).add(budget, cycles);
    final faultPage = fault == null ? null : fault & ~(rt.pageBytes - 1);
    final key = (entryPc, exitPc, kind, faultPage, opcodeAt(exitPc));
    final counts = sites[key];
    if (counts != null) {
      counts.add(budget, cycles, address: fault);
    } else if (sites.length < 4096) {
      sites[key] = _ExitCounts()..add(budget, cycles, address: fault);
    } else {
      overflow++;
    }
  }

  void clear() {
    sites.clear();
    reasons.clear();
    total.clear();
    overflow = 0;
  }

  Map<String, Object?> report() {
    final ranked = sites.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));
    return {
      ...total.report(),
      'siteOverflowEntries': overflow,
      'reasons': {for (final e in reasons.entries) e.key: e.value.report()},
      'topSites': [
        for (final e in ranked.take(40))
          {
            'entryPc': e.key.$1,
            'exitPc': e.key.$2,
            'kind': e.key.$3,
            'faultPage': e.key.$4,
            'exitOpcode': e.key.$5,
            ...e.value.report(),
          }
      ],
    };
  }
}

final class _ExitCounts {
  int count = 0, cycles = 0, zero = 0, budgets = 0;
  int? firstFaultAddress;
  int varyingAddressBits = 0;
  void add(int budget, int spent, {int? address}) {
    if (address != null) {
      firstFaultAddress ??= address;
      varyingAddressBits |= firstFaultAddress! ^ address;
    }
    count++;
    cycles += spent;
    budgets += budget;
    if (spent == 0) zero++;
  }

  void clear() {
    count = cycles = zero = budgets = varyingAddressBits = 0;
    firstFaultAddress = null;
  }

  Map<String, Object?> report() => {
        if (firstFaultAddress != null) 'firstFaultAddress': firstFaultAddress,
        if (firstFaultAddress != null) 'varyingAddressBits': varyingAddressBits,
        'count': count,
        'cycles': cycles,
        'zeroWork': zero,
        'meanCycles': count > 0 ? cycles / count : null,
        'meanEntryBudget': count > 0 ? budgets / count : null,
      };
}
