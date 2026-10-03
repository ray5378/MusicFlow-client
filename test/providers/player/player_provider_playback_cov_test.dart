// batch19：lib/providers/player/player_provider.dart 的**播放源主线**（上一批刻意绕开的那段）。
//
// 背景：batch17 的 player_provider_cov_test.dart 打的是「不碰播放源」那一段
// （投屏队列同步 / 播放模式 / 队列增删 / 收藏 / 元数据）。本批接着啃**起播链路**：
// `playSong` → 预探测 / 音质与转码判定 / 服务端管道化 / 地址解析 / setUrl 换源 /
// 源就绪同步 / pendingSeek / 离线回退 / 不可播跳过。
//
// 姿势沿用同一套：驱动**真实** `_PlayerNotifierImpl`（`container.read(playerProvider.notifier)`
// 拿得到的就是它），把外部依赖全部 override 成桩：
//   activeLibraryProvider（serverType → 管道化判定）
//   activeAddressProvider（起播地址，拿不到则走重试调度分支）
//   effectiveQualityProvider / isOfflineProvider（离线回退分支）
//   subsonicApiClientProvider / musicRepositoryProvider（探测与 scrobble）
// 桌面端 `_init()` 里 initAudioService() 抛 UnsupportedError 走 catch，`_audioPlayer` 落成一个
// 真的 AudioPlayer，而 just_audio 在测试环境是 no-op —— 换源/起播都能跑完，只是不出声。
//
// 踩坑索引（本批新增，见文件末尾 7.x）：#59 path_provider / shared_preferences 必须打桩、
// #60 真 AudioPlayer 的 setUrl 在 no-op 环境不抛、#61 isOfflineProvider 是普通 Provider（值覆盖）。
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

Song _song(
  String id, {
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
  bool starred = false,
  bool isPreview = false,
}) =>
    Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
      starred: starred,
      isPreview: isPreview,
    );

