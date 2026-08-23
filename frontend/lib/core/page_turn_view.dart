import 'package:flutter/material.dart';
import 'page_turn_mode.dart';

class PageTurnView extends StatefulWidget {
  final PageTurnMode mode;
  final int itemCount;
  final int initialIndex;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onCenterTap;
  final IndexedWidgetBuilder pageBuilder;

  const PageTurnView({
    super.key,
    required this.mode,
    required this.itemCount,
    this.initialIndex = 0,
    this.onPageChanged,
    this.onCenterTap,
    required this.pageBuilder,
  });

  @override
  State<PageTurnView> createState() => PageTurnViewState();
}

class PageTurnViewState extends State<PageTurnView> {
  late int _currentIndex;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.itemCount > 0 ? widget.itemCount - 1 : 0);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void didUpdateWidget(covariant PageTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount != oldWidget.itemCount || widget.initialIndex != oldWidget.initialIndex) {
      _currentIndex = widget.initialIndex.clamp(0, widget.itemCount > 0 ? widget.itemCount - 1 : 0);
      if (_pageController.hasClients && _pageController.page?.round() != _currentIndex) {
        _pageController.jumpToPage(_currentIndex);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void jumpToPage(int page) {
    if (page < 0 || page >= widget.itemCount) return;
    setState(() {
      _currentIndex = page;
    });
    if (widget.mode != PageTurnMode.none && _pageController.hasClients) {
      _pageController.jumpToPage(page);
    }
    widget.onPageChanged?.call(page);
  }

  void nextPage() {
    if (_currentIndex < widget.itemCount - 1) {
      jumpToPage(_currentIndex + 1);
    }
  }

  void prevPage() {
    if (_currentIndex > 0) {
      jumpToPage(_currentIndex - 1);
    }
  }

  void _handleTapDown(TapDownDetails details, BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final x = details.localPosition.dx;

    if (x < width * 0.3) {
      // 左侧 30% 区域：上一页
      prevPage();
    } else if (x > width * 0.7) {
      // 右侧 30% 区域：下一页
      nextPage();
    } else {
      // 中间 40% 区域：呼出/隐藏菜单
      widget.onCenterTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 无动画模式：纯点击瞬切，没有任何过渡
        if (widget.mode == PageTurnMode.none) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _handleTapDown(details, constraints),
            child: widget.pageBuilder(context, _currentIndex),
          );
        }

        // 上下连续滚动模式
        if (widget.mode == PageTurnMode.scroll) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (details) => _handleTapDown(details, constraints),
            child: ListView.builder(
              itemCount: widget.itemCount,
              itemBuilder: widget.pageBuilder,
            ),
          );
        }

        // 滑动 / 覆盖模式
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (details) => _handleTapDown(details, constraints),
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.itemCount,
            physics: const ClampingScrollPhysics(),
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
              widget.onPageChanged?.call(index);
            },
            itemBuilder: widget.pageBuilder,
          ),
        );
      },
    );
  }
}