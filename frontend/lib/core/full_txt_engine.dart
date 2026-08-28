import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:charset/charset.dart';
import 'package:flutter/foundation.dart';

/// 缩进统一使用两个全角空格，与 TypographyConfig.applyIndent 保持一致
const String kFullTxtIndent = '\u3000\u3000';

const GbkCodec _looseGbk = GbkCodec(allowMalformed: true);
const Utf16Decoder _utf16Decoder = Utf16Decoder();

enum FullTxtEncoding { utf8, gbk, utf16le, utf16be }

enum FullTxtErrorKind { notFound, empty, permission, undecodable, unknown }

class FullTxtEngineException implements Exception {
  final FullTxtErrorKind kind;
  final String detail;

  const FullTxtEngineException(this.kind, this.detail);

  String get userMessage {
    switch (kind) {
      case FullTxtErrorKind.notFound:
        return '文件不存在或已被移动';
      case FullTxtErrorKind.empty:
        return '文件内容为空';
      case FullTxtErrorKind.permission:
        return '没有读取该文件的权限';
      case FullTxtErrorKind.undecodable:
        return '无法识别的文本编码，可能不是纯文本文件';
      case FullTxtErrorKind.unknown:
        return '文本排版失败，请稍后重试';
    }
  }

  @override
  String toString() => 'FullTxtEngineException($kind): $detail';
}

/// 由主 isolate 用 TextPainter 实测后传入，避免 worker 内按等宽字符估算
class FullTxtLayoutMetrics {
  final double contentWidth;
  final double contentHeight;
  final double bodyAsciiWidth;
  final double bodyWideWidth;
  final double bodyLineHeight;
  final double titleAsciiWidth;
  final double titleWideWidth;
  final double titleLineHeight;
  final bool indentFirstLine;

  const FullTxtLayoutMetrics({
    required this.contentWidth,
    required this.contentHeight,
    required this.bodyAsciiWidth,
    required this.bodyWideWidth,
    required this.bodyLineHeight,
    required this.titleAsciiWidth,
    required this.titleWideWidth,
    required this.titleLineHeight,
    this.indentFirstLine = true,
  });

  int get linesPerPage =>
      math.max(2, (contentHeight / math.max(1.0, bodyLineHeight)).floor());

  int get titleRowSpan =>
      math.max(1, (titleLineHeight / math.max(1.0, bodyLineHeight)).ceil());

  @override
  bool operator ==(Object other) =>
      other is FullTxtLayoutMetrics &&
      other.contentWidth == contentWidth &&
      other.contentHeight == contentHeight &&
      other.bodyAsciiWidth == bodyAsciiWidth &&
      other.bodyWideWidth == bodyWideWidth &&
      other.bodyLineHeight == bodyLineHeight &&
      other.titleAsciiWidth == titleAsciiWidth &&
      other.titleWideWidth == titleWideWidth &&
      other.titleLineHeight == titleLineHeight &&
      other.indentFirstLine == indentFirstLine;

  @override
  int get hashCode => Object.hash(
      contentWidth,
      contentHeight,
      bodyAsciiWidth,
      bodyWideWidth,
      bodyLineHeight,
      titleAsciiWidth,
      titleWideWidth,
      titleLineHeight,
      indentFirstLine);
}

/// 轻量页索引：不携带正文，正文由 FullTxtContentLoader 按需读取
class FullTxtPageSlice {
  final int pageIndex;
  final int startByteOffset;
  final int endByteOffset;
  final String? chapterTitle;  // 章节起始页的标题
  final bool startsMidLine;    // 该页首行是上一页行内断开的续行

