// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
import '../../util/int.dart';
import '../../styles.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final CoreController controller;

  const DebugController({super.key, required this.controller});

  Widget _button(String text, void Function() func) =>
      TextButton(style: textButtonMinimum, onPressed: func, child: Text(text));

  @override
  Widget build(BuildContext context) {
    final debugger = controller.debugger;
    final opt = debugger.opt;
    final targetCpuNotifier = ValueNotifier<int>(opt.targetCpuNo);

    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      if (debugger.cpuInfos.length > 1)
        ValueListenableBuilder(
            valueListenable: targetCpuNotifier,
            builder: (ctx, value, _) =>
                _button(debugger.cpuInfos[value].name, () {
                  opt.targetCpuNo =
                      (opt.targetCpuNo + 1) % debugger.cpuInfos.length;
                  targetCpuNotifier.value = opt.targetCpuNo;
                })),
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
      _button("Frame", () => controller.run(mode: CoreController.runModeFrame)),
      SizedBox(
          width: 60,
          child: TextField(
              decoration: denseTextDecoration,
              onChanged: (v) {
                if (v.length == 4 || v.length == 6) {
                  try {
                    final breakPoint = int.parse(v, radix: 16);
                    opt.breakPoint = breakPoint;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text("breakpoint: ${breakPoint.hex24}")));
                  } catch (e) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              })),
      _button("Mem", () => debugger.toggleMem()),
      _button("VRAM", () => pushVramPage(context, controller)),
      _button("VDC", () => debugger.toggleVdc()),
      _button("Log", () => debugger.toggleLog()),
    ]);
  }
}
