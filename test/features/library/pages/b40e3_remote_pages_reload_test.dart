// batch40 E3 补测：D-057 修复锁定用例。
//
// remote_album_page / remote_playlist_page 的 `_reload()` 已改为块体，
// 重试按钮在 debug 下同样可用（修复前箭头闭包返回 Future 触发
// "setState() callback argument returned a Future" 断言，重试被阻断）。
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
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

class _StubSearchRepository extends SearchRepository {
  _StubSearchRepository() : super(SubsonicApiClient(dio: Dio()));

  List<Song> songs = <Song>[Song(id: 's1', title: '远程歌一')];
  Object? error;

  Future<List<Song>> _resolve() async {
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

SearchAlbum _album(String id, String name) => SearchAlbum(
      id: id,
      name: name,
      artist: '',
      cover: '',
      platformLabel: '',
      providerId: 'pv1',
    );

SearchPlaylist _playlist(String id, String name) => SearchPlaylist(
      id: id,
      name: name,
      trackCount: '',
      cover: '',
      platformLabel: '',
      providerId: 'pv1',
    );

AppLocalizations _loc(WidgetTester tester, Type pageType) =>
    AppLocalizations.of(tester.element(find.byType(pageType)));

Future<void> _pump(WidgetTester tester, Widget page,
    {required _StubSearchRepository repo}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        searchRepositoryProvider.overrideWithValue(repo),
        playerProvider
            .overrideWith((Ref ref) => TestPlayerNotifier(PlayerState())),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('remote_album_page: 加载失败点重试，无断言异常且恢复歌曲行(D-057)',
      (tester) async {
    final repo = _StubSearchRepository()..error = StateError('boom');
    await _pump(
      tester,
      RemoteAlbumPage(album: _album('a1', '专辑'), providerId: 'pv1'),
      repo: repo,
    );
    final loc = _loc(tester, RemoteAlbumPage);
    expect(find.text(loc.library_remote_load_failed), findsOneWidget);

    repo.error = null;
    await tester.tap(find.text(loc.widgets_retry));
    expect(tester.takeException(), isNull,
        reason: '[D-057 已修复] 重试不再触发 setState Future 断言');
    await tester.pumpAndSettle();
    expect(find.text(loc.library_remote_load_failed), findsNothing);
    expect(find.byType(SongListItem), findsOneWidget);
  });

  testWidgets('remote_playlist_page: 加载失败点重试，无断言异常且恢复歌曲行(D-057)',
      (tester) async {
    final repo = _StubSearchRepository()..error = StateError('boom');
    await _pump(
      tester,
      RemotePlaylistPage(playlist: _playlist('p1', '歌单'), providerId: 'pv1'),
      repo: repo,
    );
    final loc = _loc(tester, RemotePlaylistPage);
    expect(find.text(loc.library_remote_load_failed), findsOneWidget);

    repo.error = null;
    await tester.tap(find.text(loc.widgets_retry));
    expect(tester.takeException(), isNull,
        reason: '[D-057 已修复] 重试不再触发 setState Future 断言');
    await tester.pumpAndSettle();
    expect(find.text(loc.library_remote_load_failed), findsNothing);
    expect(find.byType(SongListItem), findsOneWidget);
  });
}
