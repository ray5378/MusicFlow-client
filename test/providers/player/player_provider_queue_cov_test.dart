// batch27：lib/providers/player/player_provider.dart 的**队列 / 播放模式 / 收藏 / 元数据**
// 后半段（源码 2384-2730：cyclePlaybackMode 起 → _summarizeStreamUrl 止）。
//
// 背景：batch19 啃的是**起播主线**（playSong → 探测 / 地址解析 / setUrl 换源 / 离线回退），
// batch17 绕开的那段（投屏队列同步 / 播放模式 / 队列增删 / 收藏 / 元数据）此后一直没成体系地
// 打过 —— 本批就是这段的收口。文件头 2320-2384 的注释已经把这块最贵的坑写清楚了：
// 「playbackMode 不能从 (loopMode, shuffleEnabled) 派生，order 与 all 底层组合完全相同」，
// 所以四态轮转、乐观先行、串行下发、persist 开关、restore 兜底 —— 五件事一条都不能省。
//
// 姿势沿用同一套（batch19 的 player_provider_playback_cov_test.dart）：驱动**真实**
// `_PlayerNotifierImpl`（`container.read(playerProvider.notifier)` 拿得到的就是它），
// 把外部依赖全部 override 成桩：
//   activeLibraryProvider / activeAddressProvider（起播地址）
//   effectiveQualityProvider / isOfflineProvider（离线回退分支）
//   subsonicApiClientProvider / musicRepositoryProvider（探测 / 收藏 / 元数据）
//
// 踩坑索引（本批新增）：
// #158-D `_favoriteHandler = FavoriteScrobbleHandler(_ref)` 是内部 new 的、**没有** Provider
//      可 override（同 #62）；但它的 `_musicRepository` 取的是 `musicRepositoryProvider`、
//      收藏写盘取的是 `_apiClient.get(...)`（= subsonicApiClientProvider），
//      所以收藏链路只能靠「仓储打桩 + api spy」观察，不能碰产品代码。
// #159-D `invalidateFavoriteProviders()` 会 invalidate `starredProvider` / `allSongsProvider` /
//      `albumDetailProvider(albumId)` —— 三个都是 `FutureProvider.autoDispose`，
//      容器里被 invalidate 后会真的去打网络；本批把它们一起 override 掉，
//      否则收藏用例红在「网络层超时」而不是业务逻辑上。
// #160-D `_restorePlaybackMode()` 在 `_init()` 里**无条件**执行（源码 760 行，
//      在 `_restorePlaybackSession()` 之前），所以「预置 prefs → boot」就能打进来，
//      不需要先造一份播放会话。
// #161-D 播种播放模式要走 `LocalStorage.setPlaybackMode(name)`，而不是
//      `SharedPreferences.setMockInitialValues({'playback_mode': ...})` —— 后者只是造了新的
//      SharedPreferences 实例，LocalStorage 内部握着的可能是上一次的缓存实例，两者未必指到同一处。
// #162-D `_modeApplyChain` 是**串行链**；「最后一次点击赢」这条契约要用**顺序 await 两次**
//      去钉（顺序执行后链尾就是最后一次），不要叠成并发再等（那样断言的是乐观状态而非链尾结果）。
// #163-D `PlayerNotifier.state` 是 Riverpod 的 public setter，测试里可以直接
//      `notifier.state = notifier.state.copyWith(...)` 摆队列，不必都走 `playSong`
//      （起播链路慢，还会把「地址解析 / 会话恢复」的噪声带进断言）。
// #164-D `clearQueue` 两条路上的 `_audioPlayer?.stop()` / `_audioHandler?.stop()` /
//      `_invalidateLoadedSource` / `_invalidateSeekRequests` 在 no-op 环境都是安全调用，
//      不需要打桩播放器就能把「保留当前曲」和「全清」两条路都走通。
// #165-D `removeFromQueue` 当前项分支里 `queue: newQueue` 保留的是**移除之后**的队列（不是空表），
//      断言别顺手写成「队列已清空」。
// #166-D `cyclePlaybackMode` 读的是 `playbackMode`（不是 `loopMode`），所以 order 与 all
//      在底层同 LoopMode.off 的情况下仍能正确轮转 —— 这条钉的是源码 2320 行那段注释的契约。
// #167-D `loopMode` / `shuffleEnabled` 会被底层播放器流**反写**（`player.loopModeStream`
//      源码 740 行、`player.shuffleModeEnabledStream` 源码 747 行）：no-op 的 just_audio
//      下流里吐回来的值和我们下发的并不一致（one 档吐回 off、order 档吐回 shuffle=true）。
//      所以四态轮转只能钉 `playbackMode` —— 源码 2320 行也明确说它是权威值。
// #168-D `clearQueue(keepCurrent: true)` 保留的是 `state.currentSong` 本身（源码 2458 行），
//      不是 `queue[currentIndex]`；正常播放态下两者是同一个对象，断言要照源码写。
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

