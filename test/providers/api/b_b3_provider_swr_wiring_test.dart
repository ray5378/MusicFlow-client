// #12 · provider 级 SWR 接线守卫（P0-1 / P0-2 的端到端回归）。
//
// 为什么需要这个文件：`b_b3_swr_test.dart` 的用例全部是 helper 级直调
// `fetchWithCacheFallback(cacheFirst: true)`，没有任何一条进入真实的
// recentPlaylistsProvider / randomSongsProvider。于是「两个首屏区块传同一个
// libraryId 作 refreshKey → 闸键碰撞 → 其中一个整会话不后台刷新」(P0-1)、
// 以及「一次性 Set 让 ref.invalidate 之后零远程请求」(P0-2) 都无法被任何
// 用例发现 —— 删掉任一 provider 的 `cacheFirst: true` 全量照绿。
//
// 这里只 fake 叶子依赖（仓库/缓存/库/地址），**不**用 overrideWith 替换被测
// provider 本身，让两个真实 provider 走完整的 helper 路径。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

ServerAddress _addr() => ServerAddress(
      id: 'a',
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
    );

MusicLibrary _lib() => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

Playlist _pl(String id) => Playlist(
      id: id,
      name: 'PL $id',
      songCount: 0,
      duration: 0,
      changed: DateTime(2024),
    );

Song _song(String id) => Song(id: id, title: 'Song $id');

/// 内存缓存：两个 scope 都预置非空数据，让 cacheFirst 首帧命中。
class _FakeCache extends MetadataCacheRepository {
  _FakeCache({required this.playlists, required this.songs});

  final List<Playlist> playlists;
  final List<Song> songs;

  @override
  Future<List<Playlist>?> getRecentPlaylists(String libraryId) async =>
      playlists;

  @override
  Future<List<Playlist>?> getPlaylists(String libraryId) async => playlists;

  @override
  Future<List<Song>?> getRandomSongs(String libraryId) async => songs;

  @override
  Future<String?> getLastLibraryId() async => 'lib-1';

  @override
  Future<void> cacheRecentPlaylists(
    String libraryId,
    List<Playlist> items,
  ) async {}

  @override
  Future<void> cacheRandomSongs(
    String libraryId,
    List<Song> items,
  ) async {}
}

/// 只覆盖 provider 真正调用到的方法，计数远程请求次数。
class _FakePlaylistRepo extends PlaylistRepository {
  _FakePlaylistRepo() : super(SubsonicApiClient(dio: Dio()));

  int fetchCalls = 0;

  @override
  Future<List<Playlist>> getPlaylists({int? size}) async {
    fetchCalls++;
    return <Playlist>[_pl('remote')];
  }
}

class _FakeMusicRepo extends MusicRepository {
  _FakeMusicRepo() : super(SubsonicApiClient(dio: Dio()));

  int fetchCalls = 0;

  @override
  Future<List<Song>> getRandomSongs({
    int? size,
    String? genre,
    int? fromYear,
    int? toYear,
  }) async {
    fetchCalls++;
    return <Song>[_song('remote')];
  }
}

/// 远程请求由外部 [Completer] 把门：首帧断言期间永不完成，断言完成后放行，
/// 让后台刷新的 `Future.timeout` 定时器正常收尾，避免 teardown 报 pending timer。
class _GatedPlaylistRepo extends PlaylistRepository {
  _GatedPlaylistRepo({required this.gate})
      : super(SubsonicApiClient(dio: Dio()));

  final Completer<List<Playlist>> gate;
  int fetchCalls = 0;

  @override
  Future<List<Playlist>> getPlaylists({int? size}) {
    fetchCalls++;
    return gate.future;
  }
}

class _GatedMusicRepo extends MusicRepository {
  _GatedMusicRepo({required this.gate}) : super(SubsonicApiClient(dio: Dio()));

  final Completer<List<Song>> gate;
  int fetchCalls = 0;

  @override
  Future<List<Song>> getRandomSongs({
    int? size,
    String? genre,
    int? fromYear,
    int? toYear,
  }) {
    fetchCalls++;
    return gate.future;
  }
}

ProviderContainer _container({
  required PlaylistRepository playlistRepo,
  required MusicRepository musicRepo,
  required _FakeCache cache,
}) =>
    ProviderContainer(
      overrides: <Override>[
        activeLibraryProvider.overrideWithValue(_lib()),
        activeAddressProvider.overrideWith((ref) => _addr()),
        ensureActiveAddressProvider.overrideWith((ref) async => _addr()),
        playlistRepositoryProvider.overrideWith((ref) => playlistRepo),
        musicRepositoryProvider.overrideWith((ref) => musicRepo),
        metadataCacheRepositoryProvider.overrideWith((ref) => cache),
      ],
    );

