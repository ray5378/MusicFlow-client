// batch33 C 路 —— `lib/features/settings/pages/offline_cached_songs_page.dart` 补测。
//
// 基线覆盖率 22.47%。页面依赖：
//   * `offlineCacheReadyProvider`（FutureProvider<void>）→ 覆盖成立即可完成
//     （pending 用 Completer 卡住可测加载态）；
//   * `offlineCacheManagerProvider` → FakeCacheManager extends
//     OfflineCacheManager，override init()/cachedSongs（不碰真实文件系统）；
//   * `playerProvider` → RecordingPlayer（TestPlayerNotifier 显式实现
//     playQueue，playEffectiveQueue 本机路径走 notifier.playQueue）；
//   * `castPeerControllerProvider` / `dlnaCastProvider` → 无投屏桩
//     （playEffectiveQueue 读两者判定路由）。
// 推帧一律有界 pump，不用 pumpAndSettle。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

const Size kView = Size(520, 1200);

final ServerAddress kAddress = ServerAddress(
  id: 'addr1',
  libraryId: 'lib1',
  label: 'Home',
  url: 'http://127.0.0.1:4533',
  priority: 0,
);

final List<CachedSongInfo> kCached = <CachedSongInfo>[
  CachedSongInfo(
    songId: 's1',
    title: '缓存曲目一',
    artist: '艺术家甲',
    album: '专辑一',
    durationSeconds: 180,
    coverArt: null,
    size: 512 * 1024, // 512 KB
  ),
  CachedSongInfo(
    songId: 's2',
    title: '缓存曲目二',
    artist: '',
    album: null,
    durationSeconds: null,
    coverArt: null,
    size: 1536 * 1024, // 1.5 MB
  ),
];

List<Song> songsOf(List<CachedSongInfo> infos) => <Song>[
      for (final info in infos)
        Song(
          id: info.songId,
          title: info.title,
          artist: info.artist.isEmpty ? null : info.artist,
          album: info.album,
          coverArt: info.coverArt,
          duration: info.durationSeconds,
          starred: false,
        ),
    ];

/// 离线缓存桩：init 空操作，cachedSongs 直接吐内存列表。
class FakeCacheManager extends OfflineCacheManager {
  FakeCacheManager(this.songs);

  final List<CachedSongInfo> songs;
  int readCount = 0;

  @override
  Future<void> init() async {}

  @override
  List<CachedSongInfo> get cachedSongs {
    readCount += 1;
    return songs;
  }
}

/// 播放器桩：显式实现 playQueue（TestPlayerNotifier 的 noSuchMethod 会静默吞）。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<int> startIndices = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
    startIndices.add(startIndex);
    state = state.copyWith(
      queue: songs,
      currentIndex: startIndex,
      currentSong: songs.isEmpty ? null : songs[startIndex.clamp(0, songs.length - 1)],
    );
  }
}

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

class _PageHarness {
  _PageHarness({List<CachedSongInfo>? songs, this.holdReady = false})
      : cache = FakeCacheManager(songs ?? kCached),
        player = RecordingPlayer() {
    if (holdReady) {
      readyCompleter = Completer<void>();
    }
  }

  final FakeCacheManager cache;
  final RecordingPlayer player;
  final bool holdReady;
  Completer<void>? readyCompleter;

  ProviderContainer? container;
  AppLocalizations? loc;

  Widget build() {
    final Completer<void>? pending = readyCompleter;
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          offlineCacheReadyProvider.overrideWith((Ref ref) {
            if (pending != null) return pending.future;
            return Future<void>.value();
          }),
          offlineCacheManagerProvider.overrideWithValue(cache),
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => StubCastPeer(ref),
          ),
          dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
        ],
      ),
      child: MediaQuery(
        data: const MediaQueryData(size: kView, devicePixelRatio: 1),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(body: OfflineCachedSongsPage()),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester, {int frames = 8}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    loc = AppLocalizations.of(
      tester.element(find.byType(OfflineCachedSongsPage)),
    );
  }
}

Finder playAllButton(AppLocalizations loc) => find.text(loc.library_play_all);

void main() {
  group('offline_cached_songs_page · 加载与空态', () {
    testWidgets('缓存未就绪 → 加载圈占位', (WidgetTester tester) async {
      final h = _PageHarness(holdReady: true);
      await h.pump(tester, frames: 3);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(MusicFlowSongRow), findsNothing);

      // 放行就绪 → 列表渲染。
      h.readyCompleter!.complete();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(MusicFlowSongRow), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('空缓存 → 空态文案，无播放全部按钮', (WidgetTester tester) async {
      final loc = AppLocalizations.of; // 占位避免 lint
      final h = _PageHarness(songs: const <CachedSongInfo>[]);
      await h.pump(tester);

      expect(find.text(h.loc!.offline_cache_cached_songs_empty), findsOneWidget);
      expect(playAllButton(h.loc!), findsNothing);
      expect(tester.takeException(), isNull);
      expect(loc, isNotNull);
    });
  });

  group('offline_cached_songs_page · 列表与播放', () {
    testWidgets('有数据 → 行渲染 + 头部计数 + 顶栏副标题(KB)', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      expect(find.text(h.loc!.offline_cache_song_count(2)), findsOneWidget);
      expect(find.text(h.loc!.library_play_all), findsOneWidget);
      // 总 2048KB < 1MB → 副标题按 KB 显示（含 ' KB'）。
      expect(find.textContaining(' MB'), findsWidgets);
      expect(find.text('缓存曲目一'), findsOneWidget);
      expect(find.text('缓存曲目二'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点行 → 以缓存列表为队列从对应 index 起播', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      await tester.tap(find.text('缓存曲目二'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(h.player.startIndices, <int>[1], reason: '点哪首播哪首');
      expect(tester.takeException(), isNull);
    });

    testWidgets('点播放全部 → 全队列从头起播', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      await tester.tap(playAllButton(h.loc!));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(h.player.startIndices, <int>[0]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('当前播放行高亮：playerProvider 发射 currentSong → 行 isCurrent', (
      WidgetTester tester,
    ) async {
      final h = _PageHarness();
      await h.pump(tester);

      h.player.emit(
        h.player.state.copyWith(currentSong: songsOf(kCached)[1]),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));

      final rows = tester
          .widgetList<MusicFlowSongRow>(find.byType(MusicFlowSongRow))
          .toList();
      expect(rows[0].isCurrent, isFalse);
      expect(rows[1].isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切歌触发后台缓存刷新：playerProvider 变化 → 重读 cache', (
      WidgetTester tester,
    ) async {
      final h = _PageHarness();
      await h.pump(tester);
      final readsBefore = h.cache.readCount;

      h.player.emit(
        h.player.state.copyWith(
          currentSong: songsOf(kCached)[0],
        ),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        h.cache.readCount,
        greaterThan(readsBefore),
        reason: 'listenManual 监听 currentSong 变化触发 _reload',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
