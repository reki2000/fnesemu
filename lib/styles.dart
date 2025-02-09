// Package imports:
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

final debugStyle = GoogleFonts.robotoMono(fontSize: 11);

const denseTextDecoration = InputDecoration(
  isDense: true,
  contentPadding: EdgeInsets.symmetric(vertical: 2),
);

IconButton iconButton(IconData icon, String tooltip, void Function() onPress) {
  return IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPress);
}
