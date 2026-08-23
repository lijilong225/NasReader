import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';

/// 单页数据切片
class TxtPage {
  final int pageIndex;
  final int startOffset; // 在全文中的起始字符索引
  final int endOffset;   // 在全文中的结束字符索引
  final String content;

  TxtPage({
    required this.pageIndex,
    required this.startOffset,
    required this.endOffset,
    required this.content,
  });
}

/// 排版配置样式
class ReaderConfig {
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final Color textColor;
  final Color backgroundColor;
  final EdgeInsets padding;

  const ReaderConfig({
    this.fontSize = 18.0,
    this.lineHeight = 1.6,
    this.letterSpacing = 1.0,
    this.paragraphSpacing = 12.0,
    this.textColor = const Color(0xFF2C2C2C),
    this.backgroundColor = const Color(0xFFF4ECD8), // 默认羊皮纸
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
  });

  TextStyle get textStyle => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        letterSpacing: letterSpacing,
        color: textColor,
        fontFamily: 'serif',
      );

  ReaderConfig copyWith({
    double? fontSize,
    double? lineHeight,
    Color? textColor,
    Color? backgroundColor,
  }) {
    return ReaderConfig(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      letterSpacing: letterSpacing,
      paragraphSpacing: paragraphSpacing,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      padding: padding,
    );
  }
}

/// TXT 分页计算器 (基于 TextPainter)
class TxtPaginator {
  /// 将纯文本按照屏幕尺寸与样式配置进行精确分页
  static List<TxtPage> paginate({
    required String text,
    required Size contentSize, // 除去 Padding 和上下安全区的净可用宽高
    required ReaderConfig config,
  }) {
    final List<TxtPage> pages = [];
    if (text.isEmpty || contentSize.width <= 0 || contentSize.height <= 0) {
      return pages;
    }

    int currentOffset = 0;
    final int totalLength = text.length;
    int pageIndex = 0;

    final textStyle = config.textStyle;
    final double maxW = contentSize.width;
    final double maxH = contentSize.height;

    while (currentOffset < totalLength) {
      // 预估单页最大字符容量，缩小二分搜索范围加速计算
      int step = 1500;
      int endOffset = (currentOffset + step > totalLength)
          ? totalLength
          : currentOffset + step;

      // 使用 TextPainter 测量
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        maxLines: null,
      );

      // 二分法寻找在 maxH 约束下的最大字符截断点
      int low = currentOffset + 1;
      int high = endOffset;
      int bestFitOffset = low;

      // 先检查粗筛截断点是否在容器高度内
      painter.text = TextSpan(
        text: text.substring(currentOffset, high),
        style: textStyle,
      );
      painter.layout(maxWidth: maxW);

      if (painter.height <= maxH && high == totalLength) {
        // 全文刚好装完
        bestFitOffset = totalLength;
      } else {
        // 二分精确定位
        while (low <= high) {
          int mid = (low + high) ~/ 2;
          final subStr = text.substring(currentOffset, mid);

          painter.text = TextSpan(text: subStr, style: textStyle);
          painter.layout(maxWidth: maxW);

          if (painter.height <= maxH) {
            bestFitOffset = mid;
            low = mid + 1; // 尝试容纳更多字符
          } else {
            high = mid - 1; // 超出高度，向左收缩
          }
        }
      }

      // 避免单字符死循环
      if (bestFitOffset <= currentOffset) {
        bestFitOffset = currentOffset + 1;
      }

      final pageContent = text.substring(currentOffset, bestFitOffset);
      pages.add(TxtPage(
        pageIndex: pageIndex++,
        startOffset: currentOffset,
        endOffset: bestFitOffset,
        content: pageContent,
      ));

      currentOffset = bestFitOffset;
    }

    return pages;
  }

  /// 异步读取文件并支持编码识别（UTF-8 与 GBK 降级）
  static Future<String> readTextFile(File file) async {
    final bytes = await file.readAsBytes();
    try {
      // 默认优先尝试 UTF-8
      return utf8.decode(bytes);
    } catch (_) {
      // 若乱码或失败，降级尝试 gbk/latin1 (可接入 fast_gbk)
      return latin1.decode(bytes);
    }
  }
}