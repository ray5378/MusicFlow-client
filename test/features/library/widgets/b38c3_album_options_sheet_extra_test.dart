// b38c3 —— album_options_sheet.dart 剩余可达分支补测（Route C）。
//
// 既有 b31c 用例把三个分支「渲染」出来了，但都没有真正点下去：
//   * line 82  收藏行在 `musicRepositoryProvider == null` 时弹网络错误后返回
//     （既有「仓库为 null」只测了「加入队列」那一行，没测收藏行）；
//   * line 232 歌单为空且 loadFailed 时空态的「重试」onAction（既有用例只断言了
//     重试按钮存在，没点）；
//   * line 267 歌单加载报错时错误态的「重试」onAction（同上）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/widgets/album_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

const Size kSheetView = Size(520, 1000);

final ServerAddress kAddress = ServerAddress(
  id: 'addr1',
  libraryId: 'lib1',
  label: 'Home',
  url: 'http://127.0.0.1:4533',
  priority: 0,
);

final Album kAlbum = Album(
  id: 'al1',
  name: '测试专辑',
  artist: '测试艺术家',
  artistId: 'ar1',
  songCount: 2,
  duration: 120,
);

final List<Song> kSongs = <Song>[
  Song(id: 's1', title: '曲目一', artist: '测试艺术家', albumId: 'al1'),
  Song(id: 's2', title: '曲目二', artist: '测试艺术家', albumId: 'al1'),
];

class FakeMusicRepository extends MusicRepository {
  FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));

  @override
  Future<AlbumDetail?> getAlbum(String albumId) async =>
      AlbumDetail(album: kAlbum, songs: kSongs);
}

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

class _RefProbe extends ConsumerWidget {
  const _RefProbe({required this.onReady});

  final void Function(WidgetRef ref, BuildContext context) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(ref, context);
    return const SizedBox.shrink();
  }
}

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class SheetHarness {
  SheetHarness({
    this.repository,
    this.playlists,
    this.playlistsError,
    this.playlistsLoadFailed = false,
  });

  final FakeMusicRepository? repository;
  final List<Playlist>? playlists;
  final Object? playlistsError;
  final bool playlistsLoadFailed;

  ProviderContainer? _container;
  AppLocalizations? loc;
  WidgetRef? hostRef;
  BuildContext? hostContext;

  Widget build() {
    final container = ProviderContainer(
      overrides: <Override>[
        musicRepositoryProvider.overrideWith((Ref ref) => repository),
        playlistRepositoryProvider.overrideWith(
          (Ref ref) => null,
        ),
        ensureActiveAddressProvider.overrideWith((Ref ref) async => kAddress),
        playlistsProvider.overrideWith((Ref ref) async {
          if (playlistsError != null) throw playlistsError!;
          return playlists ?? <Playlist>[];
        }),
        playlistsLoadFailedProvider.overrideWith(
          (Ref ref) => playlistsLoadFailed,
        ),
        playerProvider.overrideWith((Ref ref) => TestPlayerNotifier(PlayerState())),
        castPeerControllerProvider.overrideWith((Ref ref) => StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
      ],
    );
    _container = container;
    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: kSheetView, devicePixelRatio: 1),
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          builder: (BuildContext context, Widget? child) {
            loc = AppLocalizations.of(context);
            return child!;
          },
          home: Scaffold(
            body: _RefProbe(
              onReady: (WidgetRef ref, BuildContext ctx) {
                hostRef = ref;
                hostContext = ctx;
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kSheetView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => _container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 4);
  }

  Future<void> open(WidgetTester tester) async {
    unawaited(
      showAlbumOptionsSheet(
        context: hostContext!,
        ref: hostRef!,
        album: kAlbum,
      ),
    );
    await settle(tester, frames: 14);
  }
}

Finder actionRow(String title) =>
    find.widgetWithText(MusicFlowActionRow, title);

void main() {
  testWidgets('收藏行：仓库为 null → 关弹窗并弹网络错误（line 82）', (tester) async {
    final h = SheetHarness(repository: null);
    await h.pump(tester);
    await h.open(tester);

    await tester.tap(actionRow(h.loc!.library_favorite_album));
    await drain(tester);

    // 收藏动作在仓库缺失时提前返回：没有写库、也没有崩。
    expect(find.byType(MusicFlowBottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单为空且加载失败 → 点重试重新拉取（line 232）', (tester) async {
    final h = SheetHarness(
      repository: FakeMusicRepository(),
      playlists: const <Playlist>[],
      playlistsLoadFailed: true,
    );
    await h.pump(tester);
    await h.open(tester);

    await tester.tap(actionRow(h.loc!.library_add_to_playlist));
    await settle(tester, frames: 16);
    await drain(tester);

    // 空态带重试项（loadFailed）。
    expect(find.text(h.loc!.widgets_retry), findsWidgets);

    await tester.tap(find.text(h.loc!.widgets_retry).first);
    await settle(tester, frames: 16);
    await drain(tester);

    // 重试后仍为空 → 空态保持，且没有抛异常（即 invalidate 生效）。
    expect(find.text(h.loc!.library_playlists_unavailable), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单加载报错 → 点重试重新拉取（line 267）', (tester) async {
    final h = SheetHarness(
      repository: FakeMusicRepository(),
      playlistsError: StateError('playlists boom'),
    );
    await h.pump(tester);
    await h.open(tester);

    await tester.tap(actionRow(h.loc!.library_add_to_playlist));
    await settle(tester, frames: 16);
    await drain(tester);

    expect(find.text(h.loc!.library_playlist_load_failed), findsWidgets);

    await tester.tap(find.text(h.loc!.widgets_retry).first);
    await settle(tester, frames: 16);
    await drain(tester);

    // 重试后仍然报错 → 错误态保持。
    expect(find.text(h.loc!.library_playlist_load_failed), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
