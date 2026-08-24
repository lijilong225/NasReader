import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/bookmark_model.dart';
import '../services/bookmark_sync_service.dart';
import '../widgets/reader_drawer.dart';
import '../widgets/typography_config.dart';
import '../widgets/typography_settings_modal.dart';
import '../services/app_logger.dart';

enum HandMode {
  standard('常规手势'),
  oneHand('单手模式');

  final String label;
  const HandMode(this.label);
}

class EpubChapter {
  final String label;
  final String href;
  final List<EpubChapter> subitems;

  EpubChapter({
    required this.label,
    required this.href,
    this.subitems = const [],
  });

  factory EpubChapter.fromJson(Map<String, dynamic> json) {
    var rawSubs = json['subitems'] as List? ?? [];
    return EpubChapter(
      label: (json['label'] ?? '').toString().trim(),
      href: json['href'] ?? '',
      subitems: rawSubs.map((item) => EpubChapter.fromJson(item)).toList(),
    );
  }
}

class EpubReaderPage extends StatefulWidget {
  final File file;
  final String bookId;
  final String title;
  final String? initialCfi;
  final Function(String cfi, double progressPercent)? onProgressChanged;

  const EpubReaderPage({
    super.key,
    required this.file,
    required this.bookId,
    required this.title,
    this.initialCfi,
    this.onProgressChanged,
  });

  @override
  State<EpubReaderPage> createState() => _EpubReaderPageState();
}

class _EpubReaderPageState extends State<EpubReaderPage> with SingleTickerProviderStateMixin {
  late final WebViewController _webViewController;

  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = false;
  double _currentProgress = 0.0;
  String _currentCfi = '';
  List<EpubChapter> _toc = [];
  List<Bookmark> _bookmarks = [];

  HandMode _handMode = HandMode.standard;
  TypographyConfig _typoConfig = const TypographyConfig();

