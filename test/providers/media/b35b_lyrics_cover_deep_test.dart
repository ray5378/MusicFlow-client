// b35b: lyrics_cover_provider.dart 深水区补测(batch33 b33b 未覆盖分支)。
// 产品代码零改动。覆盖 currentLyricsProvider 的: 无当前曲短路、离线缓存命中
// /损坏回退/空串回退、试听歌曲 GD 歌词成功(含翻译)/空文本回退/异常回退/
// 缺 lyricId 跳过、在线取词成功写缓存、试听不写缓存。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/utils/lrc_parser.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/lyrics_repository.dart';
import 'package:musicflow_client/data/sources/remote/gd_music_api_client.dart';
import 'package:musicflow_client/providers/api/gd_music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../features/player/test_player_notifier.dart';

class MockOfflineCacheManager extends Mock implements OfflineCacheManager {}

class MockLyricsRepository extends Mock implements LyricsRepository {}

class MockGdMusicApiClient extends Mock implements GdMusicApiClient {}

MusicLibrary _lib() => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

Song _song({
  String id = 's1',
  bool isPreview = false,
  String? previewSource,
  String? previewTrackId,
  String? previewLyricId,
}) {
  return Song(
    id: id,
    title: 'Title',
    isPreview: isPreview,
    previewSource: previewSource,
    previewTrackId: previewTrackId,
    previewLyricId: previewLyricId,
  );
}

Lyrics _lyrics({String sourceId = 'repo'}) => Lyrics(
      sourceId: sourceId,
      entries: [LrcParser.parse('[00:01.00]hello')],
    );

