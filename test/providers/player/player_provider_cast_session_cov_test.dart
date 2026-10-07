// batch22：lib/providers/player/player_provider.dart 的**投屏段**与**会话恢复段**。
//
// 为什么挑这两段（开工前在 230 上按 lcov 复核过）：
//   * 投屏段（`syncQueueForCast` / `restoreStateForCast` / `resolveCastNeighborIndex`
//     / `updateNotificationCastProgress`）：`player_provider.dart` 当前 530/1047
//     = 50.62%，是全项目 TOP1 缺口；这一段是「设备选择 → 建立会话 → 进度/状态
//     镜像回本机」的唯一落点，投屏时 UI 全靠它喂数据，而它只有星散几条断言。
//   * 会话恢复段：`player_provider.dart` 的 part `player_playback_session.dart`
//     （persist / restore / 断点续播）148 行里 49 行未覆盖（99/148 = 66.89%），
//     且「恢复下标怎么算」「服务端快照怎么跟本地文件竞速」这两块**一行都没打过**。
//
// 姿势沿用 batch19 的仿真台（真 `_PlayerNotifierImpl` + 依赖全 override），本批
// 再加两件东西：① `JsonFileStore.instance.debugDirectory` 隔离会话落盘目录
// （同 session_teardown_test）；② 把 `castPeerControllerProvider` 换成可编排的
// 子类替身 —— 真实 `fetchLocalQueueForRestore()` 在 `FLUTTER_TEST` 下**直接短路
// 返回 null**（源码里有 `if (Platform.environment['FLUTTER_TEST'] != null) return null;`），
// 服务端快照那条竞速分支生产能跑、单测永远打不到，只能换替身。
//
// 踩坑索引（本批新增，承接 batch19 的 #59~#72）：
// #73 真实 `CastPeerController.fetchLocalQueueForRestore()` 在测试环境恒返回 null
//     （`Platform.environment['FLUTTER_TEST']` 短路），服务端快照竞速分支（含
//     `useServer` / `playMode` 恢复 / `queueItemToSong` 转换）**必须**用
//     `castPeerControllerProvider.overrideWith((ref) => 子类替身)` 才打得到。
//     `CastPeerController` 是可继承的普通 StateNotifier（构造只有 `: super(const
//     CastPeerState())`，无副作用体），子类化安全；构造函数形参是私有的 `_ref`，
//     跨库只能用**位置参数** `super(ref)`，写 `super._ref` 编译不过。
// #74 `playerProvider` 主体对 `starredProvider` 是 `ref.listen(..., fireImmediately: true)`
//     + `cacheAuthoritativeStarred(next.valueOrNull)`。不 override 时第一次回调把缓存
//     刷成 null，随后异步结果再刷一次 —— 所以「投屏红心 enrichment」用例**必须**
//     用 `starredProvider.overrideWithValue(...)` 把权威列表钉死；想测「无权威列表」
//     那半边就 override 成 `AsyncValue.loading()`（valueOrNull 恒 null，且不会再被
//     后来的异步结果顶掉）。这是本批唯一能稳定命中 2131 与 2153 两条互斥分支的办法。
// #75 会话恢复跑在 `_init()` 的尾巴上，容器刚建好那一瞬 `debugIsRestoringPlaybackSession`
//     仍是 false（恢复还没起步）。判「恢复已结束」只能用「连续 quiet 时长内都没有
//     再进入恢复」，不能只看一次快照（同 session_teardown_test._quiet）。
// #76 恢复尾巴的 `playSong(...)` 是 fire-and-forget，且**没有地址时不会推进下标**
//     （走不到 `player.play()` 失败 → `_handlePlaybackError` → `next()` 那条链）。
//     所以断言「恢复到第几首」必须配「不 override activeAddressProvider」，否则
//     currentIndex 会被跳过链路顶走，用例随机红。
// #77 `_persistOnce` 里 `debugBeforePersistWrite` 挂在 `payload == null` 的早退**之后**
//     （payload 为空直接 `clearPlaybackSession` + return）。想用这个钩子把一轮写卡住，
//     前提是 state 里得有非空队列，否则钩子根本不会被调用、写瞬间就返回了。
// #78 落盘租约 15s（源码常量 `_persistLease`）是**真实墙钟**比较，fakeAsync 快进不了
//     （写入走真 IO）。要打「租约过期强制放行」只能真等 16s+；单条用例记得显式
//     放宽 timeout，别撞 flutter_test 默认 30s。
// #79 jsonDecode 出来的对象恒为 `Map<String, dynamic>`，所以 `_parsePlaybackSessionQueue`
//     里 `item is Map`（非 String 键）那条防御分支**从磁盘路径永远进不去**（见「剩余
//     缺口」）；能打到的只有 `Song.fromJson` 抛异常那个 catch。
//     该分支已于 2026-10-07 作为死代码删除（batch41 E2）。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

