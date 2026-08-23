import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/epub_cover_extractor.dart';

class LocalBookshelfPage extends StatefulWidget {
  final Dio dio;

  const LocalBookshelfPage({Key? key, required this.dio}) : super(key: key);

  @override
  State<LocalBookshelfPage> createState() => _LocalBookshelfPageState();
}

class _LocalBookshelfPageState extends State<LocalBookshelfPage> with WidgetsBindingObserver {
  List<FileSystemEntity> _localBooks = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLocalBooks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 当 App 从后台切回前台或页面重新获得焦点时自动刷新
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadLocalBooks();
    }
  }

  Future<void> _loadLocalBooks() async {
    setState(() => _isLoading = true);
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localDir = Directory(p.join(appDir.path, 'books'));

      if (!localDir.existsSync()) {
        localDir.createSync(recursive: true);
      }

      // 扫描 .txt 与 .epub 文件
      final entities = localDir.listSync().where((entity) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          return ext == '.txt' || ext == '.epub';
        }
        return false;
      }).toList();

      // 按修改时间倒序排列 (新下载的书排在前面)
      entities.sort((a, b) {
        final aTime = (a as File).lastModifiedSync();
        final bTime = (b as File).lastModifiedSync();
        return bTime.compareTo(aTime);
      });

      setState(() {
        _localBooks = entities;
      });
    } catch (e) {
      debugPrint('加载本地书架失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _openBook(File file) {
    final title = p.basenameWithoutExtension(file.path);
    final ext = p.extension(file.path).toLowerCase();

    if (ext == '.txt') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) => StreamTxtReaderPage(
            file: file, // 替换 filePath: file.path
            bookTitle: title,
            dio: widget.dio,
          ),
        ),
      ).then((_) => _loadLocalBooks());
    } else if (ext == '.epub') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) => EpubReaderPage(
            file: file, // 替换 filePath: file.path
            bookTitle: title,
            dio: widget.dio,
          ),
        ),
      ).then((_) => _loadLocalBooks());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地书架'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLocalBooks,
            tooltip: '刷新书架',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadLocalBooks,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _localBooks.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 200),
                      Center(
                        child: Text(
                          '书架暂无缓存书籍\n去 NAS 书库下载看看吧',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, height: 1.5),
                        ),
                      ),
                    ],
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: 0.62,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                    ),
                    itemCount: _localBooks.length,
                    itemBuilder: (context, index) {
                      final file = _localBooks[index] as File;
                      final fileName = p.basename(file.path);
                      final ext = p.extension(file.path).toLowerCase();
                      final title = p.basenameWithoutExtension(file.path);

                      return GestureDetector(
                        onTap: () => _openBook(file),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.08),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Icon(
                                    ext == '.txt' ? Icons.description : Icons.menu_book,
                                    size: 44,
                                    color: ext == '.txt' ? Colors.blue : Colors.green,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}