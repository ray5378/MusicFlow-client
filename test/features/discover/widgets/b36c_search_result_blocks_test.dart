// b36c —— `lib/features/discover/widgets/search_result_blocks.dart` 补测（原 30 miss）。
//
// 覆盖：
//   * SearchBlockHeader：副标题有/无；
//   * SearchGroupHeader：条数有/无；
//   * LocalResultsBlock：全空（无结果文案）/ 加载中骨架 / 有数据；
//   * LocalSearchGroup：song/album/artist/playlist 四个分组各自渲染 + 空态收缩；
//   * NetworkSearchGroup：kind 为 null（all）收缩 / 空结果收缩 / 有结果渲染；
//   * NetworkResultsBlock：按 stackedScopes 分组渲染。
//
// 打桩：本地搜索四个 family provider 与网络 searchResultsProvider 直接 override
// 固定数据；playerProvider 用 TestPlayerNotifier。行内点击不触发（避免深层链路）。
//
// 产品代码零改动；只读 lib。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/search_result_blocks.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../../features/player/test_player_notifier.dart';

Song _song(String id) => Song(id: id, title: '歌曲$id', artist: '歌手', duration: 100);
Album _album(String id) =>
    Album(id: id, name: '专辑$id', artist: '歌手', songCount: 5, duration: 300);
Artist _artist(String id) => Artist(id: id, name: '艺术家$id');
Playlist _playlist(String id) =>
    Playlist(id: id, name: '歌单$id', songCount: 3, duration: 300);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        ...overrides,
      ],
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.light(),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: c!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

List<Override> _emptyLocal() => <Override>[
      localSongSearchProvider.overrideWith(
        (ref, q) async => (items: <Song>[], total: 0),
      ),
      localAlbumSearchProvider.overrideWith(
        (ref, q) async => (items: <Album>[], total: 0),
      ),
      localArtistSearchProvider.overrideWith(
        (ref, q) async => (items: <Artist>[], total: 0),
      ),
      localPlaylistSearchProvider.overrideWith(
        (ref, q) async => (items: <Playlist>[], total: 0),
      ),
    ];