// ───────────────────────── 素材 ─────────────────────────

Song _song(String id, {bool starred = false, int duration = 200}) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'flac',
      bitRate: 1411,
      duration: duration,
      starred: starred,
    );

/// 后端投屏队列条目（`castQueueItemToSong` 只认 songId/title/artist/album/albumId/
/// duration/coverArt，**不带 starred** —— 红心只能靠 state 继承或权威列表校正）。
Map<String, dynamic> _castItem(String id, {int duration = 200}) =>
    <String, dynamic>{
      'songId': id,
      'title': '投屏曲$id',
      'artist': '歌手',
      'album': '专辑',
      'albumId': 'al1',
      'duration': duration,
    };

/// 服务端本机队列快照条目（`queueItemToSong` 认 songId/title/mime/...）。
Map<String, dynamic> _serverItem(String id, {int duration = 200}) =>
    <String, dynamic>{
      'songId': id,
      'title': '服务端曲$id',
      'artist': '歌手',
      'albumId': 'al1',
      'mime': 'audio/flac',
      'duration': duration,
    };

/// 磁盘上的一份播放会话（形状对齐 `_payloadEncoder.buildSession`）。
Map<String, dynamic> _session({
  required List<Map<String, dynamic>> queue,
  Object? currentIndex = 0,
  Object? currentSongId = '',
  Object? positionMs = 0,
  Object? updatedAt = 1700000000000,
  bool isPlaying = false,
  Map<String, dynamic>? queueOrigin,
}) =>
    <String, dynamic>{
      'version': 1,
      'queue': queue,
      'currentIndex': currentIndex,
      'currentSongId': currentSongId,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
      'updatedAt': updatedAt,
      if (queueOrigin != null) 'queueOrigin': queueOrigin,
    };

List<String> _ids(Iterable<Song> songs) =>
    songs.map((s) => s.id).toList(growable: false);

// ───────────────────────── 替身 ─────────────────────────

/// 可编排的 CastPeerController 替身（踩坑 #73）。
///
/// 只改两个与会话恢复直接相关的入口，其余一律沿用真实现 —— 避免把「应该怎样」
/// 写进替身。构造用位置参数 `super(ref)`（基类形参 `_ref` 是库私有名）。
class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(Ref ref) : super(ref);

  /// `fetchLocalQueueForRestore()` 的返回值；null 表示「拉不到快照」。
  Map<String, dynamic>? snapshot;

  /// 非空则 `fetchLocalQueueForRestore()` 抛它（钉「拉取失败不许卡死恢复」）。
  Object? snapshotError;

  /// `syncLocalQueueNow()` 是否抛（钉「回推失败被吞」）。
  bool mirrorThrows = false;

  int fetchCalls = 0;
  int mirrorCalls = 0;

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async {
    fetchCalls++;
    final err = snapshotError;
    if (err != null) throw err;
    return snapshot;
  }

  @override
  Future<void> syncLocalQueueNow() async {
    mirrorCalls++;
    if (mirrorThrows) throw StateError('mirror-failed-for-test');
  }
}

// ───────────────────────── 承载器 ─────────────────────────

class _Harness {
  _Harness._(this.dir, this.container, this.notifier, this.cast);

  final Directory dir;
  final ProviderContainer container;
  final PlayerNotifier notifier;
  final _FakeCastPeerController cast;

  /// 用例自己已经 dispose 过容器时置位（teardown 不再二次 dispose）。
  bool disposed = false;

