import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class FullTxtPageSlice {
  final int pageIndex;
  final int startByteOffset;
  final int endByteOffset;
  final String content;        // 仅包含正文（已剥离章节标题）
  final String? chapterTitle;  // 章节起始页的标题

  const FullTxtPageSlice({
    required this.pageIndex,
    required this.startByteOffset,
    required this.endByteOffset,
    required this.content,
    this.chapterTitle,
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
  final bool indentFirstLine;

  const FullTxtPaginationParams({
    required this.filePath,
    required this.contentSize,
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    this.indentFirstLine = true,
  });
}

class FullTxtEngine {
  static Future<FullTxtPaginationResult> paginate(FullTxtPaginationParams params) {
    return compute(_fastPaginateWorker, params);
  }

  static FullTxtPaginationResult _fastPaginateWorker(FullTxtPaginationParams params) {
    final file = File(params.filePath);
    final bytes = file.readAsBytesSync();
    final totalBytes = bytes.length;

    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      // 非严格 UTF-8 文本，改用容错解码（allowMalformed 不会抛异常）
      text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    }

    if (text.isEmpty) {
      return const FullTxtPaginationResult(pages: [], chapters: [], totalBytes: 0);
    }

    // 目录正则
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

    final charWidth = params.fontSize + params.letterSpacing;
    final rowHeight = params.fontSize * params.lineHeight;

    final charsPerLine = (params.contentSize.width / charWidth).floor().clamp(10, 100);
    final linesPerPage = (params.contentSize.height / rowHeight).floor().clamp(5, 60);

    final pages = <FullTxtPageSlice>[];
    final chapters = <FullTxtChapterItem>[];

    final lines = text.split('\n');
    final pageBuffer = StringBuffer();

    int pageIdx = 0;
    int currentLinesOnPage = 0;
    int currentByteOffset = 0;
    int currentCharIndex = 0;
    int chapterCursor = 0;
    int chapterCount = 0;
    int pageStartByte = 0;
    String? currentPendingChapterTitle;

    for (int i = 0; i < lines.length; i++) {
      var rawLine = lines[i];
      final lineCharLengthWithBreak = rawLine.length + 1;

      // 判断当前行是否命中新章节
      bool isNewChapter = false;
      String? matchedTitle;
      if (chapterCursor < chapterPositions.length &&
          chapterPositions[chapterCursor].key <= currentCharIndex) {
        isNewChapter = true;
        matchedTitle = chapterPositions[chapterCursor].value;
        chapterCursor++;
      }

      // 命中新章节：封存旧页，开启新页，完全跳过该行正文录入
      if (isNewChapter) {
        if (currentLinesOnPage > 0 || pageBuffer.isNotEmpty) {
          final pageContent = pageBuffer.toString().trimRight();
          final pageBytes = utf8.encode(pageContent).length;
          final pageEndByte = currentByteOffset + pageBytes;

          pages.add(FullTxtPageSlice(
            pageIndex: pageIdx++,
            startByteOffset: pageStartByte,
            endByteOffset: pageEndByte,
            content: pageContent,
            chapterTitle: currentPendingChapterTitle,
          ));

          pageBuffer.clear();
          currentLinesOnPage = 0;
          pageStartByte = pageEndByte;
          currentPendingChapterTitle = null;
        }

        chapters.add(FullTxtChapterItem(
          index: chapterCount++,
          title: matchedTitle!,
          startByteOffset: currentByteOffset,
          pageIndex: pageIdx,
        ));

        currentPendingChapterTitle = matchedTitle;
        currentLinesOnPage = 1; // 仅预留标题所占行高

        // 推进字节索引并彻底跳过该标题行，绝不进入 pageBuffer
        currentCharIndex += lineCharLengthWithBreak;
        currentByteOffset += utf8.encode('$rawLine\n').length;
        continue;
      }

      var line = rawLine.trimRight();

      // 如果当前是新章节起始页第一行且为空行，直接过滤跳过
      if (currentPendingChapterTitle != null && currentLinesOnPage == 1 && line.trim().isEmpty) {
        currentCharIndex += lineCharLengthWithBreak;
        currentByteOffset += utf8.encode('$rawLine\n').length;
        continue;
      }

      // 普通正文行添加首行缩进
      if (params.indentFirstLine && line.isNotEmpty &&
          !line.startsWith('  ') && !line.startsWith('  ')) {
        line = '  $line';
      }

      int lineOffset = 0;
      while (lineOffset < line.length || (lineOffset == 0 && line.isEmpty)) {
        int endOffset = (lineOffset + charsPerLine < line.length)
            ? lineOffset + charsPerLine
            : line.length;

        final subLine = line.isEmpty ? '' : line.substring(lineOffset, endOffset);
        pageBuffer.writeln(subLine);
        currentLinesOnPage++;

        if (currentLinesOnPage >= linesPerPage) {
          final pageContent = pageBuffer.toString().trimRight();
          final pageBytes = utf8.encode(pageContent).length;
          final pageEndByte = currentByteOffset + pageBytes;

          pages.add(FullTxtPageSlice(
            pageIndex: pageIdx++,
            startByteOffset: pageStartByte,
            endByteOffset: pageEndByte,
            content: pageContent,
            chapterTitle: currentPendingChapterTitle,
          ));

          pageBuffer.clear();
          currentLinesOnPage = 0;
          pageStartByte = pageEndByte;
          currentPendingChapterTitle = null;
        }

        if (line.isEmpty) break;
        lineOffset = endOffset;
      }

      currentCharIndex += lineCharLengthWithBreak;
      currentByteOffset += utf8.encode('$rawLine\n').length;
    }

    if (pageBuffer.isNotEmpty || currentPendingChapterTitle != null) {
      final pageContent = pageBuffer.toString().trimRight();
      pages.add(FullTxtPageSlice(
        pageIndex: pageIdx,
        startByteOffset: pageStartByte,
        endByteOffset: totalBytes,
        content: pageContent,
        chapterTitle: currentPendingChapterTitle,
      ));
    }

    return FullTxtPaginationResult(
      pages: pages,
      chapters: chapters,
      totalBytes: totalBytes,
    );
  }
}