// lib/config/api_config.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// lib/config/api_config.dart 中的 AuthUser
class AuthUser {
  final int id;
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
    // 兼容 String / num 两种格式的 id
    final rawId = json['id'] ?? json['user_id'] ?? json['userId'] ?? 0;
    int parsedId = 0;
    if (rawId is num) {
      parsedId = rawId.toInt();
    } else if (rawId is String) {
      parsedId = int.tryParse(rawId) ?? 0;
    }

    return AuthUser(
      id: parsedId,
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
    _authToken = prefs.getString(_keyAuthToken);

    final rawUser = prefs.getString(_keyUserInfo);
    if (rawUser != null && rawUser.isNotEmpty) {
      try {
        _currentUser = AuthUser.fromJson(jsonDecode(rawUser));
      } catch (_) {
        _currentUser = null;
      }
    }

    isLoggedInNotifier.value = isLoggedIn;
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
    await prefs.setString(_keyAuthToken, token);
    await prefs.setString(_keyUserInfo, jsonEncode(user.toJson()));

    isLoggedInNotifier.value = true;
  }

  /// 登出：清空用户凭证与数据状态
  static Future<void> onLogout() async {
    _authToken = null;
    _currentUser = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAuthToken);
    await prefs.remove(_keyUserInfo);

    isLoggedInNotifier.value = false;
  }
}