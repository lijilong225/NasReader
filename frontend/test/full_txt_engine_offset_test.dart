import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/full_txt_engine.dart';

/// 纯数值度量，测试环境无需 TextPainter 实测
const FullTxtLayoutMetrics kTestMetrics = FullTxtLayoutMetrics(
  contentWidth: 320,
  contentHeight: 480,
  bodyAsciiWidth: 9.0,
  bodyWideWidth: 18.0,
  bodyLineHeight: 28.8,
  titleAsciiWidth: 11.25,
  titleWideWidth: 22.5,
  titleLineHeight: 31.5,
);

/// 与阅读页保持一致的定位逻辑：取最后一个起始偏移不超过目标值的页
int locatePage(List<FullTxtPageSlice> pages, int byteOffset) {
  if (pages.isEmpty || byteOffset <= 0) return 0;
  int target = 0;
  for (int i = 0; i < pages.length; i++) {
    if (pages[i].startByteOffset <= byteOffset) {
      target = i;
    } else {
      break;
    }
  }
  return target;
}

void main() {
  late Directory tempDir;
  late File txtFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('full_txt_engine_test');
    final buffer = StringBuffer();
    for (int c = 1; c <= 5; c++) {
      buffer.writeln('第$c章 测试章节标题');
      buffer.writeln();
      for (int p = 0; p < 12; p++) {
        buffer.writeln('　　这是第$c章的第$p段中文正文内容，用于验证分页字节偏移是否与原文一致。'
            '混合 ASCII text 与多字节字符，确保 UTF-8 换算路径被覆盖。');
      }
    }
    txtFile = File('${tempDir.path}/sample.txt');
    await txtFile.writeAsString(buffer.toString());
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<FullTxtPaginationResult> paginate() {
    return FullTxtEngine.paginate(FullTxtPaginationParams(
      filePath: txtFile.path,
      metrics: kTestMetrics,
    ));
  }

  test('分页字节区间连续且覆盖整个文件', () async {
    final result = await paginate();

    expect(result.pages, isNotEmpty);
    expect(result.pages.first.startByteOffset, 0);
    expect(result.pages.last.endByteOffset, result.totalBytes);
    expect(result.totalBytes, utf8.encode(await txtFile.readAsString()).length);

    for (int i = 0; i < result.pages.length; i++) {
      final page = result.pages[i];
      expect(page.startByteOffset, lessThanOrEqualTo(page.endByteOffset));
      expect(page.endByteOffset, lessThanOrEqualTo(result.totalBytes));
      if (i + 1 < result.pages.length) {
        expect(
          result.pages[i + 1].startByteOffset,
          page.endByteOffset,
          reason: '第 $i 页与第 ${i + 1} 页的字节区间必须首尾相接',
        );
      }
    }
  });

  test('保存页首偏移后可以定位回同一页（无倒退漂移）', () async {
    final result = await paginate();

    for (final page in result.pages) {
      expect(
        locatePage(result.pages, page.startByteOffset),
        page.pageIndex,
        reason: '第 ${page.pageIndex} 页的起始偏移 ${page.startByteOffset} 应定位回自身',
      );
    }
  });

  test('反复退出再进入不会累积偏移漂移', () async {
    final result = await paginate();
    final startIndex = result.pages.length ~/ 2;

    int offset = result.pages[startIndex].startByteOffset;
    for (int round = 0; round < 5; round++) {
      final located = locatePage(result.pages, offset);
      expect(located, startIndex, reason: '第 $round 轮定位发生漂移');
      offset = result.pages[located].startByteOffset;
    }
  });

  test('识别多种章节标题形式', () async {
    final file = File('${tempDir.path}/chapters.txt');
    await file.writeAsString([
      '序章',
      '正文一段内容。',
      '第 1 章 开端',
      '正文二段内容。',
      'Chapter 3 Rising',
      'body text here.',
      '番外',
      '番外正文。',
    ].join('\n'));

    final result = await FullTxtEngine.paginate(
        FullTxtPaginationParams(filePath: file.path, metrics: kTestMetrics));

    expect(result.chapters.map((c) => c.title).toList(),
        ['序章', '第 1 章 开端', 'Chapter 3 Rising', '番外']);
    expect(result.encoding, FullTxtEncoding.utf8);
  });

  test('GBK 文件字节区间连续且覆盖整个文件', () async {
    final file = File('${tempDir.path}/gbk.txt');
    final content = StringBuffer();
    for (int c = 1; c <= 3; c++) {
      content.writeln('第$c章 中文标题');
      for (int p = 0; p < 10; p++) {
        content.writeln('　　这是 GBK 编码的第$c章第$p段正文，混合 ASCII 与中文字符。');
      }
    }
    await file.writeAsBytes(gbk.encode(content.toString()));

    final result = await FullTxtEngine.paginate(
        FullTxtPaginationParams(filePath: file.path, metrics: kTestMetrics));

    expect(result.encoding, FullTxtEncoding.gbk);
    expect(result.pages.first.startByteOffset, 0);
    expect(result.pages.last.endByteOffset, result.totalBytes);
    for (int i = 0; i + 1 < result.pages.length; i++) {
      expect(result.pages[i + 1].startByteOffset, result.pages[i].endByteOffset,
          reason: 'GBK 分页第 $i 页与下一页必须首尾相接');
    }
    for (final page in result.pages) {
      expect(locatePage(result.pages, page.startByteOffset), page.pageIndex);
    }
  });

  test('空文件与缺失文件抛出可读错误', () async {
    final emptyFile = File('${tempDir.path}/empty.txt');
    await emptyFile.writeAsString('');

    await expectLater(
      FullTxtEngine.paginate(
          FullTxtPaginationParams(filePath: emptyFile.path, metrics: kTestMetrics)),
      throwsA(isA<FullTxtEngineException>()
          .having((e) => e.kind, 'kind', FullTxtErrorKind.empty)),
    );

    await expectLater(
      FullTxtEngine.paginate(FullTxtPaginationParams(
          filePath: '${tempDir.path}/nope.txt', metrics: kTestMetrics)),
      throwsA(isA<FullTxtEngineException>()
          .having((e) => e.kind, 'kind', FullTxtErrorKind.notFound)),
    );
  });

  test('惰性加载器按页读取的正文与分页边界一致', () async {
    final result = await paginate();
    final loader = FullTxtContentLoader(
      filePath: txtFile.path,
      encoding: result.encoding,
      metrics: kTestMetrics,
    );
    addTearDown(loader.dispose);

    for (final page in result.pages) {
      final content = loader.contentOf(page);
      // 章节标题由标题 TextSpan 单独渲染，正文不应重复包含
      if (page.chapterTitle != null) {
        expect(content.startsWith(page.chapterTitle!), isFalse);
      }
      expect(content, loader.contentOf(page), reason: 'LRU 缓存命中结果必须一致');
    }
  });
}
