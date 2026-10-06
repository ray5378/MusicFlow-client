import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/song.dart';
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

typedef Handler = Future<ResponseBody> Function(RequestOptions options);

class StubAdapter implements HttpClientAdapter {
  Handler handler;
  int requestCount = 0;

  StubAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    return handler(options);
  }
}

class _FakeLyricsRepository extends Mock implements LyricsRepository {}

Song song({
  required String id,
  String title = 'T',
  String? coverArt,
  bool isPreview = false,
}) =>
    Song(id: id, title: title, coverArt: coverArt, isPreview: isPreview);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory tmpDir;
  late OfflineCacheManager manager;
  late StubAdapter adapter;
  late SubsonicApiClient client;
  late _FakeLyricsRepository lyricsRepo;
  ProviderContainer? container;

  Future<ProviderContainer> newContainer({
    bool offline = false,
    bool cacheEnabled = true,
  }) async {
    await pumpEventQueue();
    container?.dispose();
    // 缓存开关经 prefs 注入：OfflineCacheSettingsNotifier._load 异步读取。
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (!cacheEnabled) 'offline_cache_enabled': false,
    });
    container = ProviderContainer(overrides: [
      offlineCacheManagerProvider.overrideWithValue(manager),
      isOfflineProvider.overrideWith((ref) => offline),
      activeLibraryProvider.overrideWithValue(null),
      subsonicApiClientProvider.overrideWithValue(client),
      effectiveQualityProvider.overrideWithValue(AudioQualityLevel.standard),
      lyricsRepositoryProvider.overrideWithValue(lyricsRepo),
    ]);
    // 预热：立即构建 settings notifier（其 _load 异步读 prefs），并等待
    // manager init 完成；多排几轮事件循环确保 _load 走完，避免其异步链
    // 跨越 container.dispose() 边界后被记到后续用例头上。
    container!.read(offlineCacheSettingsProvider.notifier);
    await container!.read(offlineCacheReadyProvider.future);
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
    }
    return container!;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('b34b_daemon_root_');
    tmpDir = await Directory.systemTemp.createTemp('b34b_daemon_tmp_');

    // path_provider：getTemporaryDirectory 指向临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmpDir.path,
    );

    manager = OfflineCacheManager(rootForTest: root);

    adapter = StubAdapter((options) async {
      final path = options.uri.path;
      if (path.contains('/rest/stream')) {
        final id = options.uri.queryParameters['id'] ?? '';
        if (id == 'fail') {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        }
        return ResponseBody.fromBytes(
          List<int>.generate(64, (i) => i % 256),
          200,
          headers: {Headers.contentTypeHeader: ['audio/mpeg']},
        );
      }
      if (path.contains('/rest/getCoverArt')) {
        final id = options.uri.queryParameters['id'] ?? '';
        if (id == 'emptycov') {
          return ResponseBody.fromBytes(const <int>[], 200);
        }
        if (id == 'failcov') {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        }
        return ResponseBody.fromBytes(
          List<int>.generate(32, (i) => 9),
          200,
          headers: {Headers.contentTypeHeader: ['image/jpeg']},
        );
      }
      return ResponseBody.fromString('{}', 200);
    });

    final dio = Dio(BaseOptions(baseUrl: 'https://srv.example'));
    dio.httpClientAdapter = adapter;
    client = SubsonicApiClient(dio: dio);
    client.setLibrary(MusicLibrary(
      id: 'lib1',
      name: 'L',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    ));

    lyricsRepo = _FakeLyricsRepository();
    registerFallbackValue(const Duration());
    when(() => lyricsRepo.getLyrics(
          songId: any(named: 'songId'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        )).thenAnswer((_) async => null);
  });

  tearDown(() async {
    // 前后排空微任务，避免上个用例残留的异步 read 被记到下个用例头上。
    await pumpEventQueue();
    container?.dispose();
    container = null;
    await pumpEventQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    manager.dispose();
    if (await root.exists()) await root.delete(recursive: true);
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  OfflineCacheDaemon daemonOf(ProviderContainer c) =>
      c.read(offlineCacheDaemonProvider);

  group('onSongStartedOnline 前置短路', () {
    test('试听歌曲（isPreview）直接返回，不产生任何请求', () async {
      final c = await newContainer();
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 'p1', isPreview: true),
        queue: [song(id: 'p1', isPreview: true)],
        index: 0,
      );
      expect(adapter.requestCount, 0);
      expect(manager.hasSong('p1'), isFalse);
    });

    test('离线状态 → 不发起下载', () async {
      final c = await newContainer(offline: true);
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 's1'),
        queue: [song(id: 's1')],
        index: 0,
      );
      expect(adapter.requestCount, 0);
      expect(manager.hasSong('s1'), isFalse);
    });

    test('缓存开关关闭 → 不发起下载（daemon 侧短路）', () async {
      final c = await newContainer(cacheEnabled: false);
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 's1'),
        queue: [song(id: 's1')],
        index: 0,
      );
      expect(adapter.requestCount, 0);
      expect(manager.hasSong('s1'), isFalse);
    });
  });

  group('onSongStartedOnline 正常缓存', () {
    test('缓存当前曲 + 队列下一首（跳过试听曲），临时文件清理', () async {
      final c = await newContainer();
      final queue = [
        song(id: 's1'),
        song(id: 'prev', isPreview: true),
        song(id: 's2'),
      ];
      await daemonOf(c).onSongStartedOnline(
        song: queue[0],
        queue: queue,
        index: 0,
      );
      expect(manager.hasSong('s1'), isTrue);
      expect(manager.hasSong('s2'), isTrue, reason: '应缓存顺序下一首可播曲');
      expect(manager.hasSong('prev'), isFalse, reason: '试听曲不缓存');
      final tmpFiles = tmpDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'));
      expect(tmpFiles, isEmpty);
    });

    test('显式传入 upcomingSong 时优先缓存该曲（随机模式语义）', () async {
      final c = await newContainer();
      final queue = [song(id: 's1'), song(id: 's2')];
      await daemonOf(c).onSongStartedOnline(
        song: queue[0],
        queue: queue,
        index: 0,
        upcomingSong: song(id: 'random9'),
      );
      expect(manager.hasSong('s1'), isTrue);
      expect(manager.hasSong('random9'), isTrue);
      expect(manager.hasSong('s2'), isFalse);
    });

    test('流下载失败 → 不落缓存也不抛异常', () async {
      final c = await newContainer();
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 'fail'),
        queue: [song(id: 'fail')],
        index: 0,
      );
      expect(manager.hasSong('fail'), isFalse);
    });

    test('歌曲元数据（标题/歌手/专辑/时长）随缓存写入', () async {
      final c = await newContainer();
      await daemonOf(c).onSongStartedOnline(
        song: Song(
          id: 'meta1',
          title: '标题',
          artist: '歌手',
          album: '专辑',
          duration: 200,
          coverArt: 'cov-meta',
        ),
        queue: [song(id: 'meta1')],
        index: 0,
      );
      final info = manager.cachedSong('meta1');
      expect(info, isNotNull);
      expect(info!.title, '标题');
      expect(info.artist, '歌手');
      expect(info.album, '专辑');
      expect(info.durationSeconds, 200);
    });
  });

  group('封面缓存', () {
    test('coverArt 为服务端 id → 拉取后按原始 key 落缓存', () async {
      final c = await newContainer();
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 's1', coverArt: 'cov-123'),
        queue: [song(id: 's1', coverArt: 'cov-123')],
        index: 0,
      );
      expect(manager.hasCover('cov-123'), isTrue);
      expect(manager.coverFile('cov-123'), isNotNull);
    });

    test('trusted-url 引用剥掉前缀后作为 coverArt id 请求', () async {
      final c = await newContainer();
      String? requestedId;
      adapter.handler = (options) async {
        final path = options.uri.path;
        if (path.contains('/rest/getCoverArt')) {
          requestedId = options.uri.queryParameters['id'];
          return ResponseBody.fromBytes(List<int>.filled(16, 5), 200);
        }
        if (path.contains('/rest/stream')) {
          return ResponseBody.fromBytes(List<int>.filled(16, 5), 200);
        }
        return ResponseBody.fromString('{}', 200);
      };
      await daemonOf(c).onSongStartedOnline(
        song: song(
          id: 's1',
          coverArt: 'trusted-url:https://img.example/c.jpg',
        ),
        queue: [song(id: 's1')],
        index: 0,
      );
      expect(requestedId, 'https://img.example/c.jpg');
      expect(
        manager.hasCover('trusted-url:https://img.example/c.jpg'),
        isTrue,
        reason: '缓存按原始 coverArt 引用为 key',
      );
    });

    test('封面下载失败/空字节 → 跳过封面但不阻塞歌曲缓存', () async {
      final c = await newContainer();
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 's1', coverArt: 'failcov'),
        queue: [song(id: 's1', coverArt: 'failcov')],
        index: 0,
      );
      expect(manager.hasSong('s1'), isTrue);
      expect(manager.hasCover('failcov'), isFalse);

      await daemonOf(c).onSongStartedOnline(
        song: song(id: 's2', coverArt: 'emptycov'),
        queue: [song(id: 's2', coverArt: 'emptycov')],
        index: 0,
      );
      expect(manager.hasSong('s2'), isTrue);
      expect(manager.hasCover('emptycov'), isFalse);
    });

    test('已缓存的封面不重复请求', () async {
      final c = await newContainer();
      await manager.putCover('cov-dup', List<int>.filled(8, 1),
          owners: ['other']);
      final before = adapter.requestCount;
      await daemonOf(c).onSongStartedOnline(
        song: song(id: 's1', coverArt: 'cov-dup'),
        queue: [song(id: 's1', coverArt: 'cov-dup')],
        index: 0,
      );
      expect(adapter.requestCount - before, 1,
          reason: '只应发起一次 stream 下载，无 getCoverArt 请求');
    });
  });

  group('busy 串行与 pending 单槽位', () {
    test('任务执行中收到新请求 → 结束后补跑最新一份', () async {
      final c = await newContainer();
      final gate = Completer<void>();
      adapter.handler = (options) async {
        if (options.uri.path.contains('/rest/stream')) {
          final id = options.uri.queryParameters['id'] ?? '';
          if (id == 's1') await gate.future;
          return ResponseBody.fromBytes(List<int>.filled(16, 3), 200);
        }
        return ResponseBody.fromString('{}', 200);
      };

      final daemon = daemonOf(c);
      final first = daemon.onSongStartedOnline(
        song: song(id: 's1'),
        queue: [song(id: 's1')],
        index: 0,
      );
      // s1 下载阻塞中 → 新请求进入 pending 槽位。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = daemon.onSongStartedOnline(
        song: song(id: 's3'),
        queue: [song(id: 's3')],
        index: 0,
      );
      await second; // 立即返回（仅入槽）
      gate.complete();
      await first; // 首个调用 await 覆盖 pending 补跑

      expect(manager.hasSong('s1'), isTrue);
      expect(manager.hasSong('s3'), isTrue, reason: 'pending 任务应在空闲后补跑');
    });

    test('快速连切：pending 只保留最新任务', () async {
      final c = await newContainer();
      final gate = Completer<void>();
      adapter.handler = (options) async {
        if (options.uri.path.contains('/rest/stream')) {
          final id = options.uri.queryParameters['id'] ?? '';
          if (id == 's1') await gate.future;
          return ResponseBody.fromBytes(List<int>.filled(16, 3), 200);
        }
        return ResponseBody.fromString('{}', 200);
      };

      final daemon = daemonOf(c);
      final first = daemon.onSongStartedOnline(
        song: song(id: 's1'),
        queue: [song(id: 's1')],
        index: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await daemon.onSongStartedOnline(
        song: song(id: 's2'),
        queue: [song(id: 's2')],
        index: 0,
      );
      await daemon.onSongStartedOnline(
        song: song(id: 's4'),
        queue: [song(id: 's4')],
        index: 0,
      );
      gate.complete();
      await first;

      expect(manager.hasSong('s1'), isTrue);
      expect(manager.hasSong('s4'), isTrue, reason: '最终只补跑最新任务 s4');
    });
  });

  group('cachePlaylistCover', () {
    test('空 key / 动态歌单名 → 不请求不落缓存', () async {
      final c = await newContainer();
      final daemon = daemonOf(c);
      await daemon.cachePlaylistCover('   ');
      await daemon.cachePlaylistCover('cov-x', playlistName: '今日漫游');
      await daemon.cachePlaylistCover('cov-x', playlistName: 'random songs');
      expect(adapter.requestCount, 0);
      expect(manager.hasPlaylistCover('cov-x'), isFalse);
    });

    test('普通歌单封面正常拉取落缓存', () async {
      final c = await newContainer();
      await daemonOf(c).cachePlaylistCover('pl-cov-1',
          playlistName: 'My Favorites');
      expect(manager.hasPlaylistCover('pl-cov-1'), isTrue);
      expect(manager.playlistCoverFile('pl-cov-1'), isNotNull);
    });
  });
}
