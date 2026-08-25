// lib/core/hand_mode.dart
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_logger.dart';

enum HandMode {
  standard('常规手势'),
  oneHand('单手模式');

  final String label;
  const HandMode(this.label);

  static const String _prefKey = 'user_hand_mode';

  static Future<HandMode> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved == HandMode.oneHand.name) return HandMode.oneHand;
    } catch (e) {
      AppLogger.log('⚠️ 手势模式读取失败，回退常规手势: $e');
    }
    return HandMode.standard;
  }

  static Future<void> saveToPrefs(HandMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (e) {
      AppLogger.log('⚠️ 手势模式保存失败，重启后将丢失: $e');
    }
  }
}