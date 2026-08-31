import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bookmark_model.dart';
import '../services/app_logger.dart';
import '../services/bookmark_sync_service.dart';
import '../widgets/reader_drawer.dart';

/// PDF 阅读器。PDF 为固定版式，不做重排，因此不接入排版设置，
/// 阅读位置以页码（0 起）作为 locator 与云端同步。
class PdfReaderPage extends StatefulWidget {
  final File file;
  final String bookId;
  final String title;
  final int initialPage;
  final double initialProgress;
  final Function(int pageIndex, double progressPercent)? onProgressChanged;

  const PdfReaderPage({
    super.key,
    required this.file,
    required this.bookId,
    required this.title,
    this.initialPage = 0,
    this.initialProgress = 0.0,
    this.onProgressChanged,
  });

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  static const String _nightModeKey = 'pdf_night_mode';
  static const String _swipeHorizontalKey = 'pdf_swipe_horizontal';

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  PDFViewController? _pdfController;
  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = false;

  int _totalPages = 0;
  int _currentPage = 0;
  int _lastReportedPage = -1;

  bool _nightMode = false;
  bool _swipeHorizontal = true;

  /// 首帧渲染完成前不能跳页，记录待恢复的目标页
  bool _initialPageApplied = false;

  List<Bookmark> _bookmarks = [];

