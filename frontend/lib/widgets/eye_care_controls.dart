import 'package:flutter/material.dart';

import 'eye_care_config.dart';

/// 护眼滤镜层，盖在正文之上、控制条之下，不拦截手势
class EyeCareOverlay extends StatelessWidget {
  final EyeCareConfig config;

  const EyeCareOverlay({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    final color = config.overlayColor;
    if (color == null) return const SizedBox.shrink();
    return IgnorePointer(child: ColoredBox(color: color));
  }
}

/// 阅读器底部控制条内的护眼开关与强度滑块
class EyeCareControlRow extends StatelessWidget {
  final EyeCareConfig config;
  final ValueChanged<EyeCareConfig> onChanged;

  const EyeCareControlRow({
    super.key,
    required this.config,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (config.intensity * 100).round();

    return Row(
      children: [
        const Icon(Icons.remove_red_eye_outlined, color: Colors.white70, size: 16),
        const SizedBox(width: 6),
        const Text('护眼', style: TextStyle(color: Colors.white70, fontSize: 12)),
        Switch(
          value: config.enabled,
          activeThumbColor: Colors.brown.shade300,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (v) => onChanged(config.copyWith(enabled: v)),
        ),
        Expanded(
          child: Slider(
            value: config.intensity.clamp(
              EyeCareConfig.minIntensity,
              EyeCareConfig.maxIntensity,
            ),
            min: EyeCareConfig.minIntensity,
            max: EyeCareConfig.maxIntensity,
            divisions: 18,
            label: '$percent%',
            // 关闭状态下置灰，避免误以为拖动就能生效
            onChanged: config.enabled
                ? (v) => onChanged(config.copyWith(intensity: v))
                : null,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '$percent%',
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
