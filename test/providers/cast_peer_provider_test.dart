import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// 把 ProviderContainer 适配成 WidgetRef，供 `playEffectiveQueue` 这类以
/// WidgetRef 为入口的转发函数在纯容器测试里调用（不必 pump 整棵 widget 树）。
class _ContainerRef implements WidgetRef {
  _ContainerRef(this.container);

  final ProviderContainer container;

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_ContainerRef.${invocation.memberName}');
}

/// 投屏(切换播放器)控制器单元测试 —— 对齐 SPEC §3.5。
/// 用 MockSubsonicApiClient 桩掉 /rest/api/v1/peers* 网络调用,
/// 用 TestPlayerNotifier 提供本机播放器状态,不构造真实音频引擎。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  const dlnaPeer = PeerInfo(
    peerId: 'dlna-1',
    name: '客厅音箱',
    kind: 'dlna',
    available: true,
  );
  const localPeer = PeerInfo(
    peerId: 'local-1',
    name: '本机',
    kind: 'local',
    available: true,
  );
  final song = Song(
    id: 's1',
    title: '测试曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 200,
  );

  setUp(() {
    client = MockSubsonicApiClient();
    playerNotifier = TestPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => playerNotifier),
      ],
    );
    controller = container.read(castPeerControllerProvider.notifier);
  });

  tearDown(() {
    // 释放控制器:停止心跳/轮询/插值定时器,避免测试间泄漏。
    container.dispose();
  });

  String statusPath(String peerId) => '/rest/api/v1/peers/$peerId/status';
  String queuePath(String peerId) => '/rest/api/v1/peers/$peerId/queue';

  /// 后端队列快照响应体（与真实服务端同形）。
  /// `items` 传 1 条时可同时服务「轻量轮询（size=1 只回当前槽位）」与「全量拉取」。
  Map<String, dynamic> queueSnapshot({
    String playMode = 'all',
    int currentIndex = 0,
    List<Map<String, dynamic>>? items,
    List<int>? shuffleOrder,
    int? shufflePos,
  }) =>
      <String, dynamic>{
        'currentIndex': currentIndex,
        'total': items?.length ?? 1,
        'playMode': playMode,
        'shuffleOrder': shuffleOrder ?? const <int>[],
        'shufflePos': shufflePos ?? -1,
        'items': items ??
            <Map<String, dynamic>>[
              <String, dynamic>{
                'songId': 's1',
                'title': '测试曲',
                'artist': '歌手',
                'albumId': 'al1',
                'duration': 200,
              },
            ],
      };

  /// 同时桩住两种队列轮询形态（SPEC §12.1 轻量轮询改造后，常规 tick 走
  /// `?offset=N&size=1`，仅重建/结构变更时才拉全量）。mocktail 的 `any(named:)`
  /// 无法匹配「传了 queryParameters」与「没传」两种调用，必须分别登记。
  void stubQueuePoll(
    Map<String, dynamic> snapshot, {
    String peerId = 'dlna-1',
  }) {
    when(() => client.getRaw(queuePath(peerId))).thenAnswer((_) async => snapshot);
    when(
      () => client.getRaw(
        queuePath(peerId),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => snapshot);
  }

  /// 建立投屏态:本机有一首歌,后端 queue/play 成功,轮询返回稳定状态。
  Future<void> setupCasting({
    String playMode = 'all',
    String state = 'PLAYING',
    double position = 5,
  }) async {
    playerNotifier.emit(
      PlayerState(
        currentSong: song,
        queue: <Song>[song],
        currentIndex: 0,
        loopMode: LoopMode.all,
      ),
    );
    when(
      () => client.postRaw(
        '/rest/api/v1/peers/dlna-1/queue/play',
        data: any(named: 'data'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{'success': true});
    when(
      () => client.postRaw(
        '/rest/api/v1/peers/dlna-1/play-mode',
        data: any(named: 'data'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});
    when(
      () => client.getRaw(statusPath('dlna-1')),
    ).thenAnswer(
      (_) async => <String, dynamic>{
        'state': state,
        'position': position,
        'duration': 200,
        'volume': 70,
        'muted': false,
      },
    );
    stubQueuePoll(queueSnapshot(playMode: playMode));
    final ok = await controller.switchTo(dlnaPeer);
    expect(ok, isTrue);
    // 等待首轮轮询 tick 回写完成。
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  // -------------------------------------------------------------------------
  // 状态与模型
  // -------------------------------------------------------------------------

  group('CastPeerState', () {
    test('defaults to local playback', () {
      expect(controller.state.activePeer, isNull);
      expect(controller.state.isCasting, isFalse);
      expect(controller.state.targetName, '本机');
      expect(controller.state.playMode, 'all');
      expect(controller.state.offline, isFalse);
    });
  });

  group('mapLocalPlayMode', () {
    test('maps local three-state modes to backend playMode', () {
      expect(mapLocalPlayMode(PlaybackMode.shuffle), 'shuffle');
      expect(mapLocalPlayMode(PlaybackMode.repeatOne), 'one');
      expect(mapLocalPlayMode(PlaybackMode.repeatAll), 'all');
    });
  });

  group('PeerInfo', () {
    test('parses json and exposes kind/queue labels', () {
      final p = PeerInfo.fromJson(<String, dynamic>{
        'peerId': 'dlna-9',
        'name': '音箱',
        'kind': 'dlna',
        'available': true,
        'queue': <String, dynamic>{'total': 3, 'isActive': true},
      });
      expect(p.peerId, 'dlna-9');
      expect(p.isLocal, isFalse);
      expect(p.kindLabel, 'DLNA');
      expect(p.queueLabel, '3 首 · 播放中');
    });

    test('列表接口没有 total 时回落到 items.length(否则 queueTotal 恒为 0)', () {
      // 实测(2026-09-10):GET /rest/api/v1/peers 的 queue 只有 items 数组,
      // 没有 total;而单设备接口 GET /peers/:id/queue 才有 total。
      // 只认 total 会让「设备列表」来源的 queueTotal 恒为 0,
      // 连带桌面歌词设备行的 ↓ 箭头永远不亮。
      final p = PeerInfo.fromJson(<String, dynamic>{
        'peerId': 'dlna-9',
        'name': '主卧',
        'kind': 'dlna',
        'available': true,
        'queue': <String, dynamic>{
          'isActive': true,
          'items': <dynamic>[
            <String, dynamic>{'songId': 'a'},
            <String, dynamic>{'songId': 'b'},
            <String, dynamic>{'songId': 'c'},
          ],
        },
      });
      expect(p.queueTotal, 3);
      expect(p.queueActive, isTrue);
      expect(p.queueLabel, '3 首 · 播放中');
    });

    test('local and group kinds map to correct labels', () {
      expect(
        PeerInfo.fromJson(<String, dynamic>{'peerId': 'l', 'kind': 'local'})
            .isLocal,
        isTrue,
      );
      expect(
        PeerInfo.fromJson(<String, dynamic>{'peerId': 'g', 'kind': 'group'})
            .kindLabel,
        '群组',
      );
      expect(
        PeerInfo.fromJson(<String, dynamic>{'peerId': 'a', 'kind': 'airplay'})
            .kindLabel,
        'AirPlay',
      );
    });
  });

  group('PeerStatus', () {
    test('parses state and derives playing/active', () {
      final s = PeerStatus.fromJson(<String, dynamic>{
        'state': 'PLAYING',
        'position': 12,
        'duration': 180,
        'volume': 60,
        'muted': false,
      });
      expect(s.playing, isTrue);
      expect(s.active, isTrue);
      expect(s.positionSeconds, 12);
      expect(s.durationSeconds, 180);
      expect(s.copyWith(positionSeconds: 99).positionSeconds, 99);
    });

    test('paused state is active but not playing', () {
      final s = PeerStatus.fromJson(<String, dynamic>{'state': 'PAUSED_PLAYBACK'});
      expect(s.playing, isFalse);
      expect(s.active, isTrue);
    });
  });

  group('queue item mapping', () {
    test('songToQueueItem shapes backend payload', () {
      final item = songToQueueItem(song);
      expect(item['songId'], 's1');
      expect(item['title'], '测试曲');
      expect(item['artist'], '歌手');
      expect(item['albumId'], 'al1');
      expect(item['duration'], 200);
      expect(item['mime'], 'audio/mpeg');
    });

    test('castQueueItemToSong maps backend queue entries for display', () {
      final s = castQueueItemToSong(<String, dynamic>{
        'songId': 'x',
        'title': 'T',
        'artist': 'A',
        'albumId': 'al1',
        'duration': 90,
      });
      expect(s.id, 'x');
      expect(s.title, 'T');
      expect(s.artist, 'A');
      expect(s.coverArt, 'al-al1');
      expect(s.duration, 90);
    });
  });

  // -------------------------------------------------------------------------
  // 注册与保活
  // -------------------------------------------------------------------------

  group('registerAndHeartbeat', () {
    test('registers local peer and sends heartbeat', () async {
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/register',
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'peer': <String, dynamic>{'peerId': 'local-abc'},
        },
      );
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/local-abc/heartbeat',
          data: any(named: 'data'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.registerAndHeartbeat();
      // 心跳在 startHeartbeat 内立即发送一次。
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verify(
        () => client.postRaw(
          '/rest/api/v1/peers/register',
          data: any(named: 'data'),
        ),
      ).called(1);
      verify(
        () => client.postRaw(
          '/rest/api/v1/peers/local-abc/heartbeat',
          data: any(named: 'data'),
        ),
      ).called(1);
    });

    test('registration failure does not throw', () async {
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/register',
          data: any(named: 'data'),
        ),
      ).thenThrow(Exception('network down'));

      await controller.registerAndHeartbeat();
      expect(controller.state.activePeer, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 切换播放器(投屏)
  // -------------------------------------------------------------------------

  group('switchTo', () {
    test('local peer just returns to local control', () async {
      final ok = await controller.switchTo(localPeer);
      expect(ok, isTrue);
      expect(controller.state.activePeer, isNull);
    });

    test('switchTo remote is a pure UI switch without pushing queue', () async {
      // 无本机歌曲也允许纯 UI 切换(对齐前端 switchPeer):不推本地队列、不投屏。
      when(() => client.getRaw(statusPath('dlna-1'))).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'STOPPED',
          'position': 0,
          'duration': 0,
          'volume': 50,
          'muted': false,
        },
      );
      stubQueuePoll(queueSnapshot(
        playMode: 'order',
        currentIndex: -1,
        items: <Map<String, dynamic>>[],
      ));

      final ok = await controller.switchTo(dlnaPeer);
      expect(ok, isTrue);
      expect(controller.state.activePeer?.peerId, 'dlna-1');
      // 纯 UI 切换:不推队列、不发 play-mode。
      verifyNever(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/play',
            data: any(named: 'data')),
      );
      verifyNever(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/play-mode',
            data: any(named: 'data')),
      );
      // 切换即开始轮询,拉取后端状态/队列镜像。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      verify(() => client.getRaw(statusPath('dlna-1'))).called(1);
      // 后端队列为空 → 镜像为空即拉全量重建(轻量轮询无从取「当前槽位」)，
      // 二次补拉与首轮共用同一个 mock 形态，故此处只断言「至少发起了队列轮询」。
      verify(() => client.getRaw(queuePath('dlna-1'))).called(greaterThan(0));
      expect(controller.state.offline, isFalse);
    });

    test('switchTo remote mirrors backend queue and play mode via polling',
        () async {
      await setupCasting();
      expect(controller.state.activePeer?.peerId, 'dlna-1');
      // 纯 UI 切换不推队列;队列/播放模式由轮询从后端镜像。
      verifyNever(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/play',
            data: any(named: 'data')),
      );
      verifyNever(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/play-mode',
            data: any(named: 'data')),
      );
      // 轮询回写:后端权威队列/播放模式/离线标记。
      expect(controller.state.playMode, 'all');
      expect(controller.state.castIndex, 0);
      expect(controller.state.status.state, 'PLAYING');
      expect(controller.state.castQueue, isNotEmpty);
      expect(controller.state.offline, isFalse);
    });

    // ==================== 服务端权威洗牌序列（镜像，客户端不自行洗牌） ====================
    //
    // 背景：历史 bug 是「遥控器指定第 N 首，设备却播别的歌」——根因在服务端
    // `QueueController.playFrom` 于 shuffle 模式下用 `Math.random` 覆盖调用方起点，
    // 而客户端又各自维护一份洗牌序列，两侧必然不一致。
    // 拍板方案：**洗牌权威唯一在服务端**，客户端只镜像 `shuffleOrder`/`shufflePos`
    // （GET /peers/:id/queue 回传，轻量轮询外层也带），绝不自行洗牌。
    // 回退本节任一条 = 双份洗牌回归 → 必然再次出现「播的不是指定的歌」。
    group('server-authoritative shuffle order (mirror only)', () {
      test('★ mirrors backend shuffleOrder/shufflePos into state', () async {
        await setupCasting();
        stubQueuePoll(queueSnapshot(
          playMode: 'shuffle',
          currentIndex: 3,
          items: <Map<String, dynamic>>[
            <String, dynamic>{'songId': 's0', 'title': 'A'},
            <String, dynamic>{'songId': 's1', 'title': 'B'},
            <String, dynamic>{'songId': 's2', 'title': 'C'},
            <String, dynamic>{'songId': 's3', 'title': 'D'},
          ],
          shuffleOrder: <int>[3, 1, 0, 2],
          shufflePos: 0,
        ));

        await controller.pollOnce();

        expect(controller.state.playMode, 'shuffle');
        expect(controller.state.shuffleOrder, <int>[3, 1, 0, 2]);
        expect(controller.state.shufflePos, 0);
      });

      test('★ 轻量轮询（size=1）也能对齐 shuffleOrder，不依赖全量补拉', () async {
        await setupCasting();
        // 先建立 4 首全量镜像。
        stubQueuePoll(queueSnapshot(
          playMode: 'shuffle',
          currentIndex: 0,
          items: <Map<String, dynamic>>[
            <String, dynamic>{'songId': 's0', 'title': 'A'},
            <String, dynamic>{'songId': 's1', 'title': 'B'},
            <String, dynamic>{'songId': 's2', 'title': 'C'},
            <String, dynamic>{'songId': 's3', 'title': 'D'},
          ],
          shuffleOrder: <int>[0, 1, 2, 3],
          shufflePos: 0,
        ));
        await controller.pollOnce();
        expect(controller.state.shuffleOrder, <int>[0, 1, 2, 3]);

        // 服务端自行推进洗牌序列（设备侧下一首）→ 轻量 tick 必须跟上。
        stubQueuePoll(queueSnapshot(
          playMode: 'shuffle',
          currentIndex: 2,
          items: <Map<String, dynamic>>[
            <String, dynamic>{'songId': 's2', 'title': 'C'},
          ],
          shuffleOrder: <int>[2, 3, 0, 1],
          shufflePos: 1,
        ));
        await controller.pollOnce();

        expect(controller.state.shuffleOrder, <int>[2, 3, 0, 1]);
        expect(controller.state.shufflePos, 1);
      });

      test('非 shuffle 模式：空序列与 -1 位置（不需要洗牌）', () async {
        await setupCasting();
        stubQueuePoll(queueSnapshot(playMode: 'all'));
        await controller.pollOnce();

        expect(controller.state.playMode, 'all');
        expect(controller.state.shuffleOrder, isEmpty);
        expect(controller.state.shufflePos, -1);
      });

      test('服务端缺字段/类型不对：保持原值，不崩溃', () async {
        await setupCasting();
        // 老版本服务端不返回 shuffleOrder/shufflePos（滚动升级窗口）。
        stubQueuePoll(<String, dynamic>{
          'currentIndex': 0,
          'total': 1,
          'playMode': 'shuffle',
          'items': <Map<String, dynamic>>[
            <String, dynamic>{'songId': 's1', 'title': '测试曲'},
          ],
        });
        await controller.pollOnce();

        expect(controller.state.playMode, 'shuffle');
        expect(controller.state.shuffleOrder, isEmpty);
        expect(controller.state.shufflePos, -1);
      });
    });

    test('leaving local saves snapshot + pauses; backToLocal restores it',
        () async {
      playerNotifier.emit(
        PlayerState(
          currentSong: song,
          queue: <Song>[song],
          currentIndex: 0,
          isPlaying: true,
          position: const Duration(seconds: 10),
          loopMode: LoopMode.all,
        ),
      );
      when(() => client.getRaw(statusPath('dlna-1'))).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'PLAYING',
          'position': 5,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );
      stubQueuePoll(queueSnapshot());

      // 离开本机:先保存本地状态快照,再暂停本机(与远端播放互斥)。
      final ok = await controller.switchTo(dlnaPeer);
      expect(ok, isTrue);
      expect(controller.state.activePeer?.peerId, 'dlna-1');
      expect(playerNotifier.state.isPlaying, isFalse);

      // 回本机:恢复快照并可选续播(对齐 switchPeer 纯 UI 切换,远端继续播)。
      await controller.backToLocal(resumeLocal: true);
      expect(controller.state.activePeer, isNull);
      expect(playerNotifier.state.isPlaying, isTrue);
      expect(playerNotifier.state.currentSong?.id, 's1');
      expect(playerNotifier.state.queue.length, 1);
      expect(playerNotifier.state.currentIndex, 0);
    });
  });

  group('backToLocal / stopCasting', () {
    test('backToLocal only switches control target, keeps state clean', () async {
      await setupCasting();
      await controller.backToLocal();
      expect(controller.state.activePeer, isNull);
      expect(controller.state.castQueue, isEmpty);
      expect(controller.state.castIndex, -1);
      expect(controller.state.offline, isFalse);
    });

    test(
        'in-flight poll after backToLocal does not clobber restored local state',
        () async {
      // 本机正在播放 s1。
      playerNotifier.emit(
        PlayerState(
          currentSong: song,
          queue: <Song>[song],
          currentIndex: 0,
          isPlaying: true,
          position: const Duration(seconds: 10),
          loopMode: LoopMode.all,
        ),
      );
      // status 立即返回;queue 响应挂起,由 Completer 控制,模拟「回本机时仍有轮询在途」。
      when(() => client.getRaw(statusPath('dlna-1'))).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'PLAYING',
          'position': 5,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );
      final queueCompleter = Completer<dynamic>();
      when(() => client.getRaw(queuePath('dlna-1')))
          .thenAnswer((_) => queueCompleter.future);
      when(() => client.getRaw(
            queuePath('dlna-1'),
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) => queueCompleter.future);

      // 切到 DLNA:保存本地快照并暂停本机,首轮轮询发出(status 已回,queue 仍在途)。
      final ok = await controller.switchTo(dlnaPeer);
      expect(ok, isTrue);
      expect(playerNotifier.state.isPlaying, isFalse);

      // 回本机:恢复本地快照(s1)并续播。
      await controller.backToLocal(resumeLocal: true);
      expect(controller.state.activePeer, isNull);
      expect(playerNotifier.state.currentSong?.id, 's1');
      expect(playerNotifier.state.isPlaying, isTrue);

      // 此刻仍在途的 queue 响应才返回:不得再镜像覆盖刚恢复的本地播放状态。
      queueCompleter.complete(<String, dynamic>{
        'currentIndex': 0,
        'total': 1,
        'playMode': 'all',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'songId': 'remote-x',
            'title': '后端曲',
            'artist': '歌手B',
            'albumId': 'al2',
            'duration': 300,
          },
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 本地播放状态保持 s1,不被后端队列覆盖。
      expect(playerNotifier.state.currentSong?.id, 's1');
      expect(playerNotifier.state.queue.length, 1);
    });

    test('stopCasting notifies backend stop and deactivate', () async {
      await setupCasting();
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/stop',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/deactivate',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.stopCasting();
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/stop',
            data: any(named: 'data')),
      ).called(1);
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/deactivate',
            data: any(named: 'data')),
      ).called(1);
      expect(controller.state.activePeer, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 传输控制
  // -------------------------------------------------------------------------

  group('transport control', () {
    test('toggle without cast routes to local player', () async {
      await controller.toggle();
      expect(playerNotifier.toggleCount, 1);
    });

    test('toggle when casting optimistically flips button state', () async {
      await setupCasting();
      expect(controller.state.status.playing, isTrue);
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/pause',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});
      // 轮询回写与暂停一致(position 不再前进),避免异步回写覆盖乐观置位。
      when(
        () => client.getRaw(statusPath('dlna-1')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'PAUSED_PLAYBACK',
          'position': 5,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );

      await controller.toggle();
      // 乐观置位(对齐前端 castTogglePlay):点击后按钮立即翻转,不依赖轮询结果。
      expect(controller.state.status.state, 'PAUSED_PLAYBACK');
      expect(controller.state.status.playing, isFalse);

      // 再点一次恢复播放。
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/play',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});
      when(
        () => client.getRaw(statusPath('dlna-1')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'PLAYING',
          'position': 6,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );
      await controller.toggle();
      expect(controller.state.status.state, 'PLAYING');
      expect(controller.state.status.playing, isTrue);
    });

    test('seek when casting posts seek and aligns smooth position', () async {
      await setupCasting(position: 5);
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/seek',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});
      // 轮询回写会取 status.position;让回写值与 seek 目标一致,保证确定性。
      when(
        () => client.getRaw(statusPath('dlna-1')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'PLAYING',
          'position': 30,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );

      await controller.seek(const Duration(seconds: 30));
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/seek',
            data: <String, dynamic>{'seconds': 30}),
      ).called(1);
      expect(controller.state.smoothPositionSeconds, 30);
    });

    test('setMuted posts mute and updates status', () async {
      await setupCasting();
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/mute',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});
      // 轮询回写 muted 为 false 会覆盖;让回写值与本次一致。
      when(
        () => client.getRaw(statusPath('dlna-1')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'PLAYING',
          'position': 5,
          'duration': 200,
          'volume': 70,
          'muted': true,
        },
      );

      await controller.setMuted(true);
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/mute',
            data: <String, dynamic>{'muted': true}),
      ).called(1);
      expect(controller.state.status.muted, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // 播放模式同步
  // -------------------------------------------------------------------------

  group('play mode sync', () {
    test('cyclePlayMode cycles order→one→all→shuffle', () async {
      await setupCasting(playMode: 'order');
      expect(controller.state.playMode, 'order');
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/play-mode',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});
      // 轮询回写会用队列快照覆盖 playMode;让后续 tick 失败,避免干扰切换序列。
      when(() => client.getRaw(statusPath('dlna-1')))
          .thenThrow(Exception('ignore tick'));
      when(() => client.getRaw(queuePath('dlna-1')))
          .thenThrow(Exception('ignore tick'));
      when(() => client.getRaw(
            queuePath('dlna-1'),
            queryParameters: any(named: 'queryParameters'),
          )).thenThrow(Exception('ignore tick'));

      await controller.cyclePlayMode(); // order → one
      expect(controller.state.playMode, 'one');
      await controller.cyclePlayMode(); // one → all
      expect(controller.state.playMode, 'all');
      await controller.cyclePlayMode(); // all → shuffle
      expect(controller.state.playMode, 'shuffle');
      await controller.cyclePlayMode(); // shuffle → order
      expect(controller.state.playMode, 'order');
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/play-mode',
            data: <String, dynamic>{'mode': 'shuffle'}),
      ).called(1);
    });
  });

  // -------------------------------------------------------------------------
  // 投屏队列操作
  // -------------------------------------------------------------------------

  group('cast queue operations', () {
    test('enqueueSongs posts queue/enqueue', () async {
      await setupCasting();
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/enqueue',
            data: any(named: 'data'),
            receiveTimeout: any(named: 'receiveTimeout')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.enqueueSongs(<Song>[song]);
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/enqueue',
            data: any(named: 'data'),
            receiveTimeout: any(named: 'receiveTimeout')),
      ).called(1);
    });

    test('jumpTo posts queue/jump', () async {
      await setupCasting();
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/jump',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.jumpTo(1);
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/jump',
            data: <String, dynamic>{'index': 1}),
      ).called(1);
    });

    test('removeQueueItem issues DELETE queue/:index', () async {
      await setupCasting();
      when(
        () => client.deleteRaw(
          '/rest/api/v1/peers/dlna-1/queue/2',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.removeQueueItem(2);
      verify(
        () => client.deleteRaw(
          '/rest/api/v1/peers/dlna-1/queue/2',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });

    test('reorderQueue posts queue/reorder', () async {
      await setupCasting();
      when(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/reorder',
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.reorderQueue(0, 2);
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/reorder',
            data: <String, dynamic>{'from': 0, 'to': 2}),
      ).called(1);
    });
  });

  // -------------------------------------------------------------------------
  // 离线与平滑进度
  // -------------------------------------------------------------------------

  group('offline handling', () {
    test('repeated poll failures mark the peer offline', () async {
      await setupCasting();
      when(() => client.getRaw(statusPath('dlna-1')))
          .thenThrow(Exception('device offline'));
      when(() => client.getRaw(queuePath('dlna-1')))
          .thenThrow(Exception('device offline'));
      when(() => client.getRaw(
            queuePath('dlna-1'),
            queryParameters: any(named: 'queryParameters'),
          )).thenThrow(Exception('device offline'));

      await controller.pollOnce();
      await controller.pollOnce();
      await controller.pollOnce();

      expect(controller.state.offline, isTrue);
      expect(controller.state.status.state, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 播放状态自愈(对齐前端 startCastPoll)
  // -------------------------------------------------------------------------

  group('playback state self-healing', () {
    test('advancing position heals stale STOPPED state to PLAYING', () async {
      await setupCasting();
      // GENA 事件缓存了 state=STOPPED,但 position 仍在前进(10 > 5)且 < duration,
      // 以「position 真实前进」为在播权威证据,强制 playing=true。
      when(
        () => client.getRaw(statusPath('dlna-1')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'STOPPED',
          'position': 10,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );

      await controller.pollOnce();
      expect(controller.state.status.state, 'PLAYING');
      expect(controller.state.status.playing, isTrue);
    });

    test('stale STOPPED without advancing position is not healed', () async {
      await setupCasting();
      // position 未前进(仍为 5)时,不误判为在播。
      when(
        () => client.getRaw(statusPath('dlna-1')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'state': 'STOPPED',
          'position': 5,
          'duration': 200,
          'volume': 70,
          'muted': false,
        },
      );

      await controller.pollOnce();
      expect(controller.state.status.state, 'STOPPED');
      expect(controller.state.status.playing, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 轻量轮询守卫（SPEC §12.1 根治，勿回退）
  // 队列权威在后端，但**不必每 2s 拉整队**：`GET /peers/:id/queue` 支持
  // `offset`/`size`，且 total/currentIndex/playMode/currentMedia 全在外层。
  // 实测 100 首：全量 26 061B → `size=1` 546B（≈48×）；5000 首量级 2MB → <1KB。
  // 回退成「每次拉全量」会让手机在投屏且大队列时持续烧流量/CPU。
  // -------------------------------------------------------------------------

  group('轻量队列轮询（SPEC §12.1）', () {
    test('常规 tick 只取当前槽位一条，不拉整队', () async {
      await setupCasting();
      // setupCasting 内的 switchTo 首轮镜像为空 → 必然全量拉一次(合理)。
      // 断言只覆盖 pollOnce() 之后的调用，故清掉此前交互。
      clearInteractions(client);

      await controller.pollOnce();

      // 必须按「本地镜像长度」定位当前槽位并只要 1 条 —— 绝不整队拉取。
      verify(
        () => client.getRaw(
          queuePath('dlna-1'),
          queryParameters: <String, String>{'offset': '1', 'size': '1'},
        ),
      ).called(greaterThan(0));
      verifyNever(() => client.getRaw(queuePath('dlna-1')));
    });

    test('服务端 total 变化时补拉全量重建镜像', () async {
      await setupCasting();
      // 服务端队列变成 3 首（本地镜像仍 1 首）→ 轻量路径抓不到，必须补拉全量。
      stubQueuePoll(<String, dynamic>{
        'currentIndex': 1,
        'total': 3,
        'playMode': 'all',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's1', 'title': '一', 'duration': 200},
          <String, dynamic>{'songId': 's2', 'title': '二', 'duration': 200},
          <String, dynamic>{'songId': 's3', 'title': '三', 'duration': 200},
        ],
      });

      await controller.pollOnce();

      expect(controller.state.castQueue.length, 3);
      expect(controller.state.castIndex, 1);
    });

    test('本地改队列结构后强制全量（pollOnce(fullQueue: true)）', () async {
      await setupCasting();

      await controller.pollOnce(fullQueue: true);

      // 强制全量走「不带 queryParameters」的形态。
      verify(() => client.getRaw(queuePath('dlna-1'))).called(greaterThan(0));
    });

    test('轻量路径用服务端权威 currentIndex 定位，不按旧扇区覆盖', () async {
      await setupCasting();
      // 本地镜像 1 首（s1）；服务端游标跳到 1，槽位取回 s2。
      stubQueuePoll(<String, dynamic>{
        'currentIndex': 1,
        'total': 2,
        'playMode': 'all',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'songId': 's2',
            'title': '第二首',
            'artist': '歌手',
            'duration': 200,
          },
        ],
      });
      // total 2 ≠ 镜像 1 → 会补拉全量，这里让全量也回 2 首，验证游标正确。
      stubQueuePoll(<String, dynamic>{
        'currentIndex': 1,
        'total': 2,
        'playMode': 'all',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's1', 'title': '一', 'duration': 200},
          <String, dynamic>{'songId': 's2', 'title': '二', 'duration': 200},
        ],
      });

      await controller.pollOnce();

      expect(controller.state.castIndex, 1);
      expect(controller.state.castQueue.length, 2);
    });
  });

  // -------------------------------------------------------------------------
  // 大队列传输超时守卫（回归防护）
  // 安卓弱网下 800+ 首必然推流失败的根因是固定 8s 超时 + Dio 全局 30s 硬顶。
  // 这里锁死「超时随规模缩放」且「预算必须同时下发给 Dio」两条约束。
  // -------------------------------------------------------------------------

  group('cast queue transfer timeout budget', () {
    test('budget scales with item count and is capped', () {
      expect(
        queueTransferBudget(0),
        const Duration(seconds: 10),
      );
      // 800 首:10s + 24s = 34s(过去固定 8s/30s 必挂)。
      expect(
        queueTransferBudget(800),
        const Duration(milliseconds: 34000),
      );
      // 5000 首:10s + 150s = 160s,未触顶。
      expect(
        queueTransferBudget(5000),
        const Duration(milliseconds: 160000),
      );
      // 触顶 180s,避免无限等待。
      expect(
        queueTransferBudget(20000),
        const Duration(milliseconds: 180000),
      );
      // 单调不减。
      expect(
        queueTransferBudget(5000).inMilliseconds,
        greaterThan(queueTransferBudget(800).inMilliseconds),
      );
    });

    test('queue/play passes the scaled budget down to dio', () async {
      await setupCasting();
      Duration? seen;
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((invocation) {
        seen = invocation.namedArguments[#receiveTimeout] as Duration?;
        return Future<dynamic>.value(<String, dynamic>{'success': true});
      });

      final songs = List<Song>.generate(
        5000,
        (i) => Song(id: 's$i', title: 't$i', duration: 100),
      );
      final ok = await controller.playQueueOnPeer(songs, startIndex: 0);

      expect(ok, isTrue);
      // 关键:预算必须落到 dio,否则全局 receiveTimeout 30s 会先砍断,
      // 外层 Future.timeout 再大也是摆设。
      expect(seen, queueTransferBudget(5000));
      expect(seen!.inSeconds, greaterThan(30));
    });
  });

  // -------------------------------------------------------------------------
  // 服务端内容点播（投屏主通道）
  // 根因回顾：投屏态下客户端是遥控器，点歌单却把「本地拉来的整队」原样推回
  // 服务端(queue/play)，5000 首歌单 = 拉 25 页 + 推 2MB。正确链路是只传
  // 「内容类型 + ID + 起始索引」，由服务端 resolveContentSongs 自行查库解析。
  // 这里锁死「内容点播通道绝不携带歌曲列表」这一核心契约。
  // -------------------------------------------------------------------------

  group('cast content play (服务端内容点播主通道)', () {
    test('posts /v1/play with content id only, never the song list', () async {
      await setupCasting();
      Map<String, dynamic>? body;
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((inv) async {
        body = inv.namedArguments[#data] as Map<String, dynamic>;
        return <String, dynamic>{'success': true};
      });

      final ok = await controller.playContentOnPeer(
        type: 'playlist',
        id: 'pl-1',
        startIndex: 42,
      );

      expect(ok, isTrue);
      expect(body, isNotNull);
      expect(body!['peerId'], 'dlna-1');
      expect(body!['type'], 'playlist');
      expect(body!['id'], 'pl-1');
      expect(body!['startIndex'], 42);
      // 核心契约：内容点播通道绝不携带歌曲列表（大队列推流失败的根因）。
      expect(body!.containsKey('items'), isFalse);
    });

    // songId 定位：起点是**身份**而非行号。服务端在解析出的队列里 findIndex，
    // 与两侧排序是否同源无关 → 从根上消除「静默播错歌」，客户端因此不再需要
    // 投后拉队列比对槽位的补丁（补丁本身会把失败退化成推 2MB 整队）。
    test('songId is sent as the start locator (identity, not row index)', () async {
      await setupCasting();
      Map<String, dynamic>? body;
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((inv) async {
        body = inv.namedArguments[#data] as Map<String, dynamic>;
        return <String, dynamic>{'success': true};
      });

      final ok = await controller.playContentOnPeer(
        type: 'playlist',
        id: 'pl-1',
        songId: 's42',
      );

      expect(ok, isTrue);
      expect(body!['songId'], 's42');
      // 传了 songId 就不该再传行号：两者语义不同，混传会让服务端误按行号取。
      expect(body!.containsKey('startIndex'), isFalse);
    });

    test('no slot verification round-trip: never GETs a single queue slot', () async {
      await setupCasting();
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});

      final ok = await controller.playContentOnPeer(
        type: 'playlist',
        id: 'pl-1',
        songId: 's42',
        localItems: <Map<String, dynamic>>[songToQueueItem(song)],
        localStartIndex: 0,
      );

      expect(ok, isTrue);
      // songId 定位后不再需要「投后拉服务端队列的某一槽位比对 songId」这一额外往返。
      // 注意：常规轮询 pollOnce() 仍会拉队列回写镜像，属正常行为——这里只锁死
      // 「不再有带 offset/size 的**槽位探测**」。
      //
      // 不能直接用 mocktail 的 verifyNever + 具名 matcher：verifyNever 进入校验模式后
      // 不再匹配已登记的桩，任何真实调用（含 queryParameters 为 null 的全量轮询）都会被
      // 报成 Unexpected call，断言必然假失败。故直接检查调用记录。
      final slotProbes = verify(
        () => client.getRaw(
          queuePath('dlna-1'),
          queryParameters: captureAny(named: 'queryParameters'),
        ),
      ).captured.whereType<Map>().where((q) => q.containsKey('offset')).toList();
      expect(
        slotProbes,
        isEmpty,
        reason: '不应再有带 offset 的槽位探测往返（补丁已随 songId 定位移除）',
      );
    });

    test('rejects when server refuses so caller can fall back', () async {
      await setupCasting();
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': false});

      expect(
        await controller.playContentOnPeer(type: 'playlist', id: 'pl-1'),
        isFalse,
      );
    });

    test('no active peer means no request at all', () async {
      expect(
        await controller.playContentOnPeer(type: 'playlist', id: 'pl-1'),
        isFalse,
      );
      // 无活跃 peer 时提前返回，连请求都不该发出。注意 postRaw 现在恒带
      // receiveTimeout 具名参数，matcher 必须一并放行，否则 verify 不匹配。
      verifyNever(
        () => client.postRaw(
          any(),
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      );
    });

    // 本地队列镜像按 songId 对齐游标：服务端按身份定位，本地高亮必须跟随同一
    // 身份，否则两边各按行号算会让界面指向与设备实际播放不同的曲目。
    test('local mirror aligns cursor by songId, not by row index', () async {
      await setupCasting();
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});

      // 本地列表顺序与服务端不同源：目标歌在本地第 2 位，但服务端会按身份找到它。
      final ok = await controller.playContentOnPeer(
        type: 'playlist',
        id: 'pl-1',
        songId: 's2',
        localItems: <Map<String, dynamic>>[
          songToQueueItem(song),
          songToQueueItem(Song(id: 's2', title: '第二首', duration: 200)),
        ],
        localStartIndex: 0,
      );

      expect(ok, isTrue);
      // 游标应指向 songId == 's2' 的那一行（下标 1），而不是传入的 localStartIndex 0。
      // 这里在轮询回写之前断言：pollOnce 是 unawaited 的异步收尾，会把服务端权威
      // 游标再覆盖回来，故只锁定「本地乐观镜像按身份对齐」这一契约。
      expect(controller.state.castIndex, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 主通道 → 兜底通道 回落
  // 主通道只是「快路径」，任何不可用（服务端拒绝/内容已删/旧版 404/槽位错位）
  // 都必须落到整队推送，否则用户点了歌什么都没发生。
  // -------------------------------------------------------------------------
  group('主通道 → 兜底通道 回落', () {
    test('主通道返回 false 时必须调用 queue/play', () async {
      await setupCasting();
      // 兜底通道的超时预算随队列规模下发（§12.2），桩必须放行 receiveTimeout。
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': false});

      final ok = await playEffectiveQueue(
        _ContainerRef(container),
        <Song>[song],
        origin: const QueueOrigin(QueueOriginKind.playlist, 'pl-1'),
      );

      expect(ok, isTrue, reason: '兜底通道成功即视为播放成功');
      verify(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).called(1);
    });

    test('服务端无从解析的来源（discover）直接走整队推送', () async {
      await setupCasting();
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});

      final ok = await playEffectiveQueue(
        _ContainerRef(container),
        <Song>[song],
        origin: const QueueOrigin(QueueOriginKind.discover),
      );

      expect(ok, isTrue);
      // 服务端无从解析 → 不该走主通道 /v1/play（那条路径服务端会 404）。
      verifyNever(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      );
      verify(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).called(1);
    });
  });

  // -------------------------------------------------------------------------
  // 接续搬移（本机 → 设备）也必须主通道优先
  //
  // 根因回顾（2026-09-10 真机复现）：搬移此前**只**做整队推送。公网遥控入口
  // 被迫整队推送，payload 随规模线性膨胀（3251 首实测 642KB/8.4s 公网），
  // 起播成功率变成客户端上行带宽的函数。
  // 局域网 :46400 同一请求仅 199ms 成功，证明问题在公网入口而非后端。
  // 主通道载荷几百字节，天然不受该闸门限制 → 搬移必须先试主通道。
  // -------------------------------------------------------------------------
  group('接续搬移主通道优先', () {
    /// 本机放着一个「源自歌单」的多曲队列，并登记来源。
    void setupLocalPlaylistQueue(String playlistId, List<Song> queue, int index) {
      playerNotifier.emit(
        PlayerState(
          currentSong: queue[index],
          queue: queue,
          currentIndex: index,
          loopMode: LoopMode.all,
        ),
      );
      container.read(queueOriginProvider.notifier).state =
          QueueOrigin(QueueOriginKind.playlist, playlistId);
    }

    List<Song> bigQueue(int n) => <Song>[
          for (var i = 0; i < n; i++)
            Song(id: 's$i', title: '曲目 $i', duration: 200),
        ];

    test('源自歌单的本机队列：只传 contentId + songId，不推整队', () async {
      await setupCasting();
      final queue = bigQueue(300);
      setupLocalPlaylistQueue('pl-big', queue, 7);

      Map<String, dynamic>? contentBody;
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((inv) async {
        contentBody = inv.namedArguments[#data] as Map<String, dynamic>;
        return <String, dynamic>{'success': true};
      });

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue);
      expect(contentBody, isNotNull, reason: '搬移必须走主通道');
      expect(contentBody!['type'], 'playlist');
      expect(contentBody!['id'], 'pl-big');
      // 起点是**身份**：本机第 7 首 → songId=s7（与两侧排序无关）。
      expect(contentBody!['songId'], 's7');
      // 核心契约：整队**绝不能**进请求体（否则 payload 随规模膨胀到 MB 级）。
      expect(contentBody!.containsKey('items'), isFalse);
      // 主通道成功即不该再走整队推送。
      verifyNever(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      );
    });

    test('来源服务端无从解析（discover）时回落整队推送', () async {
      await setupCasting();
      final queue = bigQueue(3);
      playerNotifier.emit(
        PlayerState(
          currentSong: queue[0],
          queue: queue,
          currentIndex: 0,
          loopMode: LoopMode.all,
        ),
      );
      container.read(queueOriginProvider.notifier).state =
          const QueueOrigin(QueueOriginKind.discover);
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue);
      // discover 是首页随机拼装，服务端 resolveContentSongs 无从重建 → 不能走主通道。
      verifyNever(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      );
      verify(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).called(1);
    });

    test('主通道失败（内容已删/旧版服务端）时回落整队推送', () async {
      await setupCasting();
      final queue = bigQueue(3);
      setupLocalPlaylistQueue('pl-gone', queue, 0);
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': false});
      when(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue, reason: '兜底通道成功即视为搬移成功');
      verify(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).called(1);
    });

    // -----------------------------------------------------------------------
    // 重启 App 后的搬移（会话恢复路径）
    //
    // 这是 ray 真机 16:03/16:06 两份失败日志的实际场景：App 重启后队列由
    // playback_session_v1 恢复，若来源没跟着落盘，pushLocalToPeer 就会误判
    // 「来源不可解析」而整队推送 → 大歌单照撞 403。
    // 本测试模拟「恢复出来的 PlayerState + 恢复出来的 QueueOrigin」这一现场，
    // 锁死它必须走主通道。
    // -----------------------------------------------------------------------
    test('重启 App 后（会话恢复现场）的大歌单搬移仍走主通道', () async {
      await setupCasting();
      // 模拟 _restorePlaybackSession 的产物：队列来自会话、来源来自同一会话。
      final queue = bigQueue(842);
      playerNotifier.emit(
        PlayerState(
          currentSong: queue[0],
          queue: queue,
          currentIndex: 0,
          loopMode: LoopMode.all,
        ),
      );
      // 恢复路径回填的来源（等价于 QueueOrigin.fromJson(session['queueOrigin'])）。
      container.read(queueOriginProvider.notifier).state =
          QueueOrigin.fromJson(<String, dynamic>{
        'kind': 'playlist',
        'id': 'pl-restored',
      });

      Map<String, dynamic>? contentBody;
      when(
        () => client.postRaw(
          '/rest/api/v1/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((inv) async {
        contentBody = inv.namedArguments[#data] as Map<String, dynamic>;
        return <String, dynamic>{'success': true};
      });

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue);
      expect(contentBody, isNotNull, reason: '恢复现场也必须走主通道');
      expect(contentBody!['type'], 'playlist');
      expect(contentBody!['id'], 'pl-restored');
      expect(contentBody!['songId'], 's0');
      // 842 首 ≈ 248KB，绝不能进请求体。
      expect(contentBody!.containsKey('items'), isFalse);
      verifyNever(
        () => client.postRaw(
          '/rest/api/v1/peers/dlna-1/queue/play',
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      );
    });
  });

  group('QueueOrigin server content type', () {
    test('maps server-resolvable kinds, rejects local-only ones', () {
      expect(
        const QueueOrigin(QueueOriginKind.playlist, 'p1').serverContentType,
        'playlist',
      );
      expect(
        const QueueOrigin(QueueOriginKind.album, 'a1').serverContentType,
        'album',
      );
      expect(
        const QueueOrigin(QueueOriginKind.artist, 'ar1').serverContentType,
        'artist',
      );
      // 首页随机/搜索/其它是客户端本地拼装队列，服务端无从解析 → 必须兜底。
      expect(
        const QueueOrigin(QueueOriginKind.discover).serverContentType,
        isNull,
      );
      expect(
        const QueueOrigin(QueueOriginKind.search, 'q').serverContentType,
        isNull,
      );
      expect(
        const QueueOrigin(QueueOriginKind.other, 'x').serverContentType,
        isNull,
      );
      // 有 kind 但缺 id 同样不可解析。
      expect(
        const QueueOrigin(QueueOriginKind.playlist).serverContentType,
        isNull,
      );
      expect(
        const QueueOrigin(QueueOriginKind.playlist, '').serverContentType,
        isNull,
      );
    });
  });
}