void main() {
  setUpAll(() {
    registerFallbackValue(_song());
  });

  late MockOfflineCacheManager cache;
  late MockLyricsRepository repo;
  late MockGdMusicApiClient gd;
  late TestPlayerNotifier player;
  late ProviderContainer container;

  Song? currentSong;
  bool offline = false;
  String? cachedLyrics;

  ProviderContainer buildContainer() {
    return ProviderContainer(overrides: <Override>[
      playerProvider.overrideWith((ref) => player),
      activeLibraryProvider.overrideWithValue(_lib()),
      isOfflineProvider.overrideWithValue(offline),
      offlineCacheManagerProvider.overrideWithValue(cache),
      offlineCacheReadyProvider.overrideWith((ref) async {}),
      gdMusicApiClientProvider.overrideWithValue(gd),
      lyricsRepositoryProvider.overrideWithValue(repo),
    ]);
  }

  setUp(() {
    cache = MockOfflineCacheManager();
    repo = MockLyricsRepository();
    gd = MockGdMusicApiClient();
    player = TestPlayerNotifier(PlayerState());
    currentSong = _song();
    offline = false;
    cachedLyrics = null;

    when(() => cache.lyrics(any())).thenAnswer((_) async => cachedLyrics);
    when(() => cache.putLyrics(any(), any()))
        .thenAnswer((_) async {});
    when(() => repo.getLyrics(
          songId: any(named: 'songId'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        )).thenAnswer((_) async => _lyrics());
  });

  tearDown(() {
    container.dispose();
  });

  Future<Lyrics?> readLyrics() async {
    player = TestPlayerNotifier(PlayerState(currentSong: currentSong));
    container = buildContainer();
    return container.read(currentLyricsProvider.future);
  }

  test('无当前曲 → 直接 null,不触仓库/缓存', () async {
    currentSong = null;
    final got = await readLyrics();
    expect(got, isNull);
    verifyNever(() => repo.getLyrics(
          songId: any(named: 'songId'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        ));
  });

  test('离线缓存命中 → 返回缓存歌词,不走仓库', () async {
    offline = true;
    cachedLyrics = jsonEncode(_lyrics(sourceId: 'cached').toJson());
    final got = await readLyrics();
    expect(got?.sourceId, 'cached');
    verify(() => cache.lyrics(OfflineCacheManager.lyricsKey('lib-1', 's1')))
        .called(1);
    verifyNever(() => repo.getLyrics(
          songId: any(named: 'songId'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        ));
  });

  test('离线缓存损坏(JSON 非法) → 回退仓库', () async {
    offline = true;
    cachedLyrics = 'not-json-at-all';
    final got = await readLyrics();
    expect(got?.sourceId, 'repo');
  });

  test('离线缓存空串 → 回退仓库', () async {
    offline = true;
    cachedLyrics = '';
    final got = await readLyrics();
    expect(got?.sourceId, 'repo');
  });

  test('在线取词成功 → 写离线缓存(键带 libraryId)', () async {
    final got = await readLyrics();
    expect(got?.sourceId, 'repo');
    verify(() => cache.putLyrics(
          OfflineCacheManager.lyricsKey('lib-1', 's1'),
          any(),
        )).called(1);
  });

  test('在线取词为空 → 不写缓存', () async {
    when(() => repo.getLyrics(
          songId: any(named: 'songId'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        )).thenAnswer((_) async => null);
    final got = await readLyrics();
    expect(got, isNull);
    verifyNever(() => cache.putLyrics(any(), any()));
  });

  test('试听歌曲: GD 歌词成功含翻译 → 两条 entries,sourceId 前缀 gd_', () async {
    currentSong = _song(
      isPreview: true,
      previewSource: 'netease',
      previewTrackId: 't1',
    );
    when(() => gd.fetchLyrics(source: 'netease', lyricId: 't1'))
        .thenAnswer((_) async => GdLyricResult(
              lyric: '[00:01.00]hello',
              translation: '[00:01.00]你好',
            ));
    final got = await readLyrics();
    expect(got?.sourceId, 'gd_netease');
    expect(got?.entries, hasLength(2));
    verifyNever(() => cache.putLyrics(any(), any())); // 试听不写缓存
  });

  test('试听歌曲: GD 返回空文本 → 回退常规歌词源', () async {
    currentSong = _song(
      isPreview: true,
      previewSource: 'netease',
      previewTrackId: 't1',
    );
    when(() => gd.fetchLyrics(source: 'netease', lyricId: 't1'))
        .thenAnswer((_) async => GdLyricResult(lyric: '   '));
    final got = await readLyrics();
    expect(got?.sourceId, 'repo');
  });

  test('试听歌曲: GD 抛异常 → 回退常规歌词源不崩', () async {
    currentSong = _song(
      isPreview: true,
      previewSource: 'netease',
      previewTrackId: 't1',
    );
    when(() => gd.fetchLyrics(source: 'netease', lyricId: 't1'))
        .thenThrow(StateError('gd down'));
    final got = await readLyrics();
    expect(got?.sourceId, 'repo');
  });

  test('试听歌曲: previewLyricId 优先于 previewTrackId', () async {
    currentSong = _song(
      isPreview: true,
      previewSource: 'qq',
      previewTrackId: 'track-9',
      previewLyricId: 'lyric-7',
    );
    when(() => gd.fetchLyrics(source: 'qq', lyricId: 'lyric-7'))
        .thenAnswer((_) async => GdLyricResult(lyric: '[00:02.00]x'));
    final got = await readLyrics();
    expect(got?.sourceId, 'gd_qq');
    verify(() => gd.fetchLyrics(source: 'qq', lyricId: 'lyric-7')).called(1);
  });

  test('试听歌曲: source 或 lyricId 缺失 → 跳过 GD 直走仓库', () async {
    currentSong = _song(
      isPreview: true,
      previewSource: '',
      previewTrackId: 't1',
    );
    final got = await readLyrics();
    expect(got?.sourceId, 'repo');
    verifyNever(() => gd.fetchLyrics(source: any(named: 'source'),
        lyricId: any(named: 'lyricId')));
  });
}
