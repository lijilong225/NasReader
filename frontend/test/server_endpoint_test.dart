import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';

void main() {
  test('normalizeUrl 复用 profile 的归一化规则', () {
    expect(ServerEndpointService.normalizeUrl(' http://nas:6088// '), 'http://nas:6088');
  });

  test('isReachableStatus 把 4xx 也视为服务可达', () {
    expect(ServerEndpointService.isReachableStatus(200), isTrue);
    expect(ServerEndpointService.isReachableStatus(404), isTrue);
    expect(ServerEndpointService.isReachableStatus(500), isFalse);
    expect(ServerEndpointService.isReachableStatus(null), isFalse);
  });

  test('active 在无备用地址时始终回落主地址', () {
    const withoutBackup = ServerEndpoints(
      primary: 'http://nas:6088',
      usingBackup: true,
    );
    expect(withoutBackup.hasBackup, isFalse);
    expect(withoutBackup.active, 'http://nas:6088');
  });

  test('active 在标记使用备用且备用存在时返回备用地址', () {
    const withBackup = ServerEndpoints(
      primary: 'http://nas:6088',
      backup: 'http://backup:6088',
      usingBackup: true,
    );
    expect(withBackup.active, 'http://backup:6088');

    const primaryActive = ServerEndpoints(
      primary: 'http://nas:6088',
      backup: 'http://backup:6088',
    );
    expect(primaryActive.active, 'http://nas:6088');
  });

  test('probe 对空地址直接返回不可用，不发起请求', () async {
    expect(await ServerEndpointService.probe('   '), isFalse);
  });

  test('pickAvailable 在主备均为空时返回 null', () async {
    expect(await ServerEndpointService.pickAvailable(primary: ''), isNull);
  });
}
