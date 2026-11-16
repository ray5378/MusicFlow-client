// b54a —— 「首次真实连通 → 服务端快照重恢复」的 persister 行为钉子。
//
// 背景：启动恢复跑在连接建立之前，快照请求多半拉不到 → 回退本地；连接建立
// 之后没有任何人重跑恢复，播放控制区因此常常最后上屏甚至一直空。本文件钉死
// PlaybackSessionPersister.restoreServerSnapshotAfterReconnect（b54a 新增）的
// 行为契约：
//   A1 无本地会话 → 服务端快照直接采用（播放控制上屏的主路径）；
//   A2 服务端不比基线新 → 不动（沿用 updatedAt 竞速，防「本地新、服务端旧」反杀）；
//   A3 会话级 once：连续调用只补拉一次；
//   A4 初次恢复在途 → 绝不并发第二次恢复，初次恢复自己经连接闸拿到快照；
//   A5 代际守卫：恢复后本机被清空/销毁 → 整段作废（销毁是终结语义）；
//   A6 用户已自行改动队列 → 不覆盖用户操作；
//   A7 服务端快照与当前队列同内容 → no-op（不重启当曲）；
//   A8 有本地会话 + 服务端更新 → 采用服务端队列/索引/播放模式；
//   A9 初次恢复已采用服务端（基线=服务端 updatedAt）→ 重恢复不再重复采用。
//
// 存储环境沿袭 b51a：JsonFileStore 必须每用例注入独立临时目录。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/player/playback_payload.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/player/player_session_persister.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

/// 窄接口假宿主（与 b51a 同款，另加索引/抓取次数观察点）。
class _FakeHost implements PlaybackSessionPersisterHost {
  _FakeHost();

  @override
  PlayerState state = PlayerState();

  // ignore: annotate_overrides
  bool mounted = true;

  final PlaybackPayloadEncoder encoder = PlaybackPayloadEncoder();
  @override
  PlaybackPayloadEncoder get payloadEncoder => encoder;

  @override
  QueueOrigin? queueOrigin;

  int fetchCalls = 0;
  Map<String, dynamic>? Function() onFetchServer = () => null;

  /// 可选挂起闸：非 null 时快照请求在此 await（A4 用它把初次恢复挂在
  /// 「快照在飞」窗口内；比改 onFetchServer 签名更省事）。
  Completer<void>? fetchGate;

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async {
    fetchCalls += 1;
    final gate = fetchGate;
    if (gate != null) await gate.future;
    return onFetchServer();
  }

  int syncQueueCalls = 0;
  @override
  Future<void> syncLocalQueueNow() async => syncQueueCalls++;

  final List<String> playCalls = <String>[];
  final List<int> playIndexes = <int>[];
  final List<Duration?> playInitialPositions = <Duration?>[];
  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool autoPlay = true,
    Duration? initialPosition,
  }) async {
    playCalls.add(song.id);
    playIndexes.add(index ?? -1);
    playInitialPositions.add(initialPosition);
  }

  final List<PlaybackMode> modeCalls = <PlaybackMode>[];
  @override
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true}) async {
    modeCalls.add(mode);
  }
}

Song song([String id = 's1']) => Song(
      id: id,
      title: '测试曲$id',
      artist: '歌手',
      albumId: 'al1',
      duration: 200,
    );

PlayerState stateWith({List<Song>? queue, int index = 0}) => PlayerState(
      queue: queue ?? <Song>[song()],
      currentIndex: index,
      currentSong: (queue ?? <Song>[song()]).isNotEmpty
          ? (queue ?? <Song>[song()])[index]
          : null,
      position: const Duration(seconds: 3),
      duration: const Duration(seconds: 200),
      volume: 0.4,
      playbackMode: PlaybackMode.all,
    );

