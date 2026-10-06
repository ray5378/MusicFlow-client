// b39b2 —— Route B：offline_cache_daemon 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * offline_cache_daemon.dart:116     _runJob 内部异常 → 记日志不抛
//   * offline_cache_daemon.dart:165-166 歌词非空 → putLyrics 落缓存
//   * offline_cache_daemon.dart:256/258 转码曲目按音质档计算 maxBitRate
//
// 产品代码零改动；仅新增 test/。

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/data/repositories/lyrics_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_cache_settings_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final _Handler handler;
  final List<Uri> requests = <Uri>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return handler(options);
  }
}

class _FakeLyricsRepository extends Mock implements LyricsRepository {}

class _MockCacheManager extends Mock implements OfflineCacheManager {}

Song _song({
  required String id,
  String? coverArt,
  String? suffix,
}) =>
    Song(id: id, title: '曲$id', coverArt: coverArt, suffix: suffix);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory tmpDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('b39b2_daemon_root_');
    tmpDir = await Directory.systemTemp.createTemp('b39b2_daemon_tmp_');
    // path_provider：getTemporaryDirectory 指向临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmpDir.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await root.exists()) await root.delete(recursive: true);
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  Future<ProviderContainer> newContainer({
    OfflineCacheManager? cacheManager,
    required _StubAdapter adapter,
    LyricsRepository? lyricsRepo,
  }) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://srv.example'));
    dio.httpClientAdapter = adapter;
    final client = SubsonicApiClient(dio: dio);
    client.setLibrary(MusicLibrary(
      id: 'lib1',
      name: '库',
      username: 'u',
      password: 'p',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    ));

    final container = ProviderContainer(overrides: [
      offlineCacheManagerProvider.overrideWithValue(
        cacheManager ?? OfflineCacheManager(rootForTest: root),
      ),
      isOfflineProvider.overrideWith((ref) => false),
      activeLibraryProvider.overrideWithValue(null),
      subsonicApiClientProvider.overrideWithValue(client),
      effectiveQualityProvider.overrideWithValue(AudioQualityLevel.standard),
      lyricsRepositoryProvider.overrideWithValue(
        lyricsRepo ?? _FakeLyricsRepository(),
      ),
    ]);
    // 预热 settings notifier 与 manager init（对齐 b34b 既有套路）。
    container.read(offlineCacheSettingsProvider.notifier);
    await container.read(offlineCacheReadyProvider.future);
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
    }
    return container;
  }

  _StubAdapter streamOkAdapter() => _StubAdapter((options) async {
        if (options.uri.path.contains('/rest/stream')) {
          return ResponseBody.fromBytes(
            List<int>.generate(64, (i) => i % 256),
            200,
            headers: {Headers.contentTypeHeader: ['audio/mpeg']},
          );
        }
        return ResponseBody.fromString('{}', 200);
      });

  group('_runJob 异常兜底（line 116）', () {
    test('hasSong 抛错 → 被吞且 onSongStartedOnline 不抛', () async {
      final mockCache = _MockCacheManager();
      when(() => mockCache.init()).thenAnswer((_) async {});
      when(() => mockCache.setEnabled(any())).thenReturn(null);
      when(() => mockCache.setMaxBytes(any())).thenAnswer((_) async {});
      when(() => mockCache.hasSong(any()))
          .thenThrow(StateError('cache broken (b39b2)'));

      final container = await newContainer(
        cacheManager: mockCache,
        adapter: _StubAdapter((options) async => ResponseBody.fromString('{}', 200)),
      );
      addTearDown(container.dispose);

      final daemon = container.read(offlineCacheDaemonProvider);
      // _cacheSongCover（无封面早退）→ _cacheSongData → hasSong 抛错 →
      // 命中 _runJob 的 catch（116），异常不冒泡。
      await expectLater(
        daemon.onSongStartedOnline(
          song: _song(id: 's1'),
          queue: <Song>[_song(id: 's1')],
          index: 0,
        ),
        completes,
      );
    });
  });

  group('歌词预缓存（line 165-166）', () {
    test('下一首歌词非空 → putLyrics 落缓存且 lyricsCached 置真', () async {
      final adapter = streamOkAdapter();
      final lyricsRepo = _FakeLyricsRepository();
      final lyrics = Lyrics(
        sourceId: 'mock',
        entries: <StructuredLyrics>[
          StructuredLyrics(
            synced: false,
            lines: <LyricsLine>[LyricsLine(value: '第一行')],
          ),
        ],
      );
      when(() => lyricsRepo.getLyrics(
            songId: any(named: 'songId'),
            title: any(named: 'title'),
            artist: any(named: 'artist'),
            album: any(named: 'album'),
            duration: any(named: 'duration'),
          )).thenAnswer((_) async => lyrics);

      final container = await newContainer(
        adapter: adapter,
        lyricsRepo: lyricsRepo,
      );
      addTearDown(container.dispose);
      final manager = container.read(offlineCacheManagerProvider);

      await container.read(offlineCacheDaemonProvider).onSongStartedOnline(
            song: _song(id: 's-cur'),
            queue: <Song>[_song(id: 's-cur')],
            index: 0,
            upcomingSong: _song(id: 's-next'),
          );

      final key = OfflineCacheManager.lyricsKey('', 's-next');
      expect(manager.lyricsCached(key), isTrue,
          reason: '非空歌词应已通过 putLyrics 写入缓存（165-166）');
      verify(() => lyricsRepo.getLyrics(
            songId: 's-next',
            title: any(named: 'title'),
            artist: any(named: 'artist'),
            album: any(named: 'album'),
            duration: any(named: 'duration'),
          )).called(1);
      expect(manager.hasSong('s-cur'), isTrue, reason: '前置：当前曲已缓存');
      expect(manager.hasSong('s-next'), isTrue, reason: '下一首音轨已缓存');
    });
  });

  group('转码曲目音质参数（line 256/258）', () {
    test('ape 需转码 → 按 standard 档计算 maxBitRate=192 并随流请求下发', () async {
      final adapter = streamOkAdapter();
      final container = await newContainer(adapter: adapter);
      addTearDown(container.dispose);
      final manager = container.read(offlineCacheManagerProvider);

      await container.read(offlineCacheDaemonProvider).onSongStartedOnline(
            song: _song(id: 's-ape', suffix: 'ape'),
            queue: <Song>[_song(id: 's-ape', suffix: 'ape')],
            index: 0,
          );

      expect(manager.hasSong('s-ape'), isTrue, reason: '转码曲应已缓存落盘');
      // _needsTranscoding('ape') → 'mp3'（format 非 null → 进入 256 分支）；
      // quality=standard → 258 求 maxBitRate（192）。
      final streamReq = adapter.requests
          .where((u) => u.path.contains('/rest/stream'))
          .toList();
      expect(streamReq, hasLength(1));
      expect(streamReq.single.queryParameters['format'], 'mp3');
      expect(streamReq.single.queryParameters['maxBitRate'], '192');
    });
  });
}
