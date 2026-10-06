// batch35 C 路 —— `lib/features/search/widgets/search_result_card.dart` 补测。
//
// 已有 search_result_card_coverage_gap_test.dart 覆盖「渲染 + 本地回调」；
// 本文件补 SearchResultList 各类目回调链（playRemoteSearchCollection /
// playRemoteSearchSong / importSearch*）与紧凑布局分支：
//   * song 行：点播放 → playPreviewSong（buildRemoteSong 转换）；
//   * song 行：点加库 → importSong 提交 + 后台 waitTask 完成出 toast；
//   * song 行：加库/播放失败 → 错误 toast；仓库为 null → 直接返回；
//   * album/artist/playlist 卡播放 → getCollectionSongs/getPlaylistSongs →
//     playEffectiveQueue → playerProvider.playQueue；
//   * 专辑卡加库 → importAlbum；
//   * providerId 为空 → 「未指定来源」错误 toast；
//   * 播放集合空结果 → 「无可播放」提示；
//   * compact 窗口 → 三列 GridView.count 分支；
//   * 歌曲封面非空 → _thumb/CoverArtImage 缩略图分支（地址桩 + 尾部卸载）。
//
// 踩坑记录：
// #S1 SearchRepository 是具体类（构造只收 SubsonicApiClient），桩用 extends +
//     super(SubsonicApiClient(dio: Dio()))，只 override 需要的方法。
// #S2 入库成功 toast 走 ToastNotifier → rootNavigatorKey，测试树必须
//     MaterialApp(navigatorKey: rootNavigatorKey)。
// #S3 waitTask 后台链路靠 pump 推 microtask/定时器推进。
// #S4 _thumb 会创建 CoverArtImage 真封面链：地址 override + 尾部卸载组件树，
//     避免 pending Timer 挂用例。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remixicon/remixicon.dart';

import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<String> previewSongs = <String>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
    state = state.copyWith(
      queue: songs,
      currentIndex: startIndex,
      currentSong: songs.isEmpty ? null : songs[startIndex],
    );
  }

  @override
  Future<void> playPreviewSong(Song song) async {
    previewSongs.add(song.id);
  }
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _StubSearchRepository extends SearchRepository {
  _StubSearchRepository() : super(SubsonicApiClient(dio: Dio()));

  Object? buildRemoteSongError;
  Object? importSongError;
  final List<String> importedSongIds = <String>[];
  final List<String> importedAlbumIds = <String>[];
  final List<(SearchEntityKind, String)> collectionCalls = <(SearchEntityKind, String)>[];
  final List<String> playlistSongCalls = <String>[];
  List<Song> collectionSongs = <Song>[
    Song(id: 'remote-s1', title: '远程歌一'),
  ];

  @override
  Song buildRemoteSong(SearchSong s) {
    if (buildRemoteSongError != null) throw buildRemoteSongError!;
    return Song(id: 'remote:${s.id}', title: s.name, isPreview: true);
  }

  @override
  Future<List<Song>> getCollectionSongs(
    SearchEntityKind kind,
    String providerId,
    SearchSongLike item,
  ) async {
    collectionCalls.add((kind, providerId));
    return collectionSongs;
  }

  @override
  Future<List<Song>> getPlaylistSongs(
    String providerId,
    SearchPlaylist pl,
  ) async {
    playlistSongCalls.add(providerId);
    return collectionSongs;
  }

  @override
  Future<String> importSong(String providerId, List<SearchSong> songs) async {
    if (importSongError != null) throw importSongError!;
    importedSongIds.add(songs.first.id);
    return 'task-song-1';
  }

  @override
  Future<String> importAlbum(String providerId, SearchAlbum album) async {
    importedAlbumIds.add(album.id);
    return 'task-album-1';
  }

  @override
  Future<Map<String, dynamic>> waitTask(String taskId,
      {int maxAttempts = 375, Duration interval = const Duration(milliseconds: 800)}) async {
    return <String, dynamic>{'success': true};
  }
}

SearchSong _song(String id, String name) => SearchSong(
      id: id,
      name: name,
      artist: '测试艺人',
      album: '测试专辑',
      duration: 180,
      source: 'netease',
      providerId: 'pv1',
    );

