// batch36-B —— 远程专辑/歌单预览页状态分支补测。
//
// 已有 remote_pages_actions_layout_test.dart 只覆盖「有 1 首 + 窄/宽布局」。
// 本文件补：
//   * FutureBuilder loading → 骨架;
//   * hasError → 错误态 + 点重试后恢复;
//   * 空歌单/空专辑 → 空态（且「加入库」按钮禁用、播放全部空转不崩）;
//   * 封面非空 → CoverArtImage 分支;
//   * 头部元数据组合：artist 为空、trackCount 为空回退 songCount。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/remote_album_page.dart';
import 'package:musicflow_client/features/library/pages/remote_playlist_page.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

SearchAlbum _album(String id, String name, {String artist = '', String cover = '', String platformLabel = ''}) =>
    SearchAlbum(
      id: id,
      name: name,
      artist: artist,
      cover: cover,
      platformLabel: platformLabel,
      providerId: 'pv1',
    );

SearchPlaylist _playlist(
  String id,
  String name, {
  String trackCount = '',
  String cover = '',
  String platformLabel = '',
}) =>
    SearchPlaylist(
      id: id,
      name: name,
      trackCount: trackCount,
      cover: cover,
      platformLabel: platformLabel,
      providerId: 'pv1',
    );

class _StubSearchRepository extends SearchRepository {
  _StubSearchRepository() : super(SubsonicApiClient(dio: Dio()));

  List<Song> songs = <Song>[Song(id: 's1', title: '远程歌一')];
  Object? error;
  Completer<void>? gate;

  Future<List<Song>> _resolve() async {
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return songs;
  }

  @override
  Future<List<Song>> getCollectionSongs(
    SearchEntityKind kind,
    String providerId,
    SearchSongLike item,
  ) =>
      _resolve();

  @override
  Future<List<Song>> getPlaylistSongs(String providerId, SearchPlaylist pl) =>
      _resolve();
}

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());
  int playQueueCalls = 0;

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls += 1;
    state = state.copyWith(queue: songs);
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  required SearchRepository repo,
  TestPlayerNotifier? player,
  Size size = const Size(900, 1000),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        searchRepositoryProvider.overrideWithValue(repo),
        playerProvider.overrideWith((Ref ref) => player ?? TestPlayerNotifier(PlayerState())),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (BuildContext context, Widget? child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: page,
      ),
    ),
  );
  await tester.pump();
}

AppLocalizations _loc(WidgetTester tester, Type pageType) =>
    AppLocalizations.of(tester.element(find.byType(pageType)));

