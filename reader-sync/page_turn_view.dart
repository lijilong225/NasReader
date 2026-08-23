import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'page_turn_mode.dart';

typedef PageBuilder = Widget Function(BuildContext context, int index);

class PageTurnView extends StatefulWidget {
  final int itemCount;
  final int initialIndex;
  final PageTurnMode mode;
  final PageBuilder pageBuilder;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onCenterTap;

  const PageTurnView({
    super.key,
    required this.itemCount,
    this.initialIndex = 0,
    required this.mode,
    required this.pageBuilder,
    this.onPageChanged,
    this.onCenterTap,
  });

  @override
  State<PageTurnView> createState() => PageTurnViewState();
}

class PageTurnViewState extends State<PageTurnView> with SingleTickerProviderStateMixin {
  late int _currentIndex;
  late AnimationController _animController;
  Animation<double>? _dragAnimation;

  double _dragOffsetX = 0.0;
  bool _isDragging = false;
  bool _isNext = true; // true: 翻向下一页; false: 翻向上一页

  late ScrollController _verticalScrollController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _verticalScrollController = ScrollController();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        setState(() {
          _dragOffsetX = _dragAnimation?.value ?? 0.0;
        });
      })..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          if ((_isNext && _dragOffsetX < 0) || (!_isNext && _dragOffsetX > 0)) {
            _commitPageChange(_isNext ? _currentIndex + 1 : _currentIndex - 1);
          }
          setState(() {
            _dragOffsetX = 0.0;
            _isDragging = false;
          });
        }
      });
  }

  @override
  void didUpdateWidget(PageTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIndex != _currentIndex && widget.initialIndex < widget.itemCount) {
      _currentIndex = widget.initialIndex;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  void _commitPageChange(int newIndex) {
    if (newIndex >= 0 && newIndex < widget.itemCount && newIndex != _currentIndex) {
      setState(() {
        _currentIndex = newIndex;
      });
      widget.onPageChanged?.call(_currentIndex);
    }
  }

  void jumpToPage(int index) {
    if (index >= 0 && index < widget.itemCount) {
      setState(() {
        _currentIndex = index;
        _dragOffsetX = 0.0;
      });
      widget.onPageChanged?.call(_currentIndex);
    }
  }

  void nextPage() {
    if (_currentIndex < widget.itemCount - 1 && !_isDragging) {
      _isNext = true;
      final width = MediaQuery.of(context).size.width;
      _dragAnimation = Tween<double>(begin: 0.0, end: -width).animate(
        CurvedAnimation(parent: _animController, curve: Curves.easeOutQuad),
      );
      _animController.forward(from: 0.0);
    }
  }

  void prevPage() {
    if (_currentIndex > 0 && !_isDragging) {
      _isNext = false;
      final width = MediaQuery.of(context).size.width;
      _dragAnimation = Tween<double>(begin: 0.0, end: width).animate(
        CurvedAnimation(parent: _animController, curve: Curves.easeOutQuad),
      );
      _animController.forward(from: 0.0);
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (widget.mode == PageTurnMode.scroll) return;
    _animController.stop();
    _isDragging = true;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (widget.mode == PageTurnMode.scroll) return;
    setState(() {
      _dragOffsetX += details.primaryDelta ?? 0.0;
      if (_dragOffsetX < 0) {
        _isNext = true;
      } else if (_dragOffsetX > 0) {
        _isNext = false;
      }
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (widget.mode == PageTurnMode.scroll) return;
    final width = MediaQuery.of(context).size.width;
    final velocity = details.primaryVelocity ?? 0.0;

    bool shouldFlip = false;
    if (_dragOffsetX.abs() > width * 0.25 || velocity.abs() > 400) {
      if (_dragOffsetX < 0 && _currentIndex < widget.itemCount - 1) {
        shouldFlip = true;
      } else if (_dragOffsetX > 0 && _currentIndex > 0) {
        shouldFlip = true;
      }
    }

    final double targetX = shouldFlip ? (_isNext ? -width : width) : 0.0;
    _dragAnimation = Tween<double>(begin: _dragOffsetX, end: targetX).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutQuad),
    );
    _animController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    // 模式 1: 上下连续滚动
    if (widget.mode == PageTurnMode.scroll) {
      return GestureDetector(
        onTapUp: (details) {
          final h = MediaQuery.of(context).size.height;
          final dy = details.globalPosition.dy;
          if (dy > h * 0.35 && dy < h * 0.65) {
            widget.onCenterTap?.call();
          }
        },
        child: ListView.builder(
          controller: _verticalScrollController,
          itemCount: widget.itemCount,
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          itemBuilder: (context, index) {
            return SizedBox(
              height: MediaQuery.of(context).size.height,
              child: widget.pageBuilder(context, index),
            );
          },
        ),
      );
    }

    final width = MediaQuery.of(context).size.width;

    return GestureDetector(
      onTapUp: (details) {
        final w = MediaQuery.of(context).size.width;
        final dx = details.globalPosition.dx;
        if (dx < w * 0.3) {
          prevPage();
        } else if (dx > w * 0.7) {
          nextPage();
        } else {
          widget.onCenterTap?.call();
        }
      },
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 底层：下一页/上一页（视翻页方向而定）
          if (_dragOffsetX < 0 && _currentIndex < widget.itemCount - 1)
            widget.pageBuilder(context, _currentIndex + 1)
          else if (_dragOffsetX > 0 && _currentIndex > 0)
            widget.pageBuilder(context, _currentIndex - 1)
          else
            widget.pageBuilder(context, _currentIndex),

          // 顶层动画层：当前页变形或平移
          if (_dragOffsetX != 0.0)
            _buildAnimatedLayer(width)
          else
            widget.pageBuilder(context, _currentIndex),
        ],
      ),
    );
  }

  Widget _buildAnimatedLayer(double width) {
    if (widget.mode == PageTurnMode.simulation) {
      // 模式 2: 水平仿真翻页（3D 透视角度 + 边缘阴影）
      final double progress = (_dragOffsetX / width).clamp(-1.0, 1.0);
      final double angle = progress * (math.pi / 2.2);

      return Transform(
        alignment: _isNext ? Alignment.centerRight : Alignment.centerLeft,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001) // 3D 透视深度
          ..rotateY(angle),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.pageBuilder(context, _currentIndex),
            // 折痕阴影
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withOpacity(progress.abs() * 0.35),
                    Colors.transparent,
                  ],
                  begin: _isNext ? Alignment.centerRight : Alignment.centerLeft,
                  end: _isNext ? Alignment.centerLeft : Alignment.centerRight,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // 模式 3: 平滑覆盖翻页（边缘线性阴影）
      return Transform.translate(
        offset: Offset(_dragOffsetX, 0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.pageBuilder(context, _currentIndex),
            Positioned(
              top: 0,
              bottom: 0,
              right: _isNext ? 0 : null,
              left: _isNext ? null : 0,
              child: Container(
                width: 14,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withOpacity(0.25),
                      Colors.transparent,
                    ],
                    begin: _isNext ? Alignment.centerRight : Alignment.centerLeft,
                    end: _isNext ? Alignment.centerLeft : Alignment.centerRight,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
  }
}