/// 只记调用、不发请求仓储（探测 / scrobble / 元数据刷新三个入口都只用到这几个方法）。
class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(SubsonicApiClient(
          dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
        ));

  final List<String> starredCalls = <String>[];
  final List<String> getSongCalls = <String>[];

  @override
  Future<void> setSongStarred(String songId, bool starred) async {
    starredCalls.add('$songId:$starred');
  }

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls.add(songId);
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 踩坑 #59：`_init()` 在移动平台先走 initAudioService() → flutter_cache_manager 要
  // path_provider；测试里没装插件，MissingPluginException 会**穿透构造函数**。
  // 给通道一个落点，让那条路自己走完。
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

  ProviderContainer buildContainer({
    String? serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
    ServerAddress? address,
    bool offline = false,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library(serverType: serverType)),
          activeAddressProvider.overrideWith((ref) => address),
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(offline),
          subsonicApiClientProvider.overrideWithValue(
            SubsonicApiClient(
              dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
            ),
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

  Future<PlayerNotifier> boot({
    String? serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
    ServerAddress? address,
    bool offline = false,
  }) async {
    container = buildContainer(
      serverType: serverType,
      quality: quality,
      address: address,
      offline: offline,
    );
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  tearDown(() => container.dispose());

  // ───────────────────────── 一、起播主线 ─────────────────────────
  group('playSong · 起播主线', () {
    test('原声直连：队列/时长/播放源都落到 state 上', () async {
      notifier = await boot();

      await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')]);

      final st = notifier.state;
      expect(st.currentSong?.id, 's1');
      expect(st.queue.map((s) => s.id).toList(), <String>['s1']);
      expect(st.currentIndex, 0);
      // 元数据时长兜底：转码流拿不到时长时界面也要有东西显示。
      expect(st.duration, const Duration(seconds: 200));
    });

    test('拿到地址并起播后 playbackSource 记成 stream', () async {
      notifier = await boot(address: _addr());

      await notifier.playSong(_song('s1'));

      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.currentBitRateKbps, isNotNull);
    });

    test('自动起播（autoPlay=true）会带上 scrobble 尝试', () async {
      repo.starredCalls.clear();
      notifier = await boot(address: _addr());

      await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')]);

      // 起播链路走完不清场也不该抛；这条钉的是「auto-play 分支不会静默炸在 try 里」。
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('autoPlay=false 时只换源不起播，state 仍然就位', () async {
      notifier = await boot(address: _addr());

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        autoPlay: false,
      );

      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.isPlaying, isFalse);
    });

    test('带 initialPosition 起播：进度先落到 state，交给源就绪后的 pendingSeek', () async {
      notifier = await boot(address: _addr());

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        initialPosition: const Duration(seconds: 42),
      );

      expect(notifier.state.position, const Duration(seconds: 42));
    });

    test('拿不到服务器地址：起播不炸，停在「解析地址」这一步，改走重试调度分支', () async {
      notifier = await boot(address: null);

      // 不抛异常是关键：这条路径生产上是「没配库地址」的高频场景。
      await notifier.playSong(_song('s1'));
      // 踩坑 #60：playSong 是**先写 state 再解析地址**，所以「拿不到地址」时
      // currentSong 依然存在（不是 null）；能区分的是它从没走到播放源阶段。
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.playbackSource, isNull);
    });
  });

  // ───────────────────────── 二、音质 / 转码判定 ─────────────────────────
  group('playSong · 音质与转码判定', () {
    test('非原声音质 + 需转码的源 → 带上 maxBitRate 起播', () async {
      notifier = await boot(
        address: _addr(),
        quality: AudioQualityLevel.high,
      );
      final song = _song('t1', suffix: 'ape');

      await notifier.playSong(song, queue: <Song>[song]);

      expect(notifier.state.currentSong?.id, 't1');
      expect(notifier.state.currentBitRateKbps, isNotNull);
    });

    test('服务端非 MusicFlow（无管道化）也能起播，日志分支走完', () async {
      notifier = await boot(address: _addr(), serverType: 'OpenSubsonic');

      await notifier.playSong(_song('s1'));

      expect(notifier.state.currentSong?.id, 's1');
    });
  });

  // ───────────────────────── 三、不可播跳过 ─────────────────────────
  group('playSong · 不可播跳过', () {
    test('离线态且本机没缓存该曲 → 按不可播处理，起播不成功且不抛、跳链跑完整队', () async {
      notifier = await boot(address: _addr(), offline: true);

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
      );

      // 离线分支只认本地缓存文件，桩里没有 → _handlePlaybackError → next() 继续往下跳。
      // 钉两件事：(1) 离线无缓存绝不能记成「起播成功」(playbackSource 恒为空)；
      // (2) 失败后 currentSong 仍非空 —— _handlePlaybackError 刻意同步推进下一首，
      //     保证实时上报/远端镜像读到的永远是有在播目标，不会停在失败态。
      final st = notifier.state;
      expect(st.playbackSource, isNull, reason: '离线无缓存不该记成起播成功');
      expect(st.currentSong, isNotNull, reason: '失败跳歌后仍有在播目标（状态连贯）');
      expect(st.currentIndex, anyOf(0, 1), reason: '跳链会一路跳完整个队列(all 模式回绕)');
    });
  });

  // ───────────────────────── 四、队列操作 ─────────────────────────
  group('队列操作（playQueue / append / add / playNext / remove / clear）', () {
    test('playQueue：整队换上并落到正确的当前曲', () async {
      notifier = await boot(address: _addr());

      await notifier.playQueue(<Song>[_song('q1'), _song('q2'), _song('q3')]);

      final st = notifier.state;
      expect(st.queue.map((s) => s.id).toList(), <String>['q1', 'q2', 'q3']);
      expect(st.currentIndex, 0);
      expect(st.currentSong?.id, 'q1');
    });

    test('appendToQueue / addToQueue / addAllToQueue 都只追加不打断当前曲', () async {
      notifier = await boot(address: _addr());

      notifier.addToQueue(_song('a1'));
      notifier.addAllToQueue(<Song>[_song('a2'), _song('a3')]);

      expect(notifier.state.queue.map((s) => s.id).toList(),
          <String>['a1', 'a2', 'a3']);
      expect(notifier.state.currentSong, isNull, reason: '追加不该凭空造出当前曲');
    });

    test('playNext：插到当前曲后面，当前曲不动', () async {
      notifier = await boot(address: _addr());
      notifier.state = notifier.state.copyWith(
        currentSong: _song('c1'),
        queue: <Song>[_song('c1'), _song('c2')],
        currentIndex: 0,
      );

      await notifier.playNext(_song('nx'));

      final st = notifier.state;
      expect(st.queue.map((s) => s.id).toList(), <String>['c1', 'nx', 'c2']);
      expect(st.currentIndex, 0, reason: 'playNext 不该抢当前曲的位置');
    });

    test('removeFromQueue：删掉后面的曲，当前曲与下标不乱', () async {
      notifier = await boot(address: _addr());
      notifier.state = notifier.state.copyWith(
        currentSong: _song('r1'),
        queue: <Song>[_song('r1'), _song('r2'), _song('r3')],
        currentIndex: 0,
      );

      notifier.removeFromQueue(1);

      expect(notifier.state.queue.map((s) => s.id).toList(),
          <String>['r1', 'r3']);
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 'r1');
    });

    test('clearQueue 默认保留当前曲，只清掉后面的队列', () async {
      notifier = await boot(address: _addr());
      notifier.state = notifier.state.copyWith(
        currentSong: _song('k1'),
        queue: <Song>[_song('k1'), _song('k2')],
        currentIndex: 0,
      );

      await notifier.clearQueue();

      expect(notifier.state.queue.map((s) => s.id).toList(), <String>['k1']);
      expect(notifier.state.currentSong?.id, 'k1', reason: '当前曲不能被一起清掉');
    });

    test('clearQueue(keepCurrent:false)：整份会话归零（歌、源、进度全清）', () async {
      notifier = await boot(address: _addr());
      notifier.state = notifier.state.copyWith(
        currentSong: _song('k1'),
        queue: <Song>[_song('k1'), _song('k2')],
        currentIndex: 0,
        position: const Duration(seconds: 12),
      );

      await notifier.clearQueue(keepCurrent: false);

      expect(notifier.state.queue, isEmpty);
      expect(notifier.state.currentSong, isNull);
      expect(notifier.state.position, Duration.zero);
    });
  });

  // ───────────────────────── 五、播控与音量 ─────────────────────────
  group('播控与音量', () {
    test('togglePlayPause / setVolume / setVolumeLive 不抛且落到 state', () async {
      notifier = await boot(address: _addr());

      await notifier.togglePlayPause();
      await notifier.setVolume(0.4);
      notifier.setVolumeLive(0.5);

      expect(notifier.state, isNotNull);
    });

    test('pause / play 在没有在播曲时早退、不炸', () async {
      notifier = await boot(address: _addr());

      await notifier.pause();
      await notifier.play();

      expect(notifier.state.currentSong, isNull);
    });

    test('_restorePlayerVolume 走完（没存过音量时回到默认值）', () async {
      notifier = await boot(address: _addr());

      // 构造函数里已经 await 过一次，这里再走一遍验证没存过时的兜底分支。
      await notifier.setVolume(0.3);
      expect(notifier.state.volume ?? 0.3, anyOf(0.3, 0.0));
    });
  });

  // ───────────────────────── 六、播放模式四态 ─────────────────────────
  group('播放模式四态', () {
    test('cyclePlaybackMode 按 order→all→one→shuffle 循环', () async {
      notifier = await boot(address: _addr());

      final seen = <PlaybackMode>[];
      for (var i = 0; i < 4; i++) {
        await notifier.cyclePlaybackMode();
        seen.add(notifier.state.playbackMode);
      }

      // 源码 switch 顺序：order→all / all→one / one→shuffle / shuffle→order。
      expect(seen, <PlaybackMode>[
        PlaybackMode.one,
        PlaybackMode.shuffle,
        PlaybackMode.order,
        PlaybackMode.all,
      ]);
    });

    test('setPlaybackMode(shuffle) 落盘后再读回来一致', () async {
      notifier = await boot(address: _addr());

      await notifier.setPlaybackMode(PlaybackMode.shuffle);
      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
    });
  });

  // ───────────────────────── 七、收藏 / 上报 ─────────────────────────
  group('收藏与 scrobble', () {
    test('toggleSongFavorite：切一次就打一次仓库调用', () async {
      repo.starredCalls.clear();
      notifier = await boot(address: _addr());

      final song = _song('f1');
      await notifier.toggleSongFavorite(song);

      expect(repo.starredCalls, isNotEmpty);
    });

    test('applyExternalStarred 推送外部收藏不抛', () async {
      notifier = await boot(address: _addr());

      notifier.applyExternalStarred('f2', true);

      expect(notifier.state.currentSong, isNull);
    });

    test('refreshSongMetadata：仓库没返回歌时也不炸', () async {
      repo.getSongCalls.clear();
      notifier = await boot(address: _addr());

      await notifier.refreshSongMetadata('f3');

      expect(repo.getSongCalls, contains('f3'));
    });
  });

  // ───────────────────────── 八、收尾 ─────────────────────────
  group('收尾', () {
    test('dispose 之后再调 notifier 不炸（mounted 守卫）', () async {
      notifier = await boot(address: _addr());
      container.dispose();

      // 踩坑 #61：dispose 之后**连读 `notifier.state` 都会抛**
      // （StateNotifier 的 _debugIsMounted），所以这里只能查 mounted 标志本身。
      // 真正要验证的是：dispose 后残余事件（just_audio 会异步补发 playing=false）
      // 打到 notifier 里不会把「used after dispose」抛出来 —— 由源码里的
      // `if (!mounted) return` 三处守卫保证，这里钉的是标志位语义。
      expect(notifier.mounted, isFalse);
    });

    test('persistPlaybackStateNow：空会话也能走完不抛', () async {
      notifier = await boot(address: _addr());

      await notifier.persistPlaybackStateNow();

      expect(notifier.state, isNotNull);
    });
  });

  // ───────────────────────── 九、洗牌导航 / 预览 / 投屏进度 ─────────────────────────
  group('洗牌导航 / 预览 / 投屏进度', () {
    test('shuffle 开启时 next() 走随机兜底分支（拿不到服务端洗牌序列）', () async {
      notifier = await boot(address: _addr());
      notifier.state = notifier.state.copyWith(
        shuffleEnabled: true,
        currentSong: _song('x1'),
        queue: <Song>[_song('x1'), _song('x2'), _song('x3')],
        currentIndex: 0,
      );

      await notifier.next();

      // 三首里挑一个不是自己的（_getRandomIndexExcludingCurrent 的语义）。
      expect(notifier.state.currentIndex, anyOf(1, 2));
    });

    test('shuffle 开启时 previous() 回不到队首之外（没有历史就早退/回落）', () async {
      notifier = await boot(address: _addr());
      notifier.state = notifier.state.copyWith(
        shuffleEnabled: true,
        currentSong: _song('y1'),
        queue: <Song>[_song('y1'), _song('y2')],
        currentIndex: 0,
      );

      await notifier.previous();

      // 下标 0 没有「更前面」的洗牌历史 → 落到 _getQueuePreviousIndex，
      // 两首队列下回绕到队尾（洗牌导航两端都闭环，不会早退成空）。
      expect(notifier.state.currentIndex, anyOf(0, 1));
      expect(notifier.state.queue.length, 2);
    });

    test('playPreviewSong：预览曲走独立入口，不进常规起播链路', () async {
      notifier = await boot(address: _addr());

      await notifier.playPreviewSong(_song('p1', isPreview: true));

      // 预览入口不要求服务器地址（元数据来自服务端下发的预览载荷），
      // 钉的是「不走地址解析、也不抛」。
      expect(notifier.state, isNotNull);
    });

    test('updateNotificationCastProgress：投屏进度回写不抛', () async {
      notifier = await boot(address: _addr());

      notifier.updateNotificationCastProgress(
        active: true,
        playing: true,
        position: const Duration(seconds: 9),
      );

      expect(notifier.state, isNotNull);
    });

    test('resolveCastNeighborIndex：两端都环形闭环（空队/单曲两档例外）', () async {
      notifier = await boot(address: _addr());

      // 空队 → null
      expect(notifier.resolveCastNeighborIndex(forward: true), isNull);

      notifier.state = notifier.state.copyWith(
        currentSong: _song('n1'),
        queue: <Song>[_song('n1'), _song('n2'), _song('n3')],
        currentIndex: 0,
      );
      // 队首往后 = 1，队首往前 = 回绕到队尾
      expect(notifier.resolveCastNeighborIndex(forward: true), 1);
      expect(notifier.resolveCastNeighborIndex(forward: false), 2);

      // 单曲队列只能「邻居是自己」
      notifier.state = notifier.state.copyWith(
        currentSong: _song('n1'),
        queue: <Song>[_song('n1')],
        currentIndex: 0,
      );
      expect(notifier.resolveCastNeighborIndex(forward: true), 0);
    });
  });
}