  const FullTxtPageSlice({
    required this.pageIndex,
    required this.startByteOffset,
    required this.endByteOffset,
    this.chapterTitle,
    this.startsMidLine = false,
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
  final FullTxtEncoding encoding;

  const FullTxtPaginationResult({
    required this.pages,
    required this.chapters,
    required this.totalBytes,
    required this.encoding,
  });
}

class FullTxtPaginationParams {
  final String filePath;
  final FullTxtLayoutMetrics metrics;

  const FullTxtPaginationParams({
    required this.filePath,
    required this.metrics,
  });
}

class _DecodedFile {
  final String text;
  final FullTxtEncoding encoding;
  final int bomLength;

  const _DecodedFile(this.text, this.encoding, this.bomLength);
}

bool _isWideCodeUnit(int c) {
  return (c >= 0x1100 && c <= 0x115F) ||
      (c >= 0x2E80 && c <= 0xA4CF) ||
      (c >= 0xAC00 && c <= 0xD7A3) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xFE30 && c <= 0xFE6F) ||
      (c >= 0xFF00 && c <= 0xFF60) ||
      (c >= 0xFFE0 && c <= 0xFFE6) ||
      (c >= 0xD800 && c <= 0xDBFF);
}

/// 返回每个渲染行在 [text] 中的结束字符下标（末项恒为 text.length），空串返回 [0]
List<int> _wrapBoundaries(
    String text, double maxWidth, double asciiWidth, double wideWidth) {
  if (text.isEmpty) return const [0];
  final limit = math.max(maxWidth, math.max(asciiWidth, wideWidth));
  final boundaries = <int>[];
  double acc = 0;
  int lineStart = 0;
  int i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    final isSurrogatePair = unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xDC00 &&
        text.codeUnitAt(i + 1) <= 0xDFFF;
    final step = isSurrogatePair ? 2 : 1;
    final width = _isWideCodeUnit(unit) ? wideWidth : asciiWidth;

    if (acc + width > limit && i > lineStart) {
      boundaries.add(i);
      lineStart = i;
      acc = width;
    } else {
      acc += width;
    }
    i += step;
  }
  boundaries.add(text.length);
  return boundaries;
}

int _byteLengthOf(String text, FullTxtEncoding encoding) {
  if (text.isEmpty) return 0;
  switch (encoding) {
    case FullTxtEncoding.utf8:
      return utf8.encode(text).length;
    case FullTxtEncoding.gbk:
      try {
        return _looseGbk.encode(text).length;
      } catch (_) {
        return utf8.encode(text).length;
      }
    case FullTxtEncoding.utf16le:
    case FullTxtEncoding.utf16be:
      return text.length * 2;
  }
}

int _newlineByteLength(FullTxtEncoding encoding) {
  switch (encoding) {
    case FullTxtEncoding.utf8:
    case FullTxtEncoding.gbk:
      return 1;
    case FullTxtEncoding.utf16le:
    case FullTxtEncoding.utf16be:
      return 2;
  }
}

String _decodeBytesAs(List<int> bytes, FullTxtEncoding encoding) {
  if (bytes.isEmpty) return '';
  switch (encoding) {
    case FullTxtEncoding.utf8:
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    case FullTxtEncoding.gbk:
      return _looseGbk.decode(bytes);
    case FullTxtEncoding.utf16le:
      // 区间读取的起点已跳过 BOM，不能再当作 BOM 剥离
      return _utf16Decoder.decodeUtf16Le(bytes, 0, null, false);
    case FullTxtEncoding.utf16be:
      return _utf16Decoder.decodeUtf16Be(bytes, 0, null, false);
  }
}

