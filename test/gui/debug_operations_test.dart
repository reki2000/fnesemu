import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/debug/debug_controller.dart';
import 'package:fnesemu/gui/debug/debug_pane.dart';
import 'package:fnesemu/gui/debug/disasm.dart';
import 'package:fnesemu/gui/debug/mem.dart';
import 'package:fnesemu_core/app_api.dart';

class _DebugCore extends CoreDebug {
  @override
  List<CpuInfo> get cpuInfos =>
      const [CpuInfo(7, 'Main CPU', 16), CpuInfo(3, 'Other CPU', 32)];
  final reads = <int>[];
  @override
  int programCounter(int cpuNo) => cpuNo * 256;
  @override
  (String, int) disasm(int cpuNo, int address) => ('CPU $cpuNo at $address', 1);
  @override
  int read(int cpuNo, int address) {
    reads.add(cpuNo);
    return cpuNo;
  }
}

class _Debugger extends Debugger {
  final calls = <String>[];
  final _DebugCore core;
  _Debugger._(this.core) : super(core);
  factory _Debugger() => _Debugger._(_DebugCore());
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> run() async => calls.add('run');
  @override
  Future<void> step() async => calls.add('step');
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> stepOut() async => calls.add('stepOut');
  @override
  Future<void> runToLine() async => calls.add('line');
  @override
  Future<void> runToFrame() async => calls.add('frame');
}

class _Controller extends CoreController {
  final _testDebugger = _Debugger();
  _Controller() : super((_) {}, (_) {}, (_) {}, Sram());
  @override
  _Debugger get debugger => _testDebugger;
  @override
  Future<void> run() async => fail('UI must use debugger operations');
}

