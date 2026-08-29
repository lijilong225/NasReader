// lib/services/server_failover_service.dart
import '../config/api_config.dart';
import '../core/network_client.dart';
import 'app_logger.dart';
import 'server_endpoint_service.dart';

/// 在启动与从后台恢复时校验服务器可用性，必要时在主/备之间自动切换
class ServerFailoverService {
  /// 同一次恢复可能触发多个页面回调，用锁避免并发探测
  static Future<ServerEndpointPick?>? _running;

  /// 两次探测的最小间隔，避免频繁切前后台时反复请求
  static const Duration minInterval = Duration(seconds: 10);
  static DateTime? _lastCheckedAt;

  /// 探测并应用可用地址；发生切换时返回选中的地址，否则返回 null
  static Future<ServerEndpointPick?> ensureAvailable({bool force = false}) {
    if (_running != null) return _running!;

    final last = _lastCheckedAt;
    if (!force && last != null && DateTime.now().difference(last) < minInterval) {
      return Future.value(null);
    }

    final task = _ensureAvailable();
    _running = task;
    return task.whenComplete(() {
      _running = null;
      _lastCheckedAt = DateTime.now();
    });
  }

  static Future<ServerEndpointPick?> _ensureAvailable() async {
    if (!ApiConfig.isLoggedIn) return null;

    try {
      final pick = await ServerEndpointService.ensureActiveEndpoint(
        currentUrl: ApiConfig.baseUrl,
      );
      if (pick == null) return null;

      await ApiConfig.setBaseUrl(pick.url);
      NetworkClient.updateBaseUrl(pick.url);
      return pick;
    } catch (e) {
      AppLogger.log('⚠️ 服务器可用性校验失败: $e');
      return null;
    }
  }
}
