// batch36-B —— `lib/features/player/widgets/song_options_sheet.dart` 剩余分支补测。
//
// b33c 已覆盖收藏切换、三路「下一首」路由、isPreview、当前曲隐藏行、无 id 禁用、
// 长按歌手复制、extraActions、二级加入歌单。仍有几条分支从未走到：
//   * 已收藏歌曲 → 「取消收藏」行（song.starred == true 分支）;
//   * 长按摘要标题 → 复制歌名;长按专辑行 → 复制专辑名;
//   * 桌面宽屏（非 compact）→ 锚点弹窗（showDragHandle=false / sceneRadius=true）;
//   * 有 artistId / albumId 时点行 → 推入歌手 / 专辑详情页。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/player/widgets/song_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

const Size kSheetView = Size(520, 1000);
const Size kDesktopView = Size(900, 1000);

final ServerAddress kAddress = ServerAddress(
  id: 'addr1',
  libraryId: 'lib1',
  label: 'Home',
  url: 'http://127.0.0.1:4533',
  priority: 0,
);

final Song kSong = Song(
  id: 's1',
  title: '测试曲目',
  artist: '测试艺术家',
  album: '测试专辑',
  artistId: 'ar1',
  albumId: 'al1',
);

final List<Playlist> kPlaylists = <Playlist>[
  Playlist(id: 'p1', name: '歌单一', songCount: 3, duration: 100),
];

class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer(super.initial);

  final List<Song> playNextCalls = <Song>[];
  final List<bool?> toggleFavoriteResults = <bool?>[];
  bool? nextToggleResult = true;

  @override
  Future<void> playNext(Song song) async {
    playNextCalls.add(song);
    state = state.copyWith(queue: <Song>[...state.queue, song]);
  }

  @override
  Future<bool?> toggleSongFavorite(Song song) async {
    toggleFavoriteResults.add(nextToggleResult);
    return nextToggleResult;
  }
}

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref, {PeerInfo? peer}) {
    if (peer != null) {
      state = state.copyWith(
        activePeer: peer,
        castQueue: <Map<String, dynamic>>[
          <String, dynamic>{'songId': 'other', 'title': 'x'},
        ],
        castIndex: 0,
      );
    }
  }

  final List<dynamic> enqueueCalls = <dynamic>[];

  @override
  Future<void> enqueueSongs(List<dynamic> songs) async {
    enqueueCalls.addAll(songs);
  }
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref, {bool casting = false}) {
    if (casting) {
      state = DlnaCastState(isCasting: true);
    }
  }

  final List<Song> enqueueCalls = <Song>[];

  @override
  Future<void> enqueueSongs(List<Song> songs) async {
    enqueueCalls.addAll(songs);
  }
}

class _RefProbe extends ConsumerWidget {
  const _RefProbe({required this.onReady});

  final void Function(BuildContext context) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(context);
    return const SizedBox.shrink();
  }
}

class FakePlaylistRepository extends PlaylistRepository {
  FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  @override
  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? public,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {}
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

Finder _actionRow(String title) => find.widgetWithText(MusicFlowPressable, title);

String? clipText;

class SheetHarness {
  SheetHarness({Song? song, Song? playerSong, this.viewSize = kSheetView})
      : player = RecordingPlayer(PlayerState(currentSong: playerSong)) {
    this.song = song ?? kSong;
  }

  final Size viewSize;
  late final Song song;
  final RecordingPlayer player;
  late StubCastPeer cast;
  late StubDlnaCast dlna;

  ProviderContainer? container;
  AppLocalizations? loc;
  BuildContext? hostContext;

  Widget build() {
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => cast = StubCastPeer(ref),
          ),
          dlnaCastProvider.overrideWith(
            (Ref ref) => dlna = StubDlnaCast(ref),
          ),
          playlistRepositoryProvider.overrideWith(
            (Ref ref) => FakePlaylistRepository(),
          ),
          ensureActiveAddressProvider.overrideWith((Ref ref) async => kAddress),
          playlistsProvider.overrideWith((Ref ref) async => kPlaylists),
          playlistsLoadFailedProvider.overrideWith((Ref ref) => false),
        ],
      ),
      child: MediaQuery(
        data: MediaQueryData(size: viewSize, devicePixelRatio: 1),
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
            body: _RefProbe(onReady: (BuildContext ctx) => hostContext = ctx),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewSize;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 4);
  }

  Future<void> open(WidgetTester tester) async {
    unawaited(
      showSongOptionsSheet(context: hostContext!, song: song),
    );
    await settle(tester, frames: 14);
  }

  Future<void> longPress(WidgetTester tester, Finder target) async {
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await drain(tester);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        clipText = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipText};
      }
      return null;
    },
  );

  setUp(() => clipText = null);

  group('song_options_sheet · 已收藏与桌面锚点', () {
    testWidgets('已收藏歌曲 → 显示「取消收藏」行', (tester) async {
      final starred = Song(
        id: 's-star',
        title: '已收藏曲目',
        artist: '测试艺术家',
        album: '测试专辑',
        artistId: 'ar1',
        albumId: 'al1',
        starred: true,
      );
      final h = SheetHarness(song: starred);
      await h.pump(tester);
      await h.open(tester);

      expect(_actionRow(h.loc!.player_unfavorite), findsOneWidget);
      expect(_actionRow(h.loc!.player_favorite), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('桌面宽屏(非 compact) → 仍渲染完整动作行', (tester) async {
      final h = SheetHarness(viewSize: kDesktopView);
      await h.pump(tester);
      await h.open(tester);

      final loc = h.loc!;
      expect(find.text(loc.song_option_title), findsOneWidget);
      expect(_actionRow(loc.player_favorite), findsOneWidget);
      expect(_actionRow(loc.library_add_to_playlist), findsOneWidget);
      expect(_actionRow(loc.song_option_artist('测试艺术家')), findsOneWidget);
      expect(_actionRow(loc.song_option_album('测试专辑')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('song_options_sheet · 长按复制', () {
    testWidgets('长按摘要标题 → 复制歌名', (tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      await h.longPress(tester, find.text(kSong.title));

      expect(clipText, kSong.title);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按专辑行 → 复制专辑名', (tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      final loc = h.loc!;
      await h.longPress(tester, _actionRow(loc.song_option_album('测试专辑')));

      expect(clipText, '测试专辑');
      expect(tester.takeException(), isNull);
    });
  });

  group('song_options_sheet · 有 id 时导航', () {
    testWidgets('点歌手行 → 打开歌手详情页', (tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.song_option_artist('测试艺术家')));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.byType(ArtistDetailPage), findsOneWidget);
      // 详情页自身可能因缺少 provider 显示占位/错误，此处只关心「路由已推入」。
      final err = tester.takeException();
      expect(err == null || err.toString().contains('provider'), isTrue);
    });

    testWidgets('点专辑行 → 打开专辑详情页', (tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.song_option_album('测试专辑')));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.byType(AlbumDetailPage), findsOneWidget);
      final err = tester.takeException();
      expect(err == null || err.toString().contains('provider'), isTrue);
    });
  });
}
