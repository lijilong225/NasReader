import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/page_turn_mode.dart';
import '../core/font_manager.dart';
import '../widgets/typography_config.dart';
import '../widgets/typography_settings_modal.dart';

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
  HttpServer? _localServer;
  int _serverPort = 0;
  late final WebViewController _webViewController;

  bool _isLoading = true;
  bool _showControls = false;
  double _currentProgress = 0.0;
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
    _initServerAndWebView();
  }

  @override
  void dispose() {
    _localServer?.close(force: true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initServerAndWebView() async {
    final parentDir = widget.file.parent.path;
    final staticHandler = createStaticHandler(parentDir, listDirectories: false);

    _localServer = await shelf_io.serve(staticHandler, '127.0.0.1', 0);
    _serverPort = _localServer!.port;

    final fileName = widget.file.uri.pathSegments.last;
    final epubUrl = 'http://127.0.0.1:$_serverPort/$fileName';

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
          onPageFinished: (_) {
            setState(() => _isLoading = false);
            _applyTypographyToEpub(_typoConfig);
          },
        ),
      )
      ..loadHtmlString(_buildEpubViewerHtml(epubUrl, widget.initialCfi));
  }

  void _handleJsMessage(String rawJson) {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final type = data['type'];

      switch (type) {
        case 'onRelocated':
          final cfi = data['cfi'] as String? ?? '';
          final progress = (data['percentage'] as num?)?.toDouble() ?? 0.0;
          setState(() {
            _currentCfi = cfi;
            _currentProgress = progress;
          });
          widget.onProgressChanged?.call(cfi, progress);
          break;

        case 'onTocLoaded':
          final rawToc = data['toc'] as List? ?? [];
          setState(() {
            _toc = rawToc.map((e) => EpubChapter.fromJson(e)).toList();
          });
          break;

        case 'onTapCenter':
          setState(() => _showControls = !_showControls);
          break;
      }
    } catch (_) {}
  }

  String _buildEpubViewerHtml(String epubUrl, String? startCfi) {
    final initialLocation = (startCfi != null && startCfi.isNotEmpty)
        ? '"$startCfi"'
        : 'undefined';

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <script src="https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/epubjs@0.3.93/dist/epub.min.js"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body, #viewer { width: 100vw; height: 100vh; overflow: hidden; background: #F6EFE2; }
  </style>
</head>
<body>
  <div id="viewer"></div>
  <script>
    const book = ePub("$epubUrl");
    const rendition = book.renderTo("viewer", {
      width: "100%",
      height: "100%",
      spread: "none",
      flow: "paginated"
    });

    rendition.display($initialLocation);

    book.loaded.navigation.then(function(toc) {
      FlutterChannel.postMessage(JSON.stringify({
        type: 'onTocLoaded',
        toc: toc.toc
      }));
    });

    book.ready.then(() => {
      return book.locations.generate(1000);
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

    rendition.on("click", function(event) {
      const width = window.innerWidth;
      const x = event.clientX;
      if (x < width * 0.3) {
        rendition.prev();
      } else if (x > width * 0.7) {
        rendition.next();
      } else {
        FlutterChannel.postMessage(JSON.stringify({ type: 'onTapCenter' }));
      }
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
    final bgHex = '#${bg.value.toRadixString(16).substring(2)}';
    final textHex = '#${text.value.toRadixString(16).substring(2)}';
    _webViewController.runJavaScript('window.setTheme("$bgHex", "$textHex");');
  }

  void _changePageTurnMode(PageTurnMode mode) {
    setState(() => _pageTurnMode = mode);
    final flow = mode == PageTurnMode.scroll ? 'scrolled-doc' : 'paginated';
    _webViewController.runJavaScript('window.setFlow("$flow");');
  }

  void _applyTypographyToEpub(TypographyConfig config) async {
    String fontFaceCss = '';
    if (config.customFontFamily != null) {
      final customFonts = FontManager.instance.fonts.where(
        (f) => f.fontFamily == config.customFontFamily,
      );
      if (customFonts.isNotEmpty) {
        final bytes = await customFonts.first.file.readAsBytes();
        final base64Font = base64Encode(bytes);
        fontFaceCss = "@font-face { font-family: '${config.customFontFamily}'; src: url(data:font/truetype;charset=utf-8;base64,$base64Font) format('truetype'); }";
      }
    }

    final indentVal = config.indentFirstLine ? '2em' : '0';
    final fontFamilyVal = config.customFontFamily != null
        ? "'${config.customFontFamily}', serif"
        : 'inherit';

    final jsCode = '''
      rendition.themes.fontSize("${config.fontSize}px");
      rendition.themes.default({
        'p, div': {
          'text-indent': '$indentVal !important',
          'letter-spacing': '${config.letterSpacing}px !important',
          'line-height': '${config.lineHeight} !important',
          'font-family': "$fontFamilyVal !important"
        }
      });
      if ("$fontFaceCss" !== "") {
        const style = document.createElement('style');
        style.innerHTML = "$fontFaceCss";
        document.head.appendChild(style);
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    const Text('目录',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _toc.isEmpty
                  ? const Center(child: Text('暂无目录数据'))
                  : ListView.builder(
                      itemCount: _toc.length,
                      itemBuilder: (context, index) =>
                          _buildTocItem(_toc[index]),
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
                          style:
                              const TextStyle(color: Colors.white, fontSize: 16),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.list, color: Colors.white),
                        tooltip: '目录',
                        onPressed: () =>
                            _scaffoldKey.currentState?.openDrawer(),
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
                color: Colors.black.withOpacity(0.92),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.skip_previous,
                                color: Colors.white),
                            onPressed: _prevPage,
                          ),
                          Text(
                            '${(_currentProgress * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14),
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_next,
                                color: Colors.white),
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
                            selectedColor: const Color(0xFF382E25),
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontSize: 12,
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
                            icon: const Icon(Icons.text_format,
                                color: Colors.white, size: 18),
                            label: const Text('排版 / 字体',
                                style: TextStyle(color: Colors.white, fontSize: 12)),
                            onPressed: _openTypographySettings,
                          ),
                          Row(
                            children: [
                              _buildThemeBtn('羊皮纸', const Color(0xFFF6EFE2),
                                  const Color(0xFF382E25)),
                              _buildThemeBtn('护眼', const Color(0xFFDDEBD6),
                                  const Color(0xFF233621)),
                              _buildThemeBtn('暗黑', const Color(0xFF1E1E1E),
                                  const Color(0xFF9E9E9E)),
                              _buildThemeBtn('纯白', const Color(0xFFFFFFFF),
                                  const Color(0xFF1A1A1A)),
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
        contentPadding:
            EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
        title: Text(chapter.label, style: const TextStyle(fontSize: 13)),
        onTap: () => _jumpToHref(chapter.href),
      );
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
      title: Text(chapter.label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      children:
          chapter.subitems.map((sub) => _buildTocItem(sub, depth + 1)).toList(),
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
            style: TextStyle(
              color: text,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}