import 'package:flutter/material.dart';

class ReaderThemeData {
  final String name;
  final Color bgColor;
  final Color textColor;

  const ReaderThemeData({
    required this.name,
    required this.bgColor,
    required this.textColor,
  });
}

class ReaderThemes {
  static const parchment = ReaderThemeData(
    name: '羊皮纸',
    bgColor: Color(0xFFF6EFE2),
    textColor: Color(0xFF382E25),
  );
  static const eyeCare = ReaderThemeData(
    name: '护眼',
    bgColor: Color(0xFFDDEBD6),
    textColor: Color(0xFF233621),
  );
  static const dark = ReaderThemeData(
    name: '暗黑',
    bgColor: Color(0xFF1E1E1E),
    textColor: Color(0xFF9E9E9E),
  );
  static const white = ReaderThemeData(
    name: '纯白',
    bgColor: Color(0xFFFFFFFF),
    textColor: Color(0xFF1A1A1A),
  );

  static const List<ReaderThemeData> all = [parchment, eyeCare, dark, white];
}