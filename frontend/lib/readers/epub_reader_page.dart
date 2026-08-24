import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/page_turn_mode.dart';
import '../widgets/typography_config.dart';
import '../widgets/typography_settings_modal.dart';
import '../services/app_logger.dart';

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

class _EpubReaderPageState extends State<EpubReaderPage> {
  late final WebViewController _webViewController;

  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = false;
  double _currentProgress = 0.0;
  // ignore: unused_field
  String _currentCfi = '';
  List<EpubChapter> _toc = [];

  PageTurnMode _pageTurnMode = PageTurnMode.cover;
  TypographyConfig _typoConfig = const TypographyConfig();

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _currentCfi = widget.initialCfi ?? '';
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initWebView();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
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

      // 1. 读取文件字节并转为 Base64
      final bytes = await widget.file.readAsBytes();
      final base64Epub = base64Encode(bytes);

      // 2. 初始化 WebViewController
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

      // 3. 构建并直接加载含有 Base64 数据的 HTML
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

        case 'onTapCenter':
          if (mounted) setState(() => _showControls = !_showControls);
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
    * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
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

      // 准确的热区点击与滑动防误触处理
      rendition.on("rendered", function(section, iframeView) {
        const iframeDoc = iframeView.document;
        if (!iframeDoc) return;

        let startX = 0;
        let startY = 0;
        let isMoving = false;

        iframeDoc.addEventListener("touchstart", function(e) {
          if (e.touches.length === 1) {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
            isMoving = false;
          }
        }, { passive: true });

        iframeDoc.addEventListener("touchmove", function(e) {
          if (e.touches.length === 1) {
            const dx = Math.abs(e.touches[0].clientX - startX);
            const dy = Math.abs(e.touches[0].clientY - startY);
            if (dx > 10 || dy > 10) {
              isMoving = true;
            }
          }
        }, { passive: true });

        iframeDoc.addEventListener("touchend", function(e) {
          // 如果用户是在滑动/拖拽选择，则不触发点击动作
          if (isMoving) return;

          const width = window.innerWidth || iframeDoc.documentElement.clientWidth;
          const clickX = startX;

          // 左侧 30% 翻上一页
          if (clickX < width * 0.3) {
            rendition.prev();
          }
          // 右侧 30% 翻下一页
          else if (clickX > width * 0.7) {
            rendition.next();
          }
          // 中间 40% 呼出/隐藏顶部与底部控制栏
          else {
            FlutterChannel.postMessage(JSON.stringify({ type: 'onTapCenter' }));
          }
        }, { passive: true });
      });

      window.nextPage = () => rendition.next();
      window.prevPage = () => rendition.prev();
      window.goToCfi = (cfi) => rendition.display(cfi);
      window.goToHref = (href) => rendition.display(href);
      window.setTheme = (bgColor, textColor) => {
        document.body.style.background = bgColor;
        rendition.themes.default({
          'body': { 'background': bgColor + ' !important', 'color': textColor + ' !important' },
          'p': { 'color': textColor + ' !important' }
        });
      };
      window.setFlow = (flowMode) => {
        rendition.flow(flowMode);
      };
    } catch (e) {
      FlutterChannel.postMessage(JSON.stringify({ type: 'onError', message: e.toString() }));
    }
  </script>
</body>
</html>
''';
  }

  void _nextPage() => _webViewController.runJavaScript('window.nextPage();');
  void _prevPage() => _webViewController.runJavaScript('window.prevPage();');

  void _jumpToHref(String href) {
    _webViewController.runJavaScript('window.goToHref("$href");');
    Navigator.pop(context);
  }

  void _applyTheme(Color bg, Color text) {
    final bgHex = '#${bg.toARGB32().toRadixString(16).substring(2)}';
    final textHex = '#${text.toARGB32().toRadixString(16).substring(2)}';
    _webViewController.runJavaScript('window.setTheme("$bgHex", "$textHex");');
  }

  void _changePageTurnMode(PageTurnMode mode) {
    setState(() => _pageTurnMode = mode);
    final flow = mode == PageTurnMode.scroll ? 'scrolled-doc' : 'paginated';
    _webViewController.runJavaScript('window.setFlow("$flow");');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFF6EFE2),
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
                    const Text('目录', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _toc.isEmpty
                  ? const Center(child: Text('暂无目录数据'))
                  : ListView.builder(
                      itemCount: _toc.length,
                      itemBuilder: (context, index) => _buildTocItem(_toc[index]),
                    ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _webViewController),

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
                        icon: const Icon(Icons.list, color: Colors.white),
                        tooltip: '目录',
                        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                    ],
                  ),
                ),
              ),
            ),

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

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: PageTurnMode.values.map((mode) {
                          final isSelected = _pageTurnMode == mode;
                          return ChoiceChip(
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
                              fontSize: 12,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                            onSelected: (_) => _changePageTurnMode(mode),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 10),

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
    if (chapter.subitems.isEmpty) {
      return ListTile(
        contentPadding: EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
        title: Text(chapter.label, style: const TextStyle(fontSize: 13)),
        onTap: () => _jumpToHref(chapter.href),
      );
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
      title: Text(chapter.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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