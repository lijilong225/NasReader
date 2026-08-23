import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// 章节目录项
class TxtChapterItem {
  final int index;
  final String title;
  final int startByteOffset; // 章节在全文件中的起始字节偏移量

  TxtChapterItem({
    required this.index,
    required this.title,
    required this.startByteOffset,
  });

  Map<String, dynamic> toMap() => {
    'index': index,
    'title': title,
    'startByteOffset': startByteOffset,
  };

  factory TxtChapterItem.fromMap(Map<String, dynamic> map) => TxtChapterItem(
    index: map['index'] as int,
    title: map['title'] as String,
    startByteOffset: map['startByteOffset'] as int,
  );
}

class TxtTocExtractor {
  // 正则匹配常见中文与英文章节名
  static final RegExp chapterRegex = RegExp(
    r'^\s*(?:第[0-9一二三四五六七八九十百千万零〇]+[章节回卷折篇幕集部]|Chapter\s*\d+|Preface|Prologue|Epilogue|序言|序章|前言|尾声|后记|番外).*',
    caseSensitive: false,
  );

  /// 在后台 Isolate 中快速扫描 TXT 文件并提取章节
  static Future<List<TxtChapterItem>> extractTocInIsolate(File file) async {
    final receivePort = ReceivePort();
    try {
      await Isolate.spawn(_scanWorker, _ScanTask(file.path, receivePort.sendPort));
      final rawList = await receivePort.first as List<Map<String, dynamic>>;
      return rawList.map((m) => TxtChapterItem.fromMap(m)).toList();
    } catch (_) {
      // 容错兜底：Isolate 异常时返回空目录，不阻塞主流程
      return [];
    } finally {
      receivePort.close();
    }
  }

  static void _scanWorker(_ScanTask task) async {
    final file = File(task.filePath);
    final List<Map<String, dynamic>> chapters = [];

    try {
      if (!await file.exists()) {
        task.sendPort.send(chapters);
        return;
      }

      final totalSize = await file.length();
      final stream = file.openRead();

      int currentByteOffset = 0;
      int chapterIndex = 0;
      bool hasHeader = false;

      // 使用系统级流式安全行切分
      final lines = stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final lineBytes = utf8.encode(line).length + 1; // 包含换行预估
        final trimmed = line.trim();

        if (trimmed.isNotEmpty && trimmed.length <= 45 && chapterRegex.hasMatch(trimmed)) {
          if (chapters.isEmpty && currentByteOffset > 0 && !hasHeader) {
            chapters.add({
              'index': chapterIndex++,
              'title': '序章 / 前言',
              'startByteOffset': 0,
            });
            hasHeader = true;
          }

          chapters.add({
            'index': chapterIndex++,
            'title': trimmed,
            'startByteOffset': currentByteOffset,
          });
        }

        currentByteOffset += lineBytes;
      }

      // 如果未识别出正则章节，按 300KB 分卷虚拟目录
      if (chapters.isEmpty) {
        const virtualChunkSize = 300 * 1024;
        int idx = 0;
        for (int pos = 0; pos < totalSize; pos += virtualChunkSize) {
          chapters.add({
            'index': idx,
            'title': '第 ${idx + 1} 部分',
            'startByteOffset': pos,
          });
          idx++;
        }
      }

      task.sendPort.send(chapters);
    } catch (_) {
      // 遇到编码异常或 IO 错误，直接发送已捕获的章节或空列表
      task.sendPort.send(chapters);
    }
  }
}

class _ScanTask {
  final String filePath;
  final SendPort sendPort;

  _ScanTask(this.filePath, this.sendPort);
}