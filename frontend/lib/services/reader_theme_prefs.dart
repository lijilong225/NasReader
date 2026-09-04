import 'package:shared_preferences/shared_preferences.dart';

import '../core/reader_theme.dart';
import 'app_logger.dart';

/// 阅读背景主题持久化，TXT 与 EPUB 两个阅读器共用同一份
class ReaderThemePrefs {
  static const String _key = 'reader_theme_name';

  /// 主题里的 Color 与 asset 路径都是编译期常量，存下来也无法回填，
  /// 因此只存名称，读回时到 [ReaderThemes.all] 里取回完整定义
  static Future<ReaderThemeData> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_key);
      if (name == null || name.isEmpty) return ReaderThemes.parchment;
      return resolveByName(name);
    } catch (e) {
      AppLogger.log('⚠️ 阅读背景读取失败: $e');
      return ReaderThemes.parchment;
    }
  }

  static Future<void> save(ReaderThemeData theme) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, theme.name);
    } catch (e) {
      AppLogger.log('⚠️ 阅读背景保存失败: $e');
    }
  }

  /// 主题被改名或下线后，旧存档要能安全退回默认背景而不是抛异常
  static ReaderThemeData resolveByName(String name) {
    for (final theme in ReaderThemes.all) {
      if (theme.name == name) return theme;
    }
    return ReaderThemes.parchment;
  }
}
