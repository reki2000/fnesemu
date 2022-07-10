// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../cpu/cpu_debug.dart';
import '../nes.dart';

void showDisasm(BuildContext context, int addr) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (BuildContext context) {
      final asm = nes.cpu.dumpDisasm(addr);
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