  double get _progress {
    if (_totalPages <= 0) return widget.initialProgress.clamp(0.0, 1.0);
    return ((_currentPage + 1) / _totalPages).clamp(0.0, 1.0);
  }

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage < 0 ? 0 : widget.initialPage;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadViewPrefs();
    _loadBookmarks();
  }

  @override
  void dispose() {
    _reportProgress(force: true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadViewPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final night = prefs.getBool(_nightModeKey) ?? false;
      final horizontal = prefs.getBool(_swipeHorizontalKey) ?? true;
      if (!mounted) return;
      if (night != _nightMode || horizontal != _swipeHorizontal) {
        setState(() {
          _nightMode = night;
          _swipeHorizontal = horizontal;
        });
      }
    } catch (e) {
      AppLogger.log('⚠️ PDF 视图偏好读取失败: $e');
    }
  }

  Future<void> _saveViewPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_nightModeKey, _nightMode);
      await prefs.setBool(_swipeHorizontalKey, _swipeHorizontal);
    } catch (e) {
      AppLogger.log('⚠️ PDF 视图偏好保存失败: $e');
    }
  }

  Future<void> _loadBookmarks() async {
    try {
      final list = await BookmarkSyncService.syncWithServer(widget.bookId);
      if (mounted) setState(() => _bookmarks = list);
    } catch (e) {
      AppLogger.log('❌ 拉取 PDF 书签失败: $e');
    }
  }

  void _reportProgress({bool force = false}) {
    if (_totalPages <= 0) return;
    if (!force && _currentPage == _lastReportedPage) return;
    _lastReportedPage = _currentPage;
    widget.onProgressChanged?.call(_currentPage, _progress);
  }

  Future<void> _jumpToPage(int page) async {
    if (_totalPages <= 0) return;
    final target = page.clamp(0, _totalPages - 1);
    await _pdfController?.setPage(target);
  }

  Future<void> _togglePdfBookmark() async {
    if (_totalPages <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('页面尚未准备就绪，无法记录书签'), duration: Duration(milliseconds: 1000)),
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final bookmark = Bookmark(
      id: '${widget.bookId}_$now',
      bookId: widget.bookId,
      title: '第 ${_currentPage + 1} 页',
      snippet: 'PDF 页码标注 · 共 $_totalPages 页',
      progressPercent: _progress,
      byteOffset: _currentPage,
      createdAt: now,
      updatedAt: now,
    );

    await BookmarkSyncService.saveBookmark(bookmark);
    await _loadBookmarks();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加书签并同步'), duration: Duration(milliseconds: 1200)),
      );
    }
  }

  void _jumpToBookmark(Bookmark b) {
    Navigator.pop(context);
    final page = b.byteOffset;
    if (page != null) _jumpToPage(page);
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _nightMode ? const Color(0xFF1E1E1E) : const Color(0xFFF6EFE2);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: bgColor,
      drawer: ReaderDrawer(
        title: widget.title,
        bookmarks: _bookmarks,
        onBookmarkTap: _jumpToBookmark,
        onBookmarkDelete: (b) async {
          await BookmarkSyncService.deleteBookmark(widget.bookId, b.id);
          _loadBookmarks();
        },
        tocView: _buildPageList(),
      ),
      body: Stack(
        children: [
          if (_errorMessage == null)
            PDFView(
              filePath: widget.file.path,
              enableSwipe: true,
              swipeHorizontal: _swipeHorizontal,
              pageFling: _swipeHorizontal,
              pageSnap: _swipeHorizontal,
              autoSpacing: !_swipeHorizontal,
              nightMode: _nightMode,
              backgroundColor: bgColor,
              fitPolicy: FitPolicy.BOTH,
              defaultPage: _currentPage,
              onViewCreated: (controller) => _pdfController = controller,
              onRender: (pages) {
                if (!mounted) return;
                setState(() {
                  _totalPages = pages ?? 0;
                  _isLoading = false;
                });
                // 部分设备上 defaultPage 会被首帧布局重置，渲染完成后再兜底跳一次
                if (!_initialPageApplied && widget.initialPage > 0) {
                  _initialPageApplied = true;
                  _jumpToPage(widget.initialPage);
                }
              },
              onPageChanged: (page, total) {
                if (!mounted) return;
                setState(() {
                  _currentPage = page ?? 0;
                  if (total != null && total > 0) _totalPages = total;
                });
                _reportProgress();
              },
              onError: (error) {
                AppLogger.log('❌ PDF 载入异常: $error');
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                    _errorMessage = 'PDF 文件无法打开或已损坏';
                  });
                }
              },
              onPageError: (page, error) {
                AppLogger.log('⚠️ PDF 第 $page 页渲染失败: $error');
              },
            ),

          // PDF 需保留缩放与拖动手势，仅在屏幕中心留一块热区用于呼出控制条
          if (!_isLoading && _errorMessage == null && !_showControls)
            Align(
              alignment: Alignment.center,
              child: FractionallySizedBox(
                widthFactor: 0.4,
                heightFactor: 0.16,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showControls = true),
                  child: const SizedBox.expand(),
                ),
              ),
            ),

          if (_isLoading && _errorMessage == null)
            const Center(child: CircularProgressIndicator(color: Color(0xFF382E25))),

          if (_errorMessage != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ),
              ),
            ),

          if (_showControls) ..._buildControlBars(),
        ],
      ),
    );
  }

  List<Widget> _buildControlBars() {
    return [
      // 控制条展开时，空白处点击即收起
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showControls = false),
          child: const SizedBox.expand(),
        ),
      ),
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
                  icon: const Icon(Icons.bookmark_add_outlined, color: Colors.white),
                  tooltip: '添加书签',
                  onPressed: _togglePdfBookmark,
                ),
                IconButton(
                  icon: const Icon(Icons.format_list_bulleted, color: Colors.white),
                  tooltip: '页码与书签',
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
              ],
            ),
          ),
        ),
      ),
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
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      onPressed: () => _jumpToPage(_currentPage - 1),
                    ),
                    Expanded(
                      child: Slider(
                        value: _currentPage.toDouble().clamp(
                          0,
                          _totalPages > 0 ? (_totalPages - 1).toDouble() : 0,
                        ),
                        min: 0,
                        max: _totalPages > 1 ? (_totalPages - 1).toDouble() : 1,
                        divisions: _totalPages > 1 ? _totalPages - 1 : null,
                        label: '第 ${_currentPage + 1} 页',
                        onChanged: _totalPages > 1
                            ? (value) => setState(() => _currentPage = value.round())
                            : null,
                        onChangeEnd: _totalPages > 1
                            ? (value) => _jumpToPage(value.round())
                            : null,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: () => _jumpToPage(_currentPage + 1),
                    ),
                  ],
                ),
                Text(
                  _totalPages > 0
                      ? '第 ${_currentPage + 1} / $_totalPages 页 · ${(_progress * 100).toStringAsFixed(1)}%'
                      : '正在解析页数...',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const Divider(color: Colors.white24, height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildToggleChip(
                      label: '横向翻页',
                      icon: Icons.swap_horiz,
                      selected: _swipeHorizontal,
                      onTap: () {
                        setState(() => _swipeHorizontal = !_swipeHorizontal);
                        _saveViewPrefs();
                      },
                    ),
                    _buildToggleChip(
                      label: '夜间反色',
                      icon: Icons.dark_mode_outlined,
                      selected: _nightMode,
                      onTap: () {
                        setState(() => _nightMode = !_nightMode);
                        _saveViewPrefs();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Widget _buildToggleChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      avatar: Icon(icon, size: 16, color: selected ? Colors.white : Colors.white70),
      label: Text(label),
      selected: selected,
      selectedColor: const Color(0xFF5A4A3A),
      backgroundColor: Colors.white.withValues(alpha: 0.12),
      showCheckmark: false,
      side: BorderSide(
        color: selected ? const Color(0xFF8D7358) : Colors.transparent,
        width: 1,
      ),
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.white70,
        fontSize: 11,
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      ),
      onSelected: (_) => onTap(),
    );
  }

  /// PDF 无标准目录数据，抽屉首页改为页码索引供快速跳转
  Widget _buildPageList() {
    if (_totalPages <= 0) {
      return const Center(child: Text('暂无页码数据', style: TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      itemCount: _totalPages,
      itemBuilder: (context, index) {
        final isCurrent = index == _currentPage;
        return ListTile(
          dense: true,
          selected: isCurrent,
          title: Text(
            '第 ${index + 1} 页',
            style: TextStyle(
              fontSize: 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          onTap: () {
            Navigator.pop(context);
            _jumpToPage(index);
          },
        );
      },
    );
  }
}
