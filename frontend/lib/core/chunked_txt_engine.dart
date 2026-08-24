import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

/// 分块元数据
class TextChunkMeta {
  final int index;
  final int startByte;
  final int endByte;
  final int byteLength;

  TextChunkMeta({
    required this.index,
    required this.startByte,
    required this.endByte,
    required this.byteLength,
  });
}

/// 分页切片结果
class TxtPageSlice {
  final int globalPageIndex;
  final int startByteOffset;
  final int endByteOffset;
  final String content;

  TxtPageSlice({
    required this.globalPageIndex,
    required this.startByteOffset,
    required this.endByteOffset,
    required this.content,
  });
}

class ChunkedTxtEngine {
  final File file;
  int _totalFileSize = 0;
  final List<TextChunkMeta> _chunks = [];

  // 每块 64KB
  static const int chunkSize = 64 * 1024;

  ChunkedTxtEngine(this.file);

  int get totalFileSize => _totalFileSize;
  List<TextChunkMeta> get chunks => _chunks;

  /// 1. 快速构建物理分块索引
  Future<void> buildIndex() async {
    if (!await file.exists()) return;
    _totalFileSize = await file.length();
    _chunks.clear();

    int offset = 0;
    int chunkIdx = 0;

    while (offset < _totalFileSize) {
      int end = offset + chunkSize;
      if (end > _totalFileSize) {
        end = _totalFileSize;
      }

      _chunks.add(TextChunkMeta(
        index: chunkIdx++,
        startByte: offset,
        endByte: end,
        byteLength: end - offset,
      ));

      offset = end;
    }
  }

  /// 2. 分页测算（主 UI 线程异步测算，避免原生 Isolate 缺少 Rendering Binding 导致静默崩溃）
  static Future<List<TxtPageSlice>> paginateChunkInIsolate({
    required File file,
    required TextChunkMeta chunk,
    required Size contentSize,
    required double fontSize,
    required double lineHeight,
    required double letterSpacing,
  }) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      await raf.setPosition(chunk.startByte);
      final buffer = await raf.read(chunk.endByte - chunk.startByte);
      await raf.close();

      // 安全多编码容错解码
      String chunkText;
      try {
        chunkText = utf8.decode(buffer, allowMalformed: true);
      } catch (_) {
        chunkText = latin1.decode(buffer);
      }

      final List<TxtPageSlice> slices = [];
      int currentOffset = 0;
      final int totalChars = chunkText.length;
      int pageIdx = 0;

      final textStyle = TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        letterSpacing: letterSpacing,
        fontFamily: 'serif',
      );

      final painter = TextPainter(textDirection: TextDirection.ltr);

      // 二分折行测算单页容量
      while (currentOffset < totalChars) {
        int step = 1500;
        int high = (currentOffset + step > totalChars) ? totalChars : currentOffset + step;
        int low = currentOffset + 1;
        int bestFit = low;

        painter.text = TextSpan(
          text: chunkText.substring(currentOffset, high),
          style: textStyle,
        );
        painter.layout(maxWidth: contentSize.width);

        if (painter.height <= contentSize.height && high == totalChars) {
          bestFit = totalChars;
        } else {
          while (low <= high) {
            int mid = (low + high) ~/ 2;
            painter.text = TextSpan(
              text: chunkText.substring(currentOffset, mid),
              style: textStyle,
            );
            painter.layout(maxWidth: contentSize.width);

            if (painter.height <= contentSize.height) {
              bestFit = mid;
              low = mid + 1;
            } else {
              high = mid - 1;
            }
          }
        }

        if (bestFit <= currentOffset) bestFit = currentOffset + 1;

        final pageText = chunkText.substring(currentOffset, bestFit);

        slices.add(TxtPageSlice(
          globalPageIndex: pageIdx++,
          startByteOffset: chunk.startByte + currentOffset,
          endByteOffset: chunk.startByte + bestFit,
          content: pageText,
        ));

        currentOffset = bestFit;
      }

      return slices;
    } catch (e) {
      debugPrint('分页排版测算失败: $e');
      return [];
    }
  }
}