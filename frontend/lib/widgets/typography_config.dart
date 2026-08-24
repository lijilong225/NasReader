
class TypographyConfig {
  final double fontSize;
  final double lineHeight;       // 行高倍数，如 1.6
  final double letterSpacing;    // 字间距，如 1.0
  final bool indentFirstLine;    // 是否开启段首缩进 2 字符
  final String? customFontFamily;// 自定义字体 Family，null 为系统默认

  const TypographyConfig({
    this.fontSize = 18.0,
    this.lineHeight = 1.6,
    this.letterSpacing = 1.0,
    this.indentFirstLine = true,
    this.customFontFamily,
  });

  TypographyConfig copyWith({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    bool? indentFirstLine,
    String? customFontFamily,
    bool clearFont = false,
  }) {
    return TypographyConfig(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      indentFirstLine: indentFirstLine ?? this.indentFirstLine,
      customFontFamily: clearFont ? null : (customFontFamily ?? this.customFontFamily),
    );
  }

  /// TXT 中文段落自动缩进处理
  static String applyIndent(String rawText) {
    final lines = rawText.split('\n');
    final buffer = StringBuffer();

    for (int i = 0; i < lines.length; i++) {
      String line = lines[i].trim();
      if (line.isNotEmpty) {
        // 去除多余空字符后添加全角空格缩进（2 字符）
        line = '\u3000\u3000$line';
      }
      buffer.write(line);
      if (i < lines.length - 1) {
        buffer.write('\n');
      }
    }
    return buffer.toString();
  }
}