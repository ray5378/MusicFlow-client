// b38b2 —— `lib/providers/cast/cast_peer_provider.dart` 剩余缺口补测。
//
// 已存在 cast_peer_provider_test / cast_peer_cov / cast_peer_reset / b35b /
// b37b2 等大量用例，本文件只补它们没吃到的分支：
//   * `_ensurePeerIdReady`：真正被等待方调用（此前从未进入）；
//   * `_syncLocalQueue`：未注册时补注册；增量路径只补发 play-mode + 游标；
//   * `_maybeAutoSelectPlayingTarget`：同类候选按名称序排序、恢复落定等待、
//     以及等满 10s 放弃；
//   * `_readPeerRealtimePlaying` / `_pushQueueAndPlay` / `removeQueueItem` /
//     `_abandonLocalSession` 的失败分支；
//   * `_schedulePoll` 周期回写、`pollOnce` 超时置离线、seek 屏蔽 10s 解除。
//
// 产品代码零改动；仅新增 test/。

import 'dart:async';

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

class _GapPlayer extends TestPlayerNotifier {
  _GapPlayer(super.state);

  /// 可控的「本机会话恢复中」标记（`_autoSelectFirstPlaying` 的等待条件）。
  bool restoring = false;

  /// 置 true 时 `clearQueue` 抛错，用于验证 `_abandonLocalSession` 的吞错分支。
  bool clearThrows = false;

  @override
  bool get isRestoringPlaybackSession => restoring;

  @override
  Future<void> clearQueue({bool keepCurrent = true}) async {
    if (clearThrows) throw StateError('clearQueue boom');
    await super.clearQueue(keepCurrent: keepCurrent);
  }
}

class _Req {
  _Req(this.method, this.path);

  final String method;
  final String path;

  @override
  String toString() => '$method $path';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient client;
  late _GapPlayer player;
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

