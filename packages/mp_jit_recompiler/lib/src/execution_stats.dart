/// Optional observations of CPU dispatches and their synchronous bus requests.
/// Mapped native accesses are not observed by these CPU-side counters.
final class JitExecutionStats {
  final int? Function(int pc) opcodeAt;
  final String Function(int address) regionAt;
  /// Maximum retained CPU sites and memory groups, independently.
  final int capacity;
  bool _cpuActive = false, fetching = false;
  bool get cpuActive => _cpuActive;
  int cpuDispatches = 0, cpuClocks = 0, idleClocks = 0;
  int cpuSiteOverflow = 0, memorySiteOverflow = 0;
  int memoryRequests = 0, memoryBytes = 0;
  final _cpu = <(int, int?), _CpuCounts>{};
  final _memory = <(String, String, int), int>{};

  JitExecutionStats({
    required this.opcodeAt,
    required this.regionAt,
    this.capacity = 4096,
  }) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  void beginCpuStep() => _cpuActive = true;
  void endCpuStep() {
    _cpuActive = false;
    fetching = false;
  }

  void pauseCpuStep() => _cpuActive = false;
  void resumeCpuStep() => _cpuActive = true;

  /// A dispatch can service an interrupt instead of executing the selected opcode.
  void recordCpuStep(int pc, int? opcode, int clocks) {
    final elapsed = clocks < 0 ? 0 : clocks;
    cpuDispatches++;
    cpuClocks += elapsed;
    final key = (pc, opcode);
    final counts = _cpu[key];
    if (counts != null) {
      counts.count++;
      counts.clocks += elapsed;
    } else if (_cpu.length < capacity) {
      _cpu[key] = _CpuCounts(1, elapsed);
    } else {
      cpuSiteOverflow++;
    }
  }

  void recordIdle(int clocks) {
    if (clocks > 0) idleClocks += clocks;
  }

  /// Counts requests made during CPU dispatch, including synchronous side effects.
  /// Instruction fetches are separate from data reads and compiler inspection.
  void recordMemory(
    int address,
    int size, {
    bool write = false,
    bool fetch = false,
  }) {
    if (!_cpuActive || fetching && !fetch) return;
    memoryRequests++;
    memoryBytes += size;
    final kind = fetch
        ? 'fetch'
        : write
        ? 'write'
        : 'read';
    final key = (kind, regionAt(address), size);
    final count = _memory[key];
    if (count != null) {
      _memory[key] = count + 1;
    } else if (_memory.length < capacity) {
      _memory[key] = 1;
    } else {
      memorySiteOverflow++;
    }
  }

  void clear() {
    cpuDispatches = cpuClocks = idleClocks = 0;
    cpuSiteOverflow = memorySiteOverflow = 0;
    memoryRequests = memoryBytes = 0;
    _cpu.clear();
    _memory.clear();
  }

  Map<String, Object?> report() {
    final ranked = _cpu.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));
    return {
      'cpuDispatches': cpuDispatches,
      'cpuClocks': cpuClocks,
      'idleClocks': idleClocks,
      'cpuSiteOverflow': cpuSiteOverflow,
      'memorySiteOverflow': memorySiteOverflow,
      'memoryScope': 'cpuDispatchBusRequests',
      'memoryRequests': memoryRequests,
      'memoryBytes': memoryBytes,
      'topCpuSites': [
        for (final e in ranked.take(40))
          {
            'pc': e.key.$1,
            'opcode': e.key.$2,
            'count': e.value.count,
            'clocks': e.value.clocks,
          },
      ],
      'memory': [
        for (final e in _memory.entries)
          {
            'kind': e.key.$1,
            'region': e.key.$2,
            'size': e.key.$3,
            'count': e.value,
            'bytes': e.value * e.key.$3,
          },
      ],
    };
  }
}

final class _CpuCounts {
  int count, clocks;
  _CpuCounts(this.count, this.clocks);
}