_DecodedFile _detectAndDecode(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return _DecodedFile(
      const Utf8Decoder(allowMalformed: true).convert(bytes, 3),
      FullTxtEncoding.utf8,
      3,
    );
  }
  if (hasUtf16LeBom(bytes)) {
    return _DecodedFile(_utf16Decoder.decodeUtf16Le(bytes, 0, null, true),
        FullTxtEncoding.utf16le, 2);
  }
  if (hasUtf16BeBom(bytes)) {
    return _DecodedFile(_utf16Decoder.decodeUtf16Be(bytes, 0, null, true),
        FullTxtEncoding.utf16be, 2);
  }

  try {
    return _DecodedFile(utf8.decode(bytes), FullTxtEncoding.utf8, 0);
  } on FormatException {
    // 非 UTF-8，继续按 UTF-16 / GBK 探测
  }

  final probe = math.min(bytes.length, 4096);
  int zeroAtEven = 0;
  int zeroAtOdd = 0;
  for (int i = 0; i < probe; i++) {
    if (bytes[i] != 0) continue;
    if (i.isEven) {
      zeroAtEven++;
    } else {
      zeroAtOdd++;
    }
  }
  if (zeroAtOdd > probe ~/ 8 && zeroAtEven == 0) {
    return _DecodedFile(_utf16Decoder.decodeUtf16Le(bytes, 0, null, false),
        FullTxtEncoding.utf16le, 0);
  }
  if (zeroAtEven > probe ~/ 8 && zeroAtOdd == 0) {
    return _DecodedFile(_utf16Decoder.decodeUtf16Be(bytes, 0, null, false),
        FullTxtEncoding.utf16be, 0);
  }
  if (zeroAtEven + zeroAtOdd > probe ~/ 64) {
    throw FullTxtEngineException(FullTxtErrorKind.undecodable,
        'binary probe found ${zeroAtEven + zeroAtOdd} NUL bytes');
  }

  final gbkText = _looseGbk.decode(bytes);
  final sampled = math.min(gbkText.length, 2048);
  int replacements = 0;
  for (int i = 0; i < sampled; i++) {
    if (gbkText.codeUnitAt(i) == 0xFFFD) replacements++;
  }
  if (sampled > 0 && replacements > sampled ~/ 10) {
    throw FullTxtEngineException(FullTxtErrorKind.undecodable,
        'gbk decode produced $replacements replacement chars');
  }
  return _DecodedFile(gbkText, FullTxtEncoding.gbk, 0);
}

class FullTxtEngine {
  static final RegExp _chapterRegex = RegExp(
    r'^(?:第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,8}\s*[章回节節卷集幕篇部]'
    r'|(?:chapter|section)\s*[0-9]{1,4}'
    // 无编号关键词后不能紧跟正文字符，否则「番外正文。」会被误判为标题
    r'|(?:序章|序言|楔子|前言|引子|自序|后记|後記|番外|尾声|尾聲|终章|終章|结语|結語|附录|附錄)'
    r'(?![\u4e00-\u9fffA-Za-z0-9]))',
    caseSensitive: false,
  );

  static Future<FullTxtPaginationResult> paginate(FullTxtPaginationParams params) {
    return compute(_paginateWorker, params);
  }

  static String? _matchChapterTitle(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return null;
    return _chapterRegex.matchAsPrefix(trimmed) != null ? trimmed : null;
  }

