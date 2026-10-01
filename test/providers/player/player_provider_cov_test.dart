// batch17：lib/providers/player/player_provider.dart 的**公开状态迁移 API** 缺口。
//
// 这个文件是 client 端最大的单文件洼地（851 行未覆盖 / 17.46%）。之前的测试之所以
// 打不进去，是因为 `PlayerNotifier` 是抽象类、`_PlayerNotifierImpl` 是库私有的，
// 而仓库里的 `TestPlayerNotifier` 是 `implements PlayerNotifier`：
// 它把「应该怎样」写对了，但真实现一行没跑（这正是 session_teardown_test 开头
// 吐槽的那件事）。
//
// 本文件的做法与 session_teardown_test 一致 —— **驱动真实 PlayerNotifier**：
//   `container.read(playerProvider.notifier)` 拿到的就是 `_PlayerNotifierImpl`，
//   类型是公开基类 `PlayerNotifier`，可以直接调它的公开方法。
// 桌面端 `_init()` 里 `initAudioService()` 会抛 UnsupportedError 走 catch，
// `_audioPlayer` 落成一个真的 `AudioPlayer`，而 just_audio 在测试环境下是 no-op；
// 另外源码对底层下发都做了安全调用 / try-catch（`setPlaybackMode` 甚至自带
// 'apply playback mode failed' 兜底）——所以这些状态迁移在单测里能跑通。
//
// 本批瞄准的是**不碰播放源**的那一段：投屏队列同步、播放模式四态、队列增删、
// 外部收藏推送、收藏切换、元数据刷新。
//
// 踩坑索引：#29 path_provider 打桩 / #30 投屏条目 key 是 songId / #31 next() 深路径。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

Song _song(String id, {String albumId = 'al1', bool starred = false, String? title}) => Song(
      id: id,
      title: title ?? '曲$id',
      artist: '歌手',
      albumId: albumId,
      duration: 200,
      starred: starred,
    );

PlayerState _state({
  Song? currentSong,
  List<Song> queue = const <Song>[],
  int currentIndex = 0,
  PlaybackMode playbackMode = PlaybackMode.all,
  LoopMode loopMode = LoopMode.off,
  bool shuffleEnabled = false,
  Duration position = Duration.zero,
}) => PlayerState(
      currentSong: currentSong,
      queue: queue,
      currentIndex: currentIndex,
      playbackMode: playbackMode,
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
      position: position,
      duration: const Duration(seconds: 200),
    );

