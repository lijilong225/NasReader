// lib/services/bookmark_sync_service.dart
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark_model.dart';
import '../services/app_logger.dart';

class BookmarkSyncService {
  static const String _localPrefix = 'local_bookmarks_';

  /// 软删除书签的本地墓碑保留时长，需与后端 bookmarkTombstoneTTL 保持一致
  static const Duration _tombstoneTtl = Duration(days: 30);

  /// 获取某本书的本地有效书签
  static Future<List<Bookmark>> getLocalBookmarks(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList('$_localPrefix$bookId') ?? [];
    return rawList
        .map((e) => Bookmark.fromJson(jsonDecode(e)))
        .where((b) => !b.isDeleted)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// 保存并触发异步同步
  static Future<void> saveBookmark(Bookmark bookmark) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_localPrefix${bookmark.bookId}';
    final rawList = prefs.getStringList(key) ?? [];
    
    final list = rawList.map((e) => Bookmark.fromJson(jsonDecode(e))).toList();
    final idx = list.indexWhere((b) => b.id == bookmark.id);
    if (idx >= 0) {
      list[idx] = bookmark;
    } else {
      list.add(bookmark);
    }

    await prefs.setStringList(key, list.map((e) => jsonEncode(e.toJson())).toList());
    
    // 静默推送到后端
    // ignore: body_might_complete_normally_catch_error
    syncWithServer(bookmark.bookId).catchError((e) {
      AppLogger.log('⚠️ 后端同步推迟: $e');
    });
  }

// 删除时更新为当前毫秒时间戳
  static Future<void> deleteBookmark(String bookId, String bookmarkId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_localPrefix$bookId';
    final rawList = prefs.getStringList(key) ?? [];
    
    final list = rawList.map((e) => Bookmark.fromJson(jsonDecode(e))).toList();
    final idx = list.indexWhere((b) => b.id == bookmarkId);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(
        isDeleted: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setStringList(key, list.map((e) => jsonEncode(e.toJson())).toList());
      // ignore: body_might_complete_normally_catch_error
      syncWithServer(bookId).catchError((_) {});
    }
  }

  /// 双向合并同步引擎
  static Future<List<Bookmark>> syncWithServer(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_localPrefix$bookId';
    final rawList = prefs.getStringList(key) ?? [];
    final localList = rawList.map((e) => Bookmark.fromJson(jsonDecode(e))).toList();

    // 与后端一致的墓碑过期线，超期的软删记录本地也不再保留
    final expireBefore =
        DateTime.now().subtract(_tombstoneTtl).millisecondsSinceEpoch;

    try {
      // 统一走 NetworkClient：共享超时、日志与 401 自动登出策略
      final dio = NetworkClient.getDio();

      // 1. 发送本地记录并拉取服务端记录
      final response = await dio.post(
        '/api/v1/sync/bookmarks',
        data: {
          'bookId': bookId,
          'bookmarks': localList.map((e) => e.toJson()).toList(),
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200 && response.data is List) {
        final serverData = response.data as List;
        final serverList = serverData
            .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
            .toList();

        // 2. 双向比对：以最新 updatedAt 为准 (LWW 原则)
        final mergedMap = <String, Bookmark>{};
        for (final b in localList) {
          mergedMap[b.id] = b;
        }
        // 合并时比对大小
        for (final sb in serverList) {
          if (!mergedMap.containsKey(sb.id) || sb.updatedAt > mergedMap[sb.id]!.updatedAt) {
            mergedMap[sb.id] = sb;
          }
        }

        final finalList = mergedMap.values
            .where((b) => !b.isDeleted || b.updatedAt >= expireBefore)
            .toList();
        await prefs.setStringList(key, finalList.map((e) => jsonEncode(e.toJson())).toList());

        return finalList.where((b) => !b.isDeleted).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } else {
        AppLogger.log('⚠️ 书签同步状态异常 [${response.statusCode}]: ${response.data}');
      }
    } catch (e) {
      AppLogger.log('🌐 离线模式或网络错误，回退本地书签: $e');
    }

    return localList.where((b) => !b.isDeleted).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
}