  File get sessionFile =>
      File('${dir.path}${Platform.pathSeparator}playback_session_v1.json');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 平台隔离：伪装 linux，让 `_init()` 走「桌面 = 不起 AudioService」分支
    // （android 分支的 AudioService.init 会抛出脱离 try/catch 的异步异常）。
    // 同 session_teardown_test 的姿势。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 踩坑 #59（batch19）：`_init()` 早期要 path_provider，测试里没装插件，
    // MissingPluginException 会穿透构造函数。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '/tmp/path-provider-fake',
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  MusicLibrary _library() => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: 'MusicFlow',
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  /// 等真 notifier 安静下来（踩坑 #75）：连续 [hold] 时长内都没有再进入恢复。
  Future<void> quiet(
    PlayerNotifier n, {
    Duration hold = const Duration(milliseconds: 400),
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    var quietSince = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      if (n.debugIsRestoringPlaybackSession) {
        quietSince = DateTime.now();
      } else if (DateTime.now().difference(quietSince) >= hold) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('PlayerNotifier 在预算内没有安静下来（构造期恢复疑似挂住）');
  }

  /// 起一个「存储目录隔离 + 依赖全 override + 确定性拆卸」的真 notifier。
  ///
  /// [session] 在容器构造**之前**铺到盘上，构造期的会话恢复才看得见它。
  Future<_Harness> boot({
    String prefix = 'mf_b22_',
    Map<String, dynamic>? session,
    Map<String, dynamic>? serverSnapshot,
    Object? serverSnapshotError,
    bool mirrorThrows = false,
    StarredResult? starred,
  }) async {
    final dir = Directory.systemTemp.createTempSync(prefix);
    JsonFileStore.instance.debugDirectory = dir;
    if (session != null) {
      await LocalStorage.savePlaybackSession(session);
    }

    _FakeCastPeerController? made;
    final container = ProviderContainer(
      overrides: <Override>[
        activeLibraryProvider.overrideWithValue(_library()),
        // 踩坑 #76：**不给地址** —— 恢复尾巴的 playSong 才不会走失败跳过链。
        activeAddressProvider.overrideWith((ref) => null),
        effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
        isOfflineProvider.overrideWithValue(false),
        subsonicApiClientProvider.overrideWithValue(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        ),
        musicRepositoryProvider.overrideWithValue(
          MusicRepository(
            SubsonicApiClient(
              dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
            ),
          ),
        ),
        castPeerControllerProvider.overrideWith((ref) {
          final c = _FakeCastPeerController(ref);
          c.snapshot = serverSnapshot;
          c.snapshotError = serverSnapshotError;
          c.mirrorThrows = mirrorThrows;
          made = c;
          return c;
        }),
        // 踩坑 #74：不钉死就会被 ref.listen 的后续异步结果顶掉。
        // FutureProvider 没有 overrideWithValue，「无权威列表」用一个**永不完成**
        // 的 Future 钉在 AsyncLoading 上（valueOrNull 恒 null，且不会被后来
        // 的异步结果顶掉 —— 换成 Future.error 也行，但会在日志里留一条报错）。
        starredProvider.overrideWith(
          (ref) => starred == null
              ? Completer<StarredResult>().future
              : Future<StarredResult>.value(starred),
        ),
      ],
    );

    final notifier = container.read(playerProvider.notifier);
    // 恢复跑在 `_init()` 的异步尾巴上，此刻 castPeerController 可能还没被创建；
    // 显式读一次把替身造出来，后面才拿得到（第一版在这里 `made!` 直接空指针）。
    made ??= container.read(castPeerControllerProvider.notifier)
        as _FakeCastPeerController;
    final h = _Harness._(dir, container, notifier, made!);
    await quiet(notifier);

    addTearDown(() async {
      notifier.debugBeforePersistWrite = null;
      notifier.debugBeforeRestoreResume = null;
      if (notifier.mounted) {
        try {
          await notifier
              .persistPlaybackStateNow()
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          // 用例失败路径上超时可接受：目的只是别把写留到下一个用例。
        }
      }
      JsonFileStore.instance.debugDirectory = null;
      if (!h.disposed) container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    return h;
  }

  // ═══════════════ 一、投屏队列镜像 syncQueueForCast ═══════════════

  group('一、syncQueueForCast · 后端权威队列镜像', () {
    test('1. 空 items 早退：既不重建队列也不动当前曲', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('local1')],
        currentIndex: 0,
        currentSong: _song('local1'),
      );
      final before = h.notifier.state;

      h.notifier.syncQueueForCast(const [], 0);

      // 源里 `if (songs.isEmpty) return;` 在这条之前，state 必须是**同一个对象**。
      expect(identical(h.notifier.state, before), isTrue,
          reason: '空快照不该重建 state');
      expect(_ids(h.notifier.state.queue), <String>['local1']);
    });

    test('2. 已卸装（!mounted）直接早退，不抛 used-after-dispose', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('local1')],
        currentIndex: 0,
        currentSong: _song('local1'),
      );
      h.container.dispose();
      h.disposed = true;
      expect(h.notifier.mounted, isFalse, reason: '前置：notifier 已卸装');

      // mounted 守卫一旦去掉，下面这行就是 StateNotifier 的 used-after-dispose。
      expect(() => h.notifier.syncQueueForCast(<Map<String, dynamic>>[
            _castItem('c1'),
          ], 0), returnsNormally);
    });

    test('3. 下标负越界钳到队首（设备回传 -1 不会越界）', () async {
      final h = await boot();

      h.notifier.syncQueueForCast(
        <Map<String, dynamic>>[_castItem('c1'), _castItem('c2'), _castItem('c3')],
        -5,
      );

      expect(h.notifier.state.currentIndex, 0);
      expect(h.notifier.state.currentSong?.id, 'c1');
    });

    test('4. 下标上越界钳到队尾（设备回传超大下标不会越界）', () async {
      final h = await boot();

      h.notifier.syncQueueForCast(
        <Map<String, dynamic>>[_castItem('c1'), _castItem('c2'), _castItem('c3')],
        99,
      );

      expect(h.notifier.state.currentIndex, 2);
      expect(h.notifier.state.currentSong?.id, 'c3');
    });

    test('5. 同 id 镜像继承原红心（不被 ≤2s 的轮询镜像冲成空心）', () async {
      // 踩坑 #74：给 loading → 权威列表为空 → 只走「继承」那条互斥分支。
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1', starred: true)],
        currentIndex: 0,
        currentSong: _song('c1', starred: true),
      );

      h.notifier.syncQueueForCast(<Map<String, dynamic>>[_castItem('c1')], 0);

      expect(h.notifier.state.currentSong?.id, 'c1');
      expect(h.notifier.state.currentSong?.starred, isTrue,
          reason: '投屏队列项不带 starred，同 id 必须继承，否则红心秒变空心');
    });

    test('6. 权威收藏列表把镜像项的红心点亮（服务端早已收藏）', () async {
      final h = await boot(
        starred: StarredResult(
          artists: const [],
          albums: const [],
          songs: <Song>[_song('c1', starred: true)],
        ),
      );

      h.notifier.syncQueueForCast(<Map<String, dynamic>>[_castItem('c1')], 0);

      expect(h.notifier.state.currentSong?.starred, isTrue,
          reason: '权威列表里有这首歌就必须亮红心，否则 toggleSongFavorite 方向判反');
    });

    test('7. 权威收藏列表把已失效的红心熄灭（服务端已取消收藏）', () async {
      final h = await boot(
        starred: StarredResult(
          artists: const [],
          albums: const [],
          songs: const <Song>[],
        ),
      );
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1', starred: true)],
        currentIndex: 0,
        currentSong: _song('c1', starred: true),
      );

      h.notifier.syncQueueForCast(<Map<String, dynamic>>[_castItem('c1')], 0);

      expect(h.notifier.state.currentSong?.starred, isFalse,
          reason: '权威列表为准：已取消收藏的歌不该继续亮红心');
    });

    test('8. 内容完全没变时早退：连 state 对象都不重建（不刷系统播控）', () async {
      final h = await boot();

      h.notifier.syncQueueForCast(
        <Map<String, dynamic>>[_castItem('c1'), _castItem('c2')],
        1,
      );
      final after1 = h.notifier.state;
      h.notifier.syncQueueForCast(
        <Map<String, dynamic>>[_castItem('c1'), _castItem('c2')],
        1,
      );

      expect(identical(h.notifier.state, after1), isTrue,
          reason: '同内容重复镜像必须早退，否则每 2s 一次 _updateMediaItem 白刷播控');
    });

    test('9. 整队镜像 + 进度三件套归零（切歌后不残留上一首进度）', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('local1')],
        currentIndex: 0,
        currentSong: _song('local1'),
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 200),
        bufferedPosition: const Duration(seconds: 60),
      );

      h.notifier.syncQueueForCast(
        <Map<String, dynamic>>[_castItem('c1'), _castItem('c2'), _castItem('c3')],
        1,
      );

      final st = h.notifier.state;
      expect(_ids(st.queue), <String>['c1', 'c2', 'c3']);
      expect(st.currentIndex, 1);
      expect(st.currentSong?.id, 'c2');
      expect(st.position, Duration.zero);
      expect(st.duration, Duration.zero);
      expect(st.bufferedPosition, Duration.zero);
    });
  });

  // ═══════════════ 二、回本机恢复 restoreStateForCast ═══════════════

  group('二、restoreStateForCast · 回本机恢复离开前的状态', () {
    test('10. 空队列：下标钳到 -1，当前曲原样取回传入值', () async {
      final h = await boot();

      h.notifier.restoreStateForCast(
        queue: const <Song>[],
        currentIndex: 3,
        currentSong: _song('keep'),
        position: Duration.zero,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
        isPlaying: false,
      );

      expect(h.notifier.state.currentIndex, -1);
      expect(h.notifier.state.currentSong?.id, 'keep');
      expect(h.notifier.state.queue, isEmpty);
    });

    test('11. 下标上越界钳到队尾（设备端队列比本地短）', () async {
      final h = await boot();
      final q = <Song>[_song('r1'), _song('r2')];

      h.notifier.restoreStateForCast(
        queue: q,
        currentIndex: 99,
        currentSong: null,
        position: Duration.zero,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
        isPlaying: false,
      );

      expect(h.notifier.state.currentIndex, 1);
      expect(h.notifier.state.currentSong?.id, 'r2');
    });

    test('12. 位置/循环/洗牌/播放态逐字段原样落回 state', () async {
      final h = await boot();
      final q = <Song>[_song('r1'), _song('r2'), _song('r3')];

      h.notifier.restoreStateForCast(
        queue: q,
        currentIndex: 2,
        currentSong: q[2],
        position: const Duration(seconds: 77),
        loopMode: LoopMode.one,
        shuffleEnabled: true,
        isPlaying: false,
      );

      final st = h.notifier.state;
      expect(_ids(st.queue), <String>['r1', 'r2', 'r3']);
      expect(st.currentIndex, 2);
      expect(st.position, const Duration(seconds: 77));
      expect(st.loopMode, LoopMode.one);
      expect(st.shuffleEnabled, isTrue);
      expect(st.isPlaying, isFalse);
    });

    test('13. isPlaying=true 会真的去起播（不是只把标志位写进 state）', () async {
      final h = await boot();
      // 单曲队列：起播失败后的自动跳过链推不动下标，断言才稳（踩坑 #76）。
      final q = <Song>[_song('r1')];

      h.notifier.restoreStateForCast(
        queue: q,
        currentIndex: 0,
        currentSong: q[0],
        position: Duration.zero,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
        isPlaying: true,
      );

      expect(h.notifier.state.isPlaying, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_ids(h.notifier.state.queue), <String>['r1'],
          reason: '起播失败也不许把刚恢复回来的队列清空');
    });
  });

  // ═══════════════ 三、投屏态切歌下标 resolveCastNeighborIndex ═══════════════

  group('三、resolveCastNeighborIndex · 投屏态上一首/下一首下标', () {
    test('14. 空队列返回 null（没有可切换目标）', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(queue: const <Song>[]);

      expect(h.notifier.resolveCastNeighborIndex(forward: true), isNull);
      expect(h.notifier.resolveCastNeighborIndex(forward: false), isNull);
    });

    test('15. 单曲队列返回当前下标（不前进也不回绕）', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1')],
        currentIndex: 0,
      );

      expect(h.notifier.resolveCastNeighborIndex(forward: true), 0);
      expect(h.notifier.resolveCastNeighborIndex(forward: false), 0);
    });

    test('16. 末曲「下一首」回绕到队首', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1'), _song('c2'), _song('c3')],
        currentIndex: 2,
      );

      expect(h.notifier.resolveCastNeighborIndex(forward: true), 0);
    });

    test('17. 首曲「上一首」回绕到队尾', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1'), _song('c2'), _song('c3')],
        currentIndex: 0,
      );

      expect(h.notifier.resolveCastNeighborIndex(forward: false), 2);
    });

    test('18. 非法下标先钳到合法区间再前进（不返回负数）', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1'), _song('c2'), _song('c3')],
        currentIndex: -1,
      );

      expect(h.notifier.resolveCastNeighborIndex(forward: true), 1);
    });

    test('18b. 单曲队列**不钳位**：原样返回越界的当前下标（现状钉子 · D-056）', () async {
      // 只记不改：多曲分支有 `state.currentIndex.clamp(0, queue.length - 1)`，
      // 而单曲分支直接 `return state.currentIndex`，越界下标会原样交给调用方
      // （调用方拿它去 `queue[i]` 或下发设备就会越界）。这条钉的是**当前行为**：
      // 哪天给它补上钳位，这条会红 —— 那正是修好它的信号，按新语义改成 0 即可。
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('c1')],
        currentIndex: 7,
      );

      expect(h.notifier.resolveCastNeighborIndex(forward: true), 7);
      expect(h.notifier.resolveCastNeighborIndex(forward: false), 7);
    });
  });

  // ═══════════════ 四、投屏进度上屏 updateNotificationCastProgress ═══════════════

  group('四、updateNotificationCastProgress · 投屏进度驱动系统播控', () {
    test('19. 桌面端 _audioHandler/_smtc 皆空：?. 短路不抛、不改写 PlayerState', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        duration: const Duration(seconds: 200),
        position: const Duration(seconds: 5),
      );
      final before = h.notifier.state;

      expect(
        () => h.notifier.updateNotificationCastProgress(
          active: true,
          playing: true,
          position: const Duration(seconds: 42),
        ),
        returnsNormally,
      );
      expect(identical(h.notifier.state, before), isTrue,
          reason: '进度上屏只是喂播控中心，不该反过来改写 PlayerState');
    });
  });

  // ═══════════════ 五、会话恢复 · 本地优先 ═══════════════

  group('五、会话恢复 · 本地文件为准', () {
    test('20. 盘上没有会话：不起播，state 保持初始（空队列 / 无当前曲）', () async {
      final h = await boot();

      expect(h.notifier.state.queue, isEmpty);
      expect(h.notifier.state.currentSong, isNull);
      expect(await LocalStorage.getPlaybackSession(), isNull);
    });

    test('21. 会话队列为空：先清盘（避免下次启动复活旧会话）', () async {
      // 注意（只记不改，见文档 D-055）：清完之后源里并没有 return，会继续走到
      // `queue[restoredIndex]` → 空列表 RangeError → 被外层 catch 吞掉。
      // 本例钉的是**清盘**这条对外的正确结果。
      final h = await boot(
        session: _session(
          queue: const <Map<String, dynamic>>[],
          currentIndex: 0,
          currentSongId: '',
        ),
      );

      expect(await LocalStorage.getPlaybackSession(), isNull,
          reason: '空队列会话必须清掉，否则每次启动都恢复成同一份空壳');
      expect(h.notifier.state.queue, isEmpty);
    });

    test('22. 正常本地恢复：队列 / 下标 / 当前曲一齐回屏', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
            _song('g3').toJson(),
          ],
          currentIndex: 1,
          currentSongId: 'g2',
          positionMs: 42000,
        ),
      );

      expect(_ids(h.notifier.state.queue), <String>['g1', 'g2', 'g3']);
      expect(h.notifier.state.currentIndex, 1);
      expect(h.notifier.state.currentSong?.id, 'g2');
    });

    test('23. 恢复下标越界（>= 队列长度）钳到队尾', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
            _song('g3').toJson(),
          ],
          currentIndex: 9,
          currentSongId: 'zzz',
        ),
      );

      expect(h.notifier.state.currentIndex, 2);
      expect(h.notifier.state.currentSong?.id, 'g3');
    });

    test('24. 恢复下标为负回到队首', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
            _song('g3').toJson(),
          ],
          currentIndex: -1,
          currentSongId: 'zzz',
        ),
      );

      expect(h.notifier.state.currentIndex, 0);
      expect(h.notifier.state.currentSong?.id, 'g1');
    });

    test('25. 下标与 currentSongId 不符时按 id 命中（队列被重排过也能续上）', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
            _song('g3').toJson(),
          ],
          currentIndex: 0,
          currentSongId: 'g3',
        ),
      );

      expect(h.notifier.state.currentIndex, 2,
          reason: '队列顺序变了要以 currentSongId 为准，不能盲信旧下标');
      expect(h.notifier.state.currentSong?.id, 'g3');
    });

    test('26. 队列里的坏条目跳过不炸（缓存损坏只丢一首，不整队作废）', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            // previewPicId 是硬 `as String?` 强转，非字符串直接抛 → 走 catch。
            <String, dynamic>{
              'id': 'bad',
              'title': 'Bad',
              'previewPicId': 123,
            },
          ],
          currentIndex: 0,
          currentSongId: 'g1',
        ),
      );

      expect(_ids(h.notifier.state.queue), <String>['g1']);
      expect(h.notifier.state.currentIndex, 0);
    });

    test('27. updatedAt / 下标是字符串或浮点也能解析（历史脏数据兼容）', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
            _song('g3').toJson(),
          ],
          currentIndex: '2', // 字符串下标
          currentSongId: 'g3',
          positionMs: '42000', // 字符串进度
          updatedAt: 1700000000000.0, // 浮点时间戳
        ),
      );

      expect(h.notifier.state.currentIndex, 2,
          reason: '字符串下标解析不出来就会退化成 0，续播续错歌');
      expect(h.notifier.state.currentSong?.id, 'g3');
    });

    test('28. 本地胜出时把队列回推给服务端（两端一致）', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
          ],
          currentIndex: 1,
          currentSongId: 'g2',
        ),
      );

      expect(_ids(h.notifier.state.queue), <String>['g1', 'g2']);
      expect(h.cast.mirrorCalls, greaterThanOrEqualTo(1),
          reason: '本地为准必须回推一次，否则服务端还留着上一进程的旧队列');
    });

    test('29. 回推抛异常被吞：恢复结果不受影响', () async {
      final h = await boot(
        mirrorThrows: true,
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
          ],
          currentIndex: 1,
          currentSongId: 'g2',
        ),
      );

      expect(_ids(h.notifier.state.queue), <String>['g1', 'g2']);
      expect(h.notifier.state.currentIndex, 1);
      expect(h.cast.mirrorCalls, greaterThanOrEqualTo(1));
    });

    test('30. 队列来源随会话一起恢复（列表页「正在播放」指示不丢）', () async {
      final h = await boot(
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
          ],
          currentIndex: 1,
          currentSongId: 'g2',
          queueOrigin: const <String, dynamic>{
            'kind': 'playlist',
            'id': 'pl-42',
          },
        ),
      );

      final origin = h.container.read(queueOriginProvider);
      expect(origin, isNotNull);
      expect(origin!.kind, QueueOriginKind.playlist);
      expect(origin.id, 'pl-42');
    });
  });

  // ═══════════════ 六、会话恢复 · 服务端快照新鲜度竞速 ═══════════════

  group('六、会话恢复 · 服务端快照竞速', () {
    test('31. 服务端快照更新：队列取服务端 + 播放模式按 playMode 恢复', () async {
      final h = await boot(
        serverSnapshot: <String, dynamic>{
          'items': <Map<String, dynamic>>[
            _serverItem('x1'),
            _serverItem('x2'),
            _serverItem('x3'),
          ],
          'currentIndex': 2,
          'playMode': 'shuffle',
          'updatedAt': 1800000000000,
        },
        session: _session(
          queue: <Map<String, dynamic>>[_song('g1').toJson()],
          currentIndex: 0,
          currentSongId: 'g1',
          updatedAt: 1700000000000,
        ),
      );

      expect(_ids(h.notifier.state.queue), <String>['x1', 'x2', 'x3'],
          reason: '服务端比本地新就必须用服务端队列，否则旧队列反杀服务端');
      expect(h.notifier.state.currentIndex, 2);
      // 默认 playbackMode 是 all，能断言成 shuffle 就说明 playMode 真的被采纳了。
      expect(h.notifier.state.playbackMode, PlaybackMode.shuffle);
      // 服务端为准不回推（内容一致，避免 MB 级冗余上行）。
      expect(h.cast.mirrorCalls, 0);
      // 服务端胜出后要立刻把服务端内容落成本地会话（下次启动两侧一致）。
      // 确定性驱动：bounded 轮询直等「目标内容」出现 —— 落盘是 fire-and-forget
      // 真 IO，时长不可控，固定 5s 预算在高负载下会抢跑误红；这里轮询上限 30s，
      // 且以「currentSongId == x3」为退出条件（非空即可），既有内容错也不会误绿。
      Map<String, dynamic>? saved;
      final persistDeadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(persistDeadline)) {
        final s = await LocalStorage.getPlaybackSession();
        if (s != null && s['currentSongId'] == 'x3') {
          saved = s;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(saved, isNotNull,
          reason: '服务端胜出后必须回写一次本地会话（fire-and-forget，轮询上限 30s）');
      expect(saved!['currentSongId'], 'x3',
          reason: '服务端胜出必须回写本地，否则下次启动又退回旧本地会话');
    });

    test('32. playMode=one 与缺失/未知值分别落到 one 与 order', () async {
      final one = await boot(
        serverSnapshot: <String, dynamic>{
          'items': <Map<String, dynamic>>[_serverItem('x1'), _serverItem('x2')],
          'currentIndex': 1,
          'playMode': 'one',
          'updatedAt': 1800000000000,
        },
      );
      expect(one.notifier.state.playbackMode, PlaybackMode.one);

      final unknown = await boot(
        serverSnapshot: <String, dynamic>{
          'items': <Map<String, dynamic>>[_serverItem('y1')],
          'currentIndex': 0,
          'playMode': 'weekly-radio',
          'updatedAt': 1800000000000,
        },
      );
      // 默认 playbackMode 是 all —— 落回 order 说明未知 playMode 走了 `_ =>` 兜底。
      expect(unknown.notifier.state.playbackMode, PlaybackMode.order);
    });

    test('33. 快照拉取抛异常被吞：安静回落本地会话，不卡死启动', () async {
      final h = await boot(
        serverSnapshotError: StateError('snapshot-boom'),
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
          ],
          currentIndex: 1,
          currentSongId: 'g2',
        ),
      );

      expect(h.cast.fetchCalls, 1);
      expect(_ids(h.notifier.state.queue), <String>['g1', 'g2'],
          reason: '服务端快照拉不到必须回落本地，不能因为一次异常把续播搞没');
      expect(h.notifier.state.currentIndex, 1);
    });

    test('34. 快照不比本地新时仍以本地为准（旧服务端不反杀）', () async {
      final h = await boot(
        serverSnapshot: <String, dynamic>{
          'items': <Map<String, dynamic>>[_serverItem('x1')],
          'currentIndex': 0,
          'playMode': 'shuffle',
          'updatedAt': 1600000000000, // 比本地 1700000000000 旧
        },
        session: _session(
          queue: <Map<String, dynamic>>[
            _song('g1').toJson(),
            _song('g2').toJson(),
          ],
          currentIndex: 1,
          currentSongId: 'g2',
          updatedAt: 1700000000000,
        ),
      );

      expect(_ids(h.notifier.state.queue), <String>['g1', 'g2']);
      expect(h.notifier.state.currentIndex, 1);
    });
  });

  // ═══════════════ 七、落盘防抖与租约 ═══════════════

  group('七、会话落盘 · 防抖与租约', () {
    test('35. 5s 防抖定时器到点才落盘（不是每次 state 变更都写）', () async {
      final h = await boot();
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('d1')],
        currentIndex: 0,
        currentSong: _song('d1'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await LocalStorage.getPlaybackSession(), isNull,
          reason: '防抖窗口内不该落盘');

      await Future<void>.delayed(const Duration(seconds: 6));
      final saved = await LocalStorage.getPlaybackSession();
      expect(saved, isNotNull, reason: '防抖到点必须落盘');
      expect(saved!['currentSongId'], 'd1');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('36. 落盘租约过期（>15s 仍未写完）强制放行下一轮，不永久停摆', () async {
      final h = await boot();
      // 踩坑 #77：payload 为空时钩子在早退之后、根本不会被调用 —— 先铺非空队列。
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('d1')],
        currentIndex: 0,
        currentSong: _song('d1'),
      );

      var writeCalls = 0;
      final gate = Completer<void>();
      h.notifier.debugBeforePersistWrite = () async {
        writeCalls++;
        if (writeCalls == 1) await gate.future; // 只卡住第一轮
      };
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      // 第一轮：占住「正在写」租约后永久挂起（模拟 Windows 上 rename 被占用）。
      unawaited(h.notifier.persistPlaybackStateNow());
      await Future<void>.delayed(const Duration(seconds: 16));

      // 再触发一次防抖动落盘：此刻仍挂着第一轮，只有租约过期分支能放行。
      h.notifier.state = h.notifier.state.copyWith(
        queue: <Song>[_song('d1')],
        currentIndex: 0,
        currentSong: _song('d1'),
        position: const Duration(seconds: 7),
      );
      await Future<void>.delayed(const Duration(seconds: 10));

      final saved = await LocalStorage.getPlaybackSession();
      expect(writeCalls, greaterThanOrEqualTo(2));
      expect(saved, isNotNull,
          reason: '上一轮写卡死 15s 以上必须强制放行，否则会话落盘永久停摆');
      expect(saved!['currentSongId'], 'd1');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
