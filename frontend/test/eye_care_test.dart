import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/eye_care_prefs.dart';
import 'package:nas_reader/widgets/eye_care_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('EyeCareConfig', () {
    test('默认关闭，overlayColor 为 null', () {
      const config = EyeCareConfig();
      expect(config.enabled, isFalse);
      expect(config.overlayColor, isNull);
    });

    test('开启后遮罩不透明度随强度线性增长且不超过上限', () {
      const low = EyeCareConfig(enabled: true, intensity: 0.1);
      const high = EyeCareConfig(enabled: true, intensity: 1.0);

      expect(low.overlayColor!.a, lessThan(high.overlayColor!.a));
      expect(high.overlayColor!.a, closeTo(0.42, 0.001));
      expect(high.overlayColor!.a, lessThan(0.5));
    });

    test('越界强度被夹到合法区间', () {
      const tooLow = EyeCareConfig(enabled: true, intensity: -1);
      const tooHigh = EyeCareConfig(enabled: true, intensity: 9);

      expect(tooLow.overlayColor!.a,
          closeTo(const EyeCareConfig(enabled: true, intensity: 0.1).overlayColor!.a, 0.001));
      expect(tooHigh.overlayColor!.a,
          closeTo(const EyeCareConfig(enabled: true, intensity: 1.0).overlayColor!.a, 0.001));
    });

    test('copyWith 只覆盖传入字段', () {
      const base = EyeCareConfig(enabled: false, intensity: 0.5);
      expect(base.copyWith(enabled: true), const EyeCareConfig(enabled: true, intensity: 0.5));
      expect(base.copyWith(intensity: 0.8), const EyeCareConfig(enabled: false, intensity: 0.8));
    });
  });

  group('EyeCarePrefs', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('无历史配置时返回默认值', () async {
      final loaded = await EyeCarePrefs.load();
      expect(loaded, const EyeCareConfig());
    });

    test('save 后 load 能取回同一份配置', () async {
      const config = EyeCareConfig(enabled: true, intensity: 0.75);
      await EyeCarePrefs.save(config);
      expect(await EyeCarePrefs.load(), config);
    });

    test('历史脏数据中的越界强度被夹回合法区间', () async {
      SharedPreferences.setMockInitialValues({
        'eye_care_enabled': true,
        'eye_care_intensity': 5.0,
      });

      final loaded = await EyeCarePrefs.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.intensity, EyeCareConfig.maxIntensity);
    });
  });
}
