import 'package:flutter/material.dart';

class ReaderThemeData {
  final String name;
  final Color bgColor;
  final Color textColor;

  /// 纸纹背景图 asset 路径，为空表示纯色背景；有值时 bgColor 作为图片加载前的兜底底色
  final String? backgroundImage;

  const ReaderThemeData({
    required this.name,
    required this.bgColor,
    required this.textColor,
    this.backgroundImage,
  });
}

class ReaderThemes {
  static const parchment = ReaderThemeData(
    name: '羊皮纸1',
    bgColor: Color(0xFFF6EFE2),
    textColor: Color(0xFF382E25),
  );
  static const parchment2 = ReaderThemeData(
    name: '羊皮纸2',
    bgColor: Color(0xFFF6EFE2),
    textColor: Color(0xFF382E25),
    backgroundImage: 'assets/readbg_01.jpg',
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

  static const List<ReaderThemeData> all = [parchment, parchment2, dark, white];
}