import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:charset/charset.dart';
import 'package:cp949_codec/cp949_codec.dart';
import 'package:enough_convert/big5.dart';
import 'package:flutter/foundation.dart';

/// 缩进统一使用两个全角空格，与 TypographyConfig.applyIndent 保持一致
const String kFullTxtIndent = '\u3000\u3000';

const GbkCodec _looseGbk = GbkCodec(allowMalformed: true);
const Big5Codec _looseBig5 = Big5Codec(allowInvalid: true);
const ShiftJISCodec _looseShiftJis = ShiftJISCodec(allowMalformed: true);

/// EucJPCodec 的 allowMalformed 判断是反的：传 true 会在遇到非法字节时抛异常，
/// 传 false 才写入 U+FFFD。这里需要的是宽松解码，所以必须传 false。
const EucJPCodec _looseEucJp = EucJPCodec(false);

/// charset 包自带的 EUC-KR 码表有误（会解出完全错误的汉字），改用 CP949。
/// CP949 是 EUC-KR 的超集，能兼容解码标准 EUC-KR 文本。
const CP949Codec _looseEucKr = CP949Codec(allowInvalid: true);

const Utf16Decoder _utf16Decoder = Utf16Decoder();

enum FullTxtEncoding {
  utf8,
  gbk,
  big5,
  shiftJis,
  eucJp,
  eucKr,
  utf16le,
  utf16be,
}

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

/// 双字节编码的字节数估算：ASCII 占 1 字节，其余占 2 字节。
/// Big5 / Shift-JIS 的 encoder 会把部分符号回写成 1 字节（例如 Big5 的 0xA145
/// 解成 U+2022，再编码只剩 1 字节），直接用 encode().length 会让页字节偏移漂移，
/// 所以这两种编码按码元分类计算。
int _dbcsByteLength(String text) {
  int total = 0;
  for (int i = 0; i < text.length; i++) {
    total += text.codeUnitAt(i) < 0x80 ? 1 : 2;
  }
  return total;
}

/// Shift-JIS 的半角片假名（U+FF61–U+FF9F）在源文件里只占 1 字节
int _shiftJisByteLength(String text) {
  int total = 0;
  for (int i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    total += (unit < 0x80 || (unit >= 0xFF61 && unit <= 0xFF9F)) ? 1 : 2;
  }
  return total;
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
        return _dbcsByteLength(text);
      }
    case FullTxtEncoding.big5:
      return _dbcsByteLength(text);
    case FullTxtEncoding.shiftJis:
      return _shiftJisByteLength(text);
    case FullTxtEncoding.eucJp:
      // EUC-JP 有 0x8F 开头的三字节序列，只有 encoder 能准确还原长度
      try {
        return _looseEucJp.encode(text).length;
      } catch (_) {
        return _dbcsByteLength(text);
      }
    case FullTxtEncoding.eucKr:
      try {
        return _looseEucKr.encode(text).length;
      } catch (_) {
        return _dbcsByteLength(text);
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
    case FullTxtEncoding.big5:
    case FullTxtEncoding.shiftJis:
    case FullTxtEncoding.eucJp:
    case FullTxtEncoding.eucKr:
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
    case FullTxtEncoding.big5:
      return _looseBig5.decode(bytes);
    case FullTxtEncoding.shiftJis:
      return _looseShiftJis.decode(bytes);
    case FullTxtEncoding.eucJp:
      return _looseEucJp.decode(bytes);
    case FullTxtEncoding.eucKr:
      return _looseEucKr.decode(bytes);
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

  return _rankLegacyEncodings(bytes);
}

/// 单字节编码候选的结构合法性统计
class _StructStats {
  const _StructStats(this.units, this.bad, this.multi);

  /// 按该编码规则切出的字符个数
  final int units;

  /// 不符合该编码 lead/trail 规则的字节数
  final int bad;

  /// 多字节字符个数，为 0 说明该编码根本没派上用场
  final int multi;

  double get badRatio => units == 0 ? 1 : bad / units;
}

