// lib/services/auth_service.dart
import '../config/api_config.dart';

class AuthService {
  static Future<String?> getBaseUrl() async => ApiConfig.baseUrl;
  static Future<void> saveBaseUrl(String url) async => ApiConfig.setBaseUrl(url);

  static Future<String?> getToken() async => ApiConfig.authToken;
  static Future<void> saveToken(String token) async {
    // 兼容旧接口，直接写入 ApiConfig
    await ApiConfig.onLoginSuccess(
      token: token,
      user: ApiConfig.currentUser ?? AuthUser(id: 1, username: 'User'),
    );
  }

  static Future<void> clearAuth() async => ApiConfig.onLogout();
}