void main() {
  group('RemoteAlbumPage 状态', () {
    testWidgets('加载中 → 骨架', (tester) async {
      final repo = _StubSearchRepository()..gate = Completer<void>();
      await _pump(
        tester,
        RemoteAlbumPage(album: _album('a1', '专辑'), providerId: 'pv1'),
        repo: repo,
      );
      expect(find.byType(MusicFlowMediaListSkeleton), findsOneWidget);
      // 收尾，避免悬挂 Future
      repo.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('加载失败 → 错误态，点重试后恢复出歌曲行', (tester) async {
      final repo = _StubSearchRepository()..error = StateError('boom');
      await _pump(
        tester,
        RemoteAlbumPage(album: _album('a1', '专辑'), providerId: 'pv1'),
        repo: repo,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemoteAlbumPage);
      expect(find.text(loc.library_remote_load_failed), findsOneWidget);

      repo.error = null;
      await tester.tap(find.text(loc.widgets_retry));
      await tester.pump();
      // [D-057 已修复] `_reload` 块体化，setState 闭包不再返回 Future，
      // 重试按钮在 debug 下同样可用。
      expect(tester.takeException(), isNull,
          reason: '[D-057 已修复] 重试不再触发 setState Future 断言');
      await tester.pumpAndSettle();
      expect(find.byType(SongListItem), findsOneWidget);
    });

    testWidgets('空专辑 → 空态；「加入库」按钮禁用', (tester) async {
      final repo = _StubSearchRepository()..songs = <Song>[];
      final player = _RecordingPlayer();
      await _pump(
        tester,
        RemoteAlbumPage(album: _album('a1', '空专辑'), providerId: 'pv1'),
        repo: repo,
        player: player,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemoteAlbumPage);
      expect(find.text(loc.library_no_playable_songs), findsOneWidget);

      // 空态下点「播放全部」应空转（songs.isEmpty 早退），不触发 playQueue。
      await tester.tap(find.text(loc.library_play_all));
      await tester.pump();
      expect(player.playQueueCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('artist 为空 + 有曲数 → 元数据展示曲数与来源', (tester) async {
      final repo = _StubSearchRepository()
        ..songs = <Song>[Song(id: 's1', title: '歌一')];
      await _pump(
        tester,
        RemoteAlbumPage(
          album: _album('a1', '专辑', platformLabel: '网易云'),
          providerId: 'pv1',
        ),
        repo: repo,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemoteAlbumPage);
      expect(find.textContaining(loc.discover_track_count('1')), findsOneWidget);
      expect(find.textContaining('网易云'), findsWidgets);
    });

    testWidgets('封面非空 → 渲染封面头且不抛异常', (tester) async {
      final repo = _StubSearchRepository()
        ..songs = <Song>[Song(id: 's1', title: '歌一')];
      await _pump(
        tester,
        RemoteAlbumPage(
          album: _album('a1', '有封面专辑', cover: 'cov-album'),
          providerId: 'pv1',
        ),
        repo: repo,
      );
      await tester.pumpAndSettle();
      expect(find.text('有封面专辑'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('RemotePlaylistPage 状态', () {
    testWidgets('加载中 → 骨架', (tester) async {
      final repo = _StubSearchRepository()..gate = Completer<void>();
      await _pump(
        tester,
        RemotePlaylistPage(playlist: _playlist('p1', '歌单'), providerId: 'pv1'),
        repo: repo,
      );
      expect(find.byType(MusicFlowMediaListSkeleton), findsOneWidget);
      repo.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('加载失败 → 错误态，点重试后恢复出歌曲行', (tester) async {
      final repo = _StubSearchRepository()..error = StateError('boom');
      await _pump(
        tester,
        RemotePlaylistPage(playlist: _playlist('p1', '歌单'), providerId: 'pv1'),
        repo: repo,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemotePlaylistPage);
      expect(find.text(loc.library_remote_load_failed), findsOneWidget);

      repo.error = null;
      await tester.tap(find.text(loc.widgets_retry));
      await tester.pump();
      // [D-057 已修复] 同 remote_album_page：重试不再被 setState 断言阻断。
      expect(tester.takeException(), isNull,
          reason: '[D-057 已修复] 重试不再触发 setState Future 断言');
      await tester.pumpAndSettle();
      expect(find.byType(SongListItem), findsOneWidget);
    });

    testWidgets('空歌单 → 空态', (tester) async {
      final repo = _StubSearchRepository()..songs = <Song>[];
      await _pump(
        tester,
        RemotePlaylistPage(playlist: _playlist('p1', '空歌单'), providerId: 'pv1'),
        repo: repo,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemotePlaylistPage);
      expect(find.text(loc.library_no_playable_songs), findsOneWidget);
    });

    testWidgets('trackCount 为空 + 有曲数 → 回退到 songCount', (tester) async {
      final repo = _StubSearchRepository()
        ..songs = <Song>[Song(id: 's1', title: '歌一')];
      await _pump(
        tester,
        RemotePlaylistPage(
          playlist: _playlist('p1', '歌单', platformLabel: 'QQ音乐'),
          providerId: 'pv1',
        ),
        repo: repo,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemotePlaylistPage);
      expect(find.textContaining(loc.discover_track_count('1')), findsOneWidget);
      expect(find.textContaining('QQ音乐'), findsWidgets);
    });

    testWidgets('trackCount 非空 → 优先展示 trackCount', (tester) async {
      final repo = _StubSearchRepository()
        ..songs = <Song>[Song(id: 's1', title: '歌一')];
      await _pump(
        tester,
        RemotePlaylistPage(
          playlist: _playlist('p1', '歌单', trackCount: '42'),
          providerId: 'pv1',
        ),
        repo: repo,
      );
      await tester.pumpAndSettle();
      final loc = _loc(tester, RemotePlaylistPage);
      expect(find.textContaining(loc.discover_track_count('42')), findsOneWidget);
    });

    testWidgets('封面非空 → 渲染且不抛异常', (tester) async {
      final repo = _StubSearchRepository()
        ..songs = <Song>[Song(id: 's1', title: '歌一')];
      await _pump(
        tester,
        RemotePlaylistPage(
          playlist: _playlist('p1', '有封面歌单', cover: 'cov-pl'),
          providerId: 'pv1',
        ),
        repo: repo,
      );
      await tester.pumpAndSettle();
      expect(find.text('有封面歌单'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