/// 每种候选编码用自己的 lead/trail 规则走一遍原始字节。
/// 这一步只看字节结构，与解码结果无关，可以过滤掉大部分不可能的候选。
_StructStats _structScan(Uint8List bytes, FullTxtEncoding encoding) {
  final int length = bytes.length;
  int i = 0;
  int units = 0;
  int bad = 0;
  int multi = 0;

  while (i < length) {
    final int lead = bytes[i];
    if (lead < 0x80) {
      i++;
      units++;
      continue;
    }
    final int trail = i + 1 < length ? bytes[i + 1] : -1;
    int step = 1;
    bool valid = false;

    switch (encoding) {
      case FullTxtEncoding.gbk:
        valid = lead >= 0x81 &&
            lead <= 0xFE &&
            trail >= 0x40 &&
            trail <= 0xFE &&
            trail != 0x7F;
        if (valid) step = 2;
        break;
      case FullTxtEncoding.big5:
        valid = lead >= 0x81 &&
            lead <= 0xFE &&
            ((trail >= 0x40 && trail <= 0x7E) ||
                (trail >= 0xA1 && trail <= 0xFE));
        if (valid) step = 2;
        break;
      case FullTxtEncoding.shiftJis:
        if (lead >= 0xA1 && lead <= 0xDF) {
          // 半角片假名，单字节
          i++;
          units++;
          continue;
        }
        valid = ((lead >= 0x81 && lead <= 0x9F) ||
                (lead >= 0xE0 && lead <= 0xFC)) &&
            trail >= 0x40 &&
            trail <= 0xFC &&
            trail != 0x7F;
        if (valid) step = 2;
        break;
      case FullTxtEncoding.eucJp:
        if (lead == 0x8E && trail >= 0xA1 && trail <= 0xDF) {
          valid = true;
          step = 2;
        } else if (lead == 0x8F &&
            i + 2 < length &&
            trail >= 0xA1 &&
            trail <= 0xFE &&
            bytes[i + 2] >= 0xA1 &&
            bytes[i + 2] <= 0xFE) {
          // JIS X 0212 三字节序列
          valid = true;
          step = 3;
        } else if (lead >= 0xA1 &&
            lead <= 0xFE &&
            trail >= 0xA1 &&
            trail <= 0xFE) {
          valid = true;
          step = 2;
        }
        break;
      case FullTxtEncoding.eucKr:
        valid = lead >= 0x81 &&
            lead <= 0xFD &&
            ((trail >= 0x41 && trail <= 0x5A) ||
                (trail >= 0x61 && trail <= 0x7A) ||
                (trail >= 0x81 && trail <= 0xFE));
        if (valid) step = 2;
        break;
      case FullTxtEncoding.utf8:
      case FullTxtEncoding.utf16le:
      case FullTxtEncoding.utf16be:
        valid = false;
        break;
    }

    if (valid) {
      multi++;
    } else {
      bad++;
    }
    units++;
    i += step;
  }
  return _StructStats(units, bad, multi);
}

/// 解码结果的文字构成画像，用来判断解码出来的到底是人话还是乱码
class _ScriptProfile {
  const _ScriptProfile({
    required this.sampled,
    required this.cjk,
    required this.kana,
    required this.halfKana,
    required this.hangul,
    required this.jamo,
    required this.punct,
    required this.latin,
  });

  final int sampled;
  final double cjk;
  final double kana;
  final double halfKana;
  final double hangul;
  final double jamo;
  final double punct;
  final double latin;
}

_ScriptProfile? _profileScript(String text) {
  int total = 0;
  int cjk = 0;
  int kana = 0;
  int halfKana = 0;
  int hangul = 0;
  int jamo = 0;
  int punct = 0;
  int latin = 0;

  for (int i = 0; i < text.length; i++) {
    final int unit = text.codeUnitAt(i);
    if (unit < 0x80 || unit == 0xFFFD) continue;
    total++;
    if ((unit >= 0x4E00 && unit <= 0x9FFF) ||
        (unit >= 0x3400 && unit <= 0x4DBF) ||
        (unit >= 0xF900 && unit <= 0xFAFF)) {
      cjk++;
    } else if (unit >= 0x3040 && unit <= 0x30FF) {
      kana++;
    } else if (unit >= 0xFF61 && unit <= 0xFF9F) {
      halfKana++;
    } else if (unit >= 0xAC00 && unit <= 0xD7A3) {
      hangul++;
    } else if (unit >= 0x3130 && unit <= 0x318F) {
      jamo++;
    } else if ((unit >= 0x2010 && unit <= 0x203B) ||
        (unit >= 0x3000 && unit <= 0x303F) ||
        (unit >= 0xFF01 && unit <= 0xFF5E)) {
      punct++;
    } else if ((unit >= 0x00A0 && unit <= 0x024F) ||
        (unit >= 0x0370 && unit <= 0x04FF)) {
      latin++;
    }
  }

  if (total == 0) return null;
  double r(int n) => n / total;
  return _ScriptProfile(
    sampled: total,
    cjk: r(cjk),
    kana: r(kana),
    halfKana: r(halfKana),
    hangul: r(hangul),
    jamo: r(jamo),
    punct: r(punct),
    latin: r(latin),
  );
}

