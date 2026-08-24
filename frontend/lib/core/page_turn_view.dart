// lib/core/page_turn_view.dart
import 'package:flutter/material.dart';

class PageTurnView extends StatefulWidget {
  final int itemCount;
  final int initialIndex;
  final ValueChanged<int>? onPageChanged;
  final IndexedWidgetBuilder pageBuilder;

  const PageTurnView({
    super.key,
    required this.itemCount,
    this.initialIndex = 0,
    this.onPageChanged,
    required this.pageBuilder,
  });

  @override
  State<PageTurnView> createState() => PageTurnViewState();
}

class PageTurnViewState extends State<PageTurnView> with SingleTickerProviderStateMixin {
  late int _currentIndex;
  late AnimationController _animController;
  Animation<double>? _slideAnimation;

  double _dragOffset = 0.0;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.itemCount > 0 ? widget.itemCount - 1 : 0);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void didUpdateWidget(covariant PageTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount != oldWidget.itemCount || widget.initialIndex != oldWidget.initialIndex) {
      _currentIndex = widget.initialIndex.clamp(0, widget.itemCount > 0 ? widget.itemCount - 1 : 0);
      _dragOffset = 0.0;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  /// 纯点击瞬切（无任何过渡动画）
  void jumpToPage(int page) {
    if (page < 0 || page >= widget.itemCount || page == _currentIndex) return;
    if (_animController.isAnimating) _animController.stop();

    setState(() {
      _dragOffset = 0.0;
      _currentIndex = page;
    });
    widget.onPageChanged?.call(page);
  }

  // --- 手势跟手拖拽与滑动翻页处理 ---

  void handleHorizontalDragStart(DragStartDetails details) {
    if (_animController.isAnimating) _animController.stop();
    _isDragging = true;
  }

  void handleHorizontalDragUpdate(DragUpdateDetails details, double screenWidth) {
    if (!_isDragging) return;

    setState(() {
      final delta = details.primaryDelta ?? 0.0;
      // 边界弹性阻尼：第一页向右或最后一页向左时施加阻尼
      if ((_currentIndex == 0 && (_dragOffset + delta) > 0) ||
          (_currentIndex == widget.itemCount - 1 && (_dragOffset + delta) < 0)) {
        _dragOffset += delta * 0.35;
      } else {
        _dragOffset += delta;
      }
    });
  }

  void handleHorizontalDragEnd(DragEndDetails details, double screenWidth) {
    _isDragging = false;
    final velocity = details.primaryVelocity ?? 0.0;

    // 翻页判断阈值：滑动距离超过屏幕宽度的 20%，或滑动速度超过 300px/s
    final bool reachDistanceThreshold = _dragOffset.abs() > (screenWidth * 0.20);
    final bool reachVelocityThreshold = velocity.abs() > 300.0;

    final bool isNext = _dragOffset < 0; // 向左滑是下一页
    final bool canFlip = (reachDistanceThreshold || reachVelocityThreshold) &&
        ((isNext && _currentIndex < widget.itemCount - 1) || (!isNext && _currentIndex > 0));

    double targetEndOffset = 0.0;
    int targetIndex = _currentIndex;

    if (canFlip) {
      targetEndOffset = isNext ? -screenWidth : screenWidth;
      targetIndex = isNext ? _currentIndex + 1 : _currentIndex - 1;
    } else {
      targetEndOffset = 0.0; // 回弹
    }

    _slideAnimation = Tween<double>(begin: _dragOffset, end: targetEndOffset).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    )..addListener(() {
        setState(() {
          _dragOffset = _slideAnimation!.value;
        });
      });

    _animController.forward(from: 0.0).then((_) {
      setState(() {
        _currentIndex = targetIndex;
        _dragOffset = 0.0;
      });
      if (canFlip) {
        widget.onPageChanged?.call(_currentIndex);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) {
      return const SizedBox.shrink();
    }

    Widget? underPage;
    if (_dragOffset < 0 && _currentIndex < widget.itemCount - 1) {
      underPage = widget.pageBuilder(context, _currentIndex + 1);
    } else if (_dragOffset > 0 && _currentIndex > 0) {
      underPage = widget.pageBuilder(context, _currentIndex - 1);
    }

    final currentPage = widget.pageBuilder(context, _currentIndex);

    return Stack(
      fit: StackFit.expand,
      children: [
        if (underPage != null) underPage,
        Transform.translate(
          offset: Offset(_dragOffset, 0),
          child: Container(
            decoration: BoxDecoration(
              boxShadow: [
                if (_dragOffset != 0.0)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 14.0,
                    spreadRadius: 1.0,
                    offset: Offset(_dragOffset < 0 ? 6.0 : -6.0, 0),
                  ),
              ],
            ),
            child: currentPage,
          ),
        ),
      ],
    );
  }
}