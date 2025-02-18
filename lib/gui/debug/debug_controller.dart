// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../core/debugger.dart';
import '../../core/types.dart';
import '../../util/int.dart';
import '../../styles.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final CoreController controller;
  final Debugger debugger;

  DebugController({super.key, required this.controller})
      : debugger = controller.debugger;

  Widget _button(String text, void Function() func) =>
      TextButton(style: textButtonMinimum, onPressed: func, child: Text(text));

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
      debugger.opt.breakPoint = breakPoint;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("breakpoint: ${breakPoint.hex24}"),
          duration: const Duration(milliseconds: 200)));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString()),
          duration: const Duration(milliseconds: 200)));
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
      ? pc.hex32
      : bit == 24
          ? pc.hex24
          : pc.hex16;

  Widget body(BuildContext context, DebugOption opt) =>
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _button(_targetCpu(opt).name, _toggleTargtCpu),
        _button("Step", () {
          controller.run(mode: CoreController.runModeStep);
        }),
        _button("Next", () {
          opt.breakPoint = debugger.nextPc(opt.targetCpuNo);
          controller.run();
        }),
        _button("StepOut", () {
          opt.stackPointer = debugger.stackPointer(opt.targetCpuNo);
          controller.run(mode: CoreController.runModeStepOut);
        }),
        _button("Line", () => controller.run(mode: CoreController.runModeLine)),
        _button(
            "Frame", () => controller.run(mode: CoreController.runModeFrame)),
        SizedBox(
            width: 70,
            child: TextField(
                controller: TextEditingController(
                    text:
                        _formatPc(opt.breakPoint, _targetCpu(opt).pcBitWidth)),
                decoration: denseTextDecoration,
                onChanged: (v) => _setBreakPoint(context, v, opt))),
        _button("Mem", () => debugger.toggleMem()),
        _button("VRAM", () => pushVramPage(context, controller)),
        _button("VDC", () => debugger.toggleVdc()),
        _button("Log", () => debugger.toggleLog()),
      ]);
}
