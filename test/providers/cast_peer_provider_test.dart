import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

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
    when(
      () => client.getRaw(queuePath('dlna-1')),
    ).thenAnswer(
      (_) async => <String, dynamic>{
        'currentIndex': 0,
        'total': 1,
        'playMode': playMode,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'songId': 's1',
            'title': '测试曲',
            'artist': '歌手',
            'albumId': 'al1',
            'duration': 200,
          },
        ],
      },
    );
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
      when(() => client.getRaw(queuePath('dlna-1'))).thenAnswer(
        (_) async => <String, dynamic>{
          'currentIndex': -1,
          'total': 0,
          'playMode': 'order',
          'items': <Map<String, dynamic>>[],
        },
      );

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
      verify(() => client.getRaw(queuePath('dlna-1'))).called(1);
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
      when(() => client.getRaw(queuePath('dlna-1'))).thenAnswer(
        (_) async => <String, dynamic>{
          'currentIndex': 0,
          'total': 1,
          'playMode': 'all',
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'songId': 's1',
              'title': '测试曲',
              'artist': '歌手',
              'albumId': 'al1',
              'duration': 200,
            },
          ],
        },
      );

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
      when(() => client.getRaw(queuePath('dlna-1'))).thenAnswer(
        (_) => queueCompleter.future,
      );

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
            data: any(named: 'data')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await controller.enqueueSongs(<Song>[song]);
      verify(
        () => client.postRaw('/rest/api/v1/peers/dlna-1/queue/enqueue',
            data: any(named: 'data')),
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
}
