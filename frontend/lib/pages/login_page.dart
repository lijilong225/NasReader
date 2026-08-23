import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../main_navigation_container.dart';

// --- 登录 / 注册统一页面 ---
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController =
      TextEditingController(text: serverHost);
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
      _serverController.text = savedUrl; // 已做非空判断
    } else {
      _serverController.text = 'http://192.168.5.3:6088';
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
      final dio = NetworkClient.getDio(baseUrl: serverUrl);
      final path =
          _isRegisterMode ? '/api/v1/auth/register' : '/api/v1/auth/login';

      final response = await dio.post(
        path,
        data: {
          'username': username,
          'password': password,
        },
      );

      final token = response.data['token'] as String;

      await AuthService.saveBaseUrl(serverUrl);
      await AuthService.saveToken(token);

      final authedDio = NetworkClient.getDio(baseUrl: serverUrl, token: token);

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
            '请求失败';
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
                      hintText: serverHost,
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '请输入服务器 URL' : null,
                  ),
                  const SizedBox(height: 16),

                  // 用户名
                  TextFormField(
                    controller: _usernameController,
                    decoration: InputDecoration(
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
                    decoration: InputDecoration(
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