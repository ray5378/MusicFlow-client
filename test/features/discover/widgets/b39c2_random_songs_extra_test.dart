// b39c2 —— Route C 清尾：random_songs_section.dart 剩余缺口。
//   * 83：activeLibraryProvider listenManual 回调里
//     `if (prev != null && prev.id == next.id) return;` 的 **条件为真** 分支 ——
//     活跃库实例更新但 id 不变（同一媒体库的 metadata 刷新推送）→ 早退，
//     不触发补读缓存/后台拉取。
//     既有 b37c 只打了 prev==null 的分支（81-85），本文件补同 id 早退。
//
// 手法沿用 b37c_random_songs_section_test 的 _Harness（network 全打桩）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/discover/widgets/random_songs_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

final _activeLib = StateProvider<MusicLibrary?>((ref) => null);

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());
}

class _MutableCastPeer extends CastPeerController {
  _MutableCastPeer(super.ref);
}

class _MutableDlnaCast extends DlnaCastNotifier {
  _MutableDlnaCast(super.ref);
}

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakeCache extends MetadataCacheRepository {
  _FakeCache({this.lastLibraryId});

  final String? lastLibraryId;

  @override
  Future<String?> getLastLibraryId() async => lastLibraryId;

  @override
  Future<({List<Song> songs, DateTime cachedAt})?> getRandomSongsWithMeta(
    String libraryId,
  ) async {
    return null;
  }
}

Song _song(String id, String title) =>
    Song(id: id, title: title, artist: '歌手', duration: 180);

MusicLibrary _library() => MusicLibrary(
      id: 'lib-1',
      name: '测试库',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Harness {
  late final ProviderContainer container;
  int fetchCount = 0;
  List<Song> fetched = <Song>[];

  Widget build() {
    final library = _library();
    final client = SubsonicApiClient(
      dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
    )..setLibrary(library);
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        activeLibraryProvider.overrideWith((ref) => ref.watch(_activeLib)),
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
        metadataCacheRepositoryProvider
            .overrideWithValue(_FakeCache(lastLibraryId: null)),
        musicRepositoryProvider.overrideWithValue(_FakeMusicRepository()),
        playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
        randomSongsProvider.overrideWith((ref) async {
          fetchCount += 1;
          return fetched;
        }),
        playerProvider.overrideWith((ref) => _RecordingPlayer()),
        castPeerControllerProvider
            .overrideWith((ref) => _MutableCastPeer(ref)),
        dlnaCastProvider.overrideWith((ref) => _MutableDlnaCast(ref)),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 900, child: RandomSongsSection()),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container.dispose());
    await tester.pumpWidget(build());
    await settle(tester);
  }
}

void main() {
  testWidgets('活跃库同 id 实例更新 → listenManual 早退，不重复拉取（83）',
      (tester) async {
    final h = _Harness();
    h.fetched = <Song>[_song('s1', '晴天')];
    await h.pump(tester);
    expect(h.fetchCount, 0, reason: '库为 null 且无最近库 → 初始化不拉取');

    // 空库 → 就绪库（prev == null，既有 b37c 已覆盖的分支）。
    h.container.read(_activeLib.notifier).state = _library();
    await settle(tester);
    expect(h.fetchCount, 1, reason: '活跃库就绪 → 补读缓存/后台拉取一次');

    // 同 id 新实例（metadata 刷新推送）→ prev != null && prev.id == next.id
    // → 早退（83），不触发重复拉取。
    final before = h.fetchCount;
    h.container.read(_activeLib.notifier).state = _library();
    await settle(tester);

    expect(h.fetchCount, before, reason: '同 id 更新应早退，不重复拉取');
    expect(tester.takeException(), isNull);
  });
}
