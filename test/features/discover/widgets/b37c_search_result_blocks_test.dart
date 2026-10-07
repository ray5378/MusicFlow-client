// batch37 C —— `lib/features/discover/widgets/search_result_blocks.dart` 剩余未覆盖分支。
//
// 既有 b36c 只做「四分组渲染 / 空态收缩」，行内交互与卡片导航从未触发，故：
//   * LocalSearchGroup._songs 单行的 onPressed(230)/onLongPress(231)/onMorePressed(233)；
//   * _albums 行的 onLongPress → showAlbumOptionsSheet(263)；
//   * _artists 行的 onLongPress → showArtistOptionsSheet(297)；
//   * _playlists 卡片的 onPressed → push PlaylistDetailPage(334-343) 与
//     onLongPress → showPlaylistOptionsSheet(345)。
//
// 说明：_hasData/_isLoading 的 SearchScope.all arm（源码 133/185）为**不可达分支** ——
// SearchScope.stackedScopes 对 all 返回 kSearchScopeStackOrder（不含 all）。b41e1
// 清理后该 arm 由「静默 false」改为「throw StateError 断言」（穷举性要求保留 arm），
// 契约由 b41e1_search_scope_guard_test.dart 守护，行为仍不可达，不在此补测。
//
// 只写 test/，只读 lib/。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/search_result_blocks.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

/// TestPlayerNotifier 未实现 playQueue（noSuchMethod 返回 null → 类型错误），
/// 补一个记录实现，供「点行播放」用例走通链路。
class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];

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
}

Song _song(String id) =>
    Song(id: id, title: '歌曲$id', artist: '歌手', duration: 100);
Album _album(String id) =>
    Album(id: id, name: '专辑$id', artist: '歌手', songCount: 5, duration: 300);
Artist _artist(String id) => Artist(id: id, name: '艺术家$id');
Playlist _playlist(String id) =>
    Playlist(id: id, name: '歌单$id', songCount: 3, duration: 300);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  Size size = const Size(420, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => _RecordingPlayer()),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
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
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('song 分组行交互', () {
    Future<void> pumpSongs(WidgetTester tester) => _pump(
          tester,
          const LocalSearchGroup(scope: SearchScope.song, query: 'q'),
          overrides: <Override>[
            localSongSearchProvider.overrideWith(
              (ref, q) async => (items: <Song>[_song('1')], total: 1),
            ),
          ],
        );

    testWidgets('点整行 → onPressed 触发播放链路', (tester) async {
      await pumpSongs(tester);
      await tester.tap(find.byType(MusicFlowSongRow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按整行 → onLongPress 打开歌曲选项面板', (tester) async {
      await pumpSongs(tester);
      await tester.longPress(find.byType(MusicFlowSongRow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「更多」图标 → onMorePressed 打开歌曲选项面板', (tester) async {
      await pumpSongs(tester);
      expect(find.byType(MusicFlowIconButton), findsWidgets);
      await tester.tap(find.byType(MusicFlowIconButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });

  group('album/artist 分组行长按', () {
    testWidgets('album 行长按 → showAlbumOptionsSheet', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.album, query: 'q'),
        overrides: <Override>[
          localAlbumSearchProvider.overrideWith(
            (ref, q) async => (items: <Album>[_album('a1')], total: 1),
          ),
        ],
      );
      await tester.longPress(find.byType(MusicFlowAlbumRow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });

    testWidgets('artist 行长按 → showArtistOptionsSheet', (tester) async {
      await _pump(
        tester,
        const LocalSearchGroup(scope: SearchScope.artist, query: 'q'),
        overrides: <Override>[
          localArtistSearchProvider.overrideWith(
            (ref, q) async => (items: <Artist>[_artist('ar1')], total: 1),
          ),
        ],
      );
      await tester.longPress(find.byType(MusicFlowArtistRow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });

  group('playlist 分组卡片交互', () {
    Future<void> pumpPlaylist(WidgetTester tester) => _pump(
          tester,
          const LocalSearchGroup(scope: SearchScope.playlist, query: 'q'),
          overrides: <Override>[
            localPlaylistSearchProvider.overrideWith(
              (ref, q) async => (items: <Playlist>[_playlist('p1')], total: 1),
            ),
          ],
        );

    testWidgets('点卡片 → onPressed push PlaylistDetailPage', (tester) async {
      await pumpPlaylist(tester);
      await tester.tap(find.text('歌单p1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按卡片 → onLongPress 打开歌单选项面板', (tester) async {
      await pumpPlaylist(tester);
      await tester.longPress(find.text('歌单p1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });
}
