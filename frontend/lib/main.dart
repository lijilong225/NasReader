import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// 引入本地书架与 NAS 文件浏览器页面
import 'pages/local_bookshelf_page.dart';
import 'pages/file_browser_page.dart';
import 'pages/settings_page.dart';
import 'services/app_logger.dart';

// 全局 Navigation Key，用于在 Dio 拦截器中触发 401 登出跳转
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
// main.dart 中初始化 Dio
String serverHost = 'http://192.168.5.3:6088';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NAS Reader',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF382E25),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const SplashPage(),
    );
  }
}

// --- 认证与安全存储管理服务 ---
class AuthService {
  static const _storage = FlutterSecureStorage();
  static const _keyToken = 'auth_token';
  static const _keyBaseUrl = 'server_base_url';

  static Future<String?> getToken() => _storage.read(key: _keyToken);
  static Future<void> saveToken(String token) =>
      _storage.write(key: _keyToken, value: token);

  static Future<String> getBaseUrl() async {
    final url = await _storage.read(key: _keyBaseUrl);
    return url ?? serverHost;
  }

  static Future<void> saveBaseUrl(String url) =>
      _storage.write(key: _keyBaseUrl, value: url);

  static Future<void> clearAuth() async {
    await _storage.delete(key: _keyToken);
  }
}

// --- 全局 Dio 单例构建与拦截器注入 ---
class NetworkClient {
  static Dio? _dioInstance;

  /// 清洗 BaseUrl，确保末尾既没有多余的斜杠，也没有自带的 /api 前缀
  static String sanitizeBaseUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      rawUrl = serverHost; // 回退到默认全局变量
    }
    String cleaned = rawUrl.trim();
    // 递归剔除结尾的 / 和 /api
    cleaned = cleaned.replaceAll(RegExp(r'/api/?$'), '').replaceAll(RegExp(r'/$'), '');
    return cleaned;
  }

  /// 获取 Dio 单例
  static Dio getDio({String? baseUrl, String? token}) {
    final cleanBaseUrl = sanitizeBaseUrl(baseUrl ?? _dioInstance?.options.baseUrl);

    // 如果实例已存在且 baseUrl 没有发生改变，直接复用
    if (_dioInstance != null && baseUrl == null && token == null) {
      return _dioInstance!;
    }

    final options = BaseOptions(
      baseUrl: cleanBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      contentType: 'application/json',
    );

    final dio = Dio(options);

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (reqOptions, handler) async {
          // 打印完整请求地址供调试
          AppLogger.log('🌐 [HTTP REQUEST] ${reqOptions.method} ${reqOptions.uri}');
          final currentToken = token ?? await AuthService.getToken();
          if (currentToken != null && currentToken.isNotEmpty) {
            reqOptions.headers['Authorization'] = 'Bearer $currentToken';
          }
          return handler.next(reqOptions);
        },
        onResponse: (response, handler) {
          AppLogger.log('✅ [HTTP ${response.statusCode}] ${response.requestOptions.uri}');
          return handler.next(response);
        },
        onError: (DioException error, handler) async {
          AppLogger.log('❌ [HTTP ERROR ${error.response?.statusCode}] -> ${error.requestOptions.uri}');
          // 401 鉴权失效：清除本地凭证并切回登录页
          if (error.response?.statusCode == 401) {
            await AuthService.clearAuth();
            navigatorKey.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const LoginPage()),
              (route) => false,
            );
          }
          return handler.next(error);
        },
      ),
    );

    _dioInstance = dio;
    return dio;
  }

  /// 退出登录或切换服务器时，主动重置 Dio 实例
  static void reset() {
    _dioInstance = null;
  }
}

// --- 启动引导检查页 ---
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    final token = await AuthService.getToken();
    final baseUrl = await AuthService.getBaseUrl();
    final dio = NetworkClient.getDio(baseUrl: baseUrl, token: token);

    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    if (token != null && token.isNotEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => MainNavigationContainer(dio: dio),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const LoginPage(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

// --- 底部导航主容器 (双 Tab: 本地书架 / NAS 书库) ---
class MainNavigationContainer extends StatefulWidget {
  final Dio dio;

  const MainNavigationContainer({super.key, required this.dio});

  @override
  State<MainNavigationContainer> createState() =>
      _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer> {
  int _currentIndex = 0;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      LocalBookshelfPage(dio: widget.dio),
      FileBrowserPage(dio: widget.dio),
      SettingsPage(dio: widget.dio),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.book_outlined),
            selectedIcon: Icon(Icons.book),
            label: '本地书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: 'NAS 书库',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

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
    setState(() {
      _serverController.text = savedUrl;
    });
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