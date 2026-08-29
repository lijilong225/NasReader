import 'package:flutter/material.dart';

/// 书籍列表左侧图标，右下角叠加收藏星标，仅用于展示收藏状态。
class BookLeadingIcon extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final bool isFavorite;

  const BookLeadingIcon({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.isFavorite,
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
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                isFavorite ? Icons.star : Icons.star_border,
                size: 18,
                color: isFavorite ? Colors.amber.shade600 : Colors.grey,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
