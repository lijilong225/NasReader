import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart'; // 引入 dio
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/app_logger.dart';

class LocalBookItem {
  final File file;
  final String name;
  final String title;
  final String extension;
  final int size;
  final DateTime lastModified;

  LocalBookItem({
    required this.file,
    required this.name,
    required this.title,
    required this.extension,
    required this.size,
    required this.lastModified,
  });
}

class LocalBookshelfPage extends StatefulWidget {
  final Dio? dio; // 接收 dio 参数

  const LocalBookshelfPage({super.key, this.dio});

  @override
  State<LocalBookshelfPage> createState() => LocalBookshelfPageState();
}

class LocalBookshelfPageState extends State<LocalBookshelfPage> {
  List<LocalBookItem> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    loadLocalBooks();
  }

  Future<void> loadLocalBooks() async {
    setState(() => _isLoading = true);

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));

      if (!booksDir.existsSync()) {
        booksDir.createSync(recursive: true);
      }

      final List<FileSystemEntity> entities = booksDir.listSync();
      final List<LocalBookItem> items = [];

      for (var entity in entities) {
        if (entity is File) {
          final fileName = p.basename(entity.path);
          final ext = p.extension(fileName).toLowerCase();

          if (ext == '.txt' || ext == '.epub') {
            final stat = entity.statSync();
            items.add(
              LocalBookItem(
                file: entity,
                name: fileName,
                title: p.basenameWithoutExtension(fileName),
                extension: ext,
                size: stat.size,
                lastModified: stat.modified,
              ),
            );
          }
        }
      }

      // 按最近修改时间倒序排列
      items.sort((a, b) => b.lastModified.compareTo(a.lastModified));

      if (mounted) {
        setState(() {
          _books = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.log('❌ 扫描本地书籍异常: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // 长按删除确认弹窗
  Future<void> _confirmAndDeleteBook(LocalBookItem book) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                book.name,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '占用空间: ${_formatSize(book.size)}',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除本地缓存', style: TextStyle(color: Colors.redAccent)),
                subtitle: const Text('仅删除手机本地文件，不影响 NAS 云端存储'),
                onTap: () => Navigator.pop(ctx, true),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('取消'),
                onTap: () => Navigator.pop(ctx, false),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      if (book.file.existsSync()) {
        await book.file.delete();
      }

      setState(() {
        _books.removeWhere((item) => item.name == book.name);
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除《${book.title}》本地缓存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _openBook(LocalBookItem book) {
    if (book.extension == '.txt') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StreamTxtReaderPage(
            bookId: book.name,
            file: book.file,
            title: book.title,
          ),
        ),
      ).then((_) => loadLocalBooks());
    } else if (book.extension == '.epub') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EpubReaderPage(
            bookId: book.name,
            file: book.file,
            title: book.title,
          ),
        ),
      ).then((_) => loadLocalBooks());
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地书架'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新书架',
            onPressed: loadLocalBooks,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_books.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.book_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              '书架暂无已下载书籍\n请在「NAS 书库」中浏览并点击下载',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.5),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('去下载书籍'),
              onPressed: () {
                loadLocalBooks();
              },
            ),
          ],
        ),
      );
    }

    return ListView.separated(
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
          subtitle: Text(
            '${_formatSize(book.size)} · ${book.extension.toUpperCase().replaceAll('.', '')}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
            onPressed: () => _confirmAndDeleteBook(book),
          ),
          onTap: () => _openBook(book),
          onLongPress: () => _confirmAndDeleteBook(book),
        );
      },
    );
  }
}