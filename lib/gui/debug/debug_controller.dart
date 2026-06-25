// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/debugger.dart';
import '../../core/types.dart';
import '../../styles.dart';
import 'package:fnesemu/util/int.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final CoreController controller;
  final Debugger debugger;

  DebugController({super.key, required this.controller})
      : debugger = controller.debugger;

  Widget _button(BuildContext context, String text, void Function() func) =>
      TextButton(
          style: textButtonMinimum.copyWith(
              foregroundColor: WidgetStateProperty.all(Colors.white),
              backgroundColor:
                  WidgetStateProperty.all(Theme.of(context).primaryColor)),
          onPressed: func,
          child: Text(text));

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

  CpuInfo _targetCpu(DebugOption opt) =>
      debugger.cpuInfos[_targetCpuIndex(opt.targetCpuNo)];

  _setBreakPoint(BuildContext context, String v, DebugOption opt) {
    if (v.length != _targetCpu(opt).pcBitWidth >> 2) {
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

  _toggleTargtCpu() {
    final cpuInfos = controller.debugger.cpuInfos;
    final value = (targetCpuNotifier.value + 1) % cpuInfos.length;
    controller.debugger.opt.targetCpuNo = cpuInfos[value].no;
    targetCpuNotifier.value = value;
  }

  final targetCpuNotifier = ValueNotifier<int>(0);

  @override
  Widget build(BuildContext context) => StreamBuilder(
        stream: debugger.debugStream,
        builder: (context, snapshot) =>
            (snapshot.hasData) ? body(context, snapshot.data!) : Container(),
      );

  String _formatPc(int pc, int bit) => bit == 32
      ? pc.x8
      : bit == 24
          ? pc.x6
          : pc.x4;

  Widget body(BuildContext context, DebugOption opt) =>
      Row(spacing: 3, mainAxisAlignment: MainAxisAlignment.center, children: [
        _button(context, _targetCpu(opt).name, _toggleTargtCpu),
        _button(context, "Step", () {
          controller.run(mode: CoreController.runModeStep);
        }),
        _button(context, "Next", () {
          opt.breakPoint = debugger.nextPc(opt.targetCpuNo);
          controller.run();
        }),
        _button(context, "StepOut", () {
          opt.stackPointer = debugger.stackPointer(opt.targetCpuNo);
          controller.run(mode: CoreController.runModeStepOut);
        }),
        _button(context, "Line",
            () => controller.run(mode: CoreController.runModeLine)),
        _button(context, "Frame",
            () => controller.run(mode: CoreController.runModeFrame)),
        SizedBox(
            width: 90,
            child: TextField(
              controller:
                  TextEditingController(text: opt.breakClock.toString()),
              decoration: denseTextDecoration,
              onSubmitted: (v) => _setBreakClock(context, v),
            )),
        SizedBox(
            width: 70,
            child: TextField(
              controller: TextEditingController(
                  text: _formatPc(opt.breakPoint, _targetCpu(opt).pcBitWidth)),
              decoration: denseTextDecoration,
              onSubmitted: (v) => _setBreakPoint(context, v, opt),
            )),
        _button(context, "Mem", () => debugger.toggleMem()),
        _button(context, "VRAM", () => pushVramPage(context, controller)),
        _button(context, "VDC", () => debugger.toggleVdc()),
        _button(context, "Log", () => debugger.toggleLog()),
      ]);
}
