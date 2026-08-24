import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class FullTxtPageSlice {
  final int pageIndex;
  final int startByteOffset;
  final int endByteOffset;
  final String content;

  const FullTxtPageSlice({
    required this.pageIndex,
    required this.startByteOffset,
    required this.endByteOffset,
    required this.content,
  });
}

class FullTxtChapterItem {
  final int index;
  final String title;
  final int startByteOffset;
  final int pageIndex;

  const FullTxtChapterItem({
    required this.index,
    required this.title,
    required this.startByteOffset,
    required this.pageIndex,
  });
}

class FullTxtPaginationResult {
  final List<FullTxtPageSlice> pages;
  final List<FullTxtChapterItem> chapters;
  final int totalBytes;

  const FullTxtPaginationResult({
    required this.pages,
    required this.chapters,
    required this.totalBytes,
  });
}

class FullTxtPaginationParams {
  final String filePath;
  final Size contentSize;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final String? fontFamily;

  const FullTxtPaginationParams({
    required this.filePath,
    required this.contentSize,
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    this.fontFamily,
  });
}

class _PreparseResult {
  final String text;
  final List<MapEntry<int, String>> chapterPositions;
  final int totalBytes;

  _PreparseResult({
    required this.text,
    required this.chapterPositions,
    required this.totalBytes,
  });
}

class FullTxtEngine {
  static Future<FullTxtPaginationResult> paginate(FullTxtPaginationParams params) async {
    // 1. 在 Isolate 中完成文件解码与章节正则提取
    final preparse = await compute(_preparseWorker, params.filePath);

    final text = preparse.text;
    final chapterPositions = preparse.chapterPositions;
    final totalBytes = preparse.totalBytes;

    if (text.isEmpty) {
      return FullTxtPaginationResult(pages: [], chapters: [], totalBytes: 0);
    }

    final textStyle = TextStyle(
      fontSize: params.fontSize,
      height: params.lineHeight,
      letterSpacing: params.letterSpacing,
      fontFamily: params.fontFamily ?? 'serif',
    );
    final strutStyle = StrutStyle(
      fontSize: params.fontSize,
      height: params.lineHeight,
      forceStrutHeight: true,
    );

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      strutStyle: strutStyle,
      maxLines: null,
    );

    final pages = <FullTxtPageSlice>[];
    final chapters = <FullTxtChapterItem>[];

    int startChar = 0;
    int pageIdx = 0;
    int currentByteOffset = 0;
    int chapterCursor = 0;
    int chapterIndexCount = 0;

    final targetWidth = params.contentSize.width;
    final targetHeight = params.contentSize.height;

    // 单页字符估算窗口大小（避免每次排版把整本几百万字传给 TextPainter）
    const int estimatedWindow = 1200;

    while (startChar < text.length) {
      // 检查当前字符位置是否命中章节
      while (chapterCursor < chapterPositions.length &&
          chapterPositions[chapterCursor].key <= startChar) {
        chapters.add(FullTxtChapterItem(
          index: chapterIndexCount++,
          title: chapterPositions[chapterCursor].value,
          startByteOffset: currentByteOffset,
          pageIndex: pageIdx,
        ));
        chapterCursor++;
      }

      // 仅截取当前窗口范围排版
      int windowEnd = min(startChar + estimatedWindow, text.length);
      String windowText = text.substring(startChar, windowEnd);

      textPainter.text = TextSpan(text: windowText, style: textStyle);
      textPainter.layout(maxWidth: targetWidth);

      int endChar;
      if (textPainter.size.height <= targetHeight) {
        // 如果当前窗口文字高度还小于一页，且还没到末尾，扩展窗口直到溢出
        if (windowEnd == text.length) {
          endChar = text.length;
        } else {
          // 放大窗口
          int extendedEnd = min(startChar + estimatedWindow * 2, text.length);
          windowText = text.substring(startChar, extendedEnd);
          textPainter.text = TextSpan(text: windowText, style: textStyle);
          textPainter.layout(maxWidth: targetWidth);

          if (textPainter.size.height <= targetHeight) {
            endChar = extendedEnd;
          } else {
            final position = textPainter.getPositionForOffset(Offset(targetWidth, targetHeight));
            int fitLength = position.offset;
            if (fitLength <= 0) fitLength = 1;
            endChar = startChar + fitLength;
          }
        }
      } else {
        // 窗口文本已超出一页，精准获取该高度下的字符切点
        final position = textPainter.getPositionForOffset(Offset(targetWidth, targetHeight));
        int fitLength = position.offset;
        if (fitLength <= 0) fitLength = 1;
        endChar = startChar + fitLength;
      }

      // 强校验：确保每次循环至少前进一步，彻底消除死循环
      if (endChar <= startChar) {
        endChar = startChar + 1;
      }

      final pageContent = text.substring(startChar, endChar);
      final pageByteLength = utf8.encode(pageContent).length;
      final endByteOffset = currentByteOffset + pageByteLength;

      pages.add(FullTxtPageSlice(
        pageIndex: pageIdx,
        startByteOffset: currentByteOffset,
        endByteOffset: endByteOffset,
        content: pageContent,
      ));

      startChar = endChar;
      currentByteOffset = endByteOffset;
      pageIdx++;

      // 每排版 150 页主动让出微任务，避免主线程掉帧卡顿
      if (pageIdx % 150 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return FullTxtPaginationResult(
      pages: pages,
      chapters: chapters,
      totalBytes: totalBytes,
    );
  }

  static _PreparseResult _preparseWorker(String filePath) {
    final file = File(filePath);
    final bytes = file.readAsBytesSync();
    final totalBytes = bytes.length;

    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      try {
        text = const Utf8Decoder(allowMalformed: true).convert(bytes);
      } catch (_) {
        text = String.fromCharCodes(bytes);
      }
    }

    final chapterRegex = RegExp(
      r'^\s*(第[0-9一二三四五六七八九十百千万]+[章回节卷集幕篇部]|Chapter\s*\d+|Section\s*\d+)(.*)$',
      multiLine: true,
      caseSensitive: false,
    );
    final matches = chapterRegex.allMatches(text).toList();
    final chapterPositions = <MapEntry<int, String>>[];
    for (final m in matches) {
      chapterPositions.add(MapEntry(m.start, m.group(0)?.trim() ?? '未知章节'));
    }

    return _PreparseResult(
      text: text,
      chapterPositions: chapterPositions,
      totalBytes: totalBytes,
    );
  }
}