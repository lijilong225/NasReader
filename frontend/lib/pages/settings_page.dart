import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/config/theme_manager.dart'; // 👈 引入 ThemeManager
import 'package:nas_reader/services/auth_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'login_page.dart';
import '../services/app_logger.dart';

class SettingsPage extends StatefulWidget {
  final Dio? dio;

  const SettingsPage({
    super.key,
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      calculateCacheSize();
    }
  }

  Future<void> calculateCacheSize() async {
    if (_isCalculating) return;
    _isCalculating = true;

    try {
      int totalBytes = 0;

      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        totalBytes += await _getDirSize(tempDir);
      }

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
    } catch (e) {
      AppLogger.log('⚠️ 缓存大小统计不完整: $e');
    }
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
          } catch (e) {
            AppLogger.log('⚠️ 临时文件未能删除 [${item.path}]: $e');
          }
        }
      }

      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (booksDir.existsSync()) {
        final list = booksDir.listSync();
        for (final item in list) {
          try {
            item.deleteSync(recursive: true);
          } catch (e) {
            AppLogger.log('⚠️ 缓存书籍未能删除 [${item.path}]: $e');
          }
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

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_stories, color: Color(0xFF5A4A3A)),
            SizedBox(width: 8),
            Text('关于 NAS Reader'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NAS Reader 是一款面向个人 NAS 私有云的书籍阅读与多设备同步工具。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text('核心功能：', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '• 支持 TXT 高速排版引擎与 EPUB 精准重排\n'
              '• 挂载 NAS 物理存储目录，支持即点即读与离线缓存\n'
              '• 基于 LWW 策略的云端进度与书签跨设备毫秒级同步\n'
              '• 原生跟手滑动翻页与手势热区定制',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Divider(),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('版本', style: TextStyle(fontSize: 12, color: Colors.grey)),
                Text('v0.5.6', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ApiConfig.currentUser;

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

            // 1. 账号中心入口
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('账号与服务', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF5A4A3A),
                child: Text(
                  (user?.username.isNotEmpty ?? false)
                      ? user!.username[0].toUpperCase()
                      : 'U',
                  style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              title: const Text('账号中心'),
              subtitle: Text(
                ApiConfig.isLoggedIn
                    ? (user?.nickname?.isNotEmpty == true ? user!.nickname! : (user?.username ?? '已登录'))
                    : '未登录',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AccountCenterPage(),
                  ),
                );
              },
            ),
            const Divider(),

            // 2. 外观与主题（直接与 ThemeManager.themeModeNotifier 联动）
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('外观与主题', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: ThemeManager.themeModeNotifier,
                builder: (context, currentMode, _) {
                  return SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                        icon: Icon(Icons.brightness_auto),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.light,
                        label: Text('浅色'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.dark,
                        label: Text('深色'),
                        icon: Icon(Icons.dark_mode),
                      ),
                    ],
                    selected: {currentMode},
                    onSelectionChanged: (Set<ThemeMode> newSelection) {
                      // 触发全局 ThemeManager 更新并通知 main.dart 重绘
                      ThemeManager.updateTheme(newSelection.first);
                    },
                  );
                },
              ),
            ),
            const Divider(),

            // 3. 存储与诊断
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

            // 4. 关于
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('系统信息', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              subtitle: const Text('App 概述与版本信息'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showAboutDialog,
            ),
          ],
        ),
      ),
    );
  }
}

/// 账号信息二级页面（包含退出登录）
class AccountCenterPage extends StatelessWidget {
  const AccountCenterPage({super.key});

  Future<void> _handleLogout(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号并返回登录页吗？退出后将无法自动同步阅读进度。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ApiConfig.onLogout();
      await AuthService.clearAuth();

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('jwt_token');
      await prefs.remove('token');
      await prefs.remove('is_logged_in');
    } catch (e) {
      AppLogger.log('❌ 清理 Token 异常: $e');
    }

    if (!context.mounted) return;

    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, animation, secondaryAnimation) => const LoginPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ApiConfig.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号中心'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: const Color(0xFF5A4A3A),
                    child: Text(
                      (user?.username.isNotEmpty ?? false)
                          ? user!.username[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.nickname?.isNotEmpty == true
                              ? user!.nickname!
                              : (user?.username ?? '未登录'),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '用户 ID: ${user?.id ?? "未知"}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                        if (user?.email != null && user!.email!.isNotEmpty)
                          Text(
                            user.email!,
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text('服务状态', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_outlined, color: Colors.blueAccent),
                  title: const Text('远端服务地址', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    ApiConfig.baseUrl.isNotEmpty ? ApiConfig.baseUrl : '未配置',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.sync_lock_outlined, color: Colors.green),
                  title: const Text('多端同步状态', style: TextStyle(fontSize: 14)),
                  trailing: Text(
                    ApiConfig.isLoggedIn ? '已连接' : '未授权',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: ApiConfig.isLoggedIn ? Colors.green : Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              foregroundColor: Colors.redAccent,
              backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
            ),
            onPressed: () => _handleLogout(context),
            child: const Text('退出登录', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}