/// 本地会话 payload（与磁盘上「上一次退出留下的旧会话」同一形状）。
Map<String, dynamic> localSession(
  PlaybackPayloadEncoder encoder, {
  required String songId,
  required int nowMs,
}) =>
    encoder.buildSession(
      queue: <Song>[song(songId)],
      currentIndex: 0,
      currentSongId: songId,
      position: const Duration(seconds: 7),
      duration: const Duration(seconds: 200),
      isPlaying: false,
      nowMs: nowMs,
      queueOrigin: null,
    )!;

/// 服务端快照（items/currentIndex/playMode/updatedAt，与后端同形状）。
Map<String, dynamic> serverSnap({
  required List<String> ids,
  required int updatedAt,
  int currentIndex = 0,
  String playMode = 'all',
}) => <String, dynamic>{
      'items': <dynamic>[
        for (final id in ids)
          <String, dynamic>{
            'songId': id,
            'title': 'srv$id',
            'artist': '歌手',
            'albumId': 'al1',
            'duration': 180,
          },
      ],
      'currentIndex': currentIndex,
      'playMode': playMode,
      'updatedAt': updatedAt,
    };

void main() {
  Directory? dir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('b54a_reconnect_restore');
    JsonFileStore.instance.debugDirectory = dir;
  });

  tearDown(() async {
    JsonFileStore.instance.debugDirectory = null;
    try {
      dir?.deleteSync(recursive: true);
    } catch (_) {}
    dir = null;
  });

  group('b54a 首次连通重恢复', () {
    test('A1 无本地会话 → 服务端快照直接采用', () async {
      final host = _FakeHost();
      final persister = PlaybackSessionPersister(host);
      // 冷启动未连通：初次恢复的快照请求拉不到（null）。
      host.onFetchServer = () => null;

      await persister.restorePlaybackSession();
      expect(host.playCalls, isEmpty, reason: '冷启动无本地会话、快照拉不到时不动');

      // 首次连通：补拉到服务端快照。
      host.onFetchServer = () => serverSnap(
            ids: <String>['srv-1', 'srv-2'],
            updatedAt: 500,
            currentIndex: 1,
          );
      await persister.restoreServerSnapshotAfterReconnect();

      expect(host.playCalls, <String>['srv-2'], reason: '服务端快照按 currentIndex 起播');
      expect(host.playIndexes.last, 1);
      expect(host.modeCalls, <PlaybackMode>[PlaybackMode.all]);
      expect(host.queueOrigin, isNull, reason: '服务端快照无来源 → null');
    });

    test('A2 服务端不比基线新 → 不动（沿用 updatedAt 竞速）', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', nowMs: 1000),
      );
      host.onFetchServer = () => serverSnap(ids: <String>['srv-1'], updatedAt: 500);

      await persister.restorePlaybackSession();
      expect(host.playCalls, <String>['x']);

      await persister.restoreServerSnapshotAfterReconnect();

      expect(host.playCalls, <String>['x'], reason: '服务端更旧，不得反杀本地');
      expect(host.fetchCalls, 2, reason: '初次恢复 + 补拉比对，各发生一次');
      expect(host.modeCalls, isEmpty);
    });

    test('A3 会话级 once：连续调用只补拉一次', () async {
      final host = _FakeHost();
      final persister = PlaybackSessionPersister(host);
      host.onFetchServer = () => null;
      await persister.restorePlaybackSession();

      host.onFetchServer = () => serverSnap(ids: <String>['srv-1'], updatedAt: 500);
      await persister.restoreServerSnapshotAfterReconnect();
      expect(host.fetchCalls, 2, reason: '初次恢复 1 次 + 补拉 1 次');
      expect(host.playCalls, <String>['srv-1']);

      await persister.restoreServerSnapshotAfterReconnect();
      expect(host.fetchCalls, 2, reason: 'once 标志：第二次调用不再补拉');
      expect(host.playCalls, <String>['srv-1']);
      expect(persister.debugReconnectRestoreCalls, 2, reason: '入口被调两次，第二次被 once 拦下');
    });

    test('A4 初次恢复在途 → 不并发；初次恢复自己拿到快照', () async {
      final host = _FakeHost();
      final persister = PlaybackSessionPersister(host);
      // 把初次恢复的快照请求挂在半空：此刻 isRestoringPlaybackSession == true。
      final gate = Completer<void>();
      host.fetchGate = gate;
      host.onFetchServer = () =>
          serverSnap(ids: <String>['srv-1'], updatedAt: 500);

      final restoreFuture = persister.restorePlaybackSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(persister.isRestoringPlaybackSession, isTrue);

      final callsBefore = host.fetchCalls;
      await persister.restoreServerSnapshotAfterReconnect();
      expect(host.fetchCalls, callsBefore, reason: '初次恢复在途时绝不并发第二次快照请求');

      gate.complete();
      await restoreFuture;
      expect(host.playCalls, <String>['srv-1'], reason: '初次恢复自己经连接闸拿到快照并采用');

      // once 已在跳过时消费：此后再触发也不补拉。
      await persister.restoreServerSnapshotAfterReconnect();
      expect(host.fetchCalls, callsBefore, reason: 'once 已消费，不再发第二次快照请求');
    });

    test('A5 代际守卫：恢复后本机被清空/销毁 → 整段作废', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', nowMs: 1000),
      );
      await persister.restorePlaybackSession();
      expect(host.playCalls, <String>['x']);

      persister.bumpSessionGeneration();
      host.onFetchServer = () => serverSnap(ids: <String>['srv-1'], updatedAt: 2000);

      await persister.restoreServerSnapshotAfterReconnect();

      expect(host.playCalls, <String>['x'], reason: '销毁是终结语义，重恢复无权复活');
    });

    test('A6 用户已自行改动队列 → 不覆盖用户操作', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', nowMs: 1000),
      );
      await persister.restorePlaybackSession();

      // 用户在恢复后点了另一首（内存队列 ≠ 恢复队列）。
      host.state = stateWith(queue: <Song>[song('y')]);
      host.onFetchServer = () => serverSnap(ids: <String>['srv-1'], updatedAt: 2000);

      await persister.restoreServerSnapshotAfterReconnect();

      expect(host.playCalls, <String>['x'], reason: '重恢复无权覆盖用户的主动选择');
    });

    test('A7 服务端快照与当前队列同内容 → no-op 不重启当曲', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', nowMs: 1000),
      );
      await persister.restorePlaybackSession();
      expect(host.playCalls, <String>['x']);

      host.onFetchServer = () => serverSnap(ids: <String>['x'], updatedAt: 2000);
      await persister.restoreServerSnapshotAfterReconnect();

      expect(host.playCalls, <String>['x'], reason: '同内容重启当曲纯属打扰');
    });

    test('A8 有本地会话 + 服务端更新 → 采用服务端队列/索引/播放模式', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', nowMs: 1000),
      );
      await persister.restorePlaybackSession();
      expect(host.playCalls, <String>['x']);

      host.onFetchServer = () => serverSnap(
            ids: <String>['srv-1', 'srv-2'],
            updatedAt: 2000,
            currentIndex: 1,
            playMode: 'shuffle',
          );
      await persister.restoreServerSnapshotAfterReconnect();

      expect(host.playCalls, <String>['x', 'srv-2']);
      expect(host.playIndexes.last, 1);
      expect(host.modeCalls, <PlaybackMode>[PlaybackMode.shuffle]);
      expect(host.queueOrigin, isNull);
    });

    test('A9 初次恢复已采用服务端 → 重恢复不重复采用', () async {
      final host = _FakeHost();
      final persister = PlaybackSessionPersister(host);
      host.onFetchServer = () => serverSnap(ids: <String>['srv-1'], updatedAt: 500);

      await persister.restorePlaybackSession();
      expect(host.playCalls, <String>['srv-1'], reason: '连通早的冷启动：初次恢复直接采用服务端');

      await persister.restoreServerSnapshotAfterReconnect();
      expect(host.playCalls, <String>['srv-1'], reason: '基线已是服务端 updatedAt，不再重复起播');
      expect(host.fetchCalls, 2, reason: '补拉比对发生（竞速判同），但不动状态');
    });
  });
}