SearchAlbum _album(String id, String name, {String providerId = 'pv1'}) =>
    SearchAlbum(
      id: id,
      name: name,
      artist: '测试艺人',
      trackCount: '10',
      isLocal: false,
      providerId: providerId,
    );

SearchArtist _artist(String id, String name) => SearchArtist(
      id: id,
      name: name,
      isLocal: false,
      providerId: 'pv1',
    );

SearchPlaylist _playlist(String id, String name) => SearchPlaylist(
      id: id,
      name: name,
      trackCount: '12',
      isLocal: false,
      providerId: 'pv1',
    );

late AppLocalizations loc;

Widget _build(
  WidgetTester tester,
  Widget child, {
  _StubSearchRepository? searchRepository,
  _RecordingPlayer? player,
  Size size = const Size(900, 900),
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final library = MusicLibrary(
    id: 'lib-1',
    name: '测试库',
    createdAt: DateTime(2026, 10, 1),
    updatedAt: DateTime(2026, 10, 1),
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  final container = ProviderContainer(
    overrides: <Override>[
      subsonicApiClientProvider.overrideWithValue(client),
      activeLibraryProvider.overrideWithValue(library),
      activeAddressProvider.overrideWith(
        (ref) => ServerAddress(
          id: 'addr',
          libraryId: 'lib-1',
          label: '测试',
          url: 'http://127.0.0.1:4533',
          priority: 0,
          status: ServerAddressStatus.unknown,
        ),
      ),
      // 为 null 时显式 override 为 null，避免落回真实 SearchRepository。
      searchRepositoryProvider.overrideWithValue(searchRepository),
      playerProvider.overrideWith((ref) => player ?? _RecordingPlayer()),
      castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: rootNavigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: MusicFlowTapAnchorScope(
        child: Scaffold(body: child),
      ),
    ),
  );
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('歌曲行回调链', () {
    testWidgets('点播放 → buildRemoteSong → playPreviewSong', (tester) async {
      final repo = _StubSearchRepository();
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(songs: <SearchSong>[_song('s1', '歌曲一')]),
          ),
          searchRepository: repo,
          player: player,
        ),
      );
      await settle(tester);

      // 歌曲行的第一个图标按钮是「播放」。
      await tester.tap(find.byIcon(Remix.play_circle_line).first);
      await settle(tester);

      expect(player.previewSongs, <String>['remote:s1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点加库 → importSong 提交，后台任务完成弹出成功 toast', (tester) async {
      final repo = _StubSearchRepository();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(songs: <SearchSong>[_song('s2', '歌曲二')]),
          ),
          searchRepository: repo,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.add_circle_line).first);
      await settle(tester);

      expect(repo.importedSongIds, <String>['s2']);
      // waitTask 立即完成 → 完成通知 toast 出现（song name 作为 label）。
      await settle(tester, frames: 10);
      expect(find.textContaining('歌曲二'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加库提交失败 → 弹错误 toast 不崩溃', (tester) async {
      final repo = _StubSearchRepository()..importSongError = StateError('down');
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(songs: <SearchSong>[_song('s3', '歌曲三')]),
          ),
          searchRepository: repo,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.add_circle_line).first);
      await settle(tester);

      expect(repo.importedSongIds, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('buildRemoteSong 抛错 → 弹播放失败 toast 不崩溃', (tester) async {
      final repo = _StubSearchRepository()
        ..buildRemoteSongError = StateError('bad song');
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(songs: <SearchSong>[_song('s4', '歌曲四')]),
          ),
          searchRepository: repo,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_line).first);
      await settle(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索仓库为 null：点播放/加库直接返回无异常', (tester) async {
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(songs: <SearchSong>[_song('s5', '歌曲五')]),
          ),
          player: player,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_line).first);
      await tester.tap(find.byIcon(Remix.add_circle_line).first);
      await settle(tester);

      expect(player.previewSongs, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('集合卡回调链', () {
    testWidgets('专辑卡播放 → getCollectionSongs(album) → playQueue', (tester) async {
      final repo = _StubSearchRepository();
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.album,
            outcome: SearchOutcome(albums: <SearchAlbum>[_album('a1', '专辑一')]),
          ),
          searchRepository: repo,
          player: player,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_fill).first);
      await settle(tester);

      expect(
        repo.collectionCalls,
        contains((SearchEntityKind.album, 'pv1')),
      );
      expect(player.playQueueCalls, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('专辑卡播放集合为空 → 提示无可播放', (tester) async {
      final repo = _StubSearchRepository()..collectionSongs = const <Song>[];
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.album,
            outcome: SearchOutcome(albums: <SearchAlbum>[_album('a2', '专辑二')]),
          ),
          searchRepository: repo,
          player: player,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_fill).first);
      await settle(tester);

      expect(player.playQueueCalls, isEmpty, reason: '空集合不应发起播放');
      expect(tester.takeException(), isNull);
    });

    testWidgets('专辑卡加库 → importAlbum 被调用', (tester) async {
      final repo = _StubSearchRepository();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.album,
            outcome: SearchOutcome(albums: <SearchAlbum>[_album('a3', '专辑三')]),
          ),
          searchRepository: repo,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.add_circle_line).first);
      await settle(tester);

      expect(repo.importedAlbumIds, <String>['a3']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('艺人卡播放 → getCollectionSongs(artist) 按名称拉取', (tester) async {
      final repo = _StubSearchRepository();
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.artist,
            outcome: SearchOutcome(artists: <SearchArtist>[_artist('ar1', '艺人一')]),
          ),
          searchRepository: repo,
          player: player,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_fill).first);
      await settle(tester);

      expect(
        repo.collectionCalls,
        contains((SearchEntityKind.artist, 'pv1')),
      );
      expect(player.playQueueCalls, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌单卡播放 → getPlaylistSongs（显式传 playlist，不依赖强转）', (tester) async {
      final repo = _StubSearchRepository();
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.playlist,
            outcome: SearchOutcome(playlists: <SearchPlaylist>[_playlist('p1', '歌单一')]),
          ),
          searchRepository: repo,
          player: player,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_fill).first);
      await settle(tester);

      expect(repo.playlistSongCalls, <String>['pv1']);
      expect(player.playQueueCalls, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('providerId 为空 → 弹「未指定来源」提示且不发起请求', (tester) async {
      final repo = _StubSearchRepository();
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.album,
            outcome: SearchOutcome(
              albums: <SearchAlbum>[_album('a4', '专辑四', providerId: '')],
            ),
          ),
          searchRepository: repo,
          player: player,
        ),
      );
      await settle(tester);

      await tester.tap(find.byIcon(Remix.play_circle_fill).first);
      await settle(tester);

      expect(repo.collectionCalls, isEmpty);
      expect(player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('布局分支', () {
    testWidgets('compact 窗口：三列 GridView.count', (tester) async {
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.album,
            outcome: SearchOutcome(
              albums: <SearchAlbum>[_album('a1', '专辑一'), _album('a2', '专辑二')],
            ),
          ),
          size: const Size(500, 900),
        ),
      );
      await settle(tester);

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        grid.gridDelegate,
        isA<SliverGridDelegateWithFixedCrossAxisCount>()
            .having((d) => d.crossAxisCount, '列数', 3),
        reason: 'compact 窗口应走固定三列网格',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanded 窗口：自适应 MaxCrossAxisExtent 网格', (tester) async {
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.playlist,
            outcome: SearchOutcome(
              playlists: <SearchPlaylist>[_playlist('p1', '歌单一')],
            ),
          ),
        ),
      );
      await settle(tester);

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.gridDelegate, isA<SliverGridDelegateWithMaxCrossAxisExtent>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌曲封面非空 → 渲染 CoverArtImage 缩略图', (tester) async {
      await tester.pumpWidget(
        _build(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(songs: <SearchSong>[
              SearchSong(
                id: 's9',
                name: '封面歌',
                artist: '测试艺人',
                cover: 'cov-1',
                providerId: 'pv1',
                source: 'netease',
              ),
            ]),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(CoverArtImage), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 尾部卸载，避免封面链路 pending Timer 挂用例。
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });
  });
}
