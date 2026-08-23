import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// 引入本地书架与 NAS 文件浏览器页面
import 'pages/login_page.dart';
import 'services/app_logger.dart';
import 'main_navigation_container.dart';

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