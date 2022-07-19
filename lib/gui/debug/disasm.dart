// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../cpu/cpu_debug.dart';
import '../../cpu/nes.dart';
import '../../styles.dart';

void showDisasm(BuildContext context, Nes emulator) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (BuildContext context) {
      final asm = emulator.cpu.dumpDisasm(emulator.breakpoint);
      const margin10 = EdgeInsets.all(10.0);
      final node = FocusNode();
      node.requestFocus;

      return Scaffold(
          appBar: AppBar(title: const Text('Disaseembler')),
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
