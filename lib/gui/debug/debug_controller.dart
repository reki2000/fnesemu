// Dart imports:
import 'dart:developer';

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../nes_controller.dart';
import 'disasm.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final NesController controller;

  const DebugController({Key? key, required this.controller}) : super(key: key);

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: ElevatedButton(onPressed: func, child: Text(text)));

  @override
  Widget build(BuildContext context) {
    controller.traceStream.listen((event) => log(event));

    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _button("Step", controller.runStep),
      _button("Line", controller.runScanLine),
      _button("Frame", controller.runFrame),
      SizedBox(
          width: 50,
          child: TextField(onChanged: (v) {
            if (v.length == 4) {
              try {
                final breakPoint = int.parse(v, radix: 16);
                controller.debugOption =
                    controller.debugOption.copyWith(breakPoint: breakPoint);
              } catch (e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.toString())));
              }
            }
          })),
      _button("Disasm", () => pushDisasmPage(context, controller)),
      _button("VRAM", () => pushVramPage(context, controller)),
      _button("Log", () {
        final currentOn = controller.debugOption.log;
        controller.debugOption =
            controller.debugOption.copyWith(log: !currentOn);
      }),
    ]);
  }
}
