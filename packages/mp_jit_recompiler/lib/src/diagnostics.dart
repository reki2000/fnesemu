import 'dart:typed_data';

import 'compilation_stats.dart';
import 'execution_stats.dart';
import 'ir.dart';
import 'runtime.dart';

/// Frontend-owned instruction and exit metadata for one runtime.
/// Instruction inspection reads existing mappings only and never calls the bus.
final class JitDiagnostics {
  final JitRuntime rt;
  final int instructionBytes;
  final Endian byteOrder;
  final String? Function(int pc, int reason)? guestExit;
  String Function(int address)? memoryRegion;
  JitExecutionStats? _executionStats;
  JitExecutionStats? get executionStats => _executionStats;
  JitCompilationStats? get compilationStats => rt.compilationStats;

  JitCompilationStats enableCompilationStats({int capacity = 4096}) =>
      rt.compilationStats = JitCompilationStats(capacity: capacity);

  void disableCompilationStats() => rt.compilationStats = null;

  void Function(JitExecutionStats?)? _bindExecutionStats;

  /// Connects one CPU adapter and immediately supplies the current recorder.
  void bindExecutionStats(void Function(JitExecutionStats?) bind) {
    _bindExecutionStats = bind;
    bind(_executionStats);
  }

  JitExecutionStats enableExecutionStats({int capacity = 4096}) {
    final stats = JitExecutionStats(
      opcodeAt: opcodeAt,
      regionAt: (address) => memoryRegion?.call(address) ?? 'unknown',
      capacity: capacity,
    );
    _executionStats = stats;
    _bindExecutionStats?.call(stats);
    return stats;
  }

  void disableExecutionStats() {
    _executionStats = null;
    _bindExecutionStats?.call(null);
  }

  JitDiagnostics(
    this.rt, {
    required this.instructionBytes,
    required this.byteOrder,
    this.guestExit,
  }) {
    if (instructionBytes != 2 && instructionBytes != 4) {
      throw ArgumentError.value(instructionBytes, 'instructionBytes');
    }
  }

  int? opcodeAt(int pc) {
    final address = pc & rt.addrMask;
    final offset = address & (rt.pageBytes - 1);
    final page = rt.readPages[address >>> rt.pageShift];
    if (page == null ||
        address & (instructionBytes - 1) != 0 ||
        offset + instructionBytes > rt.pageBytes) {
      return null;
    }
    final at = page.$2 + offset;
    if (at < 0 || at + instructionBytes > page.$1.length) return null;
    final bytes = ByteData.sublistView(page.$1);
    return instructionBytes == 2
        ? bytes.getUint16(at, byteOrder)
        : bytes.getUint32(at, byteOrder);
  }

  String classify(int pc, int reason, int stop, int? fault) {
    if (reason == JitReason.budget) return stop != 0 ? 'stopYield' : 'budget';
    if (reason == JitReason.invalid) return 'codeGuard';
    if (reason == JitReason.miss) return 'linkMiss';
    final guest = guestExit?.call(pc, reason);
    if (guest != null) return guest;
    if (fault != null) {
      final page = (fault & rt.addrMask) >>> rt.pageShift;
      if (rt.readPages[page] == null) return 'unmappedOrDevice';
      if (rt.writePages[page] == null) return 'protectedOrReadOnly';
      return 'memoryExit';
    }
    return 'guestExit';
  }
}

/// Bounded return-level diagnostics; use separately from throughput benchmarks.
final class NativeExitStats {
  final JitDiagnostics diagnostics;
  JitRuntime get rt => diagnostics.rt;
  final sites = <(int, int, String, int?, int?), _ExitCounts>{};
  final reasons = <String, _ExitCounts>{};
  final total = _ExitCounts();
  int overflow = 0;
  NativeExitStats(this.diagnostics) {
    rt.onNativeExit = record;
  }

  void record(
    int entryPc,
    int exitPc,
    int reason,
    int budget,
    int cycles,
    int stop,
    int? fault,
  ) {
    final kind = diagnostics.classify(exitPc, reason, stop, fault);
    total.add(budget, cycles);
    (reasons[kind] ??= _ExitCounts()).add(budget, cycles);
    final faultPage = fault == null ? null : fault & ~(rt.pageBytes - 1);
    final key = (
      entryPc,
      exitPc,
      kind,
      faultPage,
      diagnostics.opcodeAt(exitPc),
    );
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
          },
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
