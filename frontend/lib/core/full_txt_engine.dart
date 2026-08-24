import 'dart:convert';
import 'dart:io';
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

class FullTxtEngine {
  static Future<FullTxtPaginationResult> paginateInIsolate(FullTxtPaginationParams params) {
    return compute(_paginateWorker, params);
  }

  static FullTxtPaginationResult _paginateWorker(FullTxtPaginationParams params) {
    final file = File(params.filePath);
    final bytes = file.readAsBytesSync();
    final totalBytes = bytes.length;

    // 1. 尝试常用编码格式解码
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

    // 2. 预先提取目录章节与在全文中的字符位置
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

    // 3. 构建排版测算 TextPainter
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

    while (startChar < text.length) {
      // 检查当前页起始字符处是否命中新章节
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

      textPainter.text = TextSpan(text: text.substring(startChar), style: textStyle);
      textPainter.layout(maxWidth: params.contentSize.width);

      int endChar;
      if (textPainter.size.height <= params.contentSize.height) {
        endChar = text.length;
      } else {
        final position = textPainter.getPositionForOffset(
          Offset(params.contentSize.width, params.contentSize.height),
        );
        int fitLength = position.offset;
        if (fitLength <= 0) fitLength = 1;
        endChar = startChar + fitLength;
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
    }

    return FullTxtPaginationResult(
      pages: pages,
      chapters: chapters,
      totalBytes: totalBytes,
    );
  }
}