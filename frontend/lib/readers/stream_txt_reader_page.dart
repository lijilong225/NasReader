import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/chunked_txt_engine.dart';
import '../core/txt_toc_extractor.dart';
import '../core/reader_theme.dart';
import '../core/page_turn_mode.dart';
import '../core/page_turn_view.dart';
import '../widgets/typography_config.dart';
import '../widgets/typography_settings_modal.dart';
import '../services/app_logger.dart';

enum HandMode {
  standard('常规手势'),
  oneHand('单手模式');

  final String label;
  const HandMode(this.label);
}

class StreamTxtReaderPage extends StatefulWidget {
  final File file;
  final String bookId;
  final String title;
  final int initialByteOffset;
  final Function(int byteOffset, double progressPercent)? onProgressChanged;

  const StreamTxtReaderPage({
    super.key,
    required this.file,
    required this.bookId,
    required this.title,
    this.initialByteOffset = 0,
    this.onProgressChanged,
  });

  @override
  State<StreamTxtReaderPage> createState() => _StreamTxtReaderPageState();
}

class _StreamTxtReaderPageState extends State<StreamTxtReaderPage> {
  late ChunkedTxtEngine _engine;
  bool _isIndexing = true;
  String? _errorMessage;
  bool _showControls = false;

  final Map<int, List<TxtPageSlice>> _chunkPagesCache = {};
  int _currentChunkIndex = 0;
  int _currentPageInChunk = 0;
  int _currentSavedOffset = 0;

  // 关键防死循环与控制标志
  bool _isJumping = false;
  int _lastReportedOffset = -1;

  List<TxtChapterItem> _toc = [];
  int _currentChapterIndex = 0;

  ReaderThemeData _currentTheme = ReaderThemes.parchment;
  PageTurnMode _pageTurnMode = PageTurnMode.none;
  HandMode _handMode = HandMode.standard;
  TypographyConfig _typoConfig = const TypographyConfig();

  final GlobalKey<PageTurnViewState> _turnViewKey = GlobalKey<PageTurnViewState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  static const double kHorizontalPadding = 20.0;
  static const double kVerticalPadding = 12.0;
  static const double kHeaderHeight = 22.0;
  static const double kFooterHeight = 22.0;
  static const double kHeaderSpacing = 8.0;

  @override
  void initState() {
    super.initState();
    _currentSavedOffset = widget.initialByteOffset;
    _engine = ChunkedTxtEngine(widget.file);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadHandMode();
    _initEngineAndScanToc();
  }