/// 只记调用、不发请求仓储（收藏与元数据刷新两个入口都只用到这两个方法）。
class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test'))));

  final Map<String, bool> starredCalls = <String, bool>{};
  final List<String> getSongCalls = <String>[];
  Song? nextSong;
  bool throwOnStar = false;
  bool throwOnGet = false;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {
    if (throwOnStar) throw StateError('boom-star');
    starredCalls[songId] = starred;
  }

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls.add(songId);
    if (throwOnGet) throw StateError('boom-get');
    return nextSong;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 踩坑 #29：`_init()` 在移动平台会先走 initAudioService() → flutter_cache_manager
  // 要 path_provider；测试里没装插件，MissingPluginException 会**穿透构造函数**
  // （setUpAll 直接崩）。给通道一个落点让那条路自己走完。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  // 踩坑 #31：LocalStorage 走 SharedPreferences.getInstance()，
  // 不 mock 会抛 MissingPlugin（channel shared_preferences / getAll），
  // 同样从 setPlaybackMode → _persistPlaybackMode 冒出来。
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();

  ProviderContainer buildContainer() => ProviderContainer(
        overrides: <Override>[
          // 没有登录库 → 会话恢复读不到东西，直接走完，不碰网络。
          activeLibraryProvider.overrideWithValue(null),
          subsonicApiClientProvider.overrideWithValue(
            SubsonicApiClient(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test'))),
          ),
          musicRepositoryProvider.overrideWithValue(repo),
        ],
      );

  /// 等真 notifier 的构造期尾巴（AudioPlayer 就绪 + 会话恢复）落定。
  Future<void> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return;
      }
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  setUpAll(() async {
    container = buildContainer();
    notifier = container.read(playerProvider.notifier);
    await waitQuiet(notifier);
  });

  setUp(() async {
    // 落盘是进程内共享的：上一个用例 persist 过的 key 会污染下一个用例
    // （「persist=false 不落盘」会读到上一条残留）。每个用例前先清掉。
    (await SharedPreferences.getInstance()).remove('playback_mode');
    repo.starredCalls.clear();
    repo.getSongCalls.clear();
    repo.throwOnStar = false;
    repo.throwOnGet = false;
    repo.nextSong = null;
    notifier.state = _state();
  });

  tearDownAll(() => container.dispose());

  // ───────────────────────── 一、投屏队列同步 ─────────────────────────
  group('投屏队列同步（syncQueueForCast / restoreStateForCast / resolveCastNeighborIndex）', () {
    test('空 items 直接 return，不动队列', () {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        currentIndex: 0,
      );
      notifier.syncQueueForCast(<Map<String, dynamic>>[], 0);
      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['s1', 's2']);
    });

    test('内容没变 + index 一致 → 整份 state 不变（不重排进度）', () {
      // 踩坑 #30：投屏条目的 id 字段叫 **songId**，不是 id。
      // 传错 key 时 castQueueItemToSong 会拿到 ''，看起来是「内容变了」。
      final items = <Map<String, dynamic>>[
        {'songId': 's1'},
        {'songId': 's2'},
      ];
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        currentIndex: 0,
        position: const Duration(seconds: 33),
      );
      notifier.syncQueueForCast(items, 0);
      expect(notifier.state.position, const Duration(seconds: 33));
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('内容真变了 → 换队列 + 进度归零 + 当前曲跟着走', () {
      final items = <Map<String, dynamic>>[
        {'songId': 'a1'},
        {'songId': 'a2'},
      ];
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        currentIndex: 0,
        position: const Duration(seconds: 42),
      ).copyWith(bufferedPosition: const Duration(seconds: 60));
      notifier.syncQueueForCast(items, 1);
      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['a1', 'a2']);
      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.currentSong?.id, 'a2');
      // 换源必归零：投屏切歌后不能把上一首的进度带过去。
      expect(notifier.state.position, Duration.zero);
      expect(notifier.state.bufferedPosition, Duration.zero);
    });

    test('index 越界要 clamp，不能越出队列', () {
      final items = <Map<String, dynamic>>[
        {'songId': 'a1'},
        {'songId': 'a2'},
      ];
      notifier.syncQueueForCast(items, 99);
      expect(notifier.state.currentIndex, 1);
    });

    test('restoreStateForCast：isPlaying=false 只恢复状态，不起播', () {
      final queue = <Song>[_song('p1'), _song('p2')];
      notifier.restoreStateForCast(
        queue: queue,
        currentIndex: 1,
        currentSong: _song('p2'),
        position: const Duration(seconds: 7),
        loopMode: LoopMode.one,
        shuffleEnabled: false,
        isPlaying: false,
      );
      expect(notifier.state.currentSong?.id, 'p2');
      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.position, const Duration(seconds: 7));
      expect(notifier.state.loopMode, LoopMode.one);
      expect(notifier.state.shuffleEnabled, false);
      expect(notifier.state.isPlaying, false);
    });

    test('restoreStateForCast：isPlaying=true 会走续播（状态先置播放位）', () {
      notifier.restoreStateForCast(
        queue: <Song>[_song('p1')],
        currentIndex: 0,
        currentSong: _song('p1'),
        position: const Duration(seconds: 5),
        loopMode: LoopMode.off,
        shuffleEnabled: false,
        isPlaying: true,
      );
      // copyWith 先落 isPlaying，再调 _startPlayback —— 断言读的是落位后的值。
      expect(notifier.state.isPlaying, true);
    });

    test('restoreStateForCast：index 越下界（-1）时退回传进来的 currentSong', () {
      notifier.restoreStateForCast(
        queue: <Song>[_song('p1')],
        currentIndex: -1,
        currentSong: _song('fallback'),
        position: Duration.zero,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
        isPlaying: false,
      );
      // 只有 -1 才越**下界**：99 会被 clamp 回 0 而不是 fallback，
      // 所以这条用例必须传 -1 才能打到「退回 currentSong」分支。
      expect(notifier.state.currentSong?.id, 'fallback');
      expect(notifier.state.currentIndex, -1);
    });

    test('restoreStateForCast：index 越上界会被 clamp 到队尾', () {
      notifier.restoreStateForCast(
        queue: <Song>[_song('p1'), _song('p2'), _song('p3')],
        currentIndex: 99,
        currentSong: _song('fallback'),
        position: Duration.zero,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
        isPlaying: false,
      );
      expect(notifier.state.currentIndex, 2);
      expect(notifier.state.currentSong?.id, 'p3');
    });

    test('resolveCastNeighborIndex：空队列返回 null', () {
      expect(notifier.resolveCastNeighborIndex(forward: true), isNull);
      expect(notifier.resolveCastNeighborIndex(forward: false), isNull);
    });

    test('resolveCastNeighborIndex：单曲队列返回自己', () {
      notifier.state = _state(queue: <Song>[_song('s1')], currentIndex: 0);
      expect(notifier.resolveCastNeighborIndex(forward: true), 0);
      expect(notifier.resolveCastNeighborIndex(forward: false), 0);
    });

    test('resolveCastNeighborIndex：前/后都回绕', () {
      notifier.state = _state(
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        currentIndex: 0,
      );
      expect(notifier.resolveCastNeighborIndex(forward: false), 2);
      notifier.state = notifier.state.copyWith(currentIndex: 2);
      expect(notifier.resolveCastNeighborIndex(forward: true), 0);
      notifier.state = notifier.state.copyWith(currentIndex: 1);
      expect(notifier.resolveCastNeighborIndex(forward: true), 2);
    });
  });

  // ───────────────────────── 二、播放模式四态 ─────────────────────────
  group('播放模式（setPlaybackMode / cyclePlaybackMode / _persistPlaybackMode）', () {
    test('四态：playbackMode + loopMode + shuffleEnabled 的映射（order 与 all 底层同）', () {
      final expected = <PlaybackMode, (LoopMode, bool)>{
        PlaybackMode.order: (LoopMode.off, false),
        PlaybackMode.all: (LoopMode.off, false),
        PlaybackMode.one: (LoopMode.one, false),
        PlaybackMode.shuffle: (LoopMode.off, true),
      };
      for (final entry in expected.entries) {
        final mode = entry.key;
        // 带一个非 0 的 shuffleHistoryCount 进来，才能证明切模式会重置它。
        notifier.state = _state(playbackMode: PlaybackMode.all).copyWith(shuffleHistoryCount: 7);
        notifier.setPlaybackMode(mode, persist: false);
        expect(notifier.state.playbackMode, mode, reason: 'mode=$mode');
        expect(notifier.state.loopMode, entry.value.$1, reason: 'loopMode=$mode');
        expect(notifier.state.shuffleEnabled, entry.value.$2, reason: 'shuffle=$mode');
        // 切模式会重置随机历史计数，否则「上一首/下一首」会串味。
        expect(notifier.state.shuffleHistoryCount, 0, reason: 'historyCount=$mode');
      }
    });

    test('persist=true 会落盘（可从 LocalStorage.getPlaybackMode 读回）', () async {
      notifier.state = _state(playbackMode: PlaybackMode.all);
      await notifier.setPlaybackMode(PlaybackMode.shuffle);
      // 落盘 key 是 `playback_mode`（不是 playbackMode），读侧走 LocalStorage 统一口径。
      expect(await LocalStorage.getPlaybackMode(), 'shuffle');
    });

    test('persist=false 不落盘（读回默认值 all）', () async {
      notifier.state = _state(playbackMode: PlaybackMode.all);
      await notifier.setPlaybackMode(PlaybackMode.one, persist: false);
      // state 该变的都变了，但磁盘上不该留下东西。
      expect(notifier.state.playbackMode, PlaybackMode.one);
      expect(await LocalStorage.getPlaybackMode(), 'all');
    });

    test('cyclePlaybackMode 走 order→all→one→shuffle→order', () async {
      notifier.state = _state(playbackMode: PlaybackMode.order);
      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.all);
      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.one);
      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
      await notifier.cyclePlaybackMode();
      expect(notifier.state.playbackMode, PlaybackMode.order);
    });

    test('旧名 repeatOne / repeatAll 落盘后也能读回 all / one（老用户不丢模式）', () async {
      // _restorePlaybackMode 拿到的就是 getPlaybackMode 的返回值，
      // 这里守的是「读侧映射」这条契约（映射缺失会让老用户模式被重置成默认）。
      await LocalStorage.setPlaybackMode('repeatOne');
      expect(await LocalStorage.getPlaybackMode(), 'one');
      await LocalStorage.setPlaybackMode('repeatAll');
      expect(await LocalStorage.getPlaybackMode(), 'all');
      await LocalStorage.setPlaybackMode('garbage');
      expect(await LocalStorage.getPlaybackMode(), 'all');
    });
  });

  // ───────────────────────── 三、队列增删 ─────────────────────────
  group('队列增删（addToQueue / addAllToQueue / playNext）', () {
    test('addToQueue 追加到队尾', () {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1')],
        currentIndex: 0,
      );
      notifier.addToQueue(_song('s2'));
      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['s1', 's2']);
      expect(notifier.state.currentIndex, 0); // 追加不动当前曲
    });

    test('addAllToQueue 一次追加多首', () {
      notifier.state = _state(queue: <Song>[_song('s1')], currentIndex: 0);
      notifier.addAllToQueue(<Song>[_song('s2'), _song('s3')]);
      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['s1', 's2', 's3']);
    });

    test('playNext 把歌插到当前曲之后并标记为下一首', () async {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s3')],
        currentIndex: 0,
      );
      await notifier.playNext(_song('s2'));
      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['s1', 's2', 's3']);
      expect(notifier.state.currentIndex, 0); // 只是插队，不跳曲
    });

    test('连点两次 playNext：落点恒为 currentIndex+1，后者反超先点（forcedNext 后者赢）', () async {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s3')],
        currentIndex: 0,
      );
      await notifier.playNext(_song('s2'));
      await notifier.playNext(_song('s4'));
      // 插入点固定是 currentIndex+1（playNext 不推进 currentIndex），所以两首都落在
      // 同一格，后点的把先点的挤到后面 —— 与 _forcedNextSongId 的「后者赢」一致。
      // ⚠️ 观察项（已记入缺陷统计 D-019）：期望先点的 s2 更靠前时这里会红。
      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['s1', 's4', 's2', 's3']);
      // 不越界：队尾那首仍在最后，队列长度按点击数增长。
      expect(notifier.state.queue.length, 4);
      expect(notifier.state.queue.last.id, 's3');
    });
  });

  // ───────────────────────── 四、外部收藏推送 ─────────────────────────
  group('外部收藏推送（applyExternalStarred）', () {
    test('songId 为空直接 return', () {
      notifier.state = _state(currentSong: _song('s1'), queue: <Song>[_song('s1')]);
      notifier.applyExternalStarred('', true);
      expect(notifier.state.currentSong?.starred, false);
    });

    test('与本机镜像无关的歌 → 只对齐数据源，不动播放状态', () {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
      );
      notifier.applyExternalStarred('other', true);
      expect(notifier.state.currentSong?.starred, false);
      expect(notifier.state.queue.every((s) => !s.starred), true);
    });

    test('命中当前曲 → 当前曲 + 队列双对齐', () {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
      );
      notifier.applyExternalStarred('s1', true);
      expect(notifier.state.currentSong?.starred, true);
      expect(notifier.state.queue.first.starred, true);
      // 不同专辑的队列项不该被顺手改到
      expect(notifier.state.queue.last.starred, false);
    });

    test('取消收藏走同一条路径（false 也要对齐）', () {
      notifier.state = _state(
        currentSong: _song('s1', starred: true),
        queue: <Song>[_song('s1', starred: true)],
      );
      notifier.applyExternalStarred('s1', false);
      expect(notifier.state.currentSong?.starred, false);
      expect(notifier.state.queue.first.starred, false);
    });

    test('只命中队列（当前播的不是它）→ 只改队列项', () {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
      );
      notifier.applyExternalStarred('s2', true);
      expect(notifier.state.queue.last.starred, true);
      expect(notifier.state.currentSong?.starred, false);
      expect(notifier.state.currentSong?.id, 's1');
    });
  });

  // ───────────────────────── 五、收藏切换 ─────────────────────────
  group('收藏切换（toggleFavorite / toggleSongFavorite）', () {
    test('没有当前曲时 toggleFavorite 是安全的空操作', () async {
      notifier.state = _state(); // currentSong = null
      await notifier.toggleFavorite();
      expect(repo.starredCalls.isEmpty, true);
    });

    test('toggleSongFavorite 成功：写库 + 当前曲与队列一起翻转 + 返回新值', () async {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1')],
      );
      final r = await notifier.toggleSongFavorite(_song('s1'));
      expect(r, true);
      expect(repo.starredCalls['s1'], true);
      expect(notifier.state.currentSong?.starred, true);
      expect(notifier.state.queue.first.starred, true);
    });

    test('toggleSongFavorite 再点一次 = 取消收藏', () async {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1')],
      );
      await notifier.toggleSongFavorite(_song('s1'));
      final r = await notifier.toggleSongFavorite(_song('s1'));
      expect(r, false);
      expect(repo.starredCalls['s1'], false);
      expect(notifier.state.currentSong?.starred, false);
      expect(notifier.state.queue.first.starred, false);
    });

    test('toggleSongFavorite 写失败 → 返回 null 且状态保持原样（不半更新）', () async {
      repo.throwOnStar = true;
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1')],
      );
      final r = await notifier.toggleSongFavorite(_song('s1'));
      expect(r, isNull);
      expect(notifier.state.currentSong?.starred, false);
    });

    test('toggleFavorite 委托给当前曲（队列里有多首时只动当前曲）', () async {
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
      );
      await notifier.toggleFavorite();
      expect(repo.starredCalls.keys.toList(), <String>['s1']);
      expect(notifier.state.currentSong?.starred, true);
      expect(notifier.state.queue.last.starred, false);
    });
  });

  // ───────────────────────── 六、元数据刷新 ─────────────────────────
  group('元数据刷新（refreshSongMetadata）', () {
    test('空 id / 纯空白 → 不查库', () async {
      notifier.state = _state(currentSong: _song('s1'), queue: <Song>[_song('s1')]);
      await notifier.refreshSongMetadata('');
      await notifier.refreshSongMetadata('   ');
      expect(repo.getSongCalls.isEmpty, true);
    });

    test('仓库查无此歌 → 什么都不改', () async {
      notifier.state = _state(currentSong: _song('s1'), queue: <Song>[_song('s1')]);
      await notifier.refreshSongMetadata('s1');
      expect(repo.getSongCalls, <String>['s1']);
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.currentSong?.title, '曲s1');
    });

    test('命中当前曲 → 当前曲换成完整数据（含队列同步更新）', () async {
      final full = _song('s1', title: '完整标题');
      repo.nextSong = full;
      notifier.state = _state(currentSong: _song('s1'), queue: <Song>[_song('s1')]);
      await notifier.refreshSongMetadata('s1');
      expect(notifier.state.currentSong?.title, '完整标题');
      expect(notifier.state.queue.first.title, '完整标题');
    });

    test('只命中队列（当前播的不是它）→ 只换队列项，不动当前曲', () async {
      final full = _song('s2', title: '队列新标题');
      repo.nextSong = full;
      notifier.state = _state(
        currentSong: _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
      );
      await notifier.refreshSongMetadata('s2');
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.queue.map((s) => s.title).toList(), <String>['曲s1', '队列新标题']);
    });

    test('仓库抛错不冒泡（只留痕）', () async {
      repo.throwOnGet = true;
      notifier.state = _state(currentSong: _song('s1'), queue: <Song>[_song('s1')]);
      await expectLater(notifier.refreshSongMetadata('s1'), completes);
      expect(notifier.state.currentSong?.id, 's1');
    });
  });
}
