import 'package:flutter/material.dart';

/// 护眼模式配置。实现方式是在正文之上叠加一层暖色遮罩过滤蓝光，
/// 因此对 TXT / EPUB(WebView) / PDF 三种不同的渲染方式都通用。
class EyeCareConfig {
  static const double minIntensity = 0.1;
  static const double maxIntensity = 1.0;

  /// 强度拉满时的遮罩不透明度，再高会明显影响正文辨识度
  static const double _maxAlpha = 0.42;

  /// 暖琥珀色，用于抵消屏幕蓝光
  static const Color filterColor = Color(0xFFFFB65C);

  final bool enabled;
  final double intensity;

  const EyeCareConfig({
    this.enabled = false,
    this.intensity = 0.35,
  });

  /// 关闭时返回 null，调用方据此跳过遮罩层
  Color? get overlayColor {
    if (!enabled) return null;
    final safe = intensity.clamp(minIntensity, maxIntensity);
    return filterColor.withValues(alpha: safe * _maxAlpha);
  }

  EyeCareConfig copyWith({bool? enabled, double? intensity}) {
    return EyeCareConfig(
      enabled: enabled ?? this.enabled,
      intensity: intensity ?? this.intensity,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EyeCareConfig &&
      other.enabled == enabled &&
      other.intensity == intensity;

  @override
  int get hashCode => Object.hash(enabled, intensity);
}
