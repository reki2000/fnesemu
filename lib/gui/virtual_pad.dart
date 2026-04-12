// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/pad_button.dart';

/// provides virtual pad buttons such as left, up, down, right, select, start, b and a.
/// those buttons handle `tapDown` and tapUp` events
class VirtualPadWidget extends StatelessWidget {
  final CoreController controller;

  const VirtualPadWidget({
    super.key,
    required this.controller,
  });

  static const keys = "ASZXCQWE";

  @override
  Widget build(BuildContext context) {
    // build a tap-effected button
    Widget button(PadButton button,
        {String name = "", IconData? icon, String key = ""}) {
      return InkResponse(
          canRequestFocus: false,
          containedInkWell: false,
          onTapDown: (_) => controller.padDown(0, button),
          onTapUp: (_) => controller.padUp(0, button),
          child: Row(children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // icon for this button
                if (icon != null)
                  Icon(icon, color: Theme.of(context).primaryColor),
                // text shown on this button
                if (name != "")
                  Container(
                    color: Theme.of(context).primaryColor,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      name,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
            if (key != "")
              Text(
                key,
                style: const TextStyle(color: Colors.grey),
              ),
          ]));
    }

    return Container(
        width: 512,
        margin: const EdgeInsets.all(5.0),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          button(PadButton.left, icon: Icons.arrow_back),
          button(PadButton.up, icon: Icons.arrow_upward),
          button(PadButton.down, icon: Icons.arrow_downward),
          button(PadButton.right, icon: Icons.arrow_forward),
          if (controller.buttons.length > 4)
            ...controller.buttons.sublist(4).asMap().entries.map((e) => button(
                e.value,
                name: e.value.name,
                key: VirtualPadWidget.keys[e.key]))
        ]));
  }
}
