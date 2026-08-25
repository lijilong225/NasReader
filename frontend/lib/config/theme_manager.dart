// lib/config/theme_manager.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_logger.dart';

class ThemeManager {
  static final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTheme = prefs.getString('app_theme_mode');
      if (savedTheme != null) {
        themeModeNotifier.value = ThemeMode.values.firstWhere(
          (e) => e.name == savedTheme,
          orElse: () => ThemeMode.system,
        );
      }
    } catch (e) {
      AppLogger.log('⚠️ 主题偏好读取失败，回退系统主题: $e');
    }
  }

  static Future<void> updateTheme(ThemeMode mode) async {
    themeModeNotifier.value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_theme_mode', mode.name);
    } catch (e) {
      AppLogger.log('⚠️ 主题偏好保存失败，重启后将丢失: $e');
    }
  }
}