void main() {
  testWidgets('debug buttons invoke methods and CPU selection updates the view',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _Controller();
    controller.debugger.setBreakPoint(40);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DebugPane(
                debugger: controller.debugger, controller: controller))));
    controller.debugger.setDebugView(true);
    await tester.pump();
    await tester.pump();
    expect(
        tester
            .widgetList<IconButton>(find.byType(IconButton))
            .firstWhere((button) => button.tooltip == 'Pause (F4)')
            .onPressed,
        isNull);
    for (final label in [
      'Run (F5)',
      'Step (F6)',
      'StepOut (F7)',
      'Next (F8)',
      'Frame (F9)',
      'Line (F10)'
    ]) {
      await tester.tap(find.byTooltip(label));
      await tester.pump();
    }
    controller.debugger.executionStarted();
    await tester.pump();
    await tester.tap(find.byTooltip('Pause (F4)'));
    controller.debugger.executionStopped();
    await tester.pump();
    expect(controller.debugger.calls,
        ['run', 'step', 'stepOut', 'next', 'frame', 'line', 'pause']);
    expect(controller.debugger.state.breakPoint, 40);
    expect(tester.getRect(find.byType(DebugExecutionControls)).right,
        lessThanOrEqualTo(tester.getRect(find.text('CPU')).left));
    expect(tester.getTopLeft(find.text('CPU')).dx,
        lessThan(tester.getTopLeft(find.text('ViewPort')).dx));

    expect(find.text('Main CPU'), findsOneWidget);
    expect(find.text('Other CPU'), findsOneWidget);
    expect(tester.widget<DebugDisasm>(find.byType(DebugDisasm)).cpuNo, 7);
    expect(tester.widget<MemPane>(find.byType(MemPane)).cpuNo, 7);
    expect(tester.getRect(find.byType(MemPane)).left,
        greaterThanOrEqualTo(tester.getRect(find.byType(DebugDisasm)).right));
    controller.debugger.core.reads.clear();
    await tester.tap(find.text('Other CPU'));
    await tester.pump();
    expect(find.text('Other CPU'), findsOneWidget);
    expect(controller.debugger.state.targetCpuNo, 3);
    expect(tester.widget<DebugDisasm>(find.byType(DebugDisasm)).cpuNo, 3);
    expect(tester.widget<MemPane>(find.byType(MemPane)).cpuNo, 3);
    expect(controller.debugger.core.reads, isNotEmpty);
    expect(controller.debugger.core.reads.every((cpu) => cpu == 3), true);
    final memory = find.descendant(
        of: find.byType(MemPane), matching: find.byType(SelectableText));
    expect(tester.widget<SelectableText>(memory).data,
        startsWith('00000000: 03 03'));
    final dumpScroll = find
        .descendant(
            of: find.byKey(const ValueKey('memory-dump-scroll')),
            matching: find.byType(Scrollable))
        .first;
    final scrollState = tester.state<ScrollableState>(dumpScroll);
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    expect(
        tester.getSize(memory).width,
        greaterThan(tester
            .getSize(find.byKey(const ValueKey('memory-dump-scroll')))
            .width));
    scrollState.position.jumpTo(80);
    await tester.pump();
    await tester.pump();
    expect(scrollState.position.pixels, greaterThan(0));
    controller.debugger.selectCpu(7);
    await tester.pump();
    final tabs =
        tester.widget<TabBar>(find.byKey(const ValueKey('debug-cpu-tabs')));
    expect(
        DefaultTabController.of(tester.element(find.byWidget(tabs))).index, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('F4 through F10 dispatch actions without key-repeat',
      (tester) async {
    final debugger = _Debugger()..setDebugView(true);
    await tester.pumpWidget(MaterialApp(
        home: DebugShortcuts(
            debugger: debugger,
            child: const Focus(autofocus: true, child: SizedBox.expand()))));
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10
    ]) {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyRepeatEvent(key);
      await tester.sendKeyUpEvent(key);
    }
    expect(debugger.calls, ['run', 'step', 'stepOut', 'next', 'frame', 'line']);
    debugger.calls.clear();
    debugger.executionStarted();
    for (final key in [
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(debugger.calls, ['pause']);
    debugger.calls.clear();
    await tester.pumpWidget(MaterialApp(
        home: DebugShortcuts(
            debugger: debugger,
            enabled: false,
            child: const Focus(autofocus: true, child: SizedBox.expand()))));
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    expect(debugger.calls, isEmpty);
  });

  testWidgets('execution buttons track running and automatic stops',
      (tester) async {
    final debugger = _Debugger();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DebugExecutionControls(debugger: debugger))));
    void expectEnabled(bool running) {
      for (final button
          in tester.widgetList<IconButton>(find.byType(IconButton))) {
        expect(button.onPressed != null,
            button.tooltip == 'Pause (F4)' ? running : !running,
            reason: button.tooltip);
      }
    }

    expectEnabled(false);
    debugger.executionStarted();
    await tester.pump();
    expectEnabled(true);
    await tester.tap(find.byTooltip('Step (F6)'));
    expect(debugger.calls, isEmpty);
    debugger.executionStopped();
    await tester.pump();
    expectEnabled(false);
    await tester.tap(find.byTooltip('Pause (F4)'));
    expect(debugger.calls, isEmpty);
  });

  testWidgets('Log starts capture and Copy copies, stops and shows a toast',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final controller = _Controller();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DebugController(controller: controller))));
    controller.debugger.setDebugView(true);
    await tester.pump();
    await tester.tap(find.text('Log'));
    await tester.pump();
    expect(controller.debugger.logEnabled, true);
    expect(find.text('Copy 0 lines'), findsOneWidget);
    controller.debugger.recordTrace();
    controller.debugger
        .completeTrace(ExecResult(1, false, false)..setExecuted(7, true));
    controller.debugger.pushStream();
    await tester.pump();
    expect(find.text('Copy 1 lines'), findsOneWidget);

    await tester.tap(find.text('Copy 1 lines'));
    await tester.pump();
    expect(copied, isNotNull);
    expect(controller.debugger.logEnabled, false);
    expect(find.text('Log'), findsOneWidget);
    expect(find.text('Trace copied'), findsOneWidget);
    expect(controller.debugger.state.traceLog, isEmpty);

    expect(tester.takeException(), isNull);
  });
}
