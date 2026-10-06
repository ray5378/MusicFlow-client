// batch33 C 路 —— `lib/features/player/widgets/song_options_sheet.dart` 补测。
//
// 基线覆盖率 72.12%。入口 `showSongOptionsSheet` 公开、sheet 本体库私有
// （b31c #C1 套路：unawaited 发起，Future 在 pop 时才完成）。宽 520 → compact
// → 底部抽屉。重点补交互分支：
//   * 收藏切换（toggleSongFavorite 成功/返回 null）；
//   * 「下一首播放」三路路由：本机 playNext / 链路 A 投屏 enqueueSongs /
//     链路 B 直投 enqueueSongs；
//   * isPreview 歌曲只有「下一首播放」行；当前播放歌曲隐藏该行；
//   * 歌手/专辑行：无 id 时禁用；长按复制剪贴板；
//   * extraActions 渲染与点击；
//   * 「加入歌单」二级打开 AddToPlaylistSheet。
// NetworkErrorNotifier 有 20s 静态节流（b31c #C5），失败分支只断言确定性副作用。
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
import 'package:musicflow_client/features/player/widgets/song_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

const Size kSheetView = Size(520, 1000);

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

/// 播放器桩：显式实现本 sheet 触达的三个方法。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer(super.initial);

  final List<Song> playNextCalls = <Song>[];
  final List<bool?> toggleFavoriteResults = <bool?>[];
  bool? nextToggleResult = true;
  Object? toggleSongFavoriteError;

  @override
  Future<void> playNext(Song song) async {
    playNextCalls.add(song);
    state = state.copyWith(queue: <Song>[...state.queue, song]);
  }

  @override
  Future<bool?> toggleSongFavorite(Song song) async {
    if (toggleSongFavoriteError != null) throw toggleSongFavoriteError!;
    toggleFavoriteResults.add(nextToggleResult);
    return nextToggleResult;
  }
}

/// 链路 A 投屏桩：可配置 activePeer + 记录 enqueueSongs。
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

/// 链路 B 直投桩：可配置 casting 态 + 记录 enqueueSongs。
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
    Song? song,
    Song? playerSong,
    this.activePeer,
    this.dlnaCasting = false,
    this.extraActions = const <SongOptionsExtraAction>[],
  }) : player = RecordingPlayer(PlayerState(currentSong: playerSong)) {
    this.song = song ?? kSong;
  }

  late final Song song;
  final PeerInfo? activePeer;
  final bool dlnaCasting;
  final List<SongOptionsExtraAction> extraActions;

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
            (Ref ref) => cast = StubCastPeer(ref, peer: activePeer),
          ),
          dlnaCastProvider.overrideWith(
            (Ref ref) => dlna = StubDlnaCast(ref, casting: dlnaCasting),
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
            body: _RefProbe(onReady: (BuildContext ctx) => hostContext = ctx),
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
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 4);
  }

  Future<void> open(WidgetTester tester) async {
    unawaited(
      showSongOptionsSheet(
        context: hostContext!,
        song: song,
        extraActions: extraActions,
      ),
    );
    await settle(tester, frames: 14);
  }
}

class FakePlaylistRepository extends PlaylistRepository {
  FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  final List<String> addedPlaylistIds = <String>[];

  @override
  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? public,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {
    addedPlaylistIds.add(playlistId);
  }
}

Finder _actionRow(String title) =>
    find.widgetWithText(MusicFlowPressable, title);

