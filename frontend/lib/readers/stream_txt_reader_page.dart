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

  List<TxtChapterItem> _toc = [];
  int _currentChapterIndex = 0;

  ReaderThemeData _currentTheme = ReaderThemes.parchment;
  PageTurnMode _pageTurnMode = PageTurnMode.cover;
  TypographyConfig _typoConfig = const TypographyConfig();

  final GlobalKey<PageTurnViewState> _turnViewKey = GlobalKey<PageTurnViewState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _engine = ChunkedTxtEngine(widget.file);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initEngineAndScanToc();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
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

      // 1. 快速构建物理分块索引 (< 5ms)
      await _engine.buildIndex();

      if (_engine.chunks.isEmpty) {
        setState(() {
          _isIndexing = false;
          _errorMessage = 'TXT 文件为空';
        });
        return;
      }

      int targetChunk = 0;
      for (int i = 0; i < _engine.chunks.length; i++) {
        if (widget.initialByteOffset >= _engine.chunks[i].startByte &&
            widget.initialByteOffset < _engine.chunks[i].endByte) {
          targetChunk = i;
          break;
        }
      }

      _currentChunkIndex = targetChunk;

      // 2. 立即解除 Loading，优先渲染第一屏正文
      if (mounted) {
        setState(() => _isIndexing = false);
      }

      // 3. 异步分页与后台闲时扫描目录（不阻塞 UI）
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        
        // 优先加载当前页
        await _loadChunkPages(_currentChunkIndex);
        _preloadAdjacentChunks(_currentChunkIndex);
        // 异步提取目录
        TxtTocExtractor.extractTocInIsolate(widget.file).then((tocList) {
          if (mounted) {
            setState(() {
              _toc = tocList;
              _updateCurrentChapter(widget.initialByteOffset);
            });
          }
        }).catchError((_) {});
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _errorMessage = '打开书籍失败: $e';
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

  Size _getContentSize() {
    final mq = MediaQuery.of(context);
    final width = (mq.size.width - 40).clamp(200.0, 2000.0);
    final height = (mq.size.height - mq.padding.top - mq.padding.bottom - 80).clamp(300.0, 3000.0);
    return Size(width, height);
  }

  Future<void> _loadChunkPages(int chunkIdx) async {
    if (chunkIdx < 0 || chunkIdx >= _engine.chunks.length) return;
    if (_chunkPagesCache.containsKey(chunkIdx)) return;

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

      if (mounted) {
        setState(() {
          _chunkPagesCache[chunkIdx] = processedPages;
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
    _updateCurrentChapter(currentSlice.startByteOffset);

    final totalSize = _engine.totalFileSize > 0 ? _engine.totalFileSize : 1;
    final globalProgress =
        (currentSlice.endByteOffset / totalSize).clamp(0.0, 1.0);
    widget.onProgressChanged?.call(currentSlice.startByteOffset, globalProgress);

    _preloadAdjacentChunks(_currentChunkIndex);
  }

  void _jumpToChapter(TxtChapterItem chapter) {
    Navigator.pop(context);

    int targetChunk = 0;
    for (int i = 0; i < _engine.chunks.length; i++) {
      if (chapter.startByteOffset >= _engine.chunks[i].startByte &&
          chapter.startByteOffset < _engine.chunks[i].endByte) {
        targetChunk = i;
        break;
      }
    }

    setState(() {
      _currentChunkIndex = targetChunk;
      _currentPageInChunk = 0;
      _currentChapterIndex = chapter.index;
      _showControls = false;
    });

    _loadChunkPages(targetChunk).then((_) {
      final pages = _chunkPagesCache[targetChunk] ?? [];
      int targetPageInChunk = 0;

      for (int p = 0; p < pages.length; p++) {
        if (chapter.startByteOffset >= pages[p].startByteOffset &&
            chapter.startByteOffset < pages[p].endByteOffset) {
          targetPageInChunk = p;
          break;
        }
      }

      setState(() => _currentPageInChunk = targetPageInChunk);
      _turnViewKey.currentState?.jumpToPage(targetPageInChunk);
      _preloadAdjacentChunks(targetChunk);

      if (pages.isNotEmpty) {
        final slice = pages[targetPageInChunk];
        final totalSize = _engine.totalFileSize > 0 ? _engine.totalFileSize : 1;
        final progress = (slice.endByteOffset / totalSize).clamp(0.0, 1.0);
        widget.onProgressChanged?.call(slice.startByteOffset, progress);
      }
    });
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
        _loadChunkPages(_currentChunkIndex).then((_) {
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF382E25)),
              SizedBox(height: 16),
              Text('正在分析大文件章节目录与排版...', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
                const SizedBox(height: 16),
                Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        ),
      );
    }

    final currentPages = _chunkPagesCache[_currentChunkIndex] ?? [];

    return Scaffold(
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '共 ${_toc.length} 章',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
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
                              fontWeight:
                                  isCurrent ? FontWeight.bold : FontWeight.normal,
                              color: isCurrent ? Colors.brown : Colors.black87,
                            ),
                          ),
                          trailing: isCurrent
                              ? const Icon(Icons.bookmark, size: 16, color: Colors.brown)
                              : null,
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
                      IconButton(
                        icon: const Icon(Icons.format_list_bulleted,
                            color: Colors.white),
                        tooltip: '目录',
                        onPressed: () =>
                            _scaffoldKey.currentState?.openDrawer(),
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
                color: Colors.black.withOpacity(0.92),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                              _toc.isNotEmpty &&
                                      _currentChapterIndex < _toc.length
                                  ? _toc[_currentChapterIndex].title
                                  : '分块 ${_currentChunkIndex + 1}/${_engine.chunks.length}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${((_currentChunkIndex / (_engine.chunks.isNotEmpty ? _engine.chunks.length : 1)) * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
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
                            backgroundColor: Colors.white.withOpacity(0.12),
                            checkmarkColor: Colors.white,
                            showCheckmark: false,
                            side: BorderSide(
                              color: isSelected ? const Color(0xFF8D7358) : Colors.white24,
                              width: 1,
                            ),
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
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
                            icon: const Icon(Icons.text_format,
                                color: Colors.white, size: 18),
                            label: const Text('排版 / 字体',
                                style: TextStyle(color: Colors.white, fontSize: 12)),
                            onPressed: _openTypographySettings,
                          ),
                          Row(
                            children: ReaderThemes.all.map((theme) {
                              final isSelected =
                                  _currentTheme.bgColor == theme.bgColor;
                              return Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _currentTheme = theme),
                                  child: Container(
                                    width: 48,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: theme.bgColor,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: isSelected
                                            ? Colors.blueAccent
                                            : Colors.grey,
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
    );
  }

  Widget _buildPageLayout(
      TxtPageSlice slice, int pageInChunk, int totalInChunk) {
    final currentChapterTitle =
        _toc.isNotEmpty && _currentChapterIndex < _toc.length
            ? _toc[_currentChapterIndex].title
            : widget.title;

    final totalSize = _engine.totalFileSize > 0 ? _engine.totalFileSize : 1;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 20,
              child: Text(
                currentChapterTitle,
                style: TextStyle(
                  fontSize: 11,
                  color: _currentTheme.textColor.withOpacity(0.5),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                slice.content,
                style: TextStyle(
                  fontSize: _typoConfig.fontSize,
                  height: _typoConfig.lineHeight,
                  letterSpacing: _typoConfig.letterSpacing,
                  fontFamily: _typoConfig.customFontFamily ?? 'serif',
                  color: _currentTheme.textColor,
                ),
              ),
            ),
            SizedBox(
              height: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _toc.isNotEmpty
                        ? '第 ${_currentChapterIndex + 1}/${_toc.length} 章 · ${pageInChunk + 1}/$totalInChunk'
                        : '页码 ${pageInChunk + 1}/$totalInChunk',
                    style: TextStyle(
                      fontSize: 11,
                      color: _currentTheme.textColor.withOpacity(0.5),
                    ),
                  ),
                  Text(
                    '${(slice.endByteOffset / totalSize * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: _currentTheme.textColor.withOpacity(0.5),
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