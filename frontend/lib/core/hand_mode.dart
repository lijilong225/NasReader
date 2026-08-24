// lib/core/hand_mode.dart
import 'package:shared_preferences/shared_preferences.dart';

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
    } catch (_) {}
    return HandMode.standard;
  }

  static Future<void> saveToPrefs(HandMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (_) {}
  }
}