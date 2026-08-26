import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/core/network_client.dart';

import '../services/auth_service.dart';
import '../main_navigation_container.dart';
import '../services/progress_sync_service.dart';
import '../services/server_endpoint_service.dart';
import '../services/server_profile_service.dart';

// --- 登录 / 注册统一页面 ---
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController(text: ApiConfig.baseUrl);
  final _backupServerController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _inviteCodeController = TextEditingController();

  bool _isRegisterMode = false;
  bool _isLoading = false;
  String? _errorMessage;

  List<ServerProfile> _profiles = const [];
  bool _rememberPassword = true;

  /// 是否展开备用服务器输入框
  bool _showBackupField = false;

  @override
  void initState() {
    super.initState();
    _loadSavedServerUrl();
  }

  /// 默认选中最近使用过的地址，并回填该地址上次的登录信息
  Future<void> _loadSavedServerUrl() async {
    final profiles = await ServerProfileService.loadProfiles();
    final endpoints = await ServerEndpointService.load();
    final savedUrl = await AuthService.getBaseUrl();

    final initialUrl = endpoints.primary.isNotEmpty
        ? endpoints.primary
        : profiles.isNotEmpty
            ? profiles.first.url
            : ServerProfileService.normalizeUrl(
                (savedUrl != null && savedUrl.isNotEmpty) ? savedUrl : ApiConfig.baseUrl,
              );

    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _serverController.text = initialUrl;
      _backupServerController.text = endpoints.backup;
      _showBackupField = endpoints.backup.isNotEmpty;
    });

    await _fillCredentials(initialUrl);
  }

  /// 按地址自动填充上次输入的用户名与已记住的密码
  Future<void> _fillCredentials(String url) async {
    final normalized = ServerProfileService.normalizeUrl(url);
    final profile = _profiles.firstWhere(
      (p) => p.url == normalized,
      orElse: () => const ServerProfile(url: ''),
    );

    if (profile.url.isEmpty) {
      if (!mounted) return;
      setState(() {
        _usernameController.text = '';
        _passwordController.text = '';
        _rememberPassword = true;
      });
      return;
    }

    final password =
        profile.rememberPassword ? await ServerProfileService.readPassword(normalized) : '';

    if (!mounted) return;
    setState(() {
      _usernameController.text = profile.username;
      _passwordController.text = password;
      _rememberPassword = profile.rememberPassword;
      if (profile.backupUrl.isNotEmpty) {
        _backupServerController.text = profile.backupUrl;
        _showBackupField = true;
      }
    });
  }

  Future<void> _onServerSelected(String url) async {
    setState(() {
      _serverController.text = url;
      _errorMessage = null;
    });
    await _fillCredentials(url);
  }

  Future<void> _removeProfile(ServerProfile profile) async {
    await ServerProfileService.removeProfile(profile.url);
    final profiles = await ServerProfileService.loadProfiles();
    if (!mounted) return;
    setState(() => _profiles = profiles);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _backupServerController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _inviteCodeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final primaryUrl = ServerProfileService.normalizeUrl(_serverController.text);
    final backupUrl = _showBackupField
        ? ServerProfileService.normalizeUrl(_backupServerController.text)
        : '';
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    try {
      // 1. 优先探测主服务器，不可用时回落备用服务器
      final pick = await ServerEndpointService.pickAvailable(
        primary: primaryUrl,
        backup: backupUrl,
      );

      if (pick == null) {
        setState(() {
          _errorMessage = backupUrl.isEmpty
              ? '主服务器无法连接，请检查地址或配置备用服务器'
              : '主服务器与备用服务器均无法连接';
        });
        return;
      }

      final serverUrl = pick.url;

      // 2. 同步保存主备配置并更新全局 ApiConfig 的 BaseUrl
      await ServerEndpointService.save(
        primary: primaryUrl,
        backup: backupUrl,
        usingBackup: pick.usingBackup,
      );
      NetworkClient.reset();
      await ApiConfig.setBaseUrl(serverUrl);
      await AuthService.saveBaseUrl(serverUrl);

      final dio = NetworkClient.getDio(baseUrl: serverUrl);
      final path = _isRegisterMode ? '/api/v1/auth/register' : '/api/v1/auth/login';

      final response = await dio.post(
        path,
        data: {
          'username': username,
          'password': password,
          if (_isRegisterMode) 'inviteCode': _inviteCodeController.text.trim(),
        },
      );

      final data = response.data;
      final token = (data['token'] ?? data['data']?['token'] ?? '') as String;
      
      // 3. 解析用户信息（安全类型转换，避免 as int 崩溃）
      final rawUser = (data['user'] ?? data['data']?['user']) as Map<String, dynamic>?;

      final fallbackId =
          (data['userId'] ?? data['user_id'] ?? data['id'] ?? '').toString();

      final user = rawUser != null
          ? AuthUser.fromJson(rawUser)
          : AuthUser(
              id: fallbackId,
              username: username,
            );

      // 4. 核心：更新全局 ApiConfig 登录态与本地持久化
      await ApiConfig.onLoginSuccess(token: token, user: user);
      await AuthService.saveToken(token);

      final authedDio = NetworkClient.getDio(baseUrl: serverUrl, token: token);

      // 5. 登录成功后静默拉取远端全量阅读进度
      await ProgressSyncService.syncWithRemote(authedDio);

      // 6. 记录本次使用的服务器与登录信息，供下次自动填充
      await ServerProfileService.saveProfile(
        url: primaryUrl,
        username: username,
        password: password,
        rememberPassword: _rememberPassword,
        backupUrl: backupUrl,
      );

      if (!mounted) return;

      if (pick.usingBackup) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('主服务器不可用，已通过备用服务器登录')),
        );
      }

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

                  // 主服务端 URL（可从最近使用过的地址中切换）
                  TextFormField(
                    controller: _serverController,
                    decoration: InputDecoration(
                      labelText: '主服务地址',
                      hintText: ApiConfig.baseUrl,
                      prefixIcon: const Icon(Icons.dns_outlined),
                      border: const OutlineInputBorder(),
                      suffixIcon: _profiles.isEmpty
                          ? null
                          : PopupMenuButton<ServerProfile>(
                              icon: const Icon(Icons.arrow_drop_down),
                              tooltip: '最近使用的服务器',
                              onSelected: (p) => _onServerSelected(p.url),
                              itemBuilder: (ctx) => _profiles
                                  .map(
                                    (p) => PopupMenuItem<ServerProfile>(
                                      value: p,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  p.url,
                                                  style: const TextStyle(fontSize: 13),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                if (p.username.isNotEmpty)
                                                  Text(
                                                    p.username,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.close, size: 16),
                                            tooltip: '删除该记录',
                                            onPressed: () {
                                              Navigator.pop(ctx);
                                              _removeProfile(p);
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '请输入服务器 URL' : null,
                  ),
                  const SizedBox(height: 8),

                  // 备用服务地址（可选）：主服务不可用时自动尝试
                  if (_showBackupField)
                    TextFormField(
                      controller: _backupServerController,
                      decoration: InputDecoration(
                        labelText: '备用服务地址（可选）',
                        helperText: '主服务器不可用时自动尝试此地址',
                        prefixIcon: const Icon(Icons.backup_outlined),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: '移除备用服务器',
                          onPressed: () => setState(() {
                            _backupServerController.clear();
                            _showBackupField = false;
                          }),
                        ),
                      ),
                    )
                  else
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _showBackupField = true),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加备用服务器'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF382E25),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 4),

                  // 记住密码：关闭时仅保留地址与用户名
                  Row(
                    children: [
                      Checkbox(
                        value: _rememberPassword,
                        onChanged: (v) =>
                            setState(() => _rememberPassword = v ?? false),
                      ),
                      const Text('记住密码', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // 邀请码（仅注册）
                  if (_isRegisterMode) ...[
                    TextFormField(
                      controller: _inviteCodeController,
                      decoration: const InputDecoration(
                        labelText: '邀请码',
                        helperText: '由服务端管理员提供',
                        prefixIcon: Icon(Icons.vpn_key_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入邀请码' : null,
                    ),
                    const SizedBox(height: 16),
                  ],

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