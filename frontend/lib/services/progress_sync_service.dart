import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_logger.dart';

class BookProgress {
  final String bookId;
  final String title;
  final String filePath; // NAS 远端路径
  final double progressPercent;
  final String? epubCfi;
  final int? txtByteOffset;
  final int lastReadTime; // 毫秒时间戳

  BookProgress({
    required this.bookId,
    required this.title,
    required this.filePath,
    required this.progressPercent,
    this.epubCfi,
    this.txtByteOffset,
    required this.lastReadTime,
  });

  Map<String, dynamic> toJson() => {
    'book_id': bookId,
    'title': title,
    'file_path': filePath,
    'progress_percent': progressPercent,
    'epub_cfi': epubCfi,
    'txt_byte_offset': txtByteOffset,
    'last_read_time': lastReadTime,
  };

  factory BookProgress.fromJson(Map<String, dynamic> json) => BookProgress(
    bookId: json['book_id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    filePath: json['file_path']?.toString() ?? '',
    progressPercent: (json['progress_percent'] as num?)?.toDouble() ?? 0.0,
    epubCfi: json['epub_cfi']?.toString(),
    txtByteOffset: (json['txt_byte_offset'] as num?)?.toInt(),
    lastReadTime: (json['last_read_time'] as num?)?.toInt() ?? 0,
  );
}

class ProgressSyncService {
  static const String _storageKey = 'local_reading_progress_map';

  /// 1. 保存本地进度并上报给 NAS 远端
  static Future<void> updateProgress({
    required Dio? dio,
    required String bookId,
    required String title,
    required String filePath,
    required double progressPercent,
    String? epubCfi,
    int? txtByteOffset,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final item = BookProgress(
      bookId: bookId,
      title: title,
      filePath: filePath,
      progressPercent: progressPercent,
      epubCfi: epubCfi,
      txtByteOffset: txtByteOffset,
      lastReadTime: now,
    );

    // 写入本地存储
    final prefs = await SharedPreferences.getInstance();
    final rawMap = prefs.getString(_storageKey);
    Map<String, dynamic> map = rawMap != null ? jsonDecode(rawMap) : {};
    map[bookId] = item.toJson();
    await prefs.setString(_storageKey, jsonEncode(map));

    // 上报后端：POST /api/v1/sync/progress
    if (dio != null) {
      try {
        await dio.post('/api/v1/sync/progress', data: item.toJson());
      } catch (e) {
        AppLogger.log('⚠️ 上报进度至远端失败: $e');
      }
    }
  }

  /// 2. 从 NAS 远端拉取最新全量阅读进度：GET /api/v1/sync/progress
  static Future<List<BookProgress>> syncWithRemote(Dio dio) async {
    try {
      final res = await dio.get('/api/v1/sync/progress');
      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> remoteList = [];
        if (res.data is Map && res.data['data'] is List) {
          remoteList = res.data['data'];
        } else if (res.data is List) {
          remoteList = res.data;
        }

        final prefs = await SharedPreferences.getInstance();
        final rawMap = prefs.getString(_storageKey);
        Map<String, dynamic> localMap = rawMap != null ? jsonDecode(rawMap) : {};

        for (var raw in remoteList) {
          final remoteItem = BookProgress.fromJson(Map<String, dynamic>.from(raw));
          if (remoteItem.bookId.isEmpty) continue;

          // 时间戳对比：保留最新进度
          if (localMap.containsKey(remoteItem.bookId)) {
            final localItem = BookProgress.fromJson(localMap[remoteItem.bookId]);
            if (remoteItem.lastReadTime > localItem.lastReadTime) {
              localMap[remoteItem.bookId] = remoteItem.toJson();
            }
          } else {
            localMap[remoteItem.bookId] = remoteItem.toJson();
          }
        }

        await prefs.setString(_storageKey, jsonEncode(localMap));
      }
    } on DioException catch (e) {
      AppLogger.log('⚠️ 远端进度同步异常: ${e.message}');
    } catch (e) {
      AppLogger.log('⚠️ 远端进度同步异常: $e');
    }

    return getAllLocalProgress();
  }

  /// 获取本地所有阅读记录列表
  static Future<List<BookProgress>> getAllLocalProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final rawMap = prefs.getString(_storageKey);
    if (rawMap == null) return [];
    final map = jsonDecode(rawMap) as Map<String, dynamic>;
    final list = map.values.map((v) => BookProgress.fromJson(v)).toList();
    list.sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
    return list;
  }
}