  final song = Song(
    id: 's1',
    title: '测试曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 200,
  );
  final song2 = Song(
    id: 's2',
    title: '测试曲2',
    artist: '歌手',
    albumId: 'al1',
    duration: 180,
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
    if (path.endsWith('/queue')) {
      return <String, dynamic>{
        'items': <Map<String, dynamic>>[songToQueueItem(song)],
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

  /// 两个「队列已激活、非自身」的同类别候选（名称序 Z 在 A 之后）。
  Map<String, dynamic> twoDlnaPeers() => <String, dynamic>{
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{
            'peerId': 'dlna-z',
            'name': 'Z 音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{'isActive': true, 'total': 3},
          },
          <String, dynamic>{
            'peerId': 'dlna-a',
            'name': 'A 音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{'isActive': true, 'total': 3},
          },
        ],
      };

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    reqs = <_Req>[];
    onCall = null;
    client = MockSubsonicApiClient();
    player = _GapPlayer(PlayerState());
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

  int countRegister() =>
      reqs.where((r) => r.path.endsWith('/register')).length;

  test('未注册时等待 peerId：新建注册信号并等满 1.5s 预算后放弃', () async {
    onCall = (method, path) {
      if (path.endsWith('/register')) {
        // 服务端不返回 peerId → 注册信号永远不落地。
        return <String, dynamic>{
          'peer': <String, dynamic>{'peerId': ''},
        };
      }
      return defaultCall(method, path);
    };

    final sw = Stopwatch()..start();
    expect(await ctrl.waitForLocalPeerIdForTest(), isNull);
    expect(
      sw.elapsedMilliseconds,
      greaterThanOrEqualTo(1000),
      reason: '注册未落地时应挂到 Completer 上等满 kPeerIdWaitBudget，而非立即返回',
    );
  });

  test('本机队列防抖上报：尚未注册 → 先补注册再镜像', () async {
    onCall = (method, path) {
      if (path.endsWith('/register')) {
        return <String, dynamic>{
          'peer': <String, dynamic>{'peerId': ''},
        };
      }
      return defaultCall(method, path);
    };

    await ctrl.registerAndHeartbeat();
    expect(countRegister(), 1);

    player.emit(PlayerState(
      queue: <Song>[song],
      currentIndex: 0,
      currentSong: song,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(
      countRegister(),
      2,
      reason: '防抖定时器落地时本机仍未注册 → _syncLocalQueue 应先补注册',
    );
  });

  test('增量同步：队列未变、仅播放模式变化 → 补发 play-mode 再推游标', () async {
    await ctrl.registerAndHeartbeat();
    expect(ctrl.localPeerId, 'local-7');

    final queue = <Song>[song, song2];
    player.emit(PlayerState(
      queue: queue,
      currentIndex: 0,
      currentSong: song,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(
      reqs.any((r) => r.path.endsWith('/queue/play')),
      isTrue,
      reason: '首次为整队替换',
    );

    reqs.clear();
    // 同一个 queue 实例 → queueChanged 为 false，走增量分支。
    player.emit(PlayerState(
      queue: queue,
      currentIndex: 0,
      currentSong: song,
      playbackMode: PlaybackMode.shuffle,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(
      reqs.any((r) => r.path.endsWith('/play-mode')),
      isTrue,
      reason: '模式与上一次推送不同 → 补发 play-mode',
    );
    expect(
      reqs.any((r) => r.path.endsWith('/queue/index')),
      isTrue,
      reason: '增量分支总是再推一次游标',
    );
    expect(
      reqs.any((r) => r.path.endsWith('/queue/play')),
      isFalse,
      reason: '队列没变就不该整队重推',
    );
  });

  test('启动自动选目标：同类候选按名称序取首个在播端，并等本机恢复落定', () async {
    player.restoring = true;
    onCall = (method, path) {
      if (path.endsWith('/peers')) return twoDlnaPeers();
      return defaultCall(method, path);
    };

    await ctrl.loadPeers();
    // 让 _autoSelectFirstPlaying 先进入「等本机会话恢复落定」的轮询。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(ctrl.state.activePeer, isNull, reason: '恢复未落定时不切目标');

    player.restoring = false;
    // 轮询到切换落地为止（CI 满载时 200ms 一拍的循环可能比预期慢）。
    for (var i = 0; i < 40 && ctrl.state.activePeer == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(
      ctrl.state.activePeer?.peerId,
      'dlna-a',
      reason: '同类别（peerKindRank 相同）→ 按名称序取 A 音箱',
    );
  });

  test(
    '启动自动选目标：本机会话恢复迟迟不落定 → 等满 10s 放弃，保守保持本机',
    () async {
      player.restoring = true;
      onCall = (method, path) {
        if (path.endsWith('/peers')) return twoDlnaPeers();
        return defaultCall(method, path);
      };

      await ctrl.loadPeers();
      await Future<void>.delayed(const Duration(seconds: 11));

      expect(
        ctrl.state.activePeer,
        isNull,
        reason: '超过 10s 恢复仍未落定 → 放弃本轮自动接管，保持控制本机',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('自动选目标：读候选端实时状态失败 → 整轮放弃，不切目标', () async {
    onCall = (method, path) {
      if (path.endsWith('/peers')) return twoDlnaPeers();
      if (path.endsWith('/status')) throw StateError('status boom');
      return defaultCall(method, path);
    };

    final peers = await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(peers.length, 2, reason: '列表本身拉取成功');
    expect(
      ctrl.state.activePeer,
      isNull,
      reason: '实时在播判定读不到 → 不能假定候选在播，保守不切',
    );
  });

  test('destroyPeer(本机)：清内存队列抛错被吞，服务端重置照走', () async {
    player.clearThrows = true;
    await ctrl.registerAndHeartbeat();

    const selfPeer = PeerInfo(
      peerId: 'local-7',
      name: '本机',
      kind: 'local',
      available: true,
      self: true,
    );
    await ctrl.destroyPeer(selfPeer);

    expect(
      reqs.any((r) => r.path.endsWith('/reset')),
      isTrue,
      reason: '本机内存会话清理失败不应阻断服务端彻底重置',
    );
    expect(player.clearCount, 0, reason: 'clearQueue 抛错，未走到真实清理计数');
  });

  test('playQueueOnPeer：整队推送失败 → 返回 false 且不抛', () async {
    await ctrl.switchTo(remotePeer);
    onCall = (method, path) {
      if (path.endsWith('/queue/play')) throw StateError('push boom');
      return defaultCall(method, path);
    };

    expect(await ctrl.playQueueOnPeer(<Song>[song]), isFalse);
  });

  test('_pushQueueAndPlay：queue/play 成功但 play-mode 同步失败 → 仍算成功', () async {
    await ctrl.switchTo(remotePeer);
    onCall = (method, path) {
      if (path.endsWith('/play-mode')) throw StateError('mode boom');
      return defaultCall(method, path);
    };

    expect(await ctrl.playQueueOnPeer(<Song>[song]), isTrue);
    expect(
      ctrl.state.status.state,
      'PLAYING',
      reason: '模式同步是收尾动作，失败不应把整队推送判为失败',
    );
  });

  test('removeQueueItem：删除请求失败被吞，不抛给调用方', () async {
    await ctrl.switchTo(remotePeer);
    onCall = (method, path) {
      if (method == 'delete') throw StateError('delete boom');
      return defaultCall(method, path);
    };

    await ctrl.removeQueueItem(0);
    expect(
      reqs.any((r) => r.method == 'delete' && r.path.endsWith('/queue/0')),
      isTrue,
    );
  });

  test('轮询链：2s 周期到点续接下一轮（目标未切换）', () async {
    await ctrl.switchTo(remotePeer);
    await Future<void>.delayed(const Duration(milliseconds: 2400));

    final statusCalls =
        reqs.where((r) => r.path.endsWith('/status')).length;
    expect(
      statusCalls,
      greaterThanOrEqualTo(2),
      reason: '首拍 + 至少一个周期回写，轮询链不能断',
    );
  });

  test('轮询超时：连续三次 TimeoutException → 目标置离线', () async {
    await ctrl.switchTo(remotePeer);
    onCall = (method, path) {
      if (path.endsWith('/status')) {
        throw TimeoutException('poll timeout', const Duration(seconds: 6));
      }
      return defaultCall(method, path);
    };

    await ctrl.pollOnce();
    await ctrl.pollOnce();
    await ctrl.pollOnce();

    expect(ctrl.state.offline, isTrue, reason: '连续三次轮询失败 → 标记离线');
  });

  test(
    'seek 后 10s 仍未落位：解除屏蔽，恢复采纳真实上报位置',
    () async {
      onCall = (method, path) {
        if (path.endsWith('/status')) {
          // 设备停在 PAUSED、位置约 0.5s —— 正是「重锚瞬态 0」的形态。
          return <String, dynamic>{
            'state': 'PAUSED_PLAYBACK',
            'position': 0.5,
            'duration': 300.0,
          };
        }
        return defaultCall(method, path);
      };

      await ctrl.switchTo(remotePeer);
      // 先让首拍把 castIndex 落定（首拍 idx 与 castIndex 不等会清 seek 标记）。
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      await ctrl.seek(const Duration(seconds: 100));
      expect(
        ctrl.state.smoothPositionSeconds,
        100.0,
        reason: 'seek 成功后进度条乐观对齐到目标位置',
      );

      // 10s 屏蔽窗口过后才会解除：轮询到「进度不再被乐观值钉住」为止，
      // 上限 25s（CI 满载时 2s 一拍的轮询会整体后移，固定等待会 flaky）。
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline) &&
          ctrl.state.smoothPositionSeconds > 10.0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      expect(
        ctrl.state.smoothPositionSeconds,
        lessThan(10.0),
        reason: '10s 仍未落位 → 不再屏蔽上报，进度回到设备真实位置（~0.5s）',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
