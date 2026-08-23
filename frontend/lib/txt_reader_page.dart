import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'txt_paginator.dart';
import 'reader_theme.dart';

class TxtReaderPage extends StatefulWidget {
  final File file;
  final String bookId;
  final String title;
  final int initialCharOffset; // 用于历史进度断点续读
  final Function(int charOffset, double progressPercent)? onProgressChanged;

  const TxtReaderPage({
    super.key,
    required this.file,
    required this.bookId,
    required this.title,
    this.initialCharOffset = 0,
    this.onProgressChanged,
  });

  @override
  State<TxtReaderPage> createState() => _TxtReaderPageState();
}

class _TxtReaderPageState extends State<TxtReaderPage> {
  String _fullText = '';
  List<TxtPage> _pages = [];
  bool _isLoading = true;
  int _currentPageIndex = 0;
  bool _showControls = false;

  late PageController _pageController;
  late ReaderConfig _config;

  // 记录当前阅读在全文中的绝对字符偏移量
  int _currentCharOffset = 0;

  @override
  void initState() {
    super.initState();
    _currentCharOffset = widget.initialCharOffset;
    _config = ReaderConfig(
      textColor: ReaderThemes.parchment.textColor,
      backgroundColor: ReaderThemes.parchment.bgColor,
    );
    _pageController = PageController();

    // 隐藏状态栏沉浸式阅读
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadFileContent();
  }

  @override
  void dispose() {
    _pageController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadFileContent() async {
    final text = await TxtPaginator.readTextFile(widget.file);
    if (!mounted) return;

    setState(() {
      _fullText = text;
    });

    // 等待布局完成后计算首次分页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repaginate(targetOffset: _currentCharOffset);
    });
  }

  /// 重新分页（屏幕旋转、字号改变或初次加载时触发）
  void _repaginate({int? targetOffset}) {
    if (_fullText.isEmpty) return;

    final mediaQuery = MediaQuery.of(context);
    final totalW = mediaQuery.size.width;
    final totalH = mediaQuery.size.height;

    // 计算安全阅读区尺寸（扣除上下系统栏和内边距）
    final double usableW = totalW - _config.padding.horizontal;
    final double usableH = totalH -
        mediaQuery.padding.top -
        mediaQuery.padding.bottom -
        _config.padding.vertical -
        48.0; // 预留页眉页脚 48px

    final pages = TxtPaginator.paginate(
      text: _fullText,
      contentSize: Size(usableW, usableH),
      config: _config,
    );

    // 计算重排后目标 offset 落在第几页
    int newPageIndex = 0;
    final searchOffset = targetOffset ?? _currentCharOffset;
    for (int i = 0; i < pages.length; i++) {
      if (searchOffset >= pages[i].startOffset &&
          searchOffset < pages[i].endOffset) {
        newPageIndex = i;
        break;
      }
    }

    setState(() {
      _pages = pages;
      _currentPageIndex = newPageIndex;
      _isLoading = false;
    });

    // 跳转到对应页码
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(newPageIndex);
      }
    });
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentPageIndex = index;
      if (_pages.isNotEmpty && index < _pages.length) {
        _currentCharOffset = _pages[index].startOffset;
      }
    });

    // 触发进度回调同步到后端
    if (_pages.isNotEmpty && _fullText.isNotEmpty) {
      final double progress = (_pages[index].endOffset / _fullText.length).clamp(0.0, 1.0);
      widget.onProgressChanged?.call(_currentCharOffset, progress);
    }
  }

  void _updateFontSize(double delta) {
    final newSize = (_config.fontSize + delta).clamp(12.0, 32.0);
    if (newSize == _config.fontSize) return;

    setState(() {
      _config = _config.copyWith(fontSize: newSize);
    });
    _repaginate(targetOffset: _currentCharOffset);
  }

  void _changeTheme(ReaderThemeData theme) {
    setState(() {
      _config = _config.copyWith(
        backgroundColor: theme.bgColor,
        textColor: theme.textColor,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _config.backgroundColor,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                // 1. 阅读翻页主体
                GestureDetector(
                  onTapUp: (details) {
                    final width = MediaQuery.of(context).size.width;
                    final dx = details.globalPosition.dx;
                    // 点击中间区域触发菜单，左右区域翻页
                    if (dx < width * 0.3) {
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                      );
                    } else if (dx > width * 0.7) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                      );
                    } else {
                      setState(() {
                        _showControls = !_showControls;
                      });
                    }
                  },
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _pages.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final page = _pages[index];
                      return _buildPageContent(page);
                    },
                  ),
                ),

                // 2. 顶部导航栏控制条
                if (_showControls)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildTopBar(),
                  ),

                // 3. 底部样式与进度控制面板
                if (_showControls)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _buildBottomPanel(),
                  ),
              ],
            ),
    );
  }

  Widget _buildPageContent(TxtPage page) {
    final totalLen = _fullText.length;
    final double percent =
        totalLen > 0 ? (page.endOffset / totalLen * 100) : 0.0;

    return SafeArea(
      child: Padding(
        padding: _config.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 页眉：书名
            SizedBox(
              height: 20,
              child: Text(
                widget.title,
                style: TextStyle(
                  fontSize: 12,
                  color: _config.textColor.withOpacity(0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 4),

            // 正文区域
            Expanded(
              child: Text(
                page.content,
                style: _config.textStyle,
              ),
            ),

            // 页脚：页码与字数进度百分比
            SizedBox(
              height: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${page.pageIndex + 1} / ${_pages.length}',
                    style: TextStyle(
                      fontSize: 11,
                      color: _config.textColor.withOpacity(0.5),
                    ),
                  ),
                  Text(
                    '${percent.toStringAsFixed(1)}% · ${page.endOffset}/$totalLen 字',
                    style: TextStyle(
                      fontSize: 11,
                      color: _config.textColor.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: Colors.black.withOpacity(0.85),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                widget.title,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    final double currentPercent = _pages.isNotEmpty
        ? (_currentPageIndex / (_pages.length - 1)).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      color: Colors.black.withOpacity(0.9),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度拖动条
            Row(
              children: [
                Text(
                  '${_currentPageIndex + 1}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: currentPercent.isNaN ? 0.0 : currentPercent,
                    onChanged: (val) {
                      final targetPage = (val * (_pages.length - 1)).round();
                      _pageController.jumpToPage(targetPage);
                    },
                  ),
                ),
                Text(
                  '${_pages.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),

            const Divider(color: Colors.white24, height: 1),
            const SizedBox(height: 12),

            // 字体大小调节
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.text_decrease, color: Colors.white),
                  label: const Text('字号 -', style: TextStyle(color: Colors.white)),
                  onPressed: () => _updateFontSize(-2),
                ),
                Text(
                  '${_config.fontSize.toInt()}',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.text_increase, color: Colors.white),
                  label: const Text('字号 +', style: TextStyle(color: Colors.white)),
                  onPressed: () => _updateFontSize(2),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 配色主题选择
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: ReaderThemes.all.map((theme) {
                final isSelected = _config.backgroundColor == theme.bgColor;
                return GestureDetector(
                  onTap: () => _changeTheme(theme),
                  child: Container(
                    width: 64,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.bgColor,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isSelected ? Colors.blueAccent : Colors.grey,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      theme.name,
                      style: TextStyle(
                        color: theme.textColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}