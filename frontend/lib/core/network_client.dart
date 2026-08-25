// --- 全局 Dio 单例构建与拦截器注入 ---
import 'dart:developer' as AppLogger;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/main_navigation_container.dart';
import 'package:nas_reader/pages/login_page.dart';
import 'package:nas_reader/services/auth_service.dart';

// 全局 Navigation Key，用于在 Dio 拦截器中触发 401 登出跳转
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class NetworkClient {
  static Dio? _dioInstance;

  /// 清洗 BaseUrl：去除协议外末尾的斜杠、/api、/api/v1 等多余前缀，避免路由重复拼装
  static String sanitizeBaseUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      rawUrl = ApiConfig.baseUrl; // 回退到全局配置
    }
    String cleaned = rawUrl.trim();
    // 递归剔除结尾的 /api/v1、/api 以及所有尾部斜杠
    cleaned = cleaned
        .replaceAll(RegExp(r'/api/v\d+/?$'), '')
        .replaceAll(RegExp(r'/api/?$'), '')
        .replaceAll(RegExp(r'/+$'), '');
    return cleaned;
  }

  /// 获取 Dio 单例
  static Dio getDio({String? baseUrl, String? token}) {
    final targetBaseUrl = sanitizeBaseUrl(baseUrl ?? ApiConfig.baseUrl);

    // 1. 如果单例已存在，且 baseUrl 没有变更，直接复用
    if (_dioInstance != null && _dioInstance!.options.baseUrl == targetBaseUrl) {
      return _dioInstance!;
    }

    // 2. 如果 baseUrl 变更或初次初始化，创建新的 Dio 实例
    final options = BaseOptions(
      baseUrl: targetBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      contentType: 'application/json',
    );

    final dio = Dio(options);

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (reqOptions, handler) async {
          // 每次请求前动态获取最新的 Token（优先使用传入的 token，次选 ApiConfig/AuthService）
          final currentToken = token ?? ApiConfig.authToken ?? await AuthService.getToken();
          if (currentToken != null && currentToken.isNotEmpty) {
            reqOptions.headers['Authorization'] = 'Bearer $currentToken';
          }

          AppLogger.log('🌐 [HTTP REQUEST] ${reqOptions.method} ${reqOptions.uri}');
          return handler.next(reqOptions);
        },
        onResponse: (response, handler) {
          AppLogger.log('✅ [HTTP ${response.statusCode}] ${response.requestOptions.uri}');
          return handler.next(response);
        },
        onError: (DioException error, handler) async {
          AppLogger.log('❌ [HTTP ERROR ${error.response?.statusCode}] -> ${error.requestOptions.uri}');

          // 401 鉴权失效：重置网络单例、清理本地凭证并切回登录页
          if (error.response?.statusCode == 401) {
            reset();
            await ApiConfig.onLogout();
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
    _dioInstance?.close(force: true);
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