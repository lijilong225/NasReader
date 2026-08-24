import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../services/progress_sync_service.dart';
import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/app_logger.dart';

class BookshelfItem {
  final String bookId;
  final String title;
  final String extension;
  final File? localFile;
  final String remotePath;
  final double progressPercent;
  final String? epubCfi;
  final int? txtByteOffset;
  final DateTime lastReadTime;

  bool get isDownloaded => localFile != null && localFile!.existsSync();

  BookshelfItem({
    required this.bookId,
    required this.title,
    required this.extension,
    this.localFile,
    required this.remotePath,
    required this.progressPercent,
    this.epubCfi,
    this.txtByteOffset,
    required this.lastReadTime,
  });
}

class LocalBookshelfPage extends StatefulWidget {
  final Dio? dio;

  const LocalBookshelfPage({super.key, this.dio});

  @override
  State<LocalBookshelfPage> createState() => LocalBookshelfPageState();
}

class LocalBookshelfPageState extends State<LocalBookshelfPage> with WidgetsBindingObserver {
  List<BookshelfItem> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadLocalBooks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      loadLocalBooks();
    }
  }

  Future<void> loadLocalBooks() async {
    try {
      // 1. 若有网络则尝试同步一次远端进度列表
      if (widget.dio != null) {
        await ProgressSyncService.syncWithRemote(widget.dio!);
      }

      final progressList = await ProgressSyncService.getAllLocalProgress();

      // 2. 扫描本地已缓存的书籍文件
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (!booksDir.existsSync()) booksDir.createSync(recursive: true);

      final Map<String, File> localFilesMap = {};
      for (var f in booksDir.listSync()) {
        if (f is File) {
          localFilesMap[p.basename(f.path)] = f;
        }
      }

      final Map<String, BookshelfItem> mergedItems = {};

      // 3. 先加入远端记录
      for (var pItem in progressList) {
        final ext = p.extension(pItem.bookId).toLowerCase();
        final localFile = localFilesMap[pItem.bookId];

        mergedItems[pItem.bookId] = BookshelfItem(
          bookId: pItem.bookId,
          title: pItem.title.isNotEmpty ? pItem.title : p.basenameWithoutExtension(pItem.bookId),
          extension: ext,
          localFile: localFile,
          remotePath: pItem.filePath,
          progressPercent: pItem.progressPercent,
          epubCfi: pItem.epubCfi,
          txtByteOffset: pItem.txtByteOffset,
          lastReadTime: DateTime.fromMillisecondsSinceEpoch(pItem.lastReadTime),
        );
      }

      // 4. 补充本地已存在但尚未有远端进度的离线书籍
      localFilesMap.forEach((name, file) {
        if (!mergedItems.containsKey(name)) {
          final ext = p.extension(name).toLowerCase();
          if (ext == '.txt' || ext == '.epub') {
            mergedItems[name] = BookshelfItem(
              bookId: name,
              title: p.basenameWithoutExtension(name),
              extension: ext,
              localFile: file,
              remotePath: '',
              progressPercent: 0.0,
              lastReadTime: file.statSync().modified,
            );
          }
        }
      });

      final resultList = mergedItems.values.toList()
        ..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));

      if (mounted) {
        setState(() {
          _books = resultList;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.log('❌ 刷新书架异常: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openOrDownloadBook(BookshelfItem book) async {
    File targetFile;

    // 若新设备尚未下载此书，先从 NAS 远端下载
    if (!book.isDownloaded) {
      if (widget.dio == null || book.remotePath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未连接到 NAS 或缺少远端路径，无法下载此书')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在从 NAS 下载《${book.title}》...')),
      );

      final appDir = await getApplicationDocumentsDirectory();
      final savePath = p.join(appDir.path, 'books', book.bookId);
      final downloadPath = book.remotePath.startsWith('/') ? book.remotePath : '/${book.remotePath}';

      try {
        await widget.dio!.download(
          '/api/v1/files/download',
          savePath,
          queryParameters: {'path': downloadPath},
        );
        targetFile = File(savePath);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
        );
        return;
      }
    } else {
      targetFile = book.localFile!;
    }

    if (!mounted) return;

    if (book.extension == '.txt') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StreamTxtReaderPage(
            bookId: book.bookId,
            file: targetFile,
            title: book.title,
            initialByteOffset: book.txtByteOffset ?? 0,
            onProgressChanged: (byteOffset, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: book.bookId,
                title: book.title,
                filePath: book.remotePath,
                progressPercent: progress,
                txtByteOffset: byteOffset,
              );
            },
          ),
        ),
      ).then((_) => loadLocalBooks());
    } else if (book.extension == '.epub') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EpubReaderPage(
            bookId: book.bookId,
            file: targetFile,
            title: book.title,
            initialCfi: book.epubCfi,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: book.bookId,
                title: book.title,
                filePath: book.remotePath,
                progressPercent: progress,
                epubCfi: cfi,
              );
            },
          ),
        ),
      ).then((_) => loadLocalBooks());
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
            tooltip: '同步远端进度',
            onPressed: loadLocalBooks,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: loadLocalBooks,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_books.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          const Center(
            child: Text(
              '暂无书籍阅读记录\n可前往「NAS 书库」下载并阅读',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.5),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _books.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final book = _books[index];
        final isEpub = book.extension == '.epub';

        return ListTile(
          leading: Icon(
            isEpub ? Icons.menu_book : Icons.description,
            color: isEpub ? Colors.green : Colors.blue,
            size: 28,
          ),
          title: Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Row(
            children: [
              Text(
                '已读 ${(book.progressPercent * 100).toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 12, color: Colors.brown),
              ),
              const SizedBox(width: 8),
              if (!book.isDownloaded)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('云端记录 · 点击下载', style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
            ],
          ),
          trailing: Icon(
            book.isDownloaded ? Icons.chevron_right : Icons.cloud_download_outlined,
            color: Colors.grey,
          ),
          onTap: () => _openOrDownloadBook(book),
        );
      },
    );
  }
}