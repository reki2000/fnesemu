// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../styles.dart';
import '../../util.dart';
import '../nes_controller.dart';

void pushDisasmPage(BuildContext context, NesController controller) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (BuildContext context) {
      // get 20 lines of disassemble string
      final asm = range(0, 20)
          .fold<Pair<List<String>, int>>(Pair(<String>[], 0), (a, b) {
            final asm = controller.disasm(b);
            return Pair(a.i0..add(asm.i0), asm.i1);
          })
          .i0
          .join("");

      const margin10 = EdgeInsets.all(10.0);
      final node = FocusNode();
      node.requestFocus;

      return Scaffold(
          appBar: AppBar(title: const Text('DisAseembler')),
          body: Container(
              margin: margin10,
              alignment: Alignment.topLeft,
              child: Focus(
                  focusNode: node,
                  child: SelectableText(
                    asm,
                    style: debugStyle,
                    showCursor: true,
                  ))));
    }),
  );
}
