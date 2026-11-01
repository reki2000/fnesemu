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

  @override
  int get systemClockHz => 1000000;
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

  test('normal execution caps fast cores at 60 frames per second', () async {
    var frames = 0;
    var measuring = false;
    controller = CoreController((_) {}, (_) {}, (_) {
      if (!measuring) return;
      if (++frames == 8) unawaited(controller.stop());
    }, Sram());
    await controller.init('test', rom: Uint8List(1));
    final watch = Stopwatch()..start();
    measuring = true;
    await controller.run();
    watch.stop();
    expect(frames, 8);
    expect(watch.elapsedMicroseconds, greaterThanOrEqualTo(8 * 16667));
  });

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

  test(
      'next preserves persistent breakpoint and normal resume clears temporary target',
      () async {
    debugger.setBreakPoint(40);
    await debugger.next();
    expect(core.pc, 4);
    expect(debugger.state.breakPoint, 40);
    await controller.run();
    expect(core.pc, 40);
    expect(debugger.state.breakPoint, 40);
  });

  test('step out captures SP internally and pauses when it rises', () async {
    core.afterInstruction = () {
      if (core.instructions == 2) core.sp = 104;
    };
    await debugger.stepOut();
    expect(core.instructions, 2);
    expect(debugger.state.breakPoint, -1);
    await debugger.step();
    expect(core.instructions, 3);
  });

  test('line and frame operations retain the position after a partial line',
      () async {
    await debugger.step();
    expect(core.instructions, 1);
    await debugger.runToLine();
    expect(core.instructions, 2);
    await debugger.runToFrame();
    expect(core.instructions, 6);
    await debugger.runToFrame();
    expect(core.instructions, 12);
  });

  test('ordinary execution retains the optimized frame route', () async {
    core.stopAt = 6;
    await controller.run();
    expect(core.frames, 1);
    expect(core.instructions, 6);
  });

  test('a breakpoint works even when the debug view is hidden', () async {
    debugger.setBreakPoint(12);
    expect(debugger.state.showDebugView, false);
    await controller.run();
    expect(core.pc, 12);
    expect(core.frames, 0);
  });

  test('clock stops fire once and reset rearms the persistent setting',
      () async {
    debugger.setBreakClock(3);
    await controller.run();
    expect(core.instructions, 3);
    expect(debugger.state.breakClock, 3);
    core.stopAt = 6;
    await controller.run();
    expect(core.instructions, 6);
    await controller.reset();
    await controller.run();
    expect(core.instructions, 3);
  });

  test('explicit controller stop cancels an operation awaiting execution',
      () async {
    final pending = debugger.next();
    await controller.stop();
    await pending;
    expect(core.instructions, 0);
    expect(debugger.needsInstructionLoop, false);
  });

  test('stream events remain distinct immutable settings snapshots', () async {
    final events = debugger.debugStream.take(2).toList();
    await Future<void>.delayed(Duration.zero);
    debugger.setBreakPoint(24);
    final snapshots = await events.timeout(const Duration(seconds: 1));
    expect(snapshots[0].breakPoint, -1);
    expect(snapshots[1].breakPoint, 24);
    expect(identical(snapshots[0], snapshots[1]), false);
  });

  test('state notifications and nested collections are immutable snapshots',
      () async {
    debugger.setDebugView(true);
    final before = debugger.state;
    debugger.selectCpu(3);
    debugger.setMemoryAddress(0x10002);
    expect(before.targetCpuNo, 7);
    expect(before.memAddress, 0);
    expect(debugger.state.targetCpuNo, 3);
    expect(debugger.state.memAddress, 2);
    expect(debugger.read(0), 3);
    expect(() => before.disasmAddress.add(1), throwsUnsupportedError);
    expect(() => before.traceLog.add('line'), throwsUnsupportedError);
    expect(() => debugger.selectCpu(0), throwsStateError);
  });

  test('trace can be disabled, enabled again and cleared through methods',
      () async {
    debugger.setLogEnabled(true);
    await debugger.step();
    expect(debugger.state.traceLog, isNotEmpty);
    final previous = debugger.state;
    debugger.setLogEnabled(false);
    debugger.setLogEnabled(true);
    await debugger.step();
    expect(debugger.state.traceLog.length,
        lessThanOrEqualTo(previous.traceLog.length));
    debugger.clearLog();
    expect(debugger.state.traceLog, isEmpty);
    expect(previous.traceLog, isNotEmpty);
    await debugger.step();
    expect(debugger.state.traceLog, isNotEmpty);
  });

  test('stopping trace flushes statistics and Copy does not duplicate it', () {
    debugger.setLogEnabled(true);
    for (var i = 0; i < 20; i++) {
      core.clocks = i;
      debugger.recordTrace();
      debugger.completeTrace(ExecResult(i, false, false)
        ..executed0 = false
        ..setExecuted(7, true));
    }
    debugger.executionStopped();
    final text = debugger.traceText();
    expect(text, contains('period:1 iterations:20'));
    expect(text, contains('skipped 19 lines'));
    expect(text, contains('cl:0..19'));
    expect(debugger.traceText(), text);
  });

  test('log OFF discards pending capture and restores execution flags',
      () async {
    debugger.startTrace();
    await debugger.step();
    expect(debugger.state.traceLog, isNotEmpty);
    debugger.recordTrace();
    final traceCalls = core.traceCalls;
    debugger.setLogEnabled(false);
    expect(debugger.state.traceLog, isEmpty);
    expect(debugger.logEnabled, false);
    expect(debugger.stepInstructions, false);
    debugger.completeTrace(ExecResult(1, false, false)..setExecuted(7, true));
    await debugger.step();
    expect(core.traceCalls, traceCalls);
    expect(debugger.state.traceLog, isEmpty);
    debugger.startTrace();
    await debugger.step();
    expect(core.traceCalls, traceCalls + 1);
    expect(debugger.state.traceLog, hasLength(1));
  });

  test(
      'trace refreshes after an interrupt-only PC change and preserves idle capture',
      () {
    debugger.setLogEnabled(true);
    debugger.recordTrace();
    expect(core.traceCalls, 1);
    final idle = ExecResult(1, false, false)..executed0 = false;
    debugger.completeTrace(idle);
    expect(core.traceCalls, 1);
    core.pc = 0x100;
    debugger.completeTrace(idle);
    expect(core.traceCalls, 2);
    core.pc += 4;
    debugger.completeTrace(ExecResult(1, false, false)..setExecuted(7, true));
    debugger.executionStopped();
    final text = debugger.traceText();
    expect(text, contains('pc:256'));
    expect(text, isNot(contains('pc:0 ')));
  });

  test('hiding debug view stops logging and drops all capture state', () async {
    debugger.setDebugView(true);
    debugger.startTrace();
    await debugger.step();
    expect(debugger.state.traceLog, isNotEmpty);
    final traceCalls = core.traceCalls;
    debugger.setDebugView(false);
    expect(debugger.logEnabled, false);
    expect(debugger.state.traceLog, isEmpty);
    expect(debugger.needsInstructionLoop, false);
    await debugger.step();
    expect(core.traceCalls, traceCalls);
    expect(debugger.state.traceLog, isEmpty);
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

  test(
      'pending commands are superseded and explicit stop cancels a waiting operation',
      () async {
    final stopped = Completer<void>();
    int runs = 0;
    final waiting = Debugger(core,
        onStop: () => stopped.future,
        onRun: () async {
          runs++;
        });
    final first = waiting.step();
    final second = waiting.next();
    waiting.cancelExecution();
    stopped.complete();
    await Future.wait([first, second]);
    expect(runs, 0);
  });

  test('next reads PC after the execution loop has stopped', () async {
    late Debugger waiting;
    waiting = Debugger(core, onStop: () async {
      core.pc = 16;
    }, onRun: () async {
      final result = core.exec(true);
      expect(core.pc, 20);
      expect(waiting.shouldPause(result, 0), true);
    });
    await waiting.next();
  });
}