Song _song(
  String id, {
  String title = '',
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
  bool starred = false,
  bool isPreview = false,
}) =>
    Song(
      id: id,
      // 默认值走 「曲<id>」，与历史批次断言里的字符串保持一致。
      title: title.isEmpty ? '曲$id' : title,
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
      starred: starred,
      isPreview: isPreview,
    );

/// 只记调用、不留状态的仓储（收藏写盘 + 元数据读取两个入口都只用到这两个方法）。
///
/// [throwOnStar] 用来逼出 `_favoriteHandler.toggleSongFavorite` 的 catch 分支
/// （返回 null —— 那是「红心点不动但也不该崩」的兜底路径）。
/// [getSongResolver] 用来区分 `refreshSongMetadata` 的「取到歌」与「取不到歌」两路。
class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(SubsonicApiClient(
          dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
        ));

  final List<String> starredCalls = <String>[];
  final List<String> getSongCalls = <String>[];

  bool throwOnStar = false;
  bool throwOnGetSong = false;
  Song? Function(String id)? getSongResolver;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {
    if (throwOnStar) throw StateError('starred boom');
    starredCalls.add('$songId:$starred');
  }

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls.add(songId);
    if (throwOnGetSong) throw StateError('getSong boom');
    return getSongResolver?.call(songId);
  }
}

