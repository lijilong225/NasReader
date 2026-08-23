import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_service.dart';
import '../services/app_logger.dart';

class SettingsPage extends StatefulWidget {
  final ValueNotifier<ThemeMode>? themeNotifier;
  final Dio? dio;

  const SettingsPage({
    super.key,
    this.themeNotifier,
    this.dio,
  });

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  String _cacheSizeStr = '计算中...';
  bool _isClearing = false;
  bool _isCalculating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    calculateCacheSize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 监听 App 切换到前台状态时自动重新统计
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      calculateCacheSize();
    }
  }

  // 供外部或自身调用的缓存统计方法
  Future<void> calculateCacheSize() async {
    if (_isCalculating) return;
    _isCalculating = true;

    try {
      int totalBytes = 0;

      // 统计临时缓存目录
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        totalBytes += await _getDirSize(tempDir);
      }

      // 统计已下载书籍目录
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (booksDir.existsSync()) {
        totalBytes += await _getDirSize(booksDir);
      }

      if (!mounted) return;
      setState(() {
        _cacheSizeStr = _formatSize(totalBytes);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cacheSizeStr = '未知';
      });
      AppLogger.log('❌ 统计缓存异常: $e');
    } finally {
      _isCalculating = false;
    }
  }

  Future<int> _getDirSize(Directory dir) async {
    int bytes = 0;
    try {
      final list = dir.listSync(recursive: true, followLinks: false);
      for (final item in list) {
        if (item is File) {
          bytes += await item.length();
        }
      }
    } catch (_) {}
    return bytes;
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0.00 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // 清除缓存逻辑
  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理本地缓存'),
        content: const Text('将清空已下载的离线书籍与网络临时文件。确认清除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isClearing = true);

    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final list = tempDir.listSync();
        for (final item in list) {
          try {
            item.deleteSync(recursive: true);
          } catch (_) {}
        }
      }

      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (booksDir.existsSync()) {
        final list = booksDir.listSync();
        for (final item in list) {
          try {
            item.deleteSync(recursive: true);
          } catch (_) {}
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地缓存已全部清除')),
      );
      await calculateCacheSize();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理缓存失败: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() => _isClearing = false);
      }
    }
  }

  Future<void> _handleLogout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('jwt_token');
      await prefs.remove('auth_token');
      await prefs.remove('token');
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出登录')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentTheme = widget.themeNotifier?.value ?? ThemeMode.system;

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新计算缓存',
            onPressed: calculateCacheSize,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: calculateCacheSize,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 8),

            if (widget.themeNotifier != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('外观与主题', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              ),
              ListTile(
                leading: const Icon(Icons.brightness_auto),
                title: const Text('跟随系统'),
                trailing: Radio<ThemeMode>(
                  value: ThemeMode.system,
                  groupValue: currentTheme,
                  onChanged: (val) {
                    if (val != null) widget.themeNotifier!.value = val;
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.light_mode),
                title: const Text('浅色模式'),
                trailing: Radio<ThemeMode>(
                  value: ThemeMode.light,
                  groupValue: currentTheme,
                  onChanged: (val) {
                    if (val != null) widget.themeNotifier!.value = val;
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.dark_mode),
                title: const Text('深色模式'),
                trailing: Radio<ThemeMode>(
                  value: ThemeMode.dark,
                  groupValue: currentTheme,
                  onChanged: (val) {
                    if (val != null) widget.themeNotifier!.value = val;
                  },
                ),
              ),
              const Divider(),
            ],

            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('存储与诊断', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清除本地缓存'),
              subtitle: Text('包含已下载书籍及网络临时文件 ($_cacheSizeStr)'),
              trailing: _isClearing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _isClearing ? null : _clearCache,
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('查看网络诊断日志'),
              subtitle: const Text('抓包与 API 调试'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => AppLogger.showLogModal(context),
            ),

            const Divider(),

            ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: const Text('退出登录', style: TextStyle(color: Colors.redAccent)),
              onTap: _handleLogout,
            ),
          ],
        ),
      ),
    );
  }
}