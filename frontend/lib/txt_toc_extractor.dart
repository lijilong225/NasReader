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
  // 覆盖绝大部分中文书籍的正则模式（第X章/节/卷/回/幕/序言/尾声等）
  static final RegExp chapterRegex = RegExp(
    r'^\s*(?:第[0-9一二三四五六七八九十百千万零〇]+[章节回卷折篇幕集部]|Chapter\s*\d+|Preface|Prologue|Epilogue|序言|序章|前言|尾声|后记|番外).*',
    caseSensitive: false,
  );

  /// 在后台 Isolate 中快速扫描整个 TXT 文件并提取章节列表（50MB 耗时约 100~200ms）
  static Future<List<TxtChapterItem>> extractTocInIsolate(File file) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_scanWorker, _ScanTask(file.path, receivePort.sendPort));

    final rawList = await receivePort.first as List<Map<String, dynamic>>;
    return rawList.map((m) => TxtChapterItem.fromMap(m)).toList();
  }

  static void _scanWorker(_ScanTask task) async {
    final file = File(task.filePath);
    final raf = await file.open(mode: FileMode.read);
    final totalSize = await file.length();

    final List<Map<String, dynamic>> chapters = [];
    int currentByteOffset = 0;
    int chapterIndex = 0;

    // 默认首章前的内容划为"序章/前言"（如果首行不是章节名）
    bool hasHeader = false;

    // 每次以 64KB 为缓冲区流式解码扫描
    const bufferSize = 64 * 1024;
    List<int> leftover = [];

    while (currentByteOffset < totalSize) {
      final readLen = (currentByteOffset + bufferSize > totalSize)
          ? totalSize - currentByteOffset
          : bufferSize;

      await raf.setPosition(currentByteOffset);
      final rawBuffer = await raf.read(readLen);

      // 拼合上一轮未处理完的换行残留字节
      final fullBuffer = leftover + rawBuffer;
      int lastNewlineIdx = -1;

      // 寻找最后一个换行符位置 \n (ASCII 10)
      for (int i = fullBuffer.length - 1; i >= 0; i--) {
        if (fullBuffer[i] == 10) {
          lastNewlineIdx = i;
          break;
        }
      }

      List<int> processBytes;
      if (lastNewlineIdx != -1 && currentByteOffset + readLen < totalSize) {
        processBytes = fullBuffer.sublist(0, lastNewlineIdx + 1);
        leftover = fullBuffer.sublist(lastNewlineIdx + 1);
      } else {
        processBytes = fullBuffer;
        leftover = [];
      }

      String chunkString;
      try {
        chunkString = utf8.decode(processBytes, allowMalformed: true);
      } catch (_) {
        chunkString = latin1.decode(processBytes);
      }

      // 按行切分扫描
      final lines = const LineSplitter().convert(chunkString);
      int lineByteAcc = 0;

      for (var line in lines) {
        final trimmed = line.trim();
        // 章节名通常不超过 45 个字符，过滤掉误匹配的长段落
        if (trimmed.isNotEmpty && trimmed.length <= 45 && chapterRegex.hasMatch(trimmed)) {
          final chapterBytePos = currentByteOffset + lineByteAcc;

          // 若开头非第一章，先插入序章
          if (chapters.isEmpty && chapterBytePos > 0 && !hasHeader) {
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
            'startByteOffset': chapterBytePos,
          });
        }
        // 累加单行字节长度（包含 \n 换行符，预估 1~2 字节）
        lineByteAcc += utf8.encode(line).length + 1;
      }

      currentByteOffset += (processBytes.length - (leftover.isEmpty ? 0 : 0));
    }

    await raf.close();

    // 若全文未匹配到任何规范章节，则按固定容量虚拟分段作为目录
    if (chapters.isEmpty) {
      int virtualChunkSize = 300 * 1024; // 300KB 一卷
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
  }
}

class _ScanTask {
  final String filePath;
  final SendPort sendPort;

  _ScanTask(this.filePath, this.sendPort);
}