  static FullTxtPaginationResult _paginateWorker(FullTxtPaginationParams params) {
    final file = File(params.filePath);
    if (!file.existsSync()) {
      throw FullTxtEngineException(
          FullTxtErrorKind.notFound, 'missing: ${params.filePath}');
    }

    final int totalBytes;
    final Uint8List rawBytes;
    try {
      totalBytes = file.lengthSync();
      if (totalBytes == 0) {
        throw const FullTxtEngineException(FullTxtErrorKind.empty, 'length = 0');
      }
      rawBytes = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      throw FullTxtEngineException(
        code == 13 || code == 1
            ? FullTxtErrorKind.permission
            : FullTxtErrorKind.unknown,
        e.toString(),
      );
    }

    final decoded = _detectAndDecode(rawBytes);
    final text = decoded.text;
    if (text.trim().isEmpty) {
      throw const FullTxtEngineException(
          FullTxtErrorKind.empty, 'decoded text is blank');
    }

    final encoding = decoded.encoding;
    final metrics = params.metrics;
    final linesPerPage = metrics.linesPerPage;
    final newlineBytes = _newlineByteLength(encoding);

    final pages = <FullTxtPageSlice>[];
    final chapters = <FullTxtChapterItem>[];

    int pageIdx = 0;
    int linesOnPage = 0;
    int chapterCount = 0;
    int currentByteOffset = decoded.bomLength;
    int pageStartByte = decoded.bomLength;
    bool pageStartsMidLine = false;
    String? pendingChapterTitle;
    bool awaitingChapterBody = false;
    int lineStart = 0;

    while (true) {
      final newlineIndex = text.indexOf('\n', lineStart);
      final isLastLine = newlineIndex < 0;
      final rawLine = isLastLine
          ? text.substring(lineStart)
          : text.substring(lineStart, newlineIndex);
      // 末行无换行符时直接收敛到文件长度，避免尾页丢字节
      final nextLineStartByte = isLastLine
          ? totalBytes
          : math.min(
              totalBytes,
              currentByteOffset +
                  _byteLengthOf(rawLine, encoding) +
                  newlineBytes);

      final trimmed = rawLine.trimRight();
      final chapterTitle = _matchChapterTitle(trimmed);

      if (chapterTitle != null) {
        if (linesOnPage > 0 || pendingChapterTitle != null) {
          pages.add(FullTxtPageSlice(
            pageIndex: pageIdx++,
            startByteOffset: pageStartByte,
            endByteOffset: currentByteOffset,
            chapterTitle: pendingChapterTitle,
            startsMidLine: pageStartsMidLine,
          ));
          linesOnPage = 0;
          pendingChapterTitle = null;
        }
        // 新页从章节标题行行首开始
        pageStartByte = currentByteOffset;
        pageStartsMidLine = false;

        chapters.add(FullTxtChapterItem(
          index: chapterCount++,
          title: chapterTitle,
          startByteOffset: currentByteOffset,
          pageIndex: pageIdx,
        ));
        pendingChapterTitle = chapterTitle;
        awaitingChapterBody = true;

        final titleRows = _wrapBoundaries(chapterTitle, metrics.contentWidth,
                    metrics.titleAsciiWidth, metrics.titleWideWidth)
                .length *
            metrics.titleRowSpan;
        linesOnPage = math.min(titleRows, math.max(1, linesPerPage - 1));
      } else if (awaitingChapterBody && trimmed.trim().isEmpty) {
        // 章节标题后的连续空行不占版面
      } else {
        if (trimmed.trim().isNotEmpty) awaitingChapterBody = false;

        var line = trimmed;
        if (metrics.indentFirstLine &&
            line.isNotEmpty &&
            !line.startsWith('\u3000') &&
            !line.startsWith(' ')) {
          line = '$kFullTxtIndent$line';
        }
        // 渲染期注入的缩进不占原文字节，换算真实偏移时需要扣除
        final indentLength = line.length - trimmed.length;

        final boundaries = _wrapBoundaries(line, metrics.contentWidth,
            metrics.bodyAsciiWidth, metrics.bodyWideWidth);

        for (final end in boundaries) {
          linesOnPage++;
          if (linesOnPage < linesPerPage) continue;

          // 整行消费完则落到下一行行首，行内断开则按已消费的原文字符换算
          final int pageEndByte;
          if (end >= line.length) {
            pageEndByte = nextLineStartByte;
          } else {
            final consumedRawChars =
                (end - indentLength).clamp(0, trimmed.length);
            pageEndByte = math.min(
                totalBytes,
                currentByteOffset +
                    _byteLengthOf(
                        trimmed.substring(0, consumedRawChars), encoding));
          }

          pages.add(FullTxtPageSlice(
            pageIndex: pageIdx++,
            startByteOffset: pageStartByte,
            endByteOffset: pageEndByte,
            chapterTitle: pendingChapterTitle,
            startsMidLine: pageStartsMidLine,
          ));

          linesOnPage = 0;
          pageStartByte = pageEndByte;
          pageStartsMidLine = end < line.length;
          pendingChapterTitle = null;
        }
      }

      currentByteOffset = nextLineStartByte;
      if (isLastLine) break;
      lineStart = newlineIndex + 1;
    }

    if (linesOnPage > 0 || pendingChapterTitle != null || pages.isEmpty) {
      pages.add(FullTxtPageSlice(
        pageIndex: pageIdx,
        startByteOffset: pageStartByte,
        endByteOffset: totalBytes,
        chapterTitle: pendingChapterTitle,
        startsMidLine: pageStartsMidLine,
      ));
    } else if (pages.last.endByteOffset < totalBytes) {
      final last = pages.removeLast();
      pages.add(FullTxtPageSlice(
        pageIndex: last.pageIndex,
        startByteOffset: last.startByteOffset,
        endByteOffset: totalBytes,
        chapterTitle: last.chapterTitle,
        startsMidLine: last.startsMidLine,
      ));
    }

    return FullTxtPaginationResult(
      pages: pages,
      chapters: chapters,
      totalBytes: totalBytes,
      encoding: encoding,
    );
  }
}