_FakeCache _cache() => _FakeCache(
      playlists: <Playlist>[_pl('cached-pl')],
      songs: <Song>[_song('cached-song')],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NetworkErrorNotifier.resetForTest();
    refreshClockForTest = DateTime.now;
    resetRefreshGateForTest();
  });

  tearDown(() {
    NetworkErrorNotifier.resetForTest();
    refreshClockForTest = DateTime.now;
    resetRefreshGateForTest();
  });

  test(
    'P0-1 provider 接线：两个 SWR provider 同库各自都能触发一次后台刷新',
    () async {
      final playlistRepo = _FakePlaylistRepo();
      final musicRepo = _FakeMusicRepo();
      final container = _container(
        playlistRepo: playlistRepo,
        musicRepo: musicRepo,
        cache: _cache(),
      );
      addTearDown(container.dispose);

      // 两个 provider 用同一个 libraryId 构建 —— 修复前闸键都是 'lib-1'，
      // 先 build 的那个吃掉键，另一个整会话不再后台刷新。
      final recent = await container.read(recentPlaylistsProvider.future);
      final random = await container.read(randomSongsProvider.future);
      expect(recent, isNotEmpty, reason: 'recentPlaylists 应命中缓存秒出');
      expect(random, isNotEmpty, reason: 'randomSongs 应命中缓存秒出');

      // 后台刷新挂在事件队列上（Future<void>(() async {...})），排空两轮，
      // 含 invalidateSelf 触发的 provider 重跑（TTL 窗口内被挡，不再发远程）。
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        playlistRepo.fetchCalls,
        1,
        reason: 'recentPlaylistsProvider 必须把 cacheFirst:true 传进 helper',
      );
      expect(
        musicRepo.fetchCalls,
        1,
        reason: '闸键不带 label 命名空间时，先 build 的 recentPlaylists 会'
            '吃掉 randomSongs 的刷新机会 —— 修复前这里恒为 0（P0-1）',
      );
    },
  );

  test(
    'P0-2 端到端：TTL 推进后 invalidate 真能再次发出远程请求（不打 provider overrideWith）',
    () async {
      var now = DateTime(2024, 1, 1);
      refreshClockForTest = () => now;
      addTearDown(() => refreshClockForTest = DateTime.now);

      final playlistRepo = _FakePlaylistRepo();
      final musicRepo = _FakeMusicRepo();
      final container = _container(
        playlistRepo: playlistRepo,
        musicRepo: musicRepo,
        cache: _cache(),
      );
      addTearDown(container.dispose);

      final first = await container.read(recentPlaylistsProvider.future);
      expect(first, isNotEmpty);
      await pumpEventQueue();
      await pumpEventQueue();
      expect(playlistRepo.fetchCalls, 1, reason: '首次 build 后台刷新一次');

      // 窗口内显式 invalidate：仍被挡（防自我刷新死循环）。
      container.invalidate(recentPlaylistsProvider);
      await container.read(recentPlaylistsProvider.future);
      await pumpEventQueue();
      expect(playlistRepo.fetchCalls, 1, reason: '10s 窗口内不重复刷新');

      // 推进超过 TTL 后再 invalidate：必须放行，真的再发一次远程请求。
      now = now.add(const Duration(seconds: 11));
      container.invalidate(recentPlaylistsProvider);
      await container.read(recentPlaylistsProvider.future);
      await pumpEventQueue();
      expect(
        playlistRepo.fetchCalls,
        2,
        reason: '一次性 Set 会让这里恒为 1：手动/下拉刷新永久退化成'
            '零远程请求（P0-2）',
      );
    },
  );

  test(
    'P0-1 provider 接线：预热缓存 + 远程永不完成 → 首帧仍秒出缓存',
    () async {
      final playlistGate = Completer<List<Playlist>>();
      final musicGate = Completer<List<Song>>();
      final playlistRepo = _GatedPlaylistRepo(gate: playlistGate);
      final musicRepo = _GatedMusicRepo(gate: musicGate);
      addTearDown(() {
        if (!playlistGate.isCompleted) {
          playlistGate.complete(<Playlist>[]);
        }
        if (!musicGate.isCompleted) {
          musicGate.complete(<Song>[]);
        }
      });
      final container = _container(
        playlistRepo: playlistRepo,
        musicRepo: musicRepo,
        cache: _cache(),
      );
      addTearDown(container.dispose);

      // 两个 provider 的远程都被把门：若任一处 `cacheFirst: true` 被删掉，
      // 首帧就会卡在远程请求上，2s 超时直接判红（不是计时抖动，是确定性失败）。
      final sw = Stopwatch()..start();
      final recent = await container
          .read(recentPlaylistsProvider.future)
          .timeout(const Duration(seconds: 2));
      final random = await container
          .read(randomSongsProvider.future)
          .timeout(const Duration(seconds: 2));
      sw.stop();

      expect(
        recent.single.id,
        'cached-pl',
        reason: '远程还没完成就必须拿到缓存首帧（recentPlaylists）',
      );
      expect(
        random.single.id,
        'cached-song',
        reason: '远程还没完成就必须拿到缓存首帧（randomSongs）',
      );
      expect(
        sw.elapsedMilliseconds,
        lessThan(100),
        reason: '两个首屏区块首帧合计应在 100ms 内返回',
      );

      // 放行远程，让后台刷新完成并取消 Future.timeout 的定时器。
      playlistGate.complete(<Playlist>[_pl('remote')]);
      musicGate.complete(<Song>[_song('remote')]);
      await pumpEventQueue();
      await pumpEventQueue();
    },
  );
}
