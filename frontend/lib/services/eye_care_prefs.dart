import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/eye_care_config.dart';
import 'app_logger.dart';

/// 护眼模式持久化，TXT / EPUB / PDF 三个阅读器共用同一份
class EyeCarePrefs {
  static const String _enabledKey = 'eye_care_enabled';
  static const String _intensityKey = 'eye_care_intensity';

  static Future<EyeCareConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const fallback = EyeCareConfig();
      final intensity = prefs.getDouble(_intensityKey) ?? fallback.intensity;
      return EyeCareConfig(
        enabled: prefs.getBool(_enabledKey) ?? fallback.enabled,
        intensity: intensity.clamp(
          EyeCareConfig.minIntensity,
          EyeCareConfig.maxIntensity,
        ),
      );
    } catch (e) {
      AppLogger.log('⚠️ 护眼模式配置读取失败: $e');
      return const EyeCareConfig();
    }
  }

  static Future<void> save(EyeCareConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, config.enabled);
      await prefs.setDouble(_intensityKey, config.intensity);
    } catch (e) {
      AppLogger.log('⚠️ 护眼模式配置保存失败: $e');
    }
  }
}