  // 翻页状态与动画控制
  bool _isTurningPage = false;
  double _dragOffset = 0.0;
  bool _isDragging = false;
  late AnimationController _animController;
  Animation<double>? _slideAnimation;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _currentCfi = widget.initialCfi ?? '';
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _loadHandMode();
    _loadBookmarks();
    _initWebView();
  }

  @override
  void dispose() {
    _animController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadHandMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString('epub_hand_mode');
      if (savedMode == HandMode.oneHand.name && mounted) {
        setState(() => _handMode = HandMode.oneHand);
      }
    } catch (_) {}
  }

  Future<void> _saveHandMode(HandMode mode) async {
    setState(() => _handMode = mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('epub_hand_mode', mode.name);
    } catch (_) {}
  }

  Future<void> _loadBookmarks() async {
    try {
      final list = await BookmarkSyncService.syncWithServer(widget.bookId);
      if (mounted) setState(() => _bookmarks = list);
    } catch (e) {
      AppLogger.log('❌ 拉取 EPUB 书签失败: $e');
    }
  }

  Future<void> _toggleEpubBookmark() async {
    if (_currentCfi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('页面尚未准备就绪，无法记录书签'), duration: Duration(milliseconds: 1000)),
      );
      return;
    }

    final safeId = '${widget.bookId}_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final bookmark = Bookmark(
      id: safeId,
      bookId: widget.bookId,
      title: '进度 ${(_currentProgress * 100).toStringAsFixed(1)}%',
      snippet: 'EPUB 位置标注',
      progressPercent: _currentProgress,
      cfi: _currentCfi,
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

  void _jumpToEpubBookmark(Bookmark b) {
    Navigator.pop(context);
    if (b.cfi != null && b.cfi!.isNotEmpty) {
      final safeCfi = b.cfi!
          .replaceAll(r'\', r'\\')
          .replaceAll("'", r"\'")
          .replaceAll('"', r'\"');
      _webViewController.runJavaScript("window.goToCfi('$safeCfi');");
    }
  }

  Future<void> _initWebView() async {
    try {
      if (!widget.file.existsSync() || widget.file.lengthSync() == 0) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'EPUB 文件不存在或已损坏';
        });
        return;
      }

      final bytes = await widget.file.readAsBytes();
      final base64Epub = base64Encode(bytes);

      _webViewController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFFF6EFE2))
        ..addJavaScriptChannel(
          'FlutterChannel',
          onMessageReceived: (JavaScriptMessage message) {
            _handleJsMessage(message.message);
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onWebResourceError: (error) {
              AppLogger.log('❌ WebView 资源错误: ${error.description}');
            },
            onPageFinished: (_) {
              _applyTypographyToEpub(_typoConfig);
            },
          ),
        );

      if (_webViewController.platform is AndroidWebViewController) {
        AndroidWebViewController.enableDebugging(true);
      }

      final html = _buildEpubViewerHtml(base64Epub, widget.initialCfi);
      await _webViewController.loadHtmlString(html, baseUrl: 'https://localhost/');
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '读取 EPUB 文件失败: $e';
      });
      AppLogger.log('❌ EPUB 载入异常: $e');
    }
  }

  void _handleJsMessage(String rawJson) {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final type = data['type'];

      switch (type) {
        case 'onReady':
          if (mounted) setState(() => _isLoading = false);
          break;

        case 'onRelocated':
          final cfi = data['cfi'] as String? ?? '';
          final progress = (data['percentage'] as num?)?.toDouble() ?? 0.0;
          if (mounted) {
            setState(() {
              _currentCfi = cfi;
              _currentProgress = progress;
            });
          }
          widget.onProgressChanged?.call(cfi, progress);
          break;

        case 'onTocLoaded':
          final rawToc = data['toc'] as List? ?? [];
          if (mounted) {
            setState(() {
              _toc = rawToc.map((e) => EpubChapter.fromJson(e)).toList();
            });
          }
          break;

        case 'onError':
          if (mounted) {
            setState(() {
              _isLoading = false;
              _errorMessage = data['message'] ?? 'EPUB 内容解析失败';
            });
          }
          break;
      }
    } catch (_) {}
  }

  String _buildEpubViewerHtml(String base64Epub, String? startCfi) {
    final initialLocation = (startCfi != null && startCfi.isNotEmpty)
        ? "'$startCfi'"
        : 'undefined';

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.1.5/jszip.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/epubjs@0.3.88/dist/epub.min.js"></script>
  <style>
    * { 
      margin: 0; 
      padding: 0; 
      box-sizing: border-box; 
      -webkit-tap-highlight-color: transparent; 
      user-select: none;
      -webkit-user-select: none;
    }
    html, body, #viewer { width: 100vw; height: 100vh; overflow: hidden; background: #F6EFE2; }
  </style>
</head>
<body>
  <div id="viewer"></div>
  <script>
    window.onerror = function(msg, url, line) {
      FlutterChannel.postMessage(JSON.stringify({
        type: 'onError',
        message: 'JS Error: ' + msg + ' (line ' + line + ')'
      }));
    };

    function base64ToArrayBuffer(base64) {
      const binary_string = window.atob(base64);
      const len = binary_string.length;
      const bytes = new Uint8Array(len);
      for (let i = 0; i < len; i++) {
        bytes[i] = binary_string.charCodeAt(i);
      }
      return bytes.buffer;
    }

    try {
      const base64Data = "$base64Epub";
      const arrayBuffer = base64ToArrayBuffer(base64Data);

      const book = ePub(arrayBuffer);
      const rendition = book.renderTo("viewer", {
        width: "100%",
        height: "100%",
        spread: "none",
        flow: "paginated"
      });

      rendition.display($initialLocation).then(() => {
        FlutterChannel.postMessage(JSON.stringify({ type: 'onReady' }));
      }).catch(err => {
        FlutterChannel.postMessage(JSON.stringify({ type: 'onError', message: '渲染异常: ' + err }));
      });

      book.loaded.navigation.then(function(toc) {
        FlutterChannel.postMessage(JSON.stringify({
          type: 'onTocLoaded',
          toc: toc.toc
        }));
      });

      book.ready.then(() => {
        return book.locations.generate(600);
      });

      rendition.on("relocated", function(location) {
        const cfi = location.start.cfi;
        let percentage = 0;
        if (book.locations && book.locations.length()) {
          percentage = book.locations.percentageFromCfi(cfi);
        }
        FlutterChannel.postMessage(JSON.stringify({
          type: 'onRelocated',
          cfi: cfi,
          percentage: percentage
        }));
      });

      // 彻底禁用 webview 内部事件穿透，完全交由 Flutter 层九宫格引擎统一分流调度
      rendition.on("rendered", function(section, iframeView) {
        const iframeDoc = iframeView.document;
        if (!iframeDoc) return;

        iframeDoc.addEventListener("click", function(e) {
          e.preventDefault();
          e.stopPropagation();
        }, true);
      });

      window.nextPage = () => rendition.next();
      window.prevPage = () => rendition.prev();
      window.goToCfi = (cfi) => rendition.display(cfi);
      
      window.goToHref = function(href) {
        if (!href) return;
        const targetHref = href.trim();

        rendition.display(targetHref).catch(err => {
          try {
            const item = book.spine.get(targetHref);
            if (item) {
              rendition.display(item.href || item.idref);
            } else {
              const cleanHref = targetHref.split('#')[0];
              rendition.display(cleanHref);
            }
          } catch (e) {
            FlutterChannel.postMessage(JSON.stringify({
              type: 'onError',
              message: '目录跳转失败: ' + err
            }));
          }
        });
      };

      window.setTheme = (bgColor, textColor) => {
        document.body.style.background = bgColor;
        rendition.themes.default({
          'body': { 'background': bgColor + ' !important', 'color': textColor + ' !important' },
          'p': { 'color': textColor + ' !important' }
        });
      };
    } catch (e) {
      FlutterChannel.postMessage(JSON.stringify({ type: 'onError', message: e.toString() }));
    }
  </script>
</body>
</html>
''';
  }

  // 纯点击瞬切逻辑（带防抖拦截）
  void _nextPage() {
    if (_isTurningPage) return;
    _isTurningPage = true;
    _webViewController.runJavaScript('window.nextPage();');
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _isTurningPage = false;
    });
  }

  void _prevPage() {
    if (_isTurningPage) return;
    _isTurningPage = true;
    _webViewController.runJavaScript('window.prevPage();');
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _isTurningPage = false;
    });
  }

  // --- 手势滑动跟手与整页平移动画逻辑 ---

  void _handleHorizontalDragStart(DragStartDetails details) {
    if (_animController.isAnimating) _animController.stop();
    _isDragging = true;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    setState(() {
      _dragOffset += details.primaryDelta ?? 0.0;
    });
  }

  void _handleHorizontalDragEnd(DragEndDetails details, double screenWidth) {
    _isDragging = false;
    final velocity = details.primaryVelocity ?? 0.0;

    final bool reachDistanceThreshold = _dragOffset.abs() > (screenWidth * 0.20);
    final bool reachVelocityThreshold = velocity.abs() > 300.0;
    final bool canFlip = reachDistanceThreshold || reachVelocityThreshold;

    final bool isNext = _dragOffset < 0;
    double targetEndOffset = 0.0;

    if (canFlip) {
      targetEndOffset = isNext ? -screenWidth : screenWidth;
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
      if (canFlip) {
        if (isNext) {
          _webViewController.runJavaScript('window.nextPage();');
        } else {
          _webViewController.runJavaScript('window.prevPage();');
        }
      }
      setState(() {
        _dragOffset = 0.0;
      });
    });
  }

  void _jumpToHref(String href) {
    if (href.trim().isEmpty) return;

    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }

    final safeHref = href
        .trim()
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('"', r'\"');

    _webViewController.runJavaScript("window.goToHref('$safeHref');");
  }

  void _applyTheme(Color bg, Color text) {
    final bgHex = '#${bg.toARGB32().toRadixString(16).substring(2)}';
    final textHex = '#${text.toARGB32().toRadixString(16).substring(2)}';
    _webViewController.runJavaScript('window.setTheme("$bgHex", "$textHex");');
  }

  void _applyTypographyToEpub(TypographyConfig config) {
    final indentVal = config.indentFirstLine ? '2em' : '0';
    final jsCode = '''
      if (window.rendition) {
        rendition.themes.fontSize("${config.fontSize}px");
        rendition.themes.default({
          'p, div': {
            'text-indent': '$indentVal !important',
            'letter-spacing': '${config.letterSpacing}px !important',
            'line-height': '${config.lineHeight} !important'
          }
        });
      }
    ''';
    _webViewController.runJavaScript(jsCode);
  }

  void _openTypographySettings() {
    TypographySettingsModal.show(
      context,
      config: _typoConfig,
      onConfigChanged: (newConfig) {
        setState(() => _typoConfig = newConfig);
        _applyTypographyToEpub(newConfig);
      },
    );
  }

  Widget _buildNineGridGestureLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final totalHeight = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // 水平跟手滑动支持
          onHorizontalDragStart: (details) {
            if (_showControls) return;
            _handleHorizontalDragStart(details);
          },
          onHorizontalDragUpdate: (details) {
            if (_showControls) return;
            _handleHorizontalDragUpdate(details);
          },
          onHorizontalDragEnd: (details) {
            if (_showControls) return;
            _handleHorizontalDragEnd(details, totalWidth);
          },
          // 点击瞬切
          onTapUp: (details) {
            if (_isTurningPage) return;

            if (_showControls) {
              setState(() => _showControls = false);
              return;
            }

            final dx = details.localPosition.dx;
            final dy = details.localPosition.dy;

            final col = (dx / (totalWidth / 3)).clamp(0.0, 2.0).toInt();
            final row = (dy / (totalHeight / 3)).clamp(0.0, 2.0).toInt();
            final zone = row * 3 + col + 1;

            if (zone == 5) {
              setState(() => _showControls = true);
              return;
            }

            if (_handMode == HandMode.standard) {
              if (zone >= 1 && zone <= 4) {
                _prevPage();
              } else {
                _nextPage();
              }
            } else {
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
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFF6EFE2),
      drawer: ReaderDrawer(
        title: widget.title,
        bookmarks: _bookmarks,
        onBookmarkTap: _jumpToEpubBookmark,
        onBookmarkDelete: (b) async {
          await BookmarkSyncService.deleteBookmark(widget.bookId, b.id);
          _loadBookmarks();
        },
        tocView: _toc.isEmpty
            ? const Center(child: Text('暂无目录数据', style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                itemCount: _toc.length,
                itemBuilder: (context, index) => _buildTocItem(_toc[index]),
              ),
      ),
      body: Stack(
        children: [
          // 1. 底层 WebView 视图（支持跟手平移与边缘阴影）
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
              child: WebViewWidget(controller: _webViewController),
            ),
          ),

          // 2. 顶层 3x3 九宫格与水平滑动手势拦截层
          if (!_isLoading && _errorMessage == null)
            Positioned.fill(
              child: _buildNineGridGestureLayer(),
            ),

          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF382E25)),
            ),

          if (_errorMessage != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
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
                        onPressed: _toggleEpubBookmark,
                      ),
                      IconButton(
                        icon: const Icon(Icons.format_list_bulleted, color: Colors.white),
                        tooltip: '目录与书签',
                        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 4. 底部控制条（已移除翻页动画选项）
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.skip_previous, color: Colors.white),
                            onPressed: _prevPage,
                          ),
                          Text(
                            '${(_currentProgress * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_next, color: Colors.white),
                            onPressed: _nextPage,
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white24, height: 16),

                      // 手势模式切换
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
                                    color: isSelected ? Colors.white : Colors.white70,
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
                      const SizedBox(height: 12),

                      // 排版与主题
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.text_format, color: Colors.white, size: 18),
                            label: const Text('排版 / 字体', style: TextStyle(color: Colors.white, fontSize: 12)),
                            onPressed: _openTypographySettings,
                          ),
                          Row(
                            children: [
                              _buildThemeBtn('羊皮纸', const Color(0xFFF6EFE2), const Color(0xFF382E25)),
                              _buildThemeBtn('护眼', const Color(0xFFDDEBD6), const Color(0xFF233621)),
                              _buildThemeBtn('暗黑', const Color(0xFF1E1E1E), const Color(0xFF9E9E9E)),
                              _buildThemeBtn('纯白', const Color(0xFFFFFFFF), const Color(0xFF1A1A1A)),
                            ],
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

  Widget _buildTocItem(EpubChapter chapter, [int depth = 0]) {
    final hasChildren = chapter.subitems.isNotEmpty;

    if (!hasChildren) {
      return ListTile(
        contentPadding: EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
        title: Text(
          chapter.label.isNotEmpty ? chapter.label : '未命名章节',
          style: const TextStyle(fontSize: 13),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _jumpToHref(chapter.href),
      );
    }

    return ExpansionTile(
      tilePadding: EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
      title: InkWell(
        onTap: () => _jumpToHref(chapter.href),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            chapter.label.isNotEmpty ? chapter.label : '未命名章节',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      children: chapter.subitems.map((sub) => _buildTocItem(sub, depth + 1)).toList(),
    );
  }

  Widget _buildThemeBtn(String label, Color bg, Color text) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: GestureDetector(
        onTap: () => _applyTheme(bg, text),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey),
          ),
          child: Text(
            label,
            style: TextStyle(color: text, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}