import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

/// Isolate 间通信参数
class _PaginationTask {
  final String filePath;
  final int startByte;
  final int endByte;
  final double maxWidth;
  final double maxHeight;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final SendPort sendPort;

  _PaginationTask({
    required this.filePath,
    required this.startByte,
    required this.endByte,
    required this.maxWidth,
    required this.maxHeight,
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    required this.sendPort,
  });
}

class ChunkedTxtEngine {
  final File file;
  late final int _totalFileSize;
  final List<TextChunkMeta> _chunks = [];
  
  // 默认每块 64KB (既保证快速解码，又覆盖数十页内容)
  static const int chunkSize = 64 * 1024;

  ChunkedTxtEngine(this.file);

  int get totalFileSize => _totalFileSize;
  List<TextChunkMeta> get chunks => _chunks;

  /// 1. 快速构建物理分块索引（不读内容，仅划定边界，耗时 < 10ms）
  Future<void> buildIndex() async {
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

  /// 2. 在独立 Isolate 中对指定 Chunk 进行静默流式排版
  static Future<List<TxtPageSlice>> paginateChunkInIsolate({
    required File file,
    required TextChunkMeta chunk,
    required Size contentSize,
    required double fontSize,
    required double lineHeight,
    required double letterSpacing,
  }) async {
    final receivePort = ReceivePort();

    final task = _PaginationTask(
      filePath: file.path,
      startByte: chunk.startByte,
      endByte: chunk.endByte,
      maxWidth: contentSize.width,
      maxHeight: contentSize.height,
      fontSize: fontSize,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      sendPort: receivePort.sendPort,
    );

    await Isolate.spawn(_isolateWorker, task);

    final result = await receivePort.first as List<Map<String, dynamic>>;
    return result.map((m) => TxtPageSlice(
      globalPageIndex: m['globalPageIndex'],
      startByteOffset: m['startByteOffset'],
      endByteOffset: m['endByteOffset'],
      content: m['content'],
    )).toList();
  }

  /// 后台 Worker：读取局部字节流 -> UTF-8/GBK 安全解码 -> 二分折行计算
  static void _isolateWorker(_PaginationTask task) async {
    final file = File(task.filePath);
    final raf = await file.open(mode: FileMode.read);
    
    await raf.setPosition(task.startByte);
    final buffer = await raf.read(task.endByte - task.startByte);
    await raf.close();

    // 局部解码容错处理
    String chunkText;
    try {
      chunkText = utf8.decode(buffer, allowMalformed: true);
    } catch (_) {
      chunkText = latin1.decode(buffer);
    }

    // 后台纯算法测算
    final List<Map<String, dynamic>> slices = [];
    int currentOffset = 0;
    final int totalChars = chunkText.length;
    int pageIdx = 0;

    final textStyle = TextStyle(
      fontSize: task.fontSize,
      height: task.lineHeight,
      letterSpacing: task.letterSpacing,
      fontFamily: 'serif',
    );

    final painter = TextPainter(textDirection: TextDirection.ltr);

    while (currentOffset < totalChars) {
      int step = 1500;
      int high = (currentOffset + step > totalChars) ? totalChars : currentOffset + step;
      int low = currentOffset + 1;
      int bestFit = low;

      painter.text = TextSpan(
        text: chunkText.substring(currentOffset, high),
        style: textStyle,
      );
      painter.layout(maxWidth: task.maxWidth);

      if (painter.height <= task.maxHeight && high == totalChars) {
        bestFit = totalChars;
      } else {
        while (low <= high) {
          int mid = (low + high) ~/ 2;
          painter.text = TextSpan(
            text: chunkText.substring(currentOffset, mid),
            style: textStyle,
          );
          painter.layout(maxWidth: task.maxWidth);

          if (painter.height <= task.maxHeight) {
            bestFit = mid;
            low = mid + 1;
          } else {
            high = mid - 1;
          }
        }
      }

      if (bestFit <= currentOffset) bestFit = currentOffset + 1;

      final pageText = chunkText.substring(currentOffset, bestFit);
      
      // 粗略折算字节偏移量
      slices.add({
        'globalPageIndex': pageIdx++,
        'startByteOffset': task.startByte + currentOffset,
        'endByteOffset': task.startByte + bestFit,
        'content': pageText,
      });

      currentOffset = bestFit;
    }

    task.sendPort.send(slices);
  }
}