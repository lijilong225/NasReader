// lib/widgets/grid_gesture_detector.dart
import 'package:flutter/material.dart';
import '../core/hand_mode.dart';

class GridGestureDetector extends StatelessWidget {
  final HandMode mode;
  final bool showControls;
  final VoidCallback onPrevPage;
  final VoidCallback onNextPage;
  final VoidCallback onToggleControls;
  final VoidCallback onDismissControls;

  const GridGestureDetector({
    super.key,
    required this.mode,
    required this.showControls,
    required this.onPrevPage,
    required this.onNextPage,
    required this.onToggleControls,
    required this.onDismissControls,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            // 控制菜单已显示时，点击屏幕任意区域均关闭菜单
            if (showControls) {
              onDismissControls();
              return;
            }

            final dx = details.localPosition.dx;
            final dy = details.localPosition.dy;

            // 计算九宫格索引 (0, 1, 2)
            final col = (dx / (width / 3)).clamp(0.0, 2.0).toInt();
            final row = (dy / (height / 3)).clamp(0.0, 2.0).toInt();
            final zone = row * 3 + col + 1; // 1 ~ 9 号区域

            // 区域 5：唤起菜单
            if (zone == 5) {
              onToggleControls();
              return;
            }

            if (mode == HandMode.standard) {
              // 常规手势：1, 2, 3, 4 上一页；6, 7, 8, 9 下一页
              if (zone >= 1 && zone <= 4) {
                onPrevPage();
              } else {
                onNextPage();
              }
            } else {
              // 单手模式：1, 2 上一页；3, 4, 6, 7, 8, 9 下一页
              if (zone == 1 || zone == 2) {
                onPrevPage();
              } else {
                onNextPage();
              }
            }
          },
        );
      },
    );
  }
}