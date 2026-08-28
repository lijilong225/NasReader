import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/typography_config.dart';
import 'app_logger.dart';

/// 排版配置持久化，TXT 与 EPUB 共用同一份
class TypographyPrefs {
  static const String _key = 'typography_config';

  static Future<TypographyConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const TypographyConfig();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const TypographyConfig();
      return TypographyConfig.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      AppLogger.log('⚠️ 排版配置读取失败: $e');
      return const TypographyConfig();
    }
  }

  static Future<void> save(TypographyConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(config.toJson()));
    } catch (e) {
      AppLogger.log('⚠️ 排版配置保存失败: $e');
    }
  }
}