/// 按页字节区间惰性读取正文，避免整本正文常驻内存
class FullTxtContentLoader {
  FullTxtContentLoader({
    required this.filePath,
    required this.encoding,
    required this.metrics,
    this.cacheSize = 12,
  });

  final String filePath;
  final FullTxtEncoding encoding;
  final FullTxtLayoutMetrics metrics;
  final int cacheSize;

  final LinkedHashMap<int, String> _cache = LinkedHashMap<int, String>();
  RandomAccessFile? _handle;

  String contentOf(FullTxtPageSlice slice) {
    final cached = _cache.remove(slice.pageIndex);
    if (cached != null) {
      _cache[slice.pageIndex] = cached; // 重新插入以刷新 LRU 顺序
      return cached;
    }

    final content = _compose(_readRange(slice), slice);
    _cache[slice.pageIndex] = content;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return content;
  }

  void clearCache() => _cache.clear();

  void dispose() {
    _cache.clear();
    try {
      _handle?.closeSync();
    } catch (_) {
      // 关闭失败无需向上传播
    }
    _handle = null;
  }

  String _readRange(FullTxtPageSlice slice) {
    final length = slice.endByteOffset - slice.startByteOffset;
    if (length <= 0) return '';
    try {
      final handle = _handle ??= File(filePath).openSync();
      handle.setPositionSync(slice.startByteOffset);
      return _decodeBytesAs(handle.readSync(length), encoding);
    } catch (_) {
      return '';
    }
  }

  String _compose(String rawRange, FullTxtPageSlice slice) {
    if (rawRange.isEmpty) return '';

    final buffer = StringBuffer();
    bool skipTitleLine = slice.chapterTitle != null;
    bool awaitingChapterBody = skipTitleLine;
    bool isFirstEmittedLine = true;
    int lineStart = 0;

    while (true) {
      final newlineIndex = rawRange.indexOf('\n', lineStart);
      final isLastLine = newlineIndex < 0;
      final rawLine = isLastLine
          ? rawRange.substring(lineStart)
          : rawRange.substring(lineStart, newlineIndex);
      final trimmed = rawLine.trimRight();

      if (skipTitleLine) {
        skipTitleLine = false;
      } else if (awaitingChapterBody && trimmed.trim().isEmpty) {
        // 与分页阶段一致：标题后的连续空行不渲染
      } else {
        if (trimmed.trim().isNotEmpty) awaitingChapterBody = false;

        var line = trimmed;
        // 续行不再补缩进，否则与分页阶段的字节换算错位
        final asContinuation = isFirstEmittedLine && slice.startsMidLine;
        if (!asContinuation &&
            metrics.indentFirstLine &&
            line.isNotEmpty &&
            !line.startsWith('\u3000') &&
            !line.startsWith(' ')) {
          line = '$kFullTxtIndent$line';
        }
        isFirstEmittedLine = false;

        int fragmentStart = 0;
        for (final end in _wrapBoundaries(line, metrics.contentWidth,
            metrics.bodyAsciiWidth, metrics.bodyWideWidth)) {
          buffer.writeln(line.isEmpty ? '' : line.substring(fragmentStart, end));
          fragmentStart = end;
        }
      }

      if (isLastLine) break;
      lineStart = newlineIndex + 1;
    }

    return buffer.toString().trimRight();
  }
}