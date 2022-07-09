// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../cpu/cpu_debug.dart';
import '../nes.dart';

void showDebugLog(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (BuildContext context) {
      final asm = nes.cpu.dumpDebugLog();
      const margin10 = EdgeInsets.all(10.0);
      final node = FocusNode();
      node.requestFocus;

      return Scaffold(
          appBar: AppBar(title: const Text('Debug Log')),
          body: Container(
              margin: margin10,
              alignment: Alignment.topLeft,
              child: Focus(
                  focusNode: node,
                  child: SelectableText(
                    asm,
                    style: debugStyle,
                    toolbarOptions: const ToolbarOptions(
                      copy: true,
                      selectAll: true,
                    ),
                    showCursor: true,
                  ))));
    }),
  );
}
