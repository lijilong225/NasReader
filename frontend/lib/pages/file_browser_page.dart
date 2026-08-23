import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/app_logger.dart';
import '../services/auth_service.dart';
import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';

class FileItem {
  final String name;
  final String path;
  final bool isDir;
  final int size;

  FileItem({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      isDir: json['is_dir'] == true || json['isDir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class FileBrowserPage extends StatefulWidget {
  final Dio dio;

  const FileBrowserPage({super.key, required this.dio});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  String _currentPath = '/';
  List<FileItem> _items = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchDirectory(_currentPath);
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _fetchDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await widget.dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': path},
      );

      AppLogger.log('[FileBrowser] 响应: ${res.data}');

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> rawList = [];
        if (res.data is Map) {
          if (res.data['items'] is List) {
            rawList = res.data['items'];
          } else if (res.data['data'] is List) {
            rawList = res.data['data'];
          }
        } else if (res.data is List) {
          rawList = res.data;
        }

        final parsedItems = rawList
            .map((item) => FileItem.fromJson(Map<String, dynamic>.from(item)))
            .toList()
          ..sort((a, b) {
            if (a.isDir && !b.isDir) return -1;
            if (!a.isDir && b.isDir) return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

        setState(() {
          _currentPath = res.data is Map && res.data['current_path'] != null
              ? res.data['current_path'].toString()
              : path;
          _items = parsedItems;
        });
      } else {
        final err = res.data?['error'] ?? res.data?['msg'] ?? '获取目录失败';
        _showToast(err);
        setState(() => _errorMessage = err);
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final serverError = e.response?.data?['error'] ?? e.response?.data?['msg'];
      final err = serverError ?? '网络请求失败 [$status]';
      _showToast(err);
      setState(() => _errorMessage = err);
      AppLogger.log('❌ 获取目录失败: $err');
    } catch (e, stack) {
      final err = '数据解析异常: $e';
      _showToast(err);
      setState(() => _errorMessage = err);
      AppLogger.log('❌ 目录解析崩溃: $e\n$stack');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _downloadAndOpenBook(FileItem item) async {
    final fileName = item.name;
    final ext = p.extension(fileName).toLowerCase();

    if (ext != '.txt' && ext != '.epub') {
      _showToast('暂不支持该文件格式');
      return;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localDir = Directory(p.join(appDir.path, 'books'));
      if (!localDir.existsSync()) localDir.createSync(recursive: true);

      final savePath = p.join(localDir.path, fileName);
      final targetFile = File(savePath);

      if (!targetFile.existsSync()) {
        _showToast('正在下载: $fileName ...');
        await widget.dio.download(
          '/api/v1/files/download',
          savePath,
          queryParameters: {'path': item.path.isNotEmpty ? item.path : p.join(_currentPath, fileName)},
        );
      }

      if (!mounted) return;

      if (ext == '.txt') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StreamTxtReaderPage(
              bookId: fileName,
              file: targetFile,
              title: p.basenameWithoutExtension(fileName),
            ),
          ),
        );
      } else if (ext == '.epub') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EpubReaderPage(
              bookId: fileName,
              file: targetFile,
              title: p.basenameWithoutExtension(fileName),
            ),
          ),
        );
      }
    } catch (e) {
      _showToast('下载书籍失败: $e');
    }
  }

  bool _canGoBack() => _currentPath != '/' && _currentPath.isNotEmpty;

  void _goBack() {
    if (!_canGoBack()) return;
    final parent = p.dirname(_currentPath);
    _fetchDirectory(parent == '.' ? '/' : parent);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack(),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _currentPath == '/' ? 'NAS 书库根目录' : p.basename(_currentPath),
            overflow: TextOverflow.ellipsis,
          ),
          leading: _canGoBack()
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack)
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () => _fetchDirectory(_currentPath),
            ),
          ],
        ),
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                onPressed: () => _fetchDirectory(_currentPath),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_open, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              '当前目录为空或未包含 .txt / .epub 书籍\n(路径: $_currentPath)',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, height: 1.5),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _items[index];
        final ext = p.extension(item.name).toLowerCase();

        return ListTile(
          leading: Icon(
            item.isDir
                ? Icons.folder
                : (ext == '.txt'
                    ? Icons.description
                    : (ext == '.epub' ? Icons.menu_book : Icons.insert_drive_file)),
            color: item.isDir
                ? Colors.amber.shade700
                : (ext == '.epub' ? Colors.green : Colors.blue),
          ),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: item.isDir ? null : Text('${(item.size / 1024).toStringAsFixed(1)} KB'),
          onTap: () {
            if (item.isDir) {
              final nextPath = _currentPath == '/' ? '/${item.name}' : '$_currentPath/${item.name}';
              _fetchDirectory(nextPath);
            } else {
              _downloadAndOpenBook(item);
            }
          },
        );
      },
    );
  }
}