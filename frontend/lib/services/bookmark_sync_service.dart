// lib/services/bookmark_sync_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:nas_reader/config/api_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark_model.dart';
import '../services/app_logger.dart';

class BookmarkSyncService {
  static const String _localPrefix = 'local_bookmarks_';

  /// 获取服务器基础地址（可从配置或本地存储读取，支持动态配置）
  static Future<String> _getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    // 优先读取用户在设置中保存的 NAS 地址，默认回退到局域网地址
    return prefs.getString('server_base_url') ?? ApiConfig.baseUrl;
  }

  /// 获取本地保存的 JWT Token
  static Future<String?> _getAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

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
    syncWithServer(bookmark.bookId).catchError((e) {
      AppLogger.log('⚠️ 后端同步推迟: $e');
    });
  }

  /// 软删除书签
  static Future<void> deleteBookmark(String bookId, String bookmarkId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_localPrefix$bookId';
    final rawList = prefs.getStringList(key) ?? [];
    
    final list = rawList.map((e) => Bookmark.fromJson(jsonDecode(e))).toList();
    final idx = list.indexWhere((b) => b.id == bookmarkId);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(isDeleted: true, updatedAt: DateTime.now());
      await prefs.setStringList(key, list.map((e) => jsonEncode(e.toJson())).toList());
      syncWithServer(bookId).catchError((_) {});
    }
  }

  /// 双向合并同步引擎
  static Future<List<Bookmark>> syncWithServer(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_localPrefix$bookId';
    final rawList = prefs.getStringList(key) ?? [];
    final localList = rawList.map((e) => Bookmark.fromJson(jsonDecode(e))).toList();

    try {
      final baseUrl = await _getBaseUrl();
      final token = await _getAuthToken();

      // 构建完整的 URL：http://host:port/api/v1/sync/bookmarks
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/v1/sync/bookmarks');

      final headers = {
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      // 1. 发送本地记录并拉取服务端记录
      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode({
          'bookId': bookId,
          'bookmarks': localList.map((e) => e.toJson()).toList(),
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final serverData = jsonDecode(response.body) as List;
        final serverList = serverData.map((e) => Bookmark.fromJson(e)).toList();

        // 2. 双向比对：以最新 updatedAt 为准 (LWW 原则)
        final mergedMap = <String, Bookmark>{};
        for (final b in localList) {
          mergedMap[b.id] = b;
        }
        for (final sb in serverList) {
          if (!mergedMap.containsKey(sb.id) || sb.updatedAt.isAfter(mergedMap[sb.id]!.updatedAt)) {
            mergedMap[sb.id] = sb;
          }
        }

        final finalList = mergedMap.values.toList();
        await prefs.setStringList(key, finalList.map((e) => jsonEncode(e.toJson())).toList());

        return finalList.where((b) => !b.isDeleted).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } else {
        AppLogger.log('⚠️ 书签同步状态异常 [${response.statusCode}]: ${response.body}');
      }
    } catch (e) {
      AppLogger.log('🌐 离线模式或网络错误，回退本地书签: $e');
    }

    return localList.where((b) => !b.isDeleted).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
}