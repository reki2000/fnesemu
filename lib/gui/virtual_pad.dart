// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/pad_button.dart';

/// provides virtual pad buttons such as left, up, down, right, select, start, b and a.
/// those buttons handle `tapDown` and tapUp` events
class VirtualPadWidget extends StatelessWidget {
  final CoreController controller;

  /// the buttons are shrunk to be placed in a line within this width
  final double width;

  const VirtualPadWidget({
    super.key,
    required this.controller,
    required this.width,
  });

  static const keys = "ASZXCQWERD";

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).primaryColor;

    // build a tap-effected button
    Widget button(PadButton button,
        {String name = "", IconData? icon, String key = ""}) {
      return InkResponse(
          canRequestFocus: false,
          containedInkWell: false,
          onTapDown: (_) => controller.padDown(0, button),
          onTapUp: (_) => controller.padUp(0, button),
          onTapCancel: () => controller.padUp(0, button),
          // leaves room for the key label at the top right
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 6),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // icon for this button
                if (icon != null) Icon(icon, color: color),
                // text shown on this button
                if (name != "")
                  Container(
                    color: color,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      name,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                // assigned key
                if (key != "")
                  Positioned(
                    top: -10,
                    right: -8,
                    child: Text(
                      key,
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ));
    }

    return Container(
        width: width,
        margin: const EdgeInsets.all(5.0),
        child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(spacing: 8, children: [
              button(PadButton.left, icon: Icons.arrow_back),
              button(PadButton.up, icon: Icons.arrow_upward),
              button(PadButton.down, icon: Icons.arrow_downward),
              button(PadButton.right, icon: Icons.arrow_forward),
              if (controller.buttons.length > 4)
                ...controller.buttons.sublist(4).asMap().entries.map((e) =>
                    button(e.value,
                        name: e.value.name,
                        key: e.key < VirtualPadWidget.keys.length
                            ? VirtualPadWidget.keys[e.key]
                            : ""))
            ])));
  }
}