/// 传统多字节编码的候选列表。gbk 放在最前面，评分相同时优先保留现有行为。
const List<FullTxtEncoding> _legacyCandidates = [
  FullTxtEncoding.gbk,
  FullTxtEncoding.big5,
  FullTxtEncoding.shiftJis,
  FullTxtEncoding.eucJp,
  FullTxtEncoding.eucKr,
];

/// 打分阈值。低于此值说明所有候选解出来的都是乱码，判定为非文本文件。
const double _minLegacyScore = 3.0;

double? _scoreLegacyCandidate(
  Uint8List bytes,
  FullTxtEncoding encoding,
  String text,
) {
  final stats = _structScan(bytes, encoding);
  // 该编码完全没有用到多字节规则，说明它不可能是正确答案
  if (stats.multi == 0) return null;

  final profile = _profileScript(text);
  if (profile == null) return null;

  int replacements = 0;
  for (int i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0xFFFD) replacements++;
  }
  final double badRatio =
      text.isEmpty ? 1 : replacements / text.length;

  double score = 4.0 * (1.0 - badRatio) + 4.0 * (1.0 - stats.badRatio);

  // 半角片假名和兼容谚文字母在真实读物里几乎不出现，占比高就是乱码的强信号
  score -= 4.0 * profile.halfKana + 3.0 * profile.jamo;
  score += 1.5 *
      (profile.cjk +
          profile.kana +
          profile.hangul +
          profile.punct +
          profile.latin);

  switch (encoding) {
    case FullTxtEncoding.gbk:
    case FullTxtEncoding.big5:
      score += 2.0 * profile.cjk - 4.0 * (profile.kana + profile.hangul);
      break;
    case FullTxtEncoding.shiftJis:
    case FullTxtEncoding.eucJp:
      // 日文散文里假名与汉字必然共存，只有汉字说明大概率是中文被错解
      score += profile.kana >= 0.10
          ? 3.0 * math.min(profile.kana, 0.45) / 0.45
          : -3.0;
      score += profile.cjk >= 0.10 ? 1.0 : -2.0;
      score -= 4.0 * profile.hangul;
      break;
    case FullTxtEncoding.eucKr:
      score += profile.hangul >= 0.85 ? 3.0 : -3.0;
      score -= 4.0 * profile.kana;
      score -= 2.0 * profile.cjk;
      break;
    case FullTxtEncoding.utf8:
    case FullTxtEncoding.utf16le:
    case FullTxtEncoding.utf16be:
      return null;
  }
  return score;
}

/// 在 GBK / Big5 / Shift-JIS / EUC-JP / EUC-KR 之间挑一个最像人话的。
/// 宽松解码几乎对任何 CJK 字节流都不报错，所以单靠替换字符数量无法区分，
/// 必须同时看字节结构合法性和解码结果的文字构成。
_DecodedFile _rankLegacyEncodings(Uint8List bytes) {
  // 打分只取文件开头一段，避免大文件全量解码
  final Uint8List sample = bytes.length > 65536
      ? Uint8List.sublistView(bytes, 0, 65536)
      : bytes;

  FullTxtEncoding? best;
  double bestScore = 0;
  for (final encoding in _legacyCandidates) {
    String text;
    try {
      text = _decodeBytesAs(sample, encoding);
    } catch (_) {
      continue;
    }
    final score = _scoreLegacyCandidate(sample, encoding, text);
    if (score == null) continue;
    if (best == null || score > bestScore) {
      best = encoding;
      bestScore = score;
    }
  }

  if (best == null || bestScore < _minLegacyScore) {
    throw FullTxtEngineException(
      FullTxtErrorKind.undecodable,
      'no legacy encoding matched (best=${best?.name ?? 'none'} '
      'score=${bestScore.toStringAsFixed(2)})',
    );
  }
  return _DecodedFile(_decodeBytesAs(bytes, best), best, 0);
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