import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import 'types.dart';
import 'video_debug.dart';

/// Debugging data supplied by a core, independent of execution and media I/O.
/// Unsupported inspection features default to empty output.
class CoreDebug {
  /// Available runtime diagnostics in CPU order; empty without recompilation.
  Iterable<JitDiagnostics> get jitDiagnostics => const [];

  /// Whether the loaded core uses an available JIT backend.
  bool get jitEnabled => false;

  /// Whether an available JIT backend is suspended: the CPU interpreter runs
  /// on the same shared guest state and compiled blocks are kept.
  bool get jitSuspended => false;
  set jitSuspended(bool value) {}

  /// Cumulative guest CPU clocks and the subset executed by compiled code.
  int get cpuClocks => 0;
  int get jitClocks => 0;

  bool get hasPatternTables => false;
  List<DebugVideoLayer> get videoLayers => const [];
  List<DebugPatternTable> get patternTables => const [];

  List<CpuInfo> get cpuInfos => const [];

  /// debug: returns the emulator's internal status report
  String dump(
          {bool showZeroPage = false,
          bool showSpriteVram = false,
          bool showStack = false,
          bool showApu = false}) =>
      "";

  /// Debug: returns assembler text and instruction length in bytes.
  (String, int) disasm(int cpuNo, int addr) => ("", 0);

  // debug: returns PC register
  int programCounter(int cpuNo) => 0;

  // debug: returns SP register
  int stackPointer(int cpuNo) => 0;

  // debug: returns tracing CPU state - disassembed next instruction and current registers
  TraceLog trace(int cpuNo) => TraceLog(0, 0, "", "", const []);

  // debug: dump vram
  List<int> get vram => const [];

  // debug: read mem
  int read(int cpuNo, int addr) => 0;

  // debug: dump vram
  ImageBuffer renderBg() => ImageBuffer.empty();
  List<String> spriteInfo() => const [];
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();
}
