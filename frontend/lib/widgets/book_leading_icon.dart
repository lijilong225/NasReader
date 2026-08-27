import 'package:flutter/material.dart';

/// 书籍列表左侧图标，右下角叠加收藏星标。
/// 未收藏为空心星，已收藏为实心金色星，点击星标只切换收藏、不触发行点击。
class BookLeadingIcon extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;

  const BookLeadingIcon({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 42,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 7,
            child: Icon(icon, color: iconColor, size: 28),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleFavorite,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  isFavorite ? Icons.star : Icons.star_border,
                  size: 18,
                  color: isFavorite ? Colors.amber.shade600 : Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
