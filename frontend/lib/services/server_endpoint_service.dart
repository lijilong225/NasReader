// lib/services/server_endpoint_service.dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'server_profile_service.dart';

/// 主备服务器配置与当前生效地址
class ServerEndpoints {
  final String primary;
  final String backup;

  /// 当前生效地址是否为备用服务器
  final bool usingBackup;

  const ServerEndpoints({
    this.primary = '',
    this.backup = '',
    this.usingBackup = false,
  });

  bool get hasBackup => backup.isNotEmpty;

  /// 当前应当使用的地址：仅在标记为备用且备用地址存在时才返回备用
  String get active => (usingBackup && hasBackup) ? backup : primary;
}

/// 管理主/备服务器地址，并在主服务不可用时自动切换到备用地址
class ServerEndpointService {
  static const String _keyPrimary = 'server_primary_url';
  static const String _keyBackup = 'server_backup_url';
  static const String _keyUsingBackup = 'server_using_backup';

  /// 健康探针路径；旧版后端没有该路由时返回 404，仍视为“可达”
  static const String healthPath = '/api/v1/health';

  static const Duration probeTimeout = Duration(seconds: 4);

  static String normalizeUrl(String url) => ServerProfileService.normalizeUrl(url);

  /// HTTP 状态码 < 500 即认为服务可达（含 404，兼容无健康接口的旧后端）
  static bool isReachableStatus(int? statusCode) =>
      statusCode != null && statusCode < 500;

  static Future<ServerEndpoints> load() async {
    final prefs = await SharedPreferences.getInstance();
    final primary = prefs.getString(_keyPrimary) ?? '';
    final backup = prefs.getString(_keyBackup) ?? '';
    return ServerEndpoints(
      primary: primary,
      backup: backup,
      usingBackup: (prefs.getBool(_keyUsingBackup) ?? false) && backup.isNotEmpty,
    );
  }

  static Future<void> save({
    required String primary,
    required String backup,
    required bool usingBackup,
  }) async {
    final normalizedPrimary = normalizeUrl(primary);
    final normalizedBackup = normalizeUrl(backup);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPrimary, normalizedPrimary);
    await prefs.setString(_keyBackup, normalizedBackup);
    await prefs.setBool(
      _keyUsingBackup,
      usingBackup && normalizedBackup.isNotEmpty,
    );
  }

  /// 探测单个地址是否可用
  static Future<bool> probe(String url, {Dio? client}) async {
    final target = normalizeUrl(url);
    if (target.isEmpty) return false;

    final dio = client ??
        Dio(
          BaseOptions(
            connectTimeout: probeTimeout,
            receiveTimeout: probeTimeout,
            // 交由 isReachableStatus 判定，避免 4xx 抛异常
            validateStatus: (_) => true,
          ),
        );

    try {
      final response = await dio.get('$target$healthPath');
      return isReachableStatus(response.statusCode);
    } on DioException catch (e) {
      // 服务端返回了响应说明链路通畅，仅连接层失败才算不可用
      if (e.response != null) return isReachableStatus(e.response!.statusCode);
      AppLogger.log('⚠️ 服务探测失败 $target: ${e.type}');
      return false;
    } catch (e) {
      AppLogger.log('⚠️ 服务探测异常 $target: $e');
      return false;
    } finally {
      if (client == null) dio.close(force: true);
    }
  }

  /// 优先探测主服务器，不可用时回落备用服务器；均不可用返回 null
  static Future<ServerEndpointPick?> pickAvailable({
    required String primary,
    String backup = '',
    Dio? client,
  }) async {
    final normalizedPrimary = normalizeUrl(primary);
    final normalizedBackup = normalizeUrl(backup);

    if (normalizedPrimary.isNotEmpty && await probe(normalizedPrimary, client: client)) {
      return ServerEndpointPick(url: normalizedPrimary, usingBackup: false);
    }

    if (normalizedBackup.isNotEmpty && await probe(normalizedBackup, client: client)) {
      AppLogger.log('🔀 主服务器不可用，切换到备用服务器 $normalizedBackup');
      return ServerEndpointPick(url: normalizedBackup, usingBackup: true);
    }

    return null;
  }

  /// 应用启动时调用：当前用的是备用服务器且主服务器已恢复时静默切回
  ///
  /// 返回切回后的主服务器地址，无需切换时返回 null。
  static Future<String?> restorePrimaryIfAvailable({Dio? client}) async {
    final endpoints = await load();
    if (!endpoints.usingBackup || endpoints.primary.isEmpty) return null;

    if (!await probe(endpoints.primary, client: client)) return null;

    await save(
      primary: endpoints.primary,
      backup: endpoints.backup,
      usingBackup: false,
    );
    AppLogger.log('✅ 主服务器已恢复，静默切回 ${endpoints.primary}');
    return endpoints.primary;
  }
}

/// 探测结果：选中的地址及其是否为备用服务器
class ServerEndpointPick {
  final String url;
  final bool usingBackup;

  const ServerEndpointPick({required this.url, required this.usingBackup});
}
