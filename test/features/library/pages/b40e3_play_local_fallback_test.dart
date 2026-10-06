// batch40 E3 补测：D-054 修复锁定用例。
//
// artist_list_page._playLocalArtist（及 album/playlist 同型）此前被
// `unawaited(...)` 调用且无 try/catch，详情 provider future 失败时成为
// unhandled async error。修复后失败被捕获并进 Logger，页面不崩。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/library_stats_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository({required this.artists})
      : super(SubsonicApiClient(dio: Dio()));

  final List<Artist> artists;

  @override
  Future<({List<Artist> items, int total})> getArtistsPage(
    int page,
    int pageSize, {
    String? query,
  }) async {
    return (items: artists, total: artists.length);
  }
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

Artist _artist(String id, String name) => Artist(
      id: id,
      name: name,
      coverArt: null,
      albumCount: 3,
    );

late AppLocalizations loc;

Widget _build() {
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
      musicRepositoryProvider.overrideWithValue(
        _FakeMusicRepository(artists: <Artist>[_artist('ar1', '王菲')]),
      ),
      playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
      libraryCountsProvider.overrideWith(
        (ref) async =>
            const LibraryCounts(artistCount: 1, albumCount: 3, songCount: 30),
      ),
      playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
      castPeerControllerProvider.overrideWith(
        (Ref ref) => _StubCastPeer(ref),
      ),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      // 详情 provider 直接抛错：修复前 unawaited(_playLocalArtist) 会把该
      // 异常漏成 unhandled async error，guarded 测试 zone 直接判负。
      artistDetailProvider.overrideWith(
        (ref, String artistId) async => throw StateError('detail down'),
      ),
    ],
  );
  addTearDown(container.dispose);
  tester_view_setup();
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: const ArtistListPage(),
    ),
  );
}

// 为了在 _build() 之外设置 view（WidgetTester 不可再注入），此处用全局 hack。
late WidgetTester _tester;
void tester_view_setup() {
  _tester.view.physicalSize = const Size(900, 1600);
  _tester.view.devicePixelRatio = 1;
  addTearDown(_tester.view.resetPhysicalSize);
  addTearDown(_tester.view.resetDevicePixelRatio);
}

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {});

  testWidgets('详情拉取失败点播放 → 不崩、无 unhandled async error(D-054)',
      (tester) async {
    _tester = tester;
    await tester.pumpWidget(_build());
    await settle(tester);

    // 输入关键词进入聚合搜索态：卡片(SearchArtistCard)上才有「播放」入口
    // （默认列表态的行没有播放按钮）。
    await tester.enterText(find.byType(TextField).first, '王菲');
    await settle(tester);

    expect(find.byType(SearchArtistCard), findsOneWidget);

    // 歌手卡片上的播放按钮（MusicFlowIconButton，label=widgets_play）。
    final playButton = find.byWidgetPredicate(
      (w) => w is MusicFlowIconButton && w.label == loc.widgets_play,
    );
    expect(playButton, findsOneWidget);

    await tester.tap(playButton);
    await settle(tester, frames: 16);

    // 修复前：这里会以 unhandled async error（StateError detail down）判负。
    expect(tester.takeException(), isNull,
        reason: '[D-054 已修复] 详情拉取失败被捕获，不再是 unhandled async error');
    expect(find.text('王菲'), findsWidgets, reason: '页面保持原状不崩溃');
  });
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}
