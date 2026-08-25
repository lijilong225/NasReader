// lib/config/api_config.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_logger.dart';

// lib/config/api_config.dart 中的 AuthUser
class AuthUser {
  final String id;
  final String username;
  final String? email;
  final String? nickname;

  const AuthUser({
    required this.id,
    required this.username,
    this.email,
    this.nickname,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'email': email,
    'nickname': nickname,
  };

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    // 后端 user_id 是 32 位随机 hex，不能按数字解析
    final rawId = json['id'] ?? json['user_id'] ?? json['userId'] ?? '';

    return AuthUser(
      id: rawId.toString(),
      username: (json['username'] ?? '').toString(),
      email: json['email']?.toString(),
      nickname: json['nickname']?.toString(),
    );
  }
}

class ApiConfig {
  static const String _keyBaseUrl = 'server_base_url';
  static const String _keyAuthToken = 'auth_token';
  static const String _keyUserInfo = 'auth_user_info';

  /// Token 改用系统钥匙串 / Android Keystore 存储，避免明文落在 SharedPreferences
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _baseUrl = _defaultBaseUrl;
  static String? _authToken;
  static AuthUser? _currentUser;

  /// 全局登录状态监听器（UI 组件可通过 ValueListenableBuilder 监听）
  static final ValueNotifier<bool> isLoggedInNotifier = ValueNotifier<bool>(false);

  static String get _defaultBaseUrl {
    if (kIsWeb) return 'http://nas:6088';
    if (Platform.isAndroid) {
      return 'http://nas:6088';
    }
    return 'http://nas:6088';
  }

  // 基础访问器
  static String get baseUrl => _baseUrl;
  static String? get authToken => _authToken;
  static AuthUser? get currentUser => _currentUser;
  static bool get isLoggedIn => _authToken != null && _authToken!.isNotEmpty;

  /// 统一认证请求头
  static Map<String, String> get authHeaders => {
    'Content-Type': 'application/json',
    if (_authToken != null && _authToken!.isNotEmpty)
      'Authorization': 'Bearer $_authToken',
  };

  /// 应用启动时初始化加载
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_keyBaseUrl) ?? _defaultBaseUrl;
    _authToken = await _loadToken(prefs);

    final rawUser = prefs.getString(_keyUserInfo);
    if (rawUser != null && rawUser.isNotEmpty) {
      try {
        _currentUser = AuthUser.fromJson(jsonDecode(rawUser));
      } catch (e) {
        AppLogger.log('⚠️ 本地用户信息损坏，已丢弃: $e');
        _currentUser = null;
      }
    }

    isLoggedInNotifier.value = isLoggedIn;
  }

  /// 读取 Token：优先安全存储，并把历史遗留的明文 Token 迁移过去后清除
  static Future<String?> _loadToken(SharedPreferences prefs) async {
    String? token;
    try {
      token = await _secureStorage.read(key: _keyAuthToken);
    } catch (e) {
      debugPrint('⚠️ 安全存储读取失败: $e');
    }
    if (token != null && token.isNotEmpty) return token;

    final legacy = prefs.getString(_keyAuthToken);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _secureStorage.write(key: _keyAuthToken, value: legacy);
        await prefs.remove(_keyAuthToken);
      } catch (e) {
        debugPrint('⚠️ Token 迁移到安全存储失败: $e');
        return legacy;
      }
      return legacy;
    }
    return null;
  }

  /// 供其它服务读取 Token（内存未命中时回落到安全存储）
  static Future<String?> readAuthToken() async {
    if (_authToken != null && _authToken!.isNotEmpty) return _authToken;
    final prefs = await SharedPreferences.getInstance();
    _authToken = await _loadToken(prefs);
    return _authToken;
  }

  /// 动态更新服务器地址
  static Future<void> setBaseUrl(String newUrl) async {
    var cleanUrl = newUrl.trim();
    if (cleanUrl.endsWith('/')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }
    _baseUrl = cleanUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, cleanUrl);
  }

  /// 登录成功：同步更新 Token 和用户信息并持久化
  static Future<void> onLoginSuccess({
    required String token,
    required AuthUser user,
  }) async {
    _authToken = token;
    _currentUser = user;

    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.write(key: _keyAuthToken, value: token);
    await prefs.remove(_keyAuthToken); // 清理历史明文残留
    await prefs.setString(_keyUserInfo, jsonEncode(user.toJson()));

    isLoggedInNotifier.value = true;
  }

  /// 登出：清空用户凭证与数据状态
  static Future<void> onLogout() async {
    _authToken = null;
    _currentUser = null;

    final prefs = await SharedPreferences.getInstance();
    try {
      await _secureStorage.delete(key: _keyAuthToken);
    } catch (e) {
      debugPrint('⚠️ 安全存储清除 Token 失败: $e');
    }
    await prefs.remove(_keyAuthToken);
    await prefs.remove(_keyUserInfo);

    isLoggedInNotifier.value = false;
  }
}