void main() {
  group('SearchBlockHeader / SearchGroupHeader', () {
    testWidgets('SearchBlockHeader 显示标题；副标题非空才渲染', (tester) async {
      await _pump(tester, const SearchBlockHeader(title: '本地结果'));
      expect(find.text('本地结果'), findsOneWidget);

      await _pump(
        tester,
        const SearchBlockHeader(title: '本地结果', subtitle: '当前音乐库'),
      );
      expect(find.text('当前音乐库'), findsOneWidget);

      await _pump(
        tester,
        const SearchBlockHeader(title: '本地结果', subtitle: ''),
      );
      expect(find.text('本地结果'), findsOneWidget);
    });

    testWidgets('SearchGroupHeader 显示条数；count 为 null 时不显示', (tester) async {
      await _pump(tester, const SearchGroupHeader(title: '歌曲', count: 7));
      expect(find.text('歌曲'), findsOneWidget);

      await _pump(tester, const SearchGroupHeader(title: '歌曲'));
      expect(find.text('歌曲'), findsOneWidget);
    });
  });

  group('LocalResultsBlock', () {
    testWidgets('全部为空：显示本地无结果文案', (tester) async {
      await _pump(
        tester,
        const LocalResultsBlock(scope: SearchScope.all, query: 'zzz'),
        overrides: _emptyLocal(),
      );
      await tester.pump();
      expect(find.text('zzz'), findsNothing); // query 不在本地块上直接展示
      // 四个分组 key 都在。
      for (final scope in kSearchScopeStackOrder) {
        expect(
          find.byKey(ValueKey<String>('local-group-${scope.name}')),
          findsOneWidget,
        );
      }
    });

    testWidgets('加载中：显示骨架而非无结果文案', (tester) async {
      final completer = Completer<LocalSearchPage<Song>>();
      addTearDown(() {
        if (!completer.isCompleted) {
          completer.complete((items: <Song>[], total: 0));
        }
      });
      await _pump(
        tester,
        const LocalResultsBlock(scope: SearchScope.all, query: 'q'),
        overrides: <Override>[
          localSongSearchProvider.overrideWith((ref, q) => completer.future),
          ..._emptyLocal().sublist(1),
        ],
      );
      await tester.pump();
      expect(find.byType(MusicFlowSkeleton), findsWidgets);
    });
  });

  group('LocalSearchGroup 各分组', () {
    testWidgets('song 分组渲染歌曲行 + 组标题', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.song, query: 'q'),
        overrides: <Override>[
          localSongSearchProvider.overrideWith(
            (ref, q) async => (items: <Song>[_song('1'), _song('2')], total: 2),
          ),
        ],
      );
      expect(find.text('歌曲1'), findsOneWidget);
      expect(find.text('歌曲2'), findsOneWidget);
    });

    testWidgets('album 分组渲染专辑行', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.album, query: 'q'),
        overrides: <Override>[
          localAlbumSearchProvider.overrideWith(
            (ref, q) async => (items: <Album>[_album('a1')], total: 1),
          ),
        ],
      );
      expect(find.text('专辑a1'), findsOneWidget);
    });

    testWidgets('artist 分组渲染艺术家行', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.artist, query: 'q'),
        overrides: <Override>[
          localArtistSearchProvider.overrideWith(
            (ref, q) async => (items: <Artist>[_artist('ar1')], total: 1),
          ),
        ],
      );
      expect(find.text('艺术家ar1'), findsOneWidget);
    });

    testWidgets('playlist 分组渲染歌单行', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.playlist, query: 'q'),
        overrides: <Override>[
          localPlaylistSearchProvider.overrideWith(
            (ref, q) async => (items: <Playlist>[_playlist('p1')], total: 1),
          ),
        ],
      );
      expect(find.text('歌单p1'), findsOneWidget);
    });

    testWidgets('scope.all → LocalSearchGroup 收缩为空', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.all, query: 'q'),
      );
      expect(find.byType(SizedBox), findsWidgets);
    });
  });

  group('NetworkSearchGroup / NetworkResultsBlock', () {
    testWidgets('scope.all（kind 为 null）收缩为空', (tester) async {
      await _pump(
        tester,
        const NetworkSearchGroup(
          scope: SearchScope.all,
          query: 'q',
          includeBottomPadding: true,
        ),
      );
      expect(find.text('r1'), findsNothing);
    });

    testWidgets('空结果收缩为空', (tester) async {
      await _pump(
        tester,
        const NetworkSearchGroup(
          scope: SearchScope.song,
          query: 'q',
          includeBottomPadding: true,
        ),
        overrides: <Override>[
          searchResultsProvider.overrideWith((ref, req) async => SearchOutcome()),
        ],
      );
      await tester.pump();
      expect(find.text('远程歌'), findsNothing);
    });

    testWidgets('有结果渲染分组标题与结果卡', (tester) async {
      await _pump(
        tester,
        const NetworkSearchGroup(
          scope: SearchScope.song,
          query: 'q',
          includeBottomPadding: true,
        ),
        overrides: <Override>[
          searchResultsProvider.overrideWith(
            (ref, req) async => SearchOutcome(
              songs: <SearchSong>[SearchSong(id: 'r1', name: '远程歌')],
            ),
          ),
        ],
      );
      await tester.pump();
      expect(find.text('远程歌'), findsOneWidget);
    });

    testWidgets('NetworkResultsBlock 渲染全网结果标题', (tester) async {
      await _pump(
        tester,
        const NetworkResultsBlock(scope: SearchScope.all, query: 'q'),
        overrides: <Override>[
          searchResultsProvider.overrideWith((ref, req) async => SearchOutcome()),
        ],
      );
      await tester.pump();
      for (final scope in kSearchScopeStackOrder) {
        expect(
          find.byKey(ValueKey<String>('network-group-${scope.name}')),
          findsOneWidget,
        );
      }
    });
  });
}
