import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/chunked_txt_engine.dart';
import '../core/txt_toc_extractor.dart';
import '../core/reader_theme.dart';
import '../core/page_turn_mode.dart';
import '../core/page_turn_view.dart';
import '../widgets/typography_config.dart';
import '../widgets/typography_settings_modal.dart';
import '../services/app_logger.dart';

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

  List<TxtChapterItem> _toc = [];
  int _currentChapterIndex = 0;

  ReaderThemeData _currentTheme = ReaderThemes.parchment;
  PageTurnMode _pageTurnMode = PageTurnMode.none;
  TypographyConfig _typoConfig = const TypographyConfig();

  final GlobalKey<PageTurnViewState> _turnViewKey = GlobalKey<PageTurnViewState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // 严格固定的内边距与栏高常量，保证计算与渲染 100% 严丝合缝
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
    _initEngineAndScanToc();
  }

  @override
  void dispose() {
    // 退出前强制保存一次当前精确进度
    _saveCurrentProgress();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _saveCurrentProgress() {
    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];
    if (currentPages.isNotEmpty && _currentPageInChunk < currentPages.length) {
      final slice = currentPages[_currentPageInChunk];
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

      // 1. 物理索引秒建
      await _engine.buildIndex();

      if (_engine.chunks.isEmpty) {
        setState(() {
          _isIndexing = false;
          _errorMessage = 'TXT 文本分块失败';
        });
        return;
      }

      // 2. 定位目标分块
      int targetChunk = 0;
      for (int i = 0; i < _engine.chunks.length; i++) {
        if (_currentSavedOffset >= _engine.chunks[i].startByte &&
            _currentSavedOffset < _engine.chunks[i].endByte) {
          targetChunk = i;
          break;
        }
      }

      _currentChunkIndex = targetChunk;

      // 3. 立即准备渲染首屏，解除全局 Loading 状态
      if (mounted) {
        setState(() => _isIndexing = false);
      }

      // 4. 第一帧后加载当前块
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        
        // 加载当前分块并定位
        await _loadChunkPages(targetChunk, targetByteOffset: _currentSavedOffset);

        // 5. 延迟 200ms 执行后台预加载和目录扫描，绝不抢占首屏 CPU
        Future.delayed(const Duration(milliseconds: 200), () {
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
    _currentChapterIndex = activeIdx;
  }

  // 精准计算正文区域的可用宽高
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
        16.0; // 👈 增加 16px 底部绝对安全间距

    return Size(
      availableWidth.clamp(100.0, 3000.0),
      availableHeight.clamp(100.0, 4000.0),
    );
  }

  Future<void> _loadChunkPages(int chunkIdx, {int? targetByteOffset}) async {
    if (chunkIdx < 0 || chunkIdx >= _engine.chunks.length) return;

    // 1. 如果该分块已缓存，直接复用缓存并跳转目标页
    if (_chunkPagesCache.containsKey(chunkIdx)) {
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

      // 确保在下一帧完成跳转与进度保存
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _turnViewKey.currentState?.jumpToPage(targetPage);
        _saveCurrentProgress();
      });
      return;
    }

    // 2. 缓存未命中，进行 Isolate 排版测算
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
        _chunkPagesCache[chunkIdx] = processedPages;
        if (chunkIdx == _currentChunkIndex) {
          _currentPageInChunk = targetPage;
        }
      });

      if (chunkIdx == _currentChunkIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _turnViewKey.currentState?.jumpToPage(targetPage);
          _saveCurrentProgress();
        });
      }
    } catch (e) {
      AppLogger.log('❌ 分页切片异常 (chunk $chunkIdx): $e');
    }
  }

  void _preloadAdjacentChunks(int currentIdx) {
    if (currentIdx + 1 < _engine.chunks.length) _loadChunkPages(currentIdx + 1);
    if (currentIdx - 1 >= 0) _loadChunkPages(currentIdx - 1);
    _chunkPagesCache.removeWhere((idx, _) => (idx - currentIdx).abs() > 3);
  }

  void _onPageChanged(int indexInCurrentChunk) {
    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];
    if (currentPages.isEmpty || indexInCurrentChunk >= currentPages.length) return;

    setState(() => _currentPageInChunk = indexInCurrentChunk);

    final currentSlice = currentPages[indexInCurrentChunk];
    _currentSavedOffset = currentSlice.startByteOffset;
    _updateCurrentChapter(currentSlice.startByteOffset);

    // 实时保存进度
    _saveCurrentProgress();
    _preloadAdjacentChunks(_currentChunkIndex);
  }

  Future<void> _jumpToChapter(TxtChapterItem chapter) async {
    Navigator.pop(context);

    if (_engine.chunks.isEmpty) return;

    // 1. 查找目标偏移量所在的 Chunk 分块
    int targetChunk = 0;
    for (int i = 0; i < _engine.chunks.length; i++) {
      if (chapter.startByteOffset >= _engine.chunks[i].startByte &&
          chapter.startByteOffset < _engine.chunks[i].endByte) {
        targetChunk = i;
        break;
      }
    }

    // 2. 标记当前保存的章节状态
    setState(() {
      _currentChapterIndex = chapter.index;
      _currentSavedOffset = chapter.startByteOffset;
      _showControls = false;
    });

    // 3. 等待目标分块加载并计算出具体页码
    await _loadChunkPages(targetChunk, targetByteOffset: chapter.startByteOffset);

    // 4. 异步静默预加载相邻分块
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
        _loadChunkPages(_currentChunkIndex, targetByteOffset: _currentSavedOffset).then((_) {
          _preloadAdjacentChunks(_currentChunkIndex);
        });
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
            currentPages.isEmpty
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF382E25)))
                : PageTurnView(
                    key: _turnViewKey,
                    mode: _pageTurnMode,
                    itemCount: currentPages.length,
                    initialIndex: _currentPageInChunk,
                    onPageChanged: _onPageChanged,
                    onCenterTap: () => setState(() => _showControls = !_showControls),
                    pageBuilder: (context, index) {
                      return _buildPageLayout(
                        currentPages[index],
                        index,
                        currentPages.length,
                      );
                    },
                  ),

            // 顶部控制条
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

            // 底部控制面板
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
                        // 1. 进度滑条
                        Slider(
                          value: _currentChunkIndex.toDouble().clamp(0.0, (_engine.chunks.length - 1).toDouble()),
                          min: 0,
                          max: (_engine.chunks.length > 1 ? _engine.chunks.length - 1 : 1).toDouble(),
                          onChanged: (val) {
                            final target = val.toInt();
                            setState(() {
                              _currentChunkIndex = target;
                              _currentPageInChunk = 0;
                            });
                            _loadChunkPages(target).then((_) {
                              _turnViewKey.currentState?.jumpToPage(0);
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

                        // 2. 翻页模式选择
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

                        // 3. 排版设置弹窗与主题切换
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
            // 顶部章节名
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

            // 正文内容（锁定行高与基线）
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

            // 底部信息栏
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