/// 只记 GET 路径的 Subsonic 客户端替身（踩坑 #62 / #158-D）。
class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  final List<String> getPaths = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    getPaths.add(path);
    return <String, dynamic>{};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 踩坑 #59：`_init()` 在移动平台先走 initAudioService() → flutter_cache_manager 要
  // path_provider；测试里没装插件，MissingPluginException 会**穿透构造函数**。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();

  ServerAddress _addr() => ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
      );

  MusicLibrary _library({String? serverType}) => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: serverType,
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  /// 踩坑 #159-D：收藏链路会 invalidate 这三个 FutureProvider，容器内不 override
  /// 就会被真的拉起来打网络。这里全给静态值，红心相关断言只盯播放器 state。
  ProviderContainer buildContainer({
    String? serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
    ServerAddress? address,
    bool offline = false,
    SubsonicApiClient? apiClient,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library(serverType: serverType)),
          activeAddressProvider.overrideWith((ref) => address),
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(offline),
          subsonicApiClientProvider.overrideWithValue(
            apiClient ??
                SubsonicApiClient(
                  dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
                ),
          ),
          musicRepositoryProvider.overrideWithValue(repo),
          starredProvider.overrideWith((ref) async => StarredResult(
                artists: const <Artist>[],
                albums: const <Album>[],
                songs: const <Song>[],
              )),
          allSongsProvider.overrideWith((ref) async => <Song>[]),
          albumDetailProvider('al1').overrideWith((ref) async => null),
        ],
      );

  /// 等真 notifier 的构造期尾巴（AudioPlayer 就绪 + 播放模式恢复 + 会话恢复）落定。
  Future<void> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return;
      }
    }
  }

  /// 等起播链路（地址解析 → 流式就绪 → scrobble）落定（踩坑 #65）。
  Future<void> settleState(PlayerNotifier n, {int ticks = 200}) async {
    var last = '';
    for (var i = 0; i < ticks; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final st = n.state;
      final sig = '${st.currentIndex}|${st.currentSong?.id}|${st.playbackSource}';
      if (sig == last) return;
      last = sig;
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({
    String? serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
    ServerAddress? address,
    bool offline = false,
    SubsonicApiClient? apiClient,
  }) async {
    container = buildContainer(
      serverType: serverType,
      quality: quality,
      address: address,
      offline: offline,
      apiClient: apiClient,
    );
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  /// 摆一个「当前歌在 [currentIndex]」的纯状态底（踩坑 #163-D）。
  ///
  /// 不跑 `playSong` 的原因：起播链路会把地址解析 / 会话恢复 / 进度轮询全带进来，
  /// 队列操作本身跟这些无关，断言只想看队列与下标。
  void seedQueue(List<Song> queue, {required int currentIndex}) {
    notifier.state = notifier.state.copyWith(
      queue: queue,
      currentIndex: currentIndex,
      currentSong: queue[currentIndex],
      isPlaying: true,
      processingState: ProcessingState.ready,
    );
  }

  List<String> ids(List<Song> q) => q.map((s) => s.id).toList();

  setUp(() {
    repo.throwOnStar = false;
    repo.throwOnGetSong = false;
    repo.getSongResolver = null;
    repo.starredCalls.clear();
    repo.getSongCalls.clear();
  });

  tearDown(() => container.dispose());

  // ───────────────────────── 一、播放模式四态 ─────────────────────────
  group('setPlaybackMode · 四态落位与串行下发', () {
    test('order：底层 LoopMode.off + 关闭随机，playbackMode 记 order', () async {
      notifier = await boot();

      await notifier.setPlaybackMode(PlaybackMode.order, persist: false);

      final st = notifier.state;
      expect(st.playbackMode, PlaybackMode.order);
      expect(st.loopMode, LoopMode.off);
      expect(st.shuffleEnabled, isFalse);
    });

    test('one：底层 LoopMode.one（唯一让底层表达「单曲循环」的一档）', () async {
      notifier = await boot();

      await notifier.setPlaybackMode(PlaybackMode.one, persist: false);

      expect(notifier.state.playbackMode, PlaybackMode.one);
      expect(notifier.state.loopMode, LoopMode.one);
      expect(notifier.state.shuffleEnabled, isFalse);
    });

    test('shuffle：开启随机但底层仍是 LoopMode.off（队列是手动切歌）', () async {
      // 这条钉的是源码里的注释：随机模式故意不用 LoopMode.all，
      // 否则 just_audio 会在单音源下自动重放当前曲目。
      notifier = await boot();

      await notifier.setPlaybackMode(PlaybackMode.shuffle, persist: false);

      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
      expect(notifier.state.shuffleEnabled, isTrue);
      expect(notifier.state.loopMode, LoopMode.off);
    });

    test('all：与 order 底层同 LoopMode.off，差异只落在 playbackMode（派生会丢维度）',
        () async {
      // 源码 2320 行的核心注释：order 与 all 底层组合完全一致，
      // 唯一区别是「播完即停 vs 回绕」，只能靠 playbackMode 记。
      notifier = await boot();

      await notifier.setPlaybackMode(PlaybackMode.all, persist: false);

      expect(notifier.state.playbackMode, PlaybackMode.all);
      expect(notifier.state.loopMode, LoopMode.off);
      expect(notifier.state.shuffleEnabled, isFalse);
    });

    test('切模式时 shuffleHistoryCount 一律清零（不允许上一档的历史残留）', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(shuffleHistoryCount: 17);

      await notifier.setPlaybackMode(PlaybackMode.order, persist: false);

      expect(notifier.state.shuffleHistoryCount, 0);
    });

    test('persist=true 落盘：重启前最后一次选择要留在磁盘上', () async {
      notifier = await boot();

      await notifier.setPlaybackMode(PlaybackMode.one, persist: true);

      expect(await LocalStorage.getPlaybackMode(), 'one');
    });

    test('persist=false 不落盘：restore 回填与「临时预览」不该污染用户设置', () async {
      notifier = await boot();
      await notifier.setPlaybackMode(PlaybackMode.order, persist: true);
      expect(await LocalStorage.getPlaybackMode(), 'order');

      // restore 路径（源码 2396）就是 persist:false 的调用方。
      await notifier.setPlaybackMode(PlaybackMode.shuffle, persist: false);

      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
      expect(await LocalStorage.getPlaybackMode(), 'order',
          reason: 'persist=false 绝不能写盘');
    });

    test('_modeApplyChain 串行：连点两档后「最后一次点击赢」', () async {
      // 源码 2338 行注释：并发下发会让先发的后完成、把最终状态覆盖成上一档。
      // 顺序 await 两次，最终态必须等于后发的一档。
      notifier = await boot();

      await notifier.setPlaybackMode(PlaybackMode.one, persist: false);
      await notifier.setPlaybackMode(PlaybackMode.shuffle, persist: false);

      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
    });
  });

  group('cyclePlaybackMode · order→all→one→shuffle 轮转', () {
    test('四态按序走一圈并回到 order（读 playbackMode，不是 loopMode）', () async {
      // 踩坑 #166-D：order 与 all 底层同为 LoopMode.off，
      // 若 cycle 读的是 loopMode 就只能在两档之间打转。
      notifier = await boot();
      await notifier.setPlaybackMode(PlaybackMode.order, persist: false);

      // 踩坑 #167-D（续）：`loopMode` 与 `shuffleEnabled` 都会被底层播放器流
      // （`player.loopModeStream` / `player.shuffleModeEnabledStream`，源码 740 / 747 行）
      // **反写**。no-op 的 just_audio 下这些流吐回来的值和我们下发的并不一致
      // （one 档吐回 off、order 档吐回 shuffle=true），谁先落地谁赢。
      // 源码 2320 行已经写明「playbackMode 是权威值、不能从 (loopMode, shuffleEnabled) 派生」，
      // 所以轮转这一圈只钉 `playbackMode` —— 它也是产品真正用来区分 order/all 的那一维。
      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.all);

      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.one);

      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.shuffle);

      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.order);
    });
  });

  group('_restorePlaybackMode · 启动回填与兜底', () {
    // 踩坑 #160-D：该方法是 `_init()` 里无条件调用的（源码 760 行），
    // 所以「预置 prefs → boot」即可打进来。
    // 踩坑 #161-D：播种走 LocalStorage，不碰 SharedPreferences mock。
    Future<void> seedMode(String raw) async {
      await LocalStorage.setPlaybackMode(raw);
    }

    test('磁盘上是 one → 启动回填成单曲循环', () async {
      await seedMode('one');
      notifier = await boot();

      expect(notifier.state.playbackMode, PlaybackMode.one);
      expect(notifier.state.loopMode, LoopMode.one);
      // persist=false：只是回填，不该顺手把用户设置重写一遍。
      expect(await LocalStorage.getPlaybackMode(), 'one');
    });

    test('磁盘上是 shuffle → 启动回填成随机（且底层 LoopMode.off）', () async {
      await seedMode('shuffle');
      notifier = await boot();

      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
      expect(notifier.state.shuffleEnabled, isTrue);
      expect(notifier.state.loopMode, LoopMode.off);
    });

    test('旧枚举名 repeatOne 迁移成 one（老用户升级后不该被重置）', () async {
      // LocalStorage 侧会把 repeatAll/repeatOne 映射成 all/one，
      // 这里钉的是映射之后仍然能正确回填（loopMode 落到 one）。
      await seedMode('repeatOne');
      notifier = await boot();

      expect(await LocalStorage.getPlaybackMode(), 'one');
      expect(notifier.state.playbackMode, PlaybackMode.one);
      expect(notifier.state.loopMode, LoopMode.one);
    });

    test('磁盘上是非法枚举名 → 兜底 all 且不抛（firstWhere 的 orElse 分支被走到）', () async {
      await seedMode('nonsense');
      notifier = await boot();

      expect(await LocalStorage.getPlaybackMode(), 'all');
      // 兜底值：既不能崩，也不能留成别的模式。
      expect(notifier.state.playbackMode, PlaybackMode.all);
      expect(notifier.state.loopMode, LoopMode.off);
    });
  });

  // ───────────────────────── 二、队列增删 ─────────────────────────
  group('addToQueue / addAllToQueue · 追加', () {
    test('addToQueue 追加到队尾，不动当前下标', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);

      notifier.addToQueue(_song('s3'));

      expect(ids(notifier.state.queue), <String>['s1', 's2', 's3']);
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('addAllToQueue 整批接在既有队列之后（顺序保持）', () async {
      notifier = await boot();
      seedQueue([_song('s1')], currentIndex: 0);

      notifier.addAllToQueue(<Song>[_song('s2'), _song('s3')]);

      expect(ids(notifier.state.queue), <String>['s1', 's2', 's3']);
    });

    test('空队列也能追加（不依赖 playSong 先建队列）', () async {
      notifier = await boot();

      notifier.addToQueue(_song('s9'));

      expect(ids(notifier.state.queue), <String>['s9']);
    });
  });

  group('playNext · 插到下一曲', () {
    test('队列为空 / 无当前歌 → 直接兜底起播（不越界）', () async {
      // 踩坑 #60：`playSong` 是「先写 state 再解析地址」，这条路的落点就是
      // 「队列变成只有这一首、下标 0」。
      notifier = await boot();

      await notifier.playNext(_song('s7'));
      await settleState(notifier);

      expect(ids(notifier.state.queue), <String>['s7']);
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 's7');
    });

    test('有当前歌 → 插到 currentIndex + 1（不是队尾）', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2'), _song('s3')], currentIndex: 0);

      await notifier.playNext(_song('s9'));

      expect(ids(notifier.state.queue), <String>['s1', 's9', 's2', 's3']);
      expect(notifier.state.currentIndex, 0);
    });

    test('当前歌在末位 → insertIndex 被 clamp 到队尾（不越界抛异常）', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 1);

      await notifier.playNext(_song('s9'));

      expect(ids(notifier.state.queue), <String>['s1', 's2', 's9']);
      expect(notifier.state.currentIndex, 1);
    });
  });

  group('clearQueue · 保留当前曲 / 全清', () {
    test('keepCurrent=true：只清后续，当前曲留在队伍里且下标归 0', () async {
      // 注意：保留的是 `state.currentSong` 本身（源码 2458 行），不是 queue[currentIndex]。
      // 正常播放态下两者同一个对象，所以这条钉的是「后续被清掉、当前曲还在」。
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2'), _song('s3')], currentIndex: 1);

      await notifier.clearQueue();

      expect(ids(notifier.state.queue), <String>['s2']);
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 's2');
      expect(notifier.state.isPlaying, isTrue, reason: '保留当前曲就不该顺手停播');
    });

    test('keepCurrent=true 但当前没有歌 → 落到全清分支（不留空队列 + 悬空歌名）',
        () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        queue: <Song>[_song('s1')],
        currentIndex: 0,
        currentSong: null,
      );

      await notifier.clearQueue();

      expect(notifier.state.queue, isEmpty);
      expect(notifier.state.currentSong, isNull);
    });

    test('keepCurrent=false：整份播放态归零（当前曲 / 进度 / 码率 / 时长）', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);
      notifier.state = notifier.state.copyWith(
        currentBitRateKbps: 1411,
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 200),
      );

      await notifier.clearQueue(keepCurrent: false);

      final st = notifier.state;
      // 源码里那句「clearCurrentSong: true 必须走显式清除开关」就靠这几条钉住：
      // copyWith 传 null 等于未指定，清不掉。
      expect(st.currentSong, isNull);
      expect(st.queue, isEmpty);
      expect(st.currentIndex, 0);
      expect(st.isPlaying, isFalse);
      expect(st.processingState, ProcessingState.idle);
      expect(st.position, Duration.zero);
      expect(st.duration, Duration.zero);
      expect(st.currentBitRateKbps, 0);
    });

    test('全清同时收尾会话：队列来源被清掉（_finishSessionTeardown 的第一件事）', () async {
      // `_finishSessionTeardown` 干两件事：清 queueOrigin + immediate 落盘。
      // 落盘那条在本文件里由「移除当前项」那条用例钉（那里会话文件确实存在），
      // 这里专钉「来源必须跟着会话一起灭掉」，否则列表页的「正在播放」指示会
      // 跟着已经停掉的歌继续亮。
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);
      container.read(queueOriginProvider.notifier).state =
          const QueueOrigin(QueueOriginKind.playlist, 'pl9');
      expect(container.read(queueOriginProvider), isNotNull);

      await notifier.clearQueue(keepCurrent: false);

      // 确定性驱动：bounded 轮询等 teardown 生效（固定 120ms 在高负载下会抢跑）。
      final originDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (container.read(queueOriginProvider) != null &&
          DateTime.now().isBefore(originDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(container.read(queueOriginProvider), isNull);
    });
  });

  group('removeFromQueue · 越界 / 当前项 / 非当前项', () {
    test('index < 0 早退：队列与下标都不动', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 1);

      notifier.removeFromQueue(-1);

      expect(ids(notifier.state.queue), <String>['s1', 's2']);
      expect(notifier.state.currentIndex, 1);
    });

    test('index >= queue.length 早退：队列与下标都不动', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 1);

      notifier.removeFromQueue(9);

      expect(ids(notifier.state.queue), <String>['s1', 's2']);
      expect(notifier.state.currentIndex, 1);
    });

    test('移除的是当前项：整份播放态归零（保留移除**之后**的队列）', () async {
      // 踩坑 #165-D：`queue: newQueue` 是移除后的队列，不是空表。
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2'), _song('s3')], currentIndex: 1);

      notifier.removeFromQueue(1);

      final st = notifier.state;
      expect(ids(st.queue), <String>['s1', 's3']);
      expect(st.currentIndex, 0);
      expect(st.currentSong, isNull);
      expect(st.isPlaying, isFalse);
      expect(st.processingState, ProcessingState.idle);
      expect(st.position, Duration.zero);
    });

    test('移除当前项（队列里只剩它）→ 队列确实空 + 当前歌清空', () async {
      notifier = await boot();
      seedQueue([_song('s2')], currentIndex: 0);

      notifier.removeFromQueue(0);

      expect(notifier.state.queue, isEmpty);
      expect(notifier.state.currentSong, isNull);
      expect(notifier.state.currentIndex, 0);
    });

    test('移除当前项 → 同样走 _finishSessionTeardown（来源清空 + 立刻落盘）', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);
      container.read(queueOriginProvider.notifier).state =
          const QueueOrigin(QueueOriginKind.album, 'al9');

      notifier.removeFromQueue(0);

      // 确定性驱动：bounded 轮询等 immediate 落盘完成（真 IO，固定 120ms 会抢跑）。
      Map<String, dynamic>? savedSession;
      final persistDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (savedSession == null && DateTime.now().isBefore(persistDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        savedSession = await LocalStorage.getPlaybackSession();
      }

      expect(container.read(queueOriginProvider), isNull);
      expect(savedSession, isNotNull, reason: 'immediate 落盘应在轮询预算内完成');
    });

    test('移除当前项**之前**的项：当前下标左移 1', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2'), _song('s3')], currentIndex: 2);

      notifier.removeFromQueue(0);

      expect(ids(notifier.state.queue), <String>['s2', 's3']);
      expect(notifier.state.currentIndex, 1);
    });

    test('移除当前项**之后**的项：当前下标不变', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2'), _song('s3')], currentIndex: 0);

      notifier.removeFromQueue(2);

      expect(ids(notifier.state.queue), <String>['s1', 's2']);
      expect(notifier.state.currentIndex, 0);
    });
  });

  // ───────────────────────── 三、收藏 ─────────────────────────
  group('toggleFavorite / toggleSongFavorite · 红心', () {
    test('没有当前歌 → 早退，不发任何收藏写盘', () async {
      notifier = await boot();

      await notifier.toggleFavorite();

      expect(repo.starredCalls, isEmpty);
      expect(notifier.state.currentSong, isNull);
    });

    test('toggleFavorite 把当前歌翻转成已收藏并同步 state', () async {
      notifier = await boot();
      seedQueue([_song('s1')], currentIndex: 0);

      await notifier.toggleFavorite();

      expect(repo.starredCalls, <String>['s1:true']);
      expect(notifier.state.currentSong?.starred, isTrue);
    });

    test('再点一次取消收藏（方向判定以 currentSong 为准）', () async {
      notifier = await boot();
      seedQueue([_song('s1', starred: true)], currentIndex: 0);

      await notifier.toggleFavorite();

      expect(repo.starredCalls, <String>['s1:false']);
      expect(notifier.state.currentSong?.starred, isFalse);
    });

    test('toggleSongFavorite 命中队列中非当前歌：只改队列那一份', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);

      final newStarred = await notifier.toggleSongFavorite(_song('s2'));

      expect(newStarred, isTrue);
      expect(repo.starredCalls, <String>['s2:true']);
      // 当前歌那份快照不能被动到（currentSong 与 queue[0] 是同一对象引用语义）。
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.currentSong?.starred, isFalse);
      expect(notifier.state.queue[1].starred, isTrue);
    });

    test('toggleSongFavorite 命中当前歌：队列与 currentSong 两边一起对齐', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 1);

      final newStarred = await notifier.toggleSongFavorite(_song('s2'));

      expect(newStarred, isTrue);
      expect(notifier.state.currentSong?.starred, isTrue);
      expect(notifier.state.queue[1].starred, isTrue,
          reason: '播放器内读的是 queue，只更新 currentSong 会让红心点亮但队列快照仍是 false');
    });

    test('写盘抛异常 → 返回 null 且播放器 state 不被动（红心点不动也不该崩）', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 1);
      repo.throwOnStar = true;
      final before = notifier.state;

      final newStarred = await notifier.toggleSongFavorite(_song('s2'));

      expect(newStarred, isNull);
      expect(notifier.state.currentSong?.starred, before.currentSong?.starred);
      expect(identical(notifier.state, before), isTrue,
          reason: '失败路径绝不能留下半更新的 state');
    });
  });

  group('applyExternalStarred · 服务端 song_starred 推送', () {
    test('songId 为空 → 早退（防脏推送把 state 打穿）', () async {
      notifier = await boot();
      seedQueue([_song('s1')], currentIndex: 0);

      notifier.applyExternalStarred('', true);

      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.queue[0].starred, isFalse);
    });

    test('与本端镜像无关（不在队列也不是当前歌）→ 只失效 provider，不动播放状态', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);

      notifier.applyExternalStarred('other', true);

      expect(ids(notifier.state.queue), <String>['s1', 's2']);
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.queue.any((s) => s.starred), isFalse,
          reason: '不在本端队列里的歌不该被写进队列快照');
    });

    test('命中队列里的非当前歌 → 只把队列那份对齐', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);

      notifier.applyExternalStarred('s2', true);

      expect(notifier.state.queue[1].starred, isTrue);
      expect(notifier.state.currentSong?.starred, isFalse,
          reason: '推送改的是别的歌，当前曲的收藏态不受影响');
    });

    test('命中当前歌 → currentSong 与 queue 一起对齐（服务端队列项不带 starred，只能镜像）',
        () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 1);

      notifier.applyExternalStarred('s2', true);

      expect(notifier.state.currentSong?.starred, isTrue);
      expect(notifier.state.queue[1].starred, isTrue);
    });

    test('取消收藏的推送同样生效（双向）', () async {
      notifier = await boot();
      seedQueue([_song('s1', starred: true)], currentIndex: 0);

      notifier.applyExternalStarred('s1', false);

      expect(notifier.state.currentSong?.starred, isFalse);
    });
  });

  // ───────────────────────── 四、元数据刷新 ─────────────────────────
  group('refreshSongMetadata · 用仓储全量数据补齐队列快照', () {
    test('空 / 纯空白 id → 早退，不去打仓储', () async {
      notifier = await boot();

      await notifier.refreshSongMetadata('   ');

      expect(repo.getSongCalls, isEmpty);
    });

    test('仓储取不到歌 → 早退，state 保持原样', () async {
      // `_FakeMusicRepository.getSong` 默认返回 null。
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);
      final before = notifier.state;

      await notifier.refreshSongMetadata('s1');

      expect(repo.getSongCalls, <String>['s1']);
      expect(identical(notifier.state, before), isTrue);
    });

    test('命中当前歌：currentSong 换成全量数据并同步 mediaItem', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);
      repo.getSongResolver = (id) => _song(id, title: '刷新后的$id');

      await notifier.refreshSongMetadata('s1');

      expect(notifier.state.currentSong?.title, '刷新后的s1');
      expect(notifier.state.currentSong?.duration, 200);
    });

    test('只在队列里（非当前歌）：换队列那份，currentSong 不动', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2')], currentIndex: 0);
      repo.getSongResolver = (id) => _song(id, title: '刷新后的$id');

      await notifier.refreshSongMetadata('s2');

      expect(notifier.state.queue[1].title, '刷新后的s2');
      expect(notifier.state.currentSong?.title, '曲s1');
    });

    test('队列里同 id 出现多次：所有位置一起换（不全换会留旧快照）', () async {
      notifier = await boot();
      seedQueue([_song('s1'), _song('s2'), _song('s1')], currentIndex: 1);
      repo.getSongResolver = (id) => _song(id, title: '刷新后的$id');

      await notifier.refreshSongMetadata('s1');

      expect(notifier.state.queue[0].title, '刷新后的s1');
      expect(notifier.state.queue[2].title, '刷新后的s1');
    });

    test('仓储抛异常 → 只记日志，不把异常抛给调用方', () async {
      notifier = await boot();
      seedQueue([_song('s1')], currentIndex: 0);
      repo.throwOnGetSong = true;

      // 不抛出去是关键：这条路径生产上是「服务端瞬时 500」，
      // 元数据刷新失败不该把整次播放打断。
      await notifier.refreshSongMetadata('s1');

      expect(repo.getSongCalls, <String>['s1']);
      expect(notifier.state.currentSong?.title, '曲s1');
    });
  });
}
