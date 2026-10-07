// b41e2 —— [D-016 失败外显] cast 其它投屏命令下发失败的外显补测。
//
// 沿用 batch40 D-060 在 seek 上的模式：_post 返回 null = 命令未送达服务端，
// 各命令应 清判定标记 / 不做乐观回写 / Logger.warnWithTag 外显，而非「静默成功」。
// 覆盖命令：toggle(play/pause)、next、setVolume、setPlayMode（成功路径对照）。
//
// 确定性姿势：用例**直接种 state**（activePeer + status），不走 switchTo ——
// switchTo 会启动 2s 周期轮询定时器，背景轮询与断言竞速（首轮实测即被
// pollOnce 回写 PLAYING 打翻断言）。种 state 后无任何定时器，成败路径均确定。
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

  group('[D-016 失败外显] CastPeerController 命令下发失败', () {
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
      if (path.endsWith('/status')) {
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': 1.0,
          'duration': 300.0,
        };
      }
      if (path.endsWith('/register')) {
        return <String, dynamic>{
          'peer': <String, dynamic>{'peerId': 'local-7'},
        };
      }
      if (path.endsWith('/heartbeat')) return <String, dynamic>{};
      if (path.endsWith('/local-status')) return <String, dynamic>{};
      if (path.endsWith('/reset')) return <String, dynamic>{'success': true};
      if (path.endsWith('/peers')) return <String, dynamic>{'peers': <dynamic>[]};
      if (path.endsWith('/sleep-timer')) return <String, dynamic>{'active': false};
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
      return <String, dynamic>{'success': true};
    }

    Object? route(String method, String path) {
      reqs.add(_Req(method, path));
      final h = onCall;
      if (h != null) return h(method, path);
      return defaultCall(method, path);
    }

    /// 种一个「已投屏」态（不起任何轮询定时器，断言确定性）。
    void seedCastSession() {
      ctrl.state = CastPeerState(
        activePeer: remotePeer,
        status: const PeerStatus(state: 'PLAYING', active: true),
      );
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

    test('toggle 下发失败：不做任何状态写入（含乐观翻转）、不抛', () async {
      seedCastSession();
      final stateBefore = ctrl.state;
      onCall = (method, path) {
        if (path.endsWith('/pause') || path.endsWith('/play')) {
          throw StateError('transport boom');
        }
        return defaultCall(method, path);
      };

      await ctrl.toggle();
      expect(identical(ctrl.state, stateBefore), isTrue,
          reason: '[D-016] 下发失败路径不写 state（清标记/跳过乐观翻转）');
      expect(ctrl.state.status.state, 'PLAYING',
          reason: '[D-016] 失败不得翻到 PAUSED_PLAYBACK');
      expect(reqs.any((r) => r.path.endsWith('/pause')), isTrue,
          reason: '命令确实已下发（失败发生在传输层）');
    });

    test('toggle 下发成功：乐观翻转保持（回归对照，轮询回写同值）', () async {
      seedCastSession();
      // 动态 /status：pause 命令被接收后轮询回 PAUSED_PLAYBACK —— 无论补拉
      // 轮询与断言谁先谁后，终态都是 PAUSED_PLAYBACK，无竞态。
      var pauseSeen = false;
      onCall = (method, path) {
        if (path.endsWith('/pause')) {
          pauseSeen = true;
          return <String, dynamic>{'success': true};
        }
        if (path.endsWith('/status')) {
          return <String, dynamic>{
            'state': pauseSeen ? 'PAUSED_PLAYBACK' : 'PLAYING',
            'position': 1.0,
            'duration': 300.0,
          };
        }
        return defaultCall(method, path);
      };

      await ctrl.toggle();
      expect(ctrl.state.status.state, 'PAUSED_PLAYBACK',
          reason: '成功路径乐观翻转行为不变');
    });

    test('setVolume 下发失败：不做乐观回写', () async {
      seedCastSession();
      final stateBefore = ctrl.state;
      onCall = (method, path) {
        if (path.endsWith('/volume')) throw StateError('volume boom');
        return defaultCall(method, path);
      };

      await ctrl.setVolume(88);
      expect(identical(ctrl.state, stateBefore), isTrue,
          reason: '[D-016] 下发失败时不得把音量乐观回写成 88');
      expect(ctrl.state.status.volume, isNot(88));
    });

    test('setVolume 下发成功：乐观回写保持（回归对照）', () async {
      seedCastSession();
      await ctrl.setVolume(88);
      expect(ctrl.state.status.volume, 88, reason: '成功路径乐观回写行为不变');
    });

    test('setPlayMode 下发失败：不乐观写回播放模式', () async {
      seedCastSession();
      final stateBefore = ctrl.state;
      onCall = (method, path) {
        if (path.endsWith('/play-mode')) throw StateError('play-mode boom');
        return defaultCall(method, path);
      };

      await ctrl.setPlayMode('one');
      expect(identical(ctrl.state, stateBefore), isTrue,
          reason: '[D-016] 下发失败时不得乐观写回 playMode');
      expect(ctrl.state.playMode, isNot('one'));
    });

    test('next 下发失败：不改写状态、命令已到达传输层', () async {
      seedCastSession();
      final stateBefore = ctrl.state;
      onCall = (method, path) {
        if (path.endsWith('/next')) throw StateError('next boom');
        return defaultCall(method, path);
      };

      await ctrl.next();
      expect(identical(ctrl.state, stateBefore), isTrue,
          reason: '[D-016] 失败路径不改写状态（跳过补拉 pollOnce）');
      expect(reqs.any((r) => r.path.endsWith('/next')), isTrue,
          reason: '命令确实已下发（失败发生在传输层）');
    });

    test('next 下发成功：正常补拉（回归对照）', () async {
      seedCastSession();
      onCall = (method, path) {
        if (path.endsWith('/next')) {
          return <String, dynamic>{'success': true};
        }
        return defaultCall(method, path);
      };

      await ctrl.next();
      expect(reqs.any((r) => r.path.endsWith('/next')), isTrue);
      // 成功路径会补拉 pollOnce：/status 默认回 PLAYING，此处只断言状态仍合法。
      expect(ctrl.state.status.state, 'PLAYING');
    });
  });
}