String? clipText;

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
  group('song_options_sheet · 装配与行分支', () {
    testWidgets('常规歌曲 → 摘要 + 收藏/加入歌单/下一首/歌手/专辑五行', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      final loc = h.loc!;
      expect(find.text(loc.song_option_title), findsOneWidget);
      expect(_actionRow(loc.player_favorite), findsOneWidget);
      expect(_actionRow(loc.library_add_to_playlist), findsOneWidget);
      expect(_actionRow(loc.song_option_play_next), findsOneWidget);
      expect(
        _actionRow(loc.song_option_artist('测试艺术家')),
        findsOneWidget,
      );
      expect(_actionRow(loc.song_option_album('测试专辑')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('当前播放歌曲 → 隐藏「下一首播放」行', (WidgetTester tester) async {
      final h = SheetHarness(playerSong: kSong);
      // open 时 playerProvider.currentSong == song → isCurrentSong。
      await h.pump(tester);
      await h.open(tester);

      expect(_actionRow(h.loc!.song_option_play_next), findsNothing);
      expect(_actionRow(h.loc!.player_favorite), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('isPreview 歌曲 → 只有「下一首播放」行 + 预览标题', (
      WidgetTester tester,
    ) async {
      final preview = Song(
        id: 'pv1',
        title: '试听片段',
        artist: '测试艺术家',
        isPreview: true,
      );
      final h = SheetHarness(song: preview);
      await h.pump(tester);
      await h.open(tester);

      final loc = h.loc!;
      expect(find.text(loc.song_option_title_preview), findsOneWidget);
      expect(_actionRow(loc.song_option_play_next), findsOneWidget);
      expect(_actionRow(loc.player_favorite), findsNothing);
      expect(_actionRow(loc.library_add_to_playlist), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('投屏/直投中 → 「下一首播放」标题变「加入投屏队列」', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        activePeer: const PeerInfo(
          peerId: 'peer1',
          name: '客厅设备',
          kind: 'dlna',
          available: true,
        ),
      );
      await h.pump(tester);
      await h.open(tester);

      expect(_actionRow(h.loc!.song_option_enqueue), findsOneWidget);
      expect(_actionRow(h.loc!.song_option_play_next), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 artistId/albumId → 歌手/专辑行禁用', (WidgetTester tester) async {
      final bare = Song(id: 's9', title: '裸曲目', artist: '甲', album: '乙');
      final h = SheetHarness(song: bare);
      await h.pump(tester);
      await h.open(tester);

      final artistRow =
          tester.widget<MusicFlowPressable>(_actionRow(h.loc!.song_option_artist('甲')));
      final albumRow =
          tester.widget<MusicFlowPressable>(_actionRow(h.loc!.song_option_album('乙')));
      expect(artistRow.onPressed, isNull);
      expect(albumRow.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('song_options_sheet · 交互', () {
    testWidgets('点收藏 → toggleSongFavorite 成功并弹提示', (WidgetTester tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.player_favorite));
      await drain(tester);

      expect(h.player.toggleFavoriteResults, <bool?>[true]);
      expect(find.byType(MusicFlowMessage), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggleSongFavorite 返回 null → 不弹成功提示不崩', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness();
      h.player.nextToggleResult = null;
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.player_favorite));
      await drain(tester);

      expect(h.player.toggleFavoriteResults, <bool?>[null]);
      // NetworkErrorNotifier 20s 节流 → 失败提示不可断言；成功提示必不出现。
      expect(
        find.text(h.loc!.song_option_favorite_added),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('本机态点「下一首播放」→ player.playNext + 成功提示', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.song_option_play_next));
      await drain(tester);

      expect(h.player.playNextCalls.map((Song s) => s.id), <String>['s1']);
      expect(h.cast.enqueueCalls, isEmpty);
      expect(h.dlna.enqueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('链路 A 投屏 → enqueueSongs 走 castPeer，不走本机', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        activePeer: const PeerInfo(
          peerId: 'peer1',
          name: '客厅设备',
          kind: 'dlna',
          available: true,
        ),
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.song_option_enqueue));
      await drain(tester);

      expect(h.cast.enqueueCalls.map((dynamic s) => (s as Song).id),
          <String>['s1']);
      expect(h.player.playNextCalls, isEmpty);
      expect(h.dlna.enqueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('链路 B 直投 → enqueueSongs 走 dlnaCast + enqueued 提示', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(dlnaCasting: true);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.song_option_enqueue));
      await drain(tester);

      expect(h.dlna.enqueueCalls.map((Song s) => s.id), <String>['s1']);
      expect(h.player.playNextCalls, isEmpty);
      expect(h.cast.enqueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按歌手行 → 剪贴板写入', (WidgetTester tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(_actionRow(h.loc!.song_option_artist('测试艺术家'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await drain(tester);

      expect(clipText, '测试艺术家');
      expect(tester.takeException(), isNull);
    });

    testWidgets('extraActions 渲染分隔线 + 点击执行回调', (WidgetTester tester) async {
      var fired = 0;
      final h = SheetHarness(
        extraActions: <SongOptionsExtraAction>[
          SongOptionsExtraAction(
            icon: Icons.delete_outline,
            title: '自定义动作',
            isDestructive: true,
            onPressed: () async => fired += 1,
          ),
        ],
      );
      await h.pump(tester);
      await h.open(tester);

      expect(_actionRow('自定义动作'), findsOneWidget);
      await tester.tap(_actionRow('自定义动作'));
      await drain(tester);

      expect(fired, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「加入歌单」→ 打开二级添加弹窗', (WidgetTester tester) async {
      final h = SheetHarness();
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(_actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.text('歌单一'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
