import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fnesemu_core/app_api.dart';

import '../../styles.dart';

typedef _DebugAction = (
  String,
  IconData,
  LogicalKeyboardKey,
  Future<void> Function()
);

List<_DebugAction> _executionActions(Debugger debugger) => [
      ('Pause', Icons.pause, LogicalKeyboardKey.f4, debugger.pause),
      ('Run', Icons.play_arrow, LogicalKeyboardKey.f5, debugger.run),
      ('Step', Icons.arrow_downward, LogicalKeyboardKey.f6, debugger.step),
      ('StepOut', Icons.arrow_upward, LogicalKeyboardKey.f7, debugger.stepOut),
      ('Next', Icons.redo, LogicalKeyboardKey.f8, debugger.next),
      ('Frame', Icons.skip_next, LogicalKeyboardKey.f9, debugger.runToFrame),
      ('Line', Icons.last_page, LogicalKeyboardKey.f10, debugger.runToLine),
    ];

bool _actionEnabled(Debugger debugger, _DebugAction action) =>
    debugger.cpuInfos.isNotEmpty &&
    (action.$3 == LogicalKeyboardKey.f4) == debugger.state.running;

class DebugExecutionControls extends StatelessWidget {
  final Debugger debugger;
  const DebugExecutionControls({super.key, required this.debugger});
  @override
  Widget build(BuildContext context) => StreamBuilder<DebugState>(
      stream: debugger.debugStream,
      initialData: debugger.state,
      builder: (context, snapshot) =>
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (final action in _executionActions(debugger))
              IconButton(
                  tooltip: '${action.$1} (${action.$3.keyLabel})',
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  padding: const EdgeInsets.all(2),
                  iconSize: 18,
                  onPressed:
                      _actionEnabled(debugger, action) ? action.$4 : null,
                  icon: Icon(action.$2)),
          ]));
}

/// Wrap both the game and inspector so keys work while either has focus.
class DebugShortcuts extends StatelessWidget {
  final Debugger debugger;
  final bool enabled;
  final Widget child;
  const DebugShortcuts(
      {super.key,
      required this.debugger,
      required this.child,
      this.enabled = true});
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
      bindings: enabled
          ? {
              for (final action in _executionActions(debugger))
                SingleActivator(action.$3, includeRepeats: false): () {
                  if (_actionEnabled(debugger, action)) action.$4();
                },
            }
          : const {},
      child: child);
}

class DebugController extends StatefulWidget {
  final CoreController controller;
  const DebugController({super.key, required this.controller});
  @override
  State<DebugController> createState() => _DebugControllerState();
}

class _DebugControllerState extends State<DebugController> {
  CoreController get controller => widget.controller;
  Debugger get debugger => controller.debugger;
  bool _copying = false;
  Future<void> _copyTrace() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: debugger.traceText()));
      debugger.setLogEnabled(false);
      if (mounted) _showSnackBar(context, 'Trace copied');
    } catch (error) {
      if (mounted) _showSnackBar(context, 'Copy failed: $error');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Widget _button(BuildContext context, String text, void Function() func) =>
      TextButton(onPressed: func, child: Text(text));

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message), duration: const Duration(milliseconds: 200)));
  }

  int _targetCpuIndex(int targetCpuNo) {
    final cpuInfos = debugger.cpuInfos;
    for (int i = 0; i < cpuInfos.length; i++) {
      if (cpuInfos[i].no == targetCpuNo) {
        return i;
      }
    }
    return 0;
  }

  CpuInfo _targetCpu(DebugState state) =>
      debugger.cpuInfos[_targetCpuIndex(state.targetCpuNo)];

  _setBreakPoint(BuildContext context, String v, DebugState state) {
    if (v.length != (_targetCpu(state).pcBitWidth + 3) ~/ 4) {
      return;
    }

    try {
      final breakPoint = int.parse(v, radix: 16);
      debugger.setBreakPoint(breakPoint);
      _showSnackBar(context, "breakpoint: ${breakPoint.x6}");
    } catch (e) {
      _showSnackBar(context, e.toString());
    }
  }

  _setBreakClock(BuildContext context, String v) {
    if (v.isEmpty) {
      v = "0";
    }

    try {
      final clock = int.parse(v);
      debugger.setBreakClock(clock);
      _showSnackBar(context, "breakClock: $clock");
    } catch (e) {
      _showSnackBar(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder(
        stream: debugger.debugStream,
        initialData: debugger.state,
        builder: (context, snapshot) =>
            (snapshot.hasData) ? body(context, snapshot.data!) : Container(),
      );

  String _formatPc(int pc, int bit) =>
      pc.toRadixString(16).padLeft((bit + 3) ~/ 4, '0');

  Widget body(BuildContext context, DebugState state) =>
      debugger.cpuInfos.isEmpty
          ? const SizedBox.shrink()
          : Wrap(spacing: 3, runSpacing: 3, children: [
              SizedBox(
                  width: 90,
                  child: TextField(
                    controller: TextEditingController(
                        text: state.breakClock.toString()),
                    decoration: denseTextDecoration,
                    onSubmitted: (v) => _setBreakClock(context, v),
                  )),
              SizedBox(
                  width: 70,
                  child: TextField(
                    controller: TextEditingController(
                        text: _formatPc(
                            state.breakPoint, _targetCpu(state).pcBitWidth)),
                    decoration: denseTextDecoration,
                    onSubmitted: (v) => _setBreakPoint(context, v, state),
                  )),
              _button(
                  context,
                  state.log || state.traceLog.isNotEmpty
                      ? 'Copy ${state.traceLog.length} lines'
                      : 'Log', () {
                if (state.log || state.traceLog.isNotEmpty) {
                  _copyTrace();
                } else {
                  debugger.startTrace();
                }
              }),
            ]);
}
