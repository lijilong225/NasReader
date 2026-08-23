import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../services/app_logger.dart';
import '../services/auth_service.dart';
import 'login_page.dart';

class SettingsPage extends StatefulWidget {
  final Dio dio;

  const SettingsPage({super.key, required this.dio});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _serverController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _serverController.text = widget.dio.options.baseUrl;
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  void _saveServerAddress() {
    final newUrl = _serverController.text.trim();
    if (newUrl.isNotEmpty) {
      widget.dio.options.baseUrl = newUrl;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务器地址已更新')),
      );
    }
  }

  void _logout() async {
    await AuthService.clearAuth();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '连接配置',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _serverController,
            decoration: InputDecoration(
              labelText: 'NAS 服务器地址',
              hintText: 'http://192.168.1.100:8080',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.save),
                onPressed: _saveServerAddress,
                tooltip: '保存地址',
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '调试与运维',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bug_report, color: Colors.orange),
              title: const Text('HTTP 网络日志'),
              subtitle: const Text('查看 API 请求详情与错误定位'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => AppLogger.showLogModal(context),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '账号操作',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('退出登录', style: TextStyle(color: Colors.red)),
              onTap: _logout,
            ),
          ),
        ],
      ),
    );
  }
}