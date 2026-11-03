import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core_module.dart';
import 'package:fnesemu_core/src/internal/core_registry.dart';
import 'package:fnesemu_core/src/internal/core_registry_generated.dart';
import 'package:fnesemu_core/src/util/debug.dart';
import 'package:test/test.dart';

class _Core extends Core {
  int pc = 0, sp = 100, clocks = 0, instructions = 0, frames = 0;
  int? stopAt;
  int traceCalls = 0;
  bool otherCpuFirst = false;
  void Function()? afterInstruction;
  int clockHz = 1000000;

  @override
  int get clocksPerFrame => clocksInScanline * scanlinesInFrame;

  @override
  int get systemClockHz => clockHz;
  @override
  int get scanlinesInFrame => 3;
  @override
  int get clocksInScanline => 2;
  @override
  List<CpuInfo> get cpuInfos =>
      const [CpuInfo(7, 'main', 16), CpuInfo(3, 'other', 16)];
  @override
  void reset() {
    pc = clocks = instructions = frames = 0;
    debugStatus.clock = 0;
    sp = 100;
  }

  @override
  void setRom(Uint8List body) {}
  @override
  ExecResult exec(bool step) {
    instructions++;
    clocks++;
    debugStatus.clock = clocks;
    final cpu = otherCpuFirst && instructions == 1 ? 3 : 7;
    if (cpu == 7) pc += 4;
    afterInstruction?.call();
    return ExecResult(
        clocks, stopAt != null && instructions >= stopAt!, instructions.isEven)
      ..executed0 = false
      ..setExecuted(cpu, true);
  }

  @override
  ExecResult runFrame(int scanlines) {
    frames++;
    return super.runFrame(scanlines);
  }

  @override
  int programCounter(int cpuNo) => cpuNo == 7 ? pc : 0;
  @override
  int stackPointer(int cpuNo) => sp;
  @override
  (String, int) disasm(int cpuNo, int address) => ('nop', 4);
  @override
  int read(int cpuNo, int address) => cpuNo;
  @override
  TraceLog trace(int cpuNo) {
    traceCalls++;
    return TraceLog(pc, clocks, 'nop', 'pc:$pc', [pc]);
  }
}

class _Module extends CoreModule {
  final _Core core;
  _Module(this.core);
  @override
  List<CoreSystem> get systems =>
      const [CoreSystem('test', 'test', extensions: [])];
  @override
  Core create(String id) => core;
  @override
  CoreSystem? identifyRom(String name, Uint8List body) => null;
}

void main() {
  late _Core core;
  late CoreController controller;
  late CoreControllerState controllerState;
  late Debugger debugger;

  setUp(() async {
    core = _Core();
    registerCoreModules([_Module(core)]);
    controller = CoreController(
        (state) => controllerState = state, (_) {}, (_) {}, Sram());
    await controller.init('test', rom: Uint8List(1));
    debugger = controller.debugger;
  });
  tearDown(() async {
    await controller.stop();
    registerCoreModules(createInstalledCoreModules());
  });

  for (final rate in [50, 75]) {
  }

  test(
      'step waits for the advertised CPU identity and clears its temporary stop',
      () async {
    core.otherCpuFirst = true;
    await debugger.step();
    expect(core.instructions, 2);
    expect(core.pc, 4);
    expect(debugger.state.targetCpuNo, 7);
    expect(core.frames, 0);
    await debugger.step();
    expect(core.instructions, 3);
  });

  test('a breakpoint works even when the debug view is hidden', () async {
    debugger.setBreakPoint(12);
    expect(debugger.state.showDebugView, false);
    await controller.run();
    expect(core.pc, 12);
    expect(core.frames, 0);
  });

  test('pause and run use execution callbacks and clear temporary stepping',
      () async {
    await debugger.step();
    await debugger.pause();
    expect(controllerState.running, false);
    expect(debugger.state.running, false);
    expect(debugger.stepInstructions, false);
    final running = debugger.run();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(controllerState.running, true);
    expect(debugger.state.running, true);
    await debugger.pause();
    await running;
    expect(controllerState.running, false);
    expect(debugger.state.running, false);
  });

}
