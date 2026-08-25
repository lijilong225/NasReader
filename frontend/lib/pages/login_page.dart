import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/core/network_client.dart';

import '../services/auth_service.dart';
import '../main_navigation_container.dart';
import '../services/progress_sync_service.dart';

// --- 登录 / 注册统一页面 ---
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController(text: ApiConfig.baseUrl);
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isRegisterMode = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSavedServerUrl();
  }

  Future<void> _loadSavedServerUrl() async {
    final savedUrl = await AuthService.getBaseUrl();
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _serverController.text = savedUrl;
    } else {
      _serverController.text = ApiConfig.baseUrl;
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final serverUrl = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    try {
      // 1. 同步保存并更新全局 ApiConfig 的 BaseUrl
      await ApiConfig.setBaseUrl(serverUrl);
      await AuthService.saveBaseUrl(serverUrl);

      final dio = NetworkClient.getDio(baseUrl: serverUrl);
      final path = _isRegisterMode ? '/api/v1/auth/register' : '/api/v1/auth/login';

      final response = await dio.post(
        path,
        data: {
          'username': username,
          'password': password,
        },
      );

      final data = response.data;
      final token = (data['token'] ?? data['data']?['token'] ?? '') as String;
      
      // 2. 解析用户信息（安全类型转换，避免 as int 崩溃）
      final rawUser = (data['user'] ?? data['data']?['user']) as Map<String, dynamic>?;
      
      // 安全提取 ID，兼容 int、double、String 等多种返回类型
      int parsedId = 1;
      final rawId = data['userId'] ?? data['user_id'] ?? data['id'];
      if (rawId is num) {
        parsedId = rawId.toInt();
      } else if (rawId is String) {
        parsedId = int.tryParse(rawId) ?? 1;
      }

      final user = rawUser != null
          ? AuthUser.fromJson(rawUser)
          : AuthUser(
              id: parsedId, // 👈 使用安全解析后的 ID
              username: username,
            );

      // 3. 核心：更新全局 ApiConfig 登录态与本地持久化
      await ApiConfig.onLoginSuccess(token: token, user: user);
      await AuthService.saveToken(token);

      final authedDio = NetworkClient.getDio(baseUrl: serverUrl, token: token);

      // 4. 登录成功后静默拉取远端全量阅读进度
      await ProgressSyncService.syncWithRemote(authedDio);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => MainNavigationContainer(dio: authedDio),
        ),
      );
    } on DioException catch (e) {
      String msg = '网络连接失败，请检查服务器地址';
      if (e.response != null && e.response?.data != null) {
        msg = e.response?.data['error'] ??
            e.response?.data['message'] ??
            '请求失败 (HTTP ${e.response?.statusCode})';
      }
      setState(() {
        _errorMessage = msg;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '发生错误: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.auto_stories,
                    size: 64,
                    color: Color(0xFF382E25),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isRegisterMode ? '创建阅读器账号' : '登录 NAS 同步服务',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF382E25),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // 服务端 URL
                  TextFormField(
                    controller: _serverController,
                    decoration: InputDecoration(
                      labelText: '后端服务地址',
                      hintText: ApiConfig.baseUrl,
                      prefixIcon: const Icon(Icons.dns_outlined),
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '请输入服务器 URL' : null,
                  ),
                  const SizedBox(height: 16),

                  // 用户名
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().length < 3) ? '用户名至少 3 个字符' : null,
                  ),
                  const SizedBox(height: 16),

                  // 密码
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 6) ? '密码长度至少 6 位' : null,
                  ),
                  const SizedBox(height: 16),

                  if (_errorMessage != null) ...[
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                  ],

                  // 提交按钮
                  FilledButton(
                    onPressed: _isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: const Color(0xFF382E25),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _isRegisterMode ? '立即注册' : '登 录',
                            style: const TextStyle(fontSize: 16),
                          ),
                  ),
                  const SizedBox(height: 12),

                  // 模式切换
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _isRegisterMode = !_isRegisterMode;
                        _errorMessage = null;
                      });
                    },
                    child: Text(
                      _isRegisterMode
                          ? '已有账号？返回登录'
                          : '没有账号？点击注册新用户',
                      style: const TextStyle(color: Color(0xFF382E25)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}