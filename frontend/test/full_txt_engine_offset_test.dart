import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/full_txt_engine.dart';

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
      contentSize: const Size(320, 480),
      fontSize: 18,
      lineHeight: 1.6,
      letterSpacing: 0.5,
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
}
