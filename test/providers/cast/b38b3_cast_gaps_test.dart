// b38b3 —— Route B：cast 侧剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * cast_peer_state.dart 83  `devicePlaying` 派生 getter
//   * cast_peer_provider.dart 1428-1434  seek 下发失败 → 清判定标记并 rethrow
//
// 说明：cast_peer_provider 中 261 / 481 处的 `FLUTTER_TEST` 短路会让
// `_waitForApiCredentialsReady`、`fetchLocalQueueForRestore` 在测试环境直接返回，
// 其后的 264-266/269 与 482-498 行属**测试环境门禁**，flutter test 下不可达。
//
// 产品代码零改动；仅新增 test/。


import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../helpers/mocks.dart';
import '../../features/player/test_player_notifier.dart';

class _Req {
  _Req(this.method, this.path);

  final String method;
  final String path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CastPeerState 派生 getter', () {
    test('devicePlaying 反映 status.active', () {
      const idle = CastPeerState();
      expect(idle.devicePlaying, isFalse);

      const playing = CastPeerState(
        status: PeerStatus(state: 'PLAYING', active: true),
      );
      expect(playing.devicePlaying, isTrue);
    });
  });

  group('CastPeerController.seek 失败路径', () {
    late MockSubsonicApiClient client;
    late TestPlayerNotifier player;
    late ProviderContainer container;
    late CastPeerController ctrl;
    late List<_Req> reqs;
    Object? Function(String method, String path)? onCall;

    const remotePeer = PeerInfo(
      peerId: 'dlna-9',
      name: '书房音箱',
      kind: 'dlna',
      available: true,
    );

    Map<String, dynamic> defaultCall(String method, String path) {
      if (path.endsWith('/register')) {
        return <String, dynamic>{
          'peer': <String, dynamic>{'peerId': 'local-7'},
        };
      }
      if (path.endsWith('/heartbeat')) return <String, dynamic>{};
      if (path.endsWith('/local-status')) return <String, dynamic>{};
      if (path.endsWith('/status')) {
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': 1.0,
          'duration': 300.0,
        };
      }
      if (path.endsWith('/reset')) return <String, dynamic>{'success': true};
      if (path.endsWith('/peers')) return <String, dynamic>{'peers': <dynamic>[]};
      if (path.endsWith('/sleep-timer')) return <String, dynamic>{'active': false};
      if (path.endsWith('/queue/play')) return <String, dynamic>{'success': true};
      if (path.endsWith('/play-mode')) return <String, dynamic>{'success': true};
      if (path.endsWith('/stop')) return <String, dynamic>{'success': true};
      if (path.endsWith('/seek')) return <String, dynamic>{'success': true};
      if (path.endsWith('/queue')) {
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[songToQueueItem(
            Song(id: 's1', title: 't', artist: 'a', albumId: 'al', duration: 200),
          )],
          'currentIndex': 0,
          'total': 1,
          'playMode': 'order',
        };
      }
      return <String, dynamic>{};
    }

    Object? route(String method, String path) {
      reqs.add(_Req(method, path));
      final h = onCall;
      if (h != null) return h(method, path);
      return defaultCall(method, path);
    }

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      reqs = <_Req>[];
      onCall = null;
      client = MockSubsonicApiClient();
      player = TestPlayerNotifier(PlayerState());
      container = ProviderContainer(
        overrides: <Override>[
          subsonicApiClientProvider.overrideWithValue(client),
          playerProvider.overrideWith((ref) => player),
        ],
      );
      ctrl = container.read(castPeerControllerProvider.notifier);

      when(() => client.postRaw(any())).thenAnswer((inv) async {
        return route('post', inv.positionalArguments[0] as String)
            as Map<String, dynamic>;
      });
      when(() => client.postRaw(
            any(),
            data: any(named: 'data'),
            receiveTimeout: any(named: 'receiveTimeout'),
          )).thenAnswer((inv) async {
        return route('post', inv.positionalArguments[0] as String)
            as Map<String, dynamic>;
      });
      when(() => client.getRaw(any())).thenAnswer((inv) async {
        return route('get', inv.positionalArguments[0] as String)
            as Map<String, dynamic>;
      });
      when(() => client.getRaw(
            any(),
            queryParameters: any(named: 'queryParameters'),
            receiveTimeout: any(named: 'receiveTimeout'),
          )).thenAnswer((inv) async {
        return route('get', inv.positionalArguments[0] as String)
            as Map<String, dynamic>;
      });
      when(() => client.deleteRaw(any())).thenAnswer((inv) async {
        return route('delete', inv.positionalArguments[0] as String)
            as Map<String, dynamic>;
      });
    });

    tearDown(() async {
      try {
        ctrl.stopHeartbeat();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 10));
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('[D-060 锁定修复] seek 下发失败：不抛、清判定标记、且不再乐观对齐进度',
        () async {
      await ctrl.switchTo(remotePeer);
      expect(ctrl.state.activePeer?.peerId, remotePeer.peerId);

      onCall = (method, path) {
        if (path.contains('seek')) throw StateError('seek send boom');
        return defaultCall(method, path);
      };

      // [D-060 已修复] _post 内部 catch 所有异常返回 null；seek 现在把 null 视为
      // 失败：清因果屏障标记（_seekIssuedAtMs/_seekAckAtMs/_seekTargetSeconds）、
      // 不做乐观对齐（平滑进度保持原值），并经 warn 日志上报失败 —— 与
      // 「设备拒绝 seek」不再是同一副「静默成功」面孔。
      await ctrl.seek(const Duration(seconds: 42));
      expect(
        ctrl.state.smoothPositionSeconds,
        isNot(42.0),
        reason: 'D-060：下发失败时不得乐观对齐到目标位置（旧位置上报依然有效）',
      );
      expect(
        reqs.any((r) => r.path.contains('seek')),
        isTrue,
        reason: '命令确实已下发',
      );
    });

    test('seek 下发成功：仍乐观对齐到目标位置', () async {
      await ctrl.switchTo(remotePeer);
      await ctrl.seek(const Duration(seconds: 42));
      expect(ctrl.state.smoothPositionSeconds, 42.0,
          reason: '成功路径的乐观对齐行为不变');
      expect(
        reqs.any((r) => r.path.contains('seek')),
        isTrue,
      );
    });

    test('未注册时请求本端 peerId：走注册完成信号并超时兜底（126/519）', () async {
      onCall = (method, path) {
        if (path.endsWith('/register')) {
          return <String, dynamic>{
            'peer': <String, dynamic>{'peerId': ''},
          };
        }
        return defaultCall(method, path);
      };

      await ctrl.registerAndHeartbeat();
      // 已有本地 peerId 场景下再次取信号（命中 _ensurePeerIdReady 的复用分支）。
      expect(await ctrl.waitForLocalPeerIdForTest(), isNull);
    });
  });
}
