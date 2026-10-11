import 'package:flutter/material.dart';

// a monospace font of the platform, for the debug views
const debugStyle = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New'],
    fontSize: 11);

const denseTextDecoration = InputDecoration(
  isDense: true,
  contentPadding: EdgeInsets.symmetric(vertical: 2),
);

IconButton iconButton(IconData icon, String tooltip, void Function() onPress) {
  return IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPress);
}

final textButtonMinimum = TextButton.styleFrom(
    minimumSize: Size.zero,
    padding: const EdgeInsets.all(3.0),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(0))));

/// Compact, neutral controls shared by every debugger view.
ThemeData debugTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final background = Color(dark ? 0xff3a3a3a : 0xffe5e5e5);
  final selected = Color(dark ? 0xff555555 : 0xffcccccc);
  final foreground = Color(dark ? 0xffeeeeee : 0xff222222);
  final border = Color(dark ? 0xff707070 : 0xffaaaaaa);
  const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)));
  final button = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 6, vertical: 2)),
      shape: const WidgetStatePropertyAll(shape),
      elevation: const WidgetStatePropertyAll(0),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? selected : background),
      foregroundColor: WidgetStatePropertyAll(foreground),
      side: WidgetStatePropertyAll(BorderSide(color: border)));
  return base.copyWith(
      textButtonTheme: TextButtonThemeData(style: button),
      iconButtonTheme: IconButtonThemeData(style: button),
      elevatedButtonTheme: ElevatedButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(style: button),
      segmentedButtonTheme: SegmentedButtonThemeData(style: button),
      chipTheme: base.chipTheme.copyWith(
          backgroundColor: background,
          selectedColor: selected,
          checkmarkColor: foreground,
          labelStyle: TextStyle(color: foreground, fontSize: 12),
          shape: shape,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          labelPadding: const EdgeInsets.symmetric(horizontal: 2)),
      sliderTheme: base.sliderTheme.copyWith(
          activeTrackColor: foreground,
          inactiveTrackColor: border,
          thumbColor: foreground,
          trackHeight: 2));
}
