import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:musicflow_client/providers/search_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/test_player_notifier.dart';

typedef _NetworkHandler = Future<SearchOutcome> Function(SearchRequest req);

/// 范围浮层里的行(RichText 带「全部内容」等说明),pill 上没有这些说明,
/// 以此区分浮层与常驻 pill。
Finder _overlayRow(String description) =>
    find.textContaining(description, findRichText: true);

/// 发现页(热门/历史)列表里的条目,与输入框的 EditableText 区分开。
Finder _discoveryEntry(String text) => find.descendant(
      of: find.byKey(const ValueKey<String>('search_discovery')),
      matching: find.text(text),
    );

void main() {
  final songs = <Song>[
    Song(
      id: 'song-1',
      title: '晨光序曲',
      artist: '甲歌手',
      album: '清晨航线',
      duration: 204,
    ),
    Song(
      id: 'song-2',
      title: '长标题歌曲用于验证结果行布局不溢出',
      artist: '乙歌手',
      album: '夜航',
      duration: 201,
    ),
  ];
  final album = Album(
    id: 'album-1',
    name: '夜航与长标题现场专辑',
    artist: '乙歌手',
    songCount: 12,
    duration: 2840,
  );
  final artist = Artist(id: 'artist-1', name: '丙歌手乐团', albumCount: 2);
  final playlist = Playlist(
    id: 'playlist-1',
    name: '歌单样本集',
    songCount: 8,
    duration: 1600,
  );

  Override networkOverride(List<SearchRequest> requests, [_NetworkHandler? handler]) =>
      searchResultsProvider.overrideWith((ref, req) async {
        requests.add(req);
        return handler == null ? SearchOutcome() : await handler(req);
      });

  List<Override> localOverrides({
    List<Song> resultSongs = const <Song>[],
    List<Album> resultAlbums = const <Album>[],
    List<Artist> resultArtists = const <Artist>[],
    List<Playlist> resultPlaylists = const <Playlist>[],
  }) =>
      <Override>[
        localSongSearchProvider.overrideWith(
          (ref, query) async =>
              (items: resultSongs, total: resultSongs.length),
        ),
        localAlbumSearchProvider.overrideWith(
          (ref, query) async =>
              (items: resultAlbums, total: resultAlbums.length),
        ),
        localArtistSearchProvider.overrideWith(
          (ref, query) async =>
              (items: resultArtists, total: resultArtists.length),
        ),
        localPlaylistSearchProvider.overrideWith(
          (ref, query) async =>
              (items: resultPlaylists, total: resultPlaylists.length),
        ),
      ];

  Future<void> pumpSearchPage(
    WidgetTester tester, {
    required _RecordingPlayerNotifier player,
    List<Override> overrides = const <Override>[],
    Size size = const Size(430, 900),
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith((ref) => player),
          // 热门词固定,避免测试环境触碰收藏/网络链路。
          hotSearchTermsProvider.overrideWith((ref) async => <String>[]),
          ...overrides,
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const SearchPage(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> submitQuery(WidgetTester tester, String query) async {
    final textField = find.byType(TextField);
    await tester.enterText(textField, query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
  }

  /// 点范围面板外的空白处(发现页列表底部)收起浮层,
  /// 让位给下方的热门搜索/搜索历史。
  Future<void> dismissScopePanel(WidgetTester tester) async {
    await tester.tapAt(const Offset(215, 700));
    await tester.pump();
    expect(_overlayRow('全部内容'), findsNothing);
  }

  testWidgets('进入默认态:输入框聚焦、范围浮层浮出且五档齐全', (tester) async {
    await pumpSearchPage(
      tester,
      player: _RecordingPlayerNotifier(PlayerState()),
    );

    final textField = find.byType(TextField);
    expect(tester.widget<TextField>(textField).focusNode!.hasFocus, isTrue);
    // 浮层浮出:五档范围 + 各自行内说明可见。
    expect(_overlayRow('全部内容'), findsOneWidget);
    expect(_overlayRow('仅歌单'), findsOneWidget);
    expect(_overlayRow('即歌曲'), findsOneWidget);
    expect(_overlayRow('歌手'), findsOneWidget);
    // 「专辑」的说明与标签同字,行内容为「专辑  专辑」,用整行精确匹配。
    expect(find.text('专辑  专辑', findRichText: true), findsOneWidget);
    // 无热门词/无历史时,对应区块隐藏。
    expect(find.text('热门搜索'), findsNothing);
    expect(find.text('搜索历史'), findsNothing);
  });

  testWidgets('方案A:浮层浮出时可直接打字,输入后收起浮层并防抖提交', (tester) async {
    final requests = <SearchRequest>[];
    await pumpSearchPage(
      tester,
      player: _RecordingPlayerNotifier(PlayerState()),
      overrides: <Override>[
        networkOverride(requests),
        ...localOverrides(),
      ],
    );

    final textField = find.byType(TextField);

    // 空白提交不搜索(浮层收起,点回空输入框重新浮出)。
    await tester.enterText(textField, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(requests, isEmpty);
    expect(_overlayRow('全部内容'), findsNothing);
    await tester.tap(textField);
    await tester.pump();
    expect(_overlayRow('全部内容'), findsOneWidget);

    // 一旦输入关键词,浮层收起让位给结果(输入框仍可继续输入)。
    await tester.enterText(textField, '晨光');
    await tester.pump();
    expect(_overlayRow('全部内容'), findsNothing);

    // 防抖 450ms:未到时间不提交。
    await tester.pump(const Duration(milliseconds: 400));
    expect(requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    // 「所有」档对四个类目各发一次聚合搜索,按关键词去重比较。
    expect(requests.map((r) => r.query).toSet(), <String>{'晨光'});

    // 空词重复提交被忽略(仍只有首批 4 条类目请求)。
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(requests, hasLength(4));
  });

  testWidgets('范围选择:点「歌单」收起浮层,且后续搜索只查歌单一类', (tester) async {
    final requests = <SearchRequest>[];
    await pumpSearchPage(
      tester,
      player: _RecordingPlayerNotifier(PlayerState()),
      overrides: <Override>[
        networkOverride(requests),
        ...localOverrides(),
      ],
    );

    await tester.tap(_overlayRow('仅歌单'));
    await tester.pump();
    expect(_overlayRow('全部内容'), findsNothing);

    await submitQuery(tester, '夜航');
    expect(requests, isNotEmpty);
    expect(
      requests.every((r) => r.kind == SearchEntityKind.playlist),
      isTrue,
    );
  });

  testWidgets('热门搜索与搜索历史:点词即搜、记录去重置顶、单删与清空', (tester) async {
    final requests = <SearchRequest>[];
    await pumpSearchPage(
      tester,
      player: _RecordingPlayerNotifier(PlayerState()),
      overrides: <Override>[
        networkOverride(requests),
        ...localOverrides(),
        hotSearchTermsProvider.overrideWith(
          (ref) async => <String>['热门词甲'],
        ),
      ],
    );

    // 浮层(下拉面板)浮出时点掉它,露出热门搜索。
    await dismissScopePanel(tester);

    // 点热门词直接搜索(「所有」档按四个类目各发一次,按关键词去重比较)。
    await tester.tap(find.text('热门词甲'));
    await tester.pump();
    expect(requests.map((r) => r.query).toSet(), <String>{'热门词甲'});

    // 搜索后清空关键词 → 回到发现页并出现历史(浮层重新浮出,先点掉)。
    await submitQuery(tester, '晨光');
    await tester.tap(find.bySemanticsLabel('清空搜索'));
    await tester.pump();
    await dismissScopePanel(tester);
    expect(_discoveryEntry('晨光'), findsOneWidget);

    // 同词再次搜索只保留一条(去重)。
    await submitQuery(tester, '晨光');
    await tester.tap(find.bySemanticsLabel('清空搜索'));
    await tester.pump();
    await dismissScopePanel(tester);
    expect(_discoveryEntry('晨光'), findsOneWidget);

    // 再搜一个新词:最近搜索排在前面。
    await submitQuery(tester, '夜航');
    await tester.tap(find.bySemanticsLabel('清空搜索'));
    await tester.pump();
    await dismissScopePanel(tester);
    expect(_discoveryEntry('夜航'), findsOneWidget);
    final topNight = tester.getTopLeft(_discoveryEntry('夜航')).dy;
    final topMorning = tester.getTopLeft(_discoveryEntry('晨光')).dy;
    expect(topNight, lessThan(topMorning));

    // 历史已持久化到本地存储。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('search_history_v1'), isNotNull);

    // 单条删除。
    await tester.tap(find.bySemanticsLabel('删除历史 晨光'));
    await tester.pump();
    expect(_discoveryEntry('晨光'), findsNothing);
    expect(_discoveryEntry('夜航'), findsOneWidget);

    // 清空全部。
    await tester.tap(find.bySemanticsLabel('清空搜索历史'));
    await tester.pump();
    expect(find.text('搜索历史'), findsNothing);
  });

  testWidgets('「所有」档本地结果按 歌单 → 歌曲 → 专辑 → 艺术家 分组堆叠', (tester) async {
    final requests = <SearchRequest>[];
    await pumpSearchPage(
      tester,
      player: _RecordingPlayerNotifier(PlayerState()),
      size: const Size(430, 1600),
      overrides: <Override>[
        networkOverride(requests),
        ...localOverrides(
          resultSongs: songs,
          resultAlbums: <Album>[album],
          resultArtists: <Artist>[artist],
          resultPlaylists: <Playlist>[playlist],
        ),
      ],
    );

    await submitQuery(tester, '夜航');
    await tester.pump();

    expect(find.text('本地结果'), findsOneWidget);
    expect(find.text('全网结果'), findsOneWidget);

    // 堆叠顺序:歌单卡 → 歌曲行 → 专辑行 → 艺术家行。
    final playlistTop = tester.getTopLeft(find.text('歌单样本集')).dy;
    final songTop = tester.getTopLeft(find.text('晨光序曲')).dy;
    final albumTop = tester.getTopLeft(find.text('夜航与长标题现场专辑')).dy;
    final artistTop = tester.getTopLeft(find.text('丙歌手乐团')).dy;
    expect(playlistTop, lessThan(songTop));
    expect(songTop, lessThan(albumTop));
    expect(albumTop, lessThan(artistTop));

    // 「所有」档对四类都发起聚合搜索。
    expect(
      requests.map((r) => r.kind).toSet(),
      <SearchEntityKind>{
        SearchEntityKind.playlist,
        SearchEntityKind.song,
        SearchEntityKind.album,
        SearchEntityKind.artist,
      },
    );
  });

  testWidgets('点击行为:歌曲播放整队、专辑/艺术家进入详情路由', (tester) async {
    final player = _RecordingPlayerNotifier(PlayerState());
    final requests = <SearchRequest>[];
    await pumpSearchPage(
      tester,
      player: player,
      size: const Size(430, 1600),
      overrides: <Override>[
        networkOverride(requests),
        ...localOverrides(
          resultSongs: songs,
          resultAlbums: <Album>[album],
          resultArtists: <Artist>[artist],
        ),
      ],
    );

    await submitQuery(tester, '夜航');
    await tester.pump();

    // 点第二首:按整队播放,起点为该首下标。
    await tester.tap(find.text('长标题歌曲用于验证结果行布局不溢出'));
    await tester.pump();
    expect(player.playedQueues.single, songs);
    expect(player.startIndices.single, 1);

    // 专辑 → 详情页。
    await tester.tap(find.text('夜航与长标题现场专辑'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumDetailPage), findsOneWidget);

    Navigator.of(tester.element(find.byType(AlbumDetailPage))).pop();
    await tester.pumpAndSettle();

    // 艺术家 → 详情页。
    await tester.tap(find.text('丙歌手乐团'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistDetailPage), findsOneWidget);
  });
}

class _RecordingPlayerNotifier extends TestPlayerNotifier {
  _RecordingPlayerNotifier(super.state);

  final List<List<Song>> playedQueues = <List<Song>>[];
  final List<int> startIndices = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    bool shuffleRandomStart = false,
    int startIndex = 0,
  }) async {
    playedQueues.add(List<Song>.unmodifiable(songs));
    startIndices.add(startIndex);
  }
}
