import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/debug/debug_controller.dart';
import 'package:fnesemu/gui/debug/debug_pane.dart';
import 'package:fnesemu_core/app_api.dart';

void main() {
  testWidgets('debug views tolerate an unloaded core and remembered options',
      (tester) async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    final debugger = controller.debugger;
    debugger.setMemoryVisible(true);
    debugger.setVideoVisible(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      DebugController(controller: controller),
      DebugPane(debugger: debugger),
    ]))));
    debugger.setDebugView(true);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Step'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
