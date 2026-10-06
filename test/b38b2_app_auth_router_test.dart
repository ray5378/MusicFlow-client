// b38b2 —— `lib/app.dart` 中 `routerProvider` 的认证状态监听分支补测。
//
// b34b / b37b2 测的是 App widget 本身（缩放、主题、redirect），它们都把
// `routerProvider` 换成了桩路由 —— 于是 provider 体内那条 `ref.listen<AuthState>`
// 从未真正跑过：登录成功 → 注册本机 peer + 起心跳；登出 → 停心跳 + 回本机；
// 以及「认证翻转 / 初始化完成」时的路由跳转。
//
// 这里用真实 `routerProvider` + 可操控的 `authStateProvider`，把这两条翻转都
// 驱动一遍。断言落在**可观测副作用**上：登录翻转会向服务端注册本机 peer，
// 登出翻转会读回本机（activePeer 清空）。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import 'helpers/mocks.dart';
import 'features/player/test_player_notifier.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockLibraryRepository extends Mock implements LibraryRepository {}

/// 只借用 AuthNotifier 的状态机；`_init()` 会因 mock 未打桩直接走进 catch，
/// 落地为「未认证、初始化完成」，正好是这条监听分支的起点。
class _TestAuthNotifier extends AuthNotifier {
  _TestAuthNotifier() : super(_MockAuthRepository(), _MockLibraryRepository());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient client;
  late TestPlayerNotifier player;
  late _TestAuthNotifier auth;
  late ProviderContainer container;
  late List<String> paths;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    paths = <String>[];
    client = MockSubsonicApiClient();
    player = TestPlayerNotifier(PlayerState());
    auth = _TestAuthNotifier();
    container = ProviderContainer(
      overrides: <Override>[
        authStateProvider.overrideWith((ref) => auth),
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => player),
      ],
    );

    Object? route(String path) {
      paths.add(path);
      if (path.endsWith('/register')) {
        return <String, dynamic>{
          'peer': <String, dynamic>{'peerId': 'local-7'},
        };
      }
      if (path.endsWith('/status')) {
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': 1.0,
          'duration': 300.0,
        };
      }
      if (path.endsWith('/queue/play')) {
        return <String, dynamic>{'success': true};
      }
      if (path.endsWith('/queue')) {
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[],
          'currentIndex': 0,
          'total': 0,
        };
      }
      return <String, dynamic>{};
    }

    when(() => client.postRaw(any())).thenAnswer(
        (inv) async => route(inv.positionalArguments[0] as String));
    when(() => client.postRaw(
          any(),
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        )).thenAnswer(
        (inv) async => route(inv.positionalArguments[0] as String));
    when(() => client.getRaw(any())).thenAnswer(
        (inv) async => route(inv.positionalArguments[0] as String));
    when(() => client.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
          receiveTimeout: any(named: 'receiveTimeout'),
        )).thenAnswer(
        (inv) async => route(inv.positionalArguments[0] as String));
    when(() => client.deleteRaw(any())).thenAnswer(
        (inv) async => route(inv.positionalArguments[0] as String));
  });

  tearDown(() {
    container.dispose();
  });

  test('认证翻转驱动 routerProvider 的监听分支：登录→注册 peer，登出→回本机',
      () async {
    // 建立 provider（内部 ref.listen 生效）。
    container.read(routerProvider);

    // 登录成功：未认证 → 已认证。
    auth.state = AuthState(isAuthenticated: true, isInitializing: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      paths.any((p) => p.endsWith('/rest/api/v1/peers/register')),
      isTrue,
      reason: '登录成功后应注册本机 peer 并起心跳',
    );
    expect(
      container.read(castPeerControllerProvider.notifier).localPeerId,
      'local-7',
    );

    // 登出：已认证 → 未认证。
    paths.clear();
    auth.state = AuthState(isAuthenticated: false, isInitializing: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      container.read(castPeerControllerProvider).activePeer,
      isNull,
      reason: '登出后控制目标应回到本机',
    );
  });
}