  @override
  void dispose() {
    _saveCurrentProgress();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadHandMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString('txt_hand_mode');
      if (savedMode == HandMode.oneHand.name && mounted) {
        setState(() => _handMode = HandMode.oneHand);
      }
    } catch (_) {}
  }

  Future<void> _saveHandMode(HandMode mode) async {
    setState(() => _handMode = mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('txt_hand_mode', mode.name);
    } catch (_) {}
  }

  void _saveCurrentProgress() {
    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];
    if (currentPages.isNotEmpty && _currentPageInChunk < currentPages.length) {
      final slice = currentPages[_currentPageInChunk];
      if (slice.startByteOffset == _lastReportedOffset) return;
      _lastReportedOffset = slice.startByteOffset;

      final totalSize = _engine.totalFileSize > 0 ? _engine.totalFileSize : 1;
      final progress = (slice.endByteOffset / totalSize).clamp(0.0, 1.0);
      widget.onProgressChanged?.call(slice.startByteOffset, progress);
    }
  }

  Future<void> _initEngineAndScanToc() async {
    try {
      if (!widget.file.existsSync() || widget.file.lengthSync() == 0) {
        setState(() {
          _isIndexing = false;
          _errorMessage = '文件不存在或内容为空';
        });
        return;
      }

      await _engine.buildIndex();

      if (_engine.chunks.isEmpty) {
        setState(() {
          _isIndexing = false;
          _errorMessage = 'TXT 文本分块失败';
        });
        return;
      }

      int targetChunk = 0;
      for (int i = 0; i < _engine.chunks.length; i++) {
        if (_currentSavedOffset >= _engine.chunks[i].startByte &&
            _currentSavedOffset < _engine.chunks[i].endByte) {
          targetChunk = i;
          break;
        }
      }

      _currentChunkIndex = targetChunk;

      if (mounted) {
        setState(() => _isIndexing = false);
      }

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        
        await _loadChunkPages(targetChunk, targetByteOffset: _currentSavedOffset, isCurrentDisplayChunk: true);

        Future.delayed(const Duration(milliseconds: 250), () {
          if (!mounted) return;
          _preloadAdjacentChunks(targetChunk);

          TxtTocExtractor.extractTocInIsolate(widget.file).then((tocList) {
            if (mounted) {
              setState(() {
                _toc = tocList;
                _updateCurrentChapter(_currentSavedOffset);
              });
            }
          }).catchError((_) {});
        });
      });
    } catch (e, stack) {
      AppLogger.log('❌ TXT 初始化异常: $e\n$stack');
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _errorMessage = '解析 TXT 异常: $e';
        });
      }
    }
  }

  void _updateCurrentChapter(int byteOffset) {
    if (_toc.isEmpty) return;
    int activeIdx = 0;
    for (int i = 0; i < _toc.length; i++) {
      if (byteOffset >= _toc[i].startByteOffset) {
        activeIdx = i;
      } else {
        break;
      }
    }
    if (_currentChapterIndex != activeIdx) {
      setState(() => _currentChapterIndex = activeIdx);
    }
  }

  Size _getContentSize() {
    final mq = MediaQuery.of(context);
    final availableWidth = mq.size.width - (kHorizontalPadding * 2);
    final availableHeight = mq.size.height -
        mq.padding.top -
        mq.padding.bottom -
        (kVerticalPadding * 2) -
        kHeaderHeight -
        kFooterHeight -
        kHeaderSpacing -
        16.0;

    return Size(
      availableWidth.clamp(100.0, 3000.0),
      availableHeight.clamp(100.0, 4000.0),
    );
  }

  Future<void> _loadChunkPages(
    int chunkIdx, {
    int? targetByteOffset,
    bool isCurrentDisplayChunk = false,
  }) async {
    if (chunkIdx < 0 || chunkIdx >= _engine.chunks.length) return;

    // 1. 命中缓存
    if (_chunkPagesCache.containsKey(chunkIdx)) {
      if (isCurrentDisplayChunk) {
        final cachedPages = _chunkPagesCache[chunkIdx]!;
        int targetPage = 0;
        if (targetByteOffset != null && cachedPages.isNotEmpty) {
          for (int p = 0; p < cachedPages.length; p++) {
            final isLastPage = (p == cachedPages.length - 1);
            if (targetByteOffset >= cachedPages[p].startByteOffset &&
                (targetByteOffset < cachedPages[p].endByteOffset || isLastPage)) {
              targetPage = p;
              break;
            }
          }
        }

        setState(() {
          _currentChunkIndex = chunkIdx;
          _currentPageInChunk = targetPage;
        });

        _isJumping = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _turnViewKey.currentState?.jumpToPage(targetPage);
            Future.delayed(const Duration(milliseconds: 150), () {
              if (mounted) _isJumping = false;
            });
            _saveCurrentProgress();
          }
        });
      }
      return;
    }

    // 2. 缓存未命中，在 Isolate 中排版
    try {
      final contentSize = _getContentSize();
      final pages = await ChunkedTxtEngine.paginateChunkInIsolate(
        file: widget.file,
        chunk: _engine.chunks[chunkIdx],
        contentSize: contentSize,
        fontSize: _typoConfig.fontSize,
        lineHeight: _typoConfig.lineHeight,
        letterSpacing: _typoConfig.letterSpacing,
      );

      final processedPages = pages.map((slice) {
        final processedContent = _typoConfig.indentFirstLine
            ? TypographyConfig.applyIndent(slice.content)
            : slice.content;
        return TxtPageSlice(
          globalPageIndex: slice.globalPageIndex,
          startByteOffset: slice.startByteOffset,
          endByteOffset: slice.endByteOffset,
          content: processedContent,
        );
      }).toList();

      if (!mounted) return;

      _chunkPagesCache[chunkIdx] = processedPages;

      if (isCurrentDisplayChunk) {
        int targetPage = 0;
        if (targetByteOffset != null && processedPages.isNotEmpty) {
          for (int p = 0; p < processedPages.length; p++) {
            final isLastPage = (p == processedPages.length - 1);
            if (targetByteOffset >= processedPages[p].startByteOffset &&
                (targetByteOffset < processedPages[p].endByteOffset || isLastPage)) {
              targetPage = p;
              break;
            }
          }
        }

        setState(() {
          _currentChunkIndex = chunkIdx;
          _currentPageInChunk = targetPage;
        });

        _isJumping = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _turnViewKey.currentState?.jumpToPage(targetPage);
            Future.delayed(const Duration(milliseconds: 150), () {
              if (mounted) _isJumping = false;
            });
            _saveCurrentProgress();
          }
        });
      }
    } catch (e) {
      AppLogger.log('❌ 分页切片异常 (chunk $chunkIdx): $e');
    }
  }

  void _preloadAdjacentChunks(int currentIdx) {
    if (currentIdx + 1 < _engine.chunks.length) {
      _loadChunkPages(currentIdx + 1, isCurrentDisplayChunk: false);
    }
    if (currentIdx - 1 >= 0) {
      _loadChunkPages(currentIdx - 1, isCurrentDisplayChunk: false);
    }
    _chunkPagesCache.removeWhere((idx, _) => (idx - currentIdx).abs() > 2);
  }

  void _onPageChanged(int indexInCurrentChunk) {
    if (_isJumping) return;

    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];
    if (currentPages.isEmpty || indexInCurrentChunk >= currentPages.length) return;

    _currentPageInChunk = indexInCurrentChunk;

    final currentSlice = currentPages[indexInCurrentChunk];
    _currentSavedOffset = currentSlice.startByteOffset;
    _updateCurrentChapter(currentSlice.startByteOffset);

    _saveCurrentProgress();
    _preloadAdjacentChunks(_currentChunkIndex);
  }

  void _prevPage() {
    if (_currentPageInChunk > 0) {
      _turnViewKey.currentState?.jumpToPage(_currentPageInChunk - 1);
    } else if (_currentChunkIndex > 0) {
      final prevChunkIdx = _currentChunkIndex - 1;
      _loadChunkPages(prevChunkIdx, isCurrentDisplayChunk: true).then((_) {
        final pages = _chunkPagesCache[prevChunkIdx] ?? [];
        if (pages.isNotEmpty) {
          _turnViewKey.currentState?.jumpToPage(pages.length - 1);
        }
      });
    }
  }

  void _nextPage() {
    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];
    if (_currentPageInChunk < currentPages.length - 1) {
      _turnViewKey.currentState?.jumpToPage(_currentPageInChunk + 1);
    } else if (_currentChunkIndex < _engine.chunks.length - 1) {
      _loadChunkPages(_currentChunkIndex + 1, isCurrentDisplayChunk: true).then((_) {
        _turnViewKey.currentState?.jumpToPage(0);
      });
    }
  }

  Future<void> _jumpToChapter(TxtChapterItem chapter) async {
    Navigator.pop(context);

    if (_engine.chunks.isEmpty) return;

    int targetChunk = 0;
    for (int i = 0; i < _engine.chunks.length; i++) {
      if (chapter.startByteOffset >= _engine.chunks[i].startByte &&
          chapter.startByteOffset < _engine.chunks[i].endByte) {
        targetChunk = i;
        break;
      }
    }

    setState(() {
      _currentChapterIndex = chapter.index;
      _currentSavedOffset = chapter.startByteOffset;
      _showControls = false;
    });

    await _loadChunkPages(
      targetChunk,
      targetByteOffset: chapter.startByteOffset,
      isCurrentDisplayChunk: true,
    );

    _preloadAdjacentChunks(targetChunk);
  }

  void _openTypographySettings() {
    TypographySettingsModal.show(
      context,
      config: _typoConfig,
      onConfigChanged: (newConfig) {
        setState(() {
          _typoConfig = newConfig;
          _chunkPagesCache.clear();
        });
        _loadChunkPages(
          _currentChunkIndex,
          targetByteOffset: _currentSavedOffset,
          isCurrentDisplayChunk: true,
        ).then((_) {
          _preloadAdjacentChunks(_currentChunkIndex);
        });
      },
    );
  }

  /// 核心实现：3x3 九宫格热区触控引擎
  Widget _buildNineGridGestureLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final totalHeight = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            // 控制栏显示时，轻触屏幕任意区域仅收起控制栏
            if (_showControls) {
              setState(() => _showControls = false);
              return;
            }

            final dx = details.localPosition.dx;
            final dy = details.localPosition.dy;

            // 计算所在的行和列 (0, 1, 2)
            final col = (dx / (totalWidth / 3)).clamp(0.0, 2.0).toInt();
            final row = (dy / (totalHeight / 3)).clamp(0.0, 2.0).toInt();

            // 转化为 1 ~ 9 号区域
            final zone = row * 3 + col + 1;

            // 区域 5：唤起控制菜单
            if (zone == 5) {
              setState(() => _showControls = true);
              return;
            }

            if (_handMode == HandMode.standard) {
              // 常规手势：1、2、3、4 上一页；6、7、8、9 下一页
              if (zone >= 1 && zone <= 4) {
                _prevPage();
              } else {
                _nextPage();
              }
            } else {
              // 单手模式：1、2 上一页；3、4、6、7、8、9 下一页
              if (zone == 1 || zone == 2) {
                _prevPage();
              } else {
                _nextPage();
              }
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isIndexing) {
      return const Scaffold(
        backgroundColor: Color(0xFFF6EFE2),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF382E25)),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }

    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        _saveCurrentProgress();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: _currentTheme.bgColor,
        drawer: Drawer(
          child: Column(
            children: [
              DrawerHeader(
                decoration: const BoxDecoration(color: Color(0xFF382E25)),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text('共 ${_toc.length} 章', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _toc.isEmpty
                    ? const Center(child: Text('未识别到目录章节', style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        itemCount: _toc.length,
                        itemBuilder: (context, index) {
                          final item = _toc[index];
                          final isCurrent = index == _currentChapterIndex;

                          return ListTile(
                            dense: true,
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                color: isCurrent ? Colors.brown : Colors.black87,
                              ),
                            ),
                            trailing: isCurrent ? const Icon(Icons.bookmark, size: 16, color: Colors.brown) : null,
                            onTap: () => _jumpToChapter(item),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        body: Stack(
          children: [
            // 1. 底层排版渲染视图
            currentPages.isEmpty
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF382E25)))
                : PageTurnView(
                    key: _turnViewKey,
                    mode: _pageTurnMode,
                    itemCount: currentPages.length,
                    initialIndex: _currentPageInChunk,
                    onPageChanged: _onPageChanged,
                    pageBuilder: (context, index) {
                      return _buildPageLayout(
                        currentPages[index],
                        index,
                        currentPages.length,
                      );
                    },
                  ),

            // 2. 顶层 3x3 九宫格手势拦截层
            if (currentPages.isNotEmpty)
              Positioned.fill(
                child: _buildNineGridGestureLayer(),
              ),

            // 3. 顶部控制条
            if (_showControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.85),
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () {
                            _saveCurrentProgress();
                            Navigator.pop(context);
                          },
                        ),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(color: Colors.white, fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.format_list_bulleted, color: Colors.white),
                          tooltip: '目录',
                          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 4. 底部控制面板
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.92),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 进度滑条
                        Slider(
                          value: _currentChunkIndex.toDouble().clamp(0.0, (_engine.chunks.length - 1).toDouble()),
                          min: 0,
                          max: (_engine.chunks.length > 1 ? _engine.chunks.length - 1 : 1).toDouble(),
                          onChanged: (val) {
                            final target = val.toInt();
                            _loadChunkPages(target, isCurrentDisplayChunk: true).then((_) {
                              _preloadAdjacentChunks(target);
                            });
                          },
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                _toc.isNotEmpty && _currentChapterIndex < _toc.length
                                    ? _toc[_currentChapterIndex].title
                                    : '分块 ${_currentChunkIndex + 1}/${_engine.chunks.length}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${((_currentChunkIndex / (_engine.chunks.isNotEmpty ? _engine.chunks.length : 1)) * 100).toStringAsFixed(1)}%',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        const Divider(color: Colors.white24, height: 16),

                        // 手势模式切换（常规手势 / 单手模式）
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('手势操作', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            Row(
                              children: HandMode.values.map((mode) {
                                final isSelected = _handMode == mode;
                                return Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: ChoiceChip(
                                    label: Text(mode.label),
                                    selected: isSelected,
                                    selectedColor: const Color(0xFF5A4A3A),
                                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                                    checkmarkColor: Colors.white,
                                    showCheckmark: false,
                                    side: BorderSide(
                                      color: isSelected ? const Color(0xFF8D7358) : Colors.transparent,
                                      width: 1,
                                    ),
                                    labelStyle: TextStyle(
                                      color: isSelected ? Colors.white : Colors.black87,
                                      fontSize: 11,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                    onSelected: (_) => _saveHandMode(mode),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // 翻页模式选择
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: PageTurnMode.values.map((mode) {
                            final isSelected = _pageTurnMode == mode;
                            return ChoiceChip(
                              label: Text(mode.label),
                              selected: isSelected,
                              selectedColor: const Color(0xFF5A4A3A),
                              backgroundColor: Colors.white.withValues(alpha: 0.85),
                              checkmarkColor: Colors.white,
                              showCheckmark: false,
                              side: BorderSide(
                                color: isSelected ? const Color(0xFF8D7358) : Colors.transparent,
                                width: 1,
                              ),
                              labelStyle: TextStyle(
                                color: isSelected ? Colors.white : Colors.black87,
                                fontSize: 12,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                              onSelected: (_) {
                                setState(() => _pageTurnMode = mode);
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 10),

                        // 排版与主题切换
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.text_format, color: Colors.white, size: 18),
                              label: const Text('排版 / 字体', style: TextStyle(color: Colors.white, fontSize: 12)),
                              onPressed: _openTypographySettings,
                            ),
                            Row(
                              children: ReaderThemes.all.map((theme) {
                                final isSelected = _currentTheme.bgColor == theme.bgColor;
                                return Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: GestureDetector(
                                    onTap: () => setState(() => _currentTheme = theme),
                                    child: Container(
                                      width: 48,
                                      height: 28,
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
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageLayout(TxtPageSlice slice, int pageInChunk, int totalInChunk) {
    final currentChapterTitle = _toc.isNotEmpty && _currentChapterIndex < _toc.length
        ? _toc[_currentChapterIndex].title
        : widget.title;

    final totalSize = _engine.totalFileSize > 0 ? _engine.totalFileSize : 1;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kHorizontalPadding,
          vertical: kVerticalPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: kHeaderHeight,
              child: Text(
                currentChapterTitle,
                style: TextStyle(
                  fontSize: 11,
                  color: _currentTheme.textColor.withValues(alpha: 0.5),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: kHeaderSpacing),

            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  slice.content,
                  strutStyle: StrutStyle(
                    fontSize: _typoConfig.fontSize,
                    height: _typoConfig.lineHeight,
                    forceStrutHeight: true,
                  ),
                  style: TextStyle(
                    fontSize: _typoConfig.fontSize,
                    height: _typoConfig.lineHeight,
                    letterSpacing: _typoConfig.letterSpacing,
                    fontFamily: _typoConfig.customFontFamily ?? 'serif',
                    color: _currentTheme.textColor,
                  ),
                ),
              ),
            ),

            SizedBox(
              height: kFooterHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _toc.isNotEmpty
                        ? '第 ${_currentChapterIndex + 1}/${_toc.length} 章 · ${pageInChunk + 1}/$totalInChunk'
                        : '页码 ${pageInChunk + 1}/$totalInChunk',
                    style: TextStyle(
                      fontSize: 11,
                      color: _currentTheme.textColor.withValues(alpha: 0.5),
                    ),
                  ),
                  Text(
                    '${(slice.endByteOffset / totalSize * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: _currentTheme.textColor.withValues(alpha: 0.5),
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
}