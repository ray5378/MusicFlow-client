import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// 音乐仓库假实现：只覆盖 music_provider 真正调用到的方法。
class _FakeRepo extends MusicRepository {
  _FakeRepo() : super(SubsonicApiClient(dio: Dio()));

  List<Song> songs = <Song>[];
  List<Album> albums = <Album>[];
  List<Artist> artists = <Artist>[];
  AlbumDetail? albumDetail;
  ArtistDetail? artistDetail;
  SearchResult? searchResult;
  StarredResult? starredResult;

  Object? error;

  void failWith(Object e) => error = e;

  T _guard<T>(T value) {
    final current = error;
    if (current != null) throw current;
    return value;
  }

  @override
  Future<List<Song>> getRandomSongs({
    int? size,
    String? genre,
    int? fromYear,
    int? toYear,
  }) async =>
      _guard(songs);

  @override
  Future<List<Album>> getAlbumList({
    required String type,
    int? size,
    int? offset,
  }) async =>
      _guard(albums);

  @override
  Future<AlbumDetail?> getAlbum(String albumId) async => _guard(albumDetail);

  @override
  Future<List<Song>> getAllSongs({String query = ''}) async => _guard(songs);

  @override
  Future<List<Album>> getAllAlbums({String query = ''}) async => _guard(albums);

  @override
  Future<List<Artist>> getAllArtists({String query = ''}) async =>
      _guard(artists);

  @override
  Future<ArtistDetail?> getArtist(String artistId) async =>
      _guard(artistDetail);

  @override
  Future<List<Song>> getTopSongs(String artistName, {int? count}) async =>
      _guard(songs);

  @override
  Future<SearchResult> search({
    required String query,
    int? artistCount,
    int? albumCount,
    int? songCount,
  }) async =>
      _guard(
        searchResult ??
            SearchResult(artists: const [], albums: const [], songs: const []),
      );

  @override
  Future<StarredResult> getStarred() async => _guard(
        starredResult ??
            StarredResult(artists: const [], albums: const [], songs: const []),
      );
}

/// 元数据缓存仓库假实现：内存态，可注入读失败。
class _FakeCache extends MetadataCacheRepository {
  final List<String> calls = <String>[];

  List<Song>? randomSongs;
  List<Album>? recentAlbums;
  List<Album>? frequentAlbums;
  List<Album>? newestAlbums;
  List<Album>? allAlbums;
  AlbumDetail? albumDetail;
  List<Song>? allSongs;
  List<Artist>? allArtists;
  ArtistDetailCache? artistDetail;
  StarredCache? starred;

  bool failRead = false;

  void _note(String op) {
    calls.add(op);
    if (failRead && op.startsWith('read:')) {
      throw StateError('cache read boom: $op');
    }
  }

  @override
  Future<void> cacheRandomSongs(String libraryId, List<Song> songs) async {
    _note('write:randomSongs');
    randomSongs = songs;
  }

  @override
  Future<List<Song>?> getRandomSongs(String libraryId) async {
    _note('read:randomSongs');
    return randomSongs;
  }

  @override
  Future<void> cacheRecentAlbums(String libraryId, List<Album> albums) async {
    _note('write:recentAlbums');
    recentAlbums = albums;
  }

  @override
  Future<List<Album>?> getRecentAlbums(String libraryId) async {
    _note('read:recentAlbums');
    return recentAlbums;
  }

  @override
  Future<void> cacheFrequentAlbums(String libraryId, List<Album> albums) async {
    _note('write:frequentAlbums');
    frequentAlbums = albums;
  }

  @override
  Future<List<Album>?> getFrequentAlbums(String libraryId) async {
    _note('read:frequentAlbums');
    return frequentAlbums;
  }

  @override
  Future<void> cacheNewestAlbums(String libraryId, List<Album> albums) async {
    _note('write:newestAlbums');
    newestAlbums = albums;
  }

  @override
  Future<List<Album>?> getNewestAlbums(String libraryId) async {
    _note('read:newestAlbums');
    return newestAlbums;
  }

  @override
  Future<void> cacheAllAlbums(String libraryId, List<Album> albums) async {
    _note('write:allAlbums');
    allAlbums = albums;
  }

  @override
  Future<List<Album>?> getAllAlbums(String libraryId) async {
    _note('read:allAlbums');
    return allAlbums;
  }

  @override
  Future<void> cacheAlbumDetail(String libraryId, AlbumDetail detail) async {
    _note('write:albumDetail');
    albumDetail = detail;
  }

  @override
  Future<AlbumDetail?> getAlbumDetail(String libraryId, String albumId) async {
    _note('read:albumDetail');
    return albumDetail;
  }

  @override
  Future<void> cacheAllSongs(String libraryId, List<Song> songs) async {
    _note('write:allSongs');
    allSongs = songs;
  }

  @override
  Future<List<Song>?> getAllSongs(String libraryId) async {
    _note('read:allSongs');
    return allSongs;
  }

  @override
  Future<void> cacheAllArtists(String libraryId, List<Artist> artists) async {
    _note('write:allArtists');
    allArtists = artists;
  }

  @override
  Future<List<Artist>?> getAllArtists(String libraryId) async {
    _note('read:allArtists');
    return allArtists;
  }

  @override
  Future<void> cacheArtistDetail(
    String libraryId,
    Artist artist,
    List<Album> albums,
    List<Song> songs,
  ) async {
    _note('write:artistDetail');
    artistDetail = ArtistDetailCache(
      artist: artist,
      albums: albums,
      songs: songs,
    );
  }

  @override
  Future<ArtistDetailCache?> getArtistDetail(
    String libraryId,
    String artistId,
  ) async {
    _note('read:artistDetail');
    return artistDetail;
  }

  @override
  Future<void> cacheStarred(
    String libraryId, {
    required List<Artist> artists,
    required List<Album> albums,
    required List<Song> songs,
  }) async {
    _note('write:starred');
    starred = StarredCache(artists: artists, albums: albums, songs: songs);
  }

  @override
  Future<StarredCache?> getStarred(String libraryId) async {
    _note('read:starred');
    return starred;
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

MusicLibrary _library() => MusicLibrary(
      id: 'lib-1',
      name: 'Test Library',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

ServerAddress _address() => ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
    );

Song _song(String id) => Song(id: id, title: 'Song $id', duration: 120);

Album _album(String id) => Album(id: id, name: 'Album $id', songCount: 1, duration: 120);

Artist _artist(String id) => Artist(id: id, name: 'Artist $id');

ProviderContainer _container({
  required _FakeRepo repo,
  required _FakeCache cache,
  MusicLibrary? library,
  bool hasLibrary = true,
  bool addressOk = true,
}) {
  return ProviderContainer(
    overrides: <Override>[
      musicRepositoryProvider.overrideWithValue(repo),
      metadataCacheRepositoryProvider.overrideWithValue(cache),
      activeLibraryProvider.overrideWithValue(hasLibrary ? _library() : null),
      ensureActiveAddressProvider.overrideWith((ref) async {
        if (!addressOk) throw StateError('offline');
        return _address();
      }),
    ],
  );
}

void main() {
  // 远程失败且无缓存兜底时会走 NetworkErrorNotifier.show → ToastNotifier
  // （读 rootNavigatorKey.currentState），需要绑定已初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('musicRepositoryProvider 无活跃库时返回 null', () {
    final container = ProviderContainer(
      overrides: <Override>[activeLibraryProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    expect(container.read(musicRepositoryProvider), isNull);
  });

  test('musicRepositoryProvider 有活跃库时按 apiClient 构建仓库', () {
    final container = ProviderContainer(
      overrides: <Override>[
        activeLibraryProvider.overrideWithValue(_library()),
        subsonicApiClientProvider.overrideWithValue(
          SubsonicApiClient(dio: Dio()),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(musicRepositoryProvider), isA<MusicRepository>());
  });

  test('各区块失败标记 Provider 默认均为 false', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(randomSongsLoadFailedProvider), isFalse);
    expect(container.read(recentAlbumsLoadFailedProvider), isFalse);
    expect(container.read(frequentAlbumsLoadFailedProvider), isFalse);
    expect(container.read(allSongsLoadFailedProvider), isFalse);
    expect(container.read(allAlbumsLoadFailedProvider), isFalse);
    expect(container.read(albumDetailLoadFailedProvider('al-1')), isFalse);
    expect(container.read(newestAlbumsLoadFailedProvider), isFalse);
    expect(container.read(allArtistsLoadFailedProvider), isFalse);
    expect(container.read(artistDetailLoadFailedProvider('ar-1')), isFalse);
    expect(container.read(starredLoadFailedProvider), isFalse);
    expect(container.read(topSongsByArtistLoadFailedProvider('A')), isFalse);
    expect(container.read(searchLoadFailedProvider('q')), isFalse);
  });

  test('notifyRandomSongsChanged 广播单调递增的版本号', () async {
    final seen = <int>[];
    final subscription = randomSongsChangedStream().listen(seen.add);
    addTearDown(subscription.cancel);

    notifyRandomSongsChanged();
    await Future<void>.delayed(Duration.zero);
    notifyRandomSongsChanged();
    await Future<void>.delayed(Duration.zero);

    expect(seen.length, 2);
    expect(seen[1], greaterThan(seen[0]));
  });

  test('randomSongs 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..songs = <Song>[_song('s1'), _song('s2')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(randomSongsProvider, (_, __) {});
    final songs = await container.read(randomSongsProvider.future);

    expect(songs.map((e) => e.id).toList(), <String>['s1', 's2']);
    expect(cache.calls, contains('write:randomSongs'));
    expect(cache.randomSongs?.length, 2);
    expect(container.read(randomSongsLoadFailedProvider), isFalse);
  });

  test('randomSongs 远程失败且缓存命中：回落缓存', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache()..randomSongs = <Song>[_song('cached')];
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(randomSongsProvider, (_, __) {});
    final songs = await container.read(randomSongsProvider.future);

    expect(songs.single.id, 'cached');
    expect(cache.calls, contains('read:randomSongs'));
    expect(container.read(randomSongsLoadFailedProvider), isFalse);
  });

  test('randomSongs 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(randomSongsProvider, (_, __) {});
    final songs = await container.read(randomSongsProvider.future);

    expect(songs, isEmpty);
    expect(container.read(randomSongsLoadFailedProvider), isTrue);
  });

  test('randomSongs 远程失败且缓存读取抛异常：降级为空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache()
      ..failRead = true
      ..randomSongs = <Song>[_song('cached')];
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(randomSongsProvider, (_, __) {});
    final songs = await container.read(randomSongsProvider.future);

    expect(songs, isEmpty);
    expect(container.read(randomSongsLoadFailedProvider), isTrue);
  });

  test('recentAlbums 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(recentAlbumsProvider, (_, __) {});
    final albums = await container.read(recentAlbumsProvider.future);

    expect(albums, isEmpty);
    expect(cache.calls, contains('read:recentAlbums'));
    expect(container.read(recentAlbumsLoadFailedProvider), isTrue);
  });

  test('recentAlbums 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..albums = <Album>[_album('a1')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(recentAlbumsProvider, (_, __) {});
    final albums = await container.read(recentAlbumsProvider.future);

    expect(albums.single.id, 'a1');
    expect(cache.calls, contains('write:recentAlbums'));
    expect(container.read(recentAlbumsLoadFailedProvider), isFalse);
  });

  test('frequentAlbums 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(frequentAlbumsProvider, (_, __) {});
    final albums = await container.read(frequentAlbumsProvider.future);

    expect(albums, isEmpty);
    expect(cache.calls, contains('read:frequentAlbums'));
    expect(container.read(frequentAlbumsLoadFailedProvider), isTrue);
  });

  test('frequentAlbums 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..albums = <Album>[_album('f1')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(frequentAlbumsProvider, (_, __) {});
    final albums = await container.read(frequentAlbumsProvider.future);

    expect(albums.single.id, 'f1');
    expect(cache.calls, contains('write:frequentAlbums'));
    expect(container.read(frequentAlbumsLoadFailedProvider), isFalse);
  });

  test('newestAlbums 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(newestAlbumsProvider, (_, __) {});
    final albums = await container.read(newestAlbumsProvider.future);

    expect(albums, isEmpty);
    expect(cache.calls, contains('read:newestAlbums'));
    expect(container.read(newestAlbumsLoadFailedProvider), isTrue);
  });

  test('newestAlbums 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..albums = <Album>[_album('n1')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(newestAlbumsProvider, (_, __) {});
    final albums = await container.read(newestAlbumsProvider.future);

    expect(albums.single.id, 'n1');
    expect(cache.calls, contains('write:newestAlbums'));
    expect(container.read(newestAlbumsLoadFailedProvider), isFalse);
  });

  test('allAlbums 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(allAlbumsProvider, (_, __) {});
    final albums = await container.read(allAlbumsProvider.future);

    expect(albums, isEmpty);
    expect(cache.calls, contains('read:allAlbums'));
    expect(container.read(allAlbumsLoadFailedProvider), isTrue);
  });

  test('allAlbums 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..albums = <Album>[_album('b1'), _album('b2')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(allAlbumsProvider, (_, __) {});
    final albums = await container.read(allAlbumsProvider.future);

    expect(albums.map((e) => e.id).toList(), <String>['b1', 'b2']);
    expect(cache.calls, contains('write:allAlbums'));
    expect(container.read(allAlbumsLoadFailedProvider), isFalse);
  });

  test('albumDetail 远程成功：写缓存并返回详情', () async {
    final repo = _FakeRepo()
      ..albumDetail = AlbumDetail(
        album: _album('al-1'),
        songs: <Song>[_song('s1')],
      );
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = albumDetailProvider('al-1');
    container.listen(provider, (_, __) {});
    final detail = await container.read(provider.future);

    expect(detail, isNotNull);
    expect(detail!.album.id, 'al-1');
    expect(detail.songs.single.id, 's1');
    expect(cache.calls, contains('write:albumDetail'));
    expect(container.read(albumDetailLoadFailedProvider('al-1')), isFalse);
  });

  test('albumDetail 活跃库为空时直接返回 null', () async {
    final repo = _FakeRepo();
    final cache = _FakeCache();
    final container = _container(
      repo: repo,
      cache: cache,
      hasLibrary: false,
    );
    addTearDown(container.dispose);

    final provider = albumDetailProvider('al-1');
    container.listen(provider, (_, __) {});
    final detail = await container.read(provider.future);

    expect(detail, isNull);
    expect(cache.calls, isEmpty);
  });

  test('albumDetail 远程失败且无缓存：返回 null 并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = albumDetailProvider('al-missing');
    container.listen(provider, (_, __) {});
    final detail = await container.read(provider.future);

    expect(detail, isNull);
    expect(cache.calls, contains('read:albumDetail'));
    expect(container.read(albumDetailLoadFailedProvider('al-missing')), isTrue);
  });

  test('allSongs 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..songs = <Song>[_song('s1')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(allSongsProvider, (_, __) {});
    final songs = await container.read(allSongsProvider.future);

    expect(songs.single.id, 's1');
    expect(cache.calls, contains('write:allSongs'));
    expect(container.read(allSongsLoadFailedProvider), isFalse);
  });

  test('allSongs 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(allSongsProvider, (_, __) {});
    final songs = await container.read(allSongsProvider.future);

    expect(songs, isEmpty);
    expect(cache.calls, contains('read:allSongs'));
    expect(container.read(allSongsLoadFailedProvider), isTrue);
  });

  test('allArtists 远程成功：写缓存并清失败标记', () async {
    final repo = _FakeRepo()..artists = <Artist>[_artist('ar-1')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(allArtistsProvider, (_, __) {});
    final artists = await container.read(allArtistsProvider.future);

    expect(artists.single.id, 'ar-1');
    expect(cache.calls, contains('write:allArtists'));
    expect(container.read(allArtistsLoadFailedProvider), isFalse);
  });

  test('allArtists 远程失败且无缓存：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(allArtistsProvider, (_, __) {});
    final artists = await container.read(allArtistsProvider.future);

    expect(artists, isEmpty);
    expect(cache.calls, contains('read:allArtists'));
    expect(container.read(allArtistsLoadFailedProvider), isTrue);
  });

  test('artistDetail 远程成功：写缓存并返回详情', () async {
    final repo = _FakeRepo()
      ..artistDetail = ArtistDetail(
        artist: _artist('ar-1'),
        albums: <Album>[_album('al-1')],
        songs: <Song>[_song('s1')],
      );
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = artistDetailProvider('ar-1');
    container.listen(provider, (_, __) {});
    final detail = await container.read(provider.future);

    expect(detail, isNotNull);
    expect(detail!.artist.id, 'ar-1');
    expect(cache.calls, contains('write:artistDetail'));
    expect(container.read(artistDetailLoadFailedProvider('ar-1')), isFalse);
  });

  test('artistDetail 远程失败且缓存命中：重建 ArtistDetail 返回', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache()
      ..artistDetail = ArtistDetailCache(
        artist: _artist('ar-9'),
        albums: <Album>[_album('al-9')],
        songs: <Song>[_song('s9')],
      );
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = artistDetailProvider('ar-9');
    container.listen(provider, (_, __) {});
    final detail = await container.read(provider.future);

    expect(detail, isNotNull);
    expect(detail!.artist.id, 'ar-9');
    expect(detail.albums.single.id, 'al-9');
    expect(detail.songs.single.id, 's9');
    expect(cache.calls, contains('read:artistDetail'));
    expect(container.read(artistDetailLoadFailedProvider('ar-9')), isFalse);
  });

  test('topSongs 远程成功：返回歌曲并清失败标记', () async {
    final repo = _FakeRepo()..songs = <Song>[_song('t1')];
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = topSongsByArtistProvider('Alice');
    container.listen(provider, (_, __) {});
    final songs = await container.read(provider.future);

    expect(songs.single.id, 't1');
    expect(container.read(topSongsByArtistLoadFailedProvider('Alice')), isFalse);
  });

  test('topSongs 远程失败：返回空并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = topSongsByArtistProvider('Bob');
    container.listen(provider, (_, __) {});
    final songs = await container.read(provider.future);

    expect(songs, isEmpty);
    expect(container.read(topSongsByArtistLoadFailedProvider('Bob')), isTrue);
  });

  test('topSongs 歌手名为空白：不请求直接返回空', () async {
    final repo = _FakeRepo()..failWith(StateError('must not be called'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = topSongsByArtistProvider('   ');
    container.listen(provider, (_, __) {});
    final songs = await container.read(provider.future);

    expect(songs, isEmpty);
  });

  test('search 远程成功：返回结果并清失败标记', () async {
    final repo = _FakeRepo()
      ..searchResult = SearchResult(
        artists: <Artist>[_artist('ar-1')],
        albums: <Album>[],
        songs: <Song>[_song('s1')],
      );
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final flag = searchLoadFailedProvider('q1');
    container.listen(flag, (_, __) {});
    container.read(flag.notifier).state = true;

    final provider = searchProvider('q1');
    container.listen(provider, (_, __) {});
    final result = await container.read(provider.future);

    expect(result.artists.single.id, 'ar-1');
    expect(result.songs.single.id, 's1');
    expect(container.read(flag), isFalse);
  });

  test('search 远程失败：返回空结果并标记失败', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final flag = searchLoadFailedProvider('q2');
    container.listen(flag, (_, __) {});

    final provider = searchProvider('q2');
    container.listen(provider, (_, __) {});
    final result = await container.read(provider.future);

    expect(result.isEmpty, isTrue);
    expect(container.read(flag), isTrue);
  });

  test('search 空查询：不请求直接返回空结果', () async {
    final repo = _FakeRepo()..failWith(StateError('must not be called'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final provider = searchProvider('');
    container.listen(provider, (_, __) {});
    final result = await container.read(provider.future);

    expect(result.isEmpty, isTrue);
    expect(cache.calls, isEmpty);
  });

  test('starred 远程成功：写缓存并返回收藏', () async {
    final repo = _FakeRepo()
      ..starredResult = StarredResult(
        artists: <Artist>[_artist('ar-1')],
        albums: <Album>[_album('al-1')],
        songs: <Song>[_song('s1')],
      );
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(starredProvider, (_, __) {});
    final result = await container.read(starredProvider.future);

    expect(result.songs.single.id, 's1');
    expect(cache.calls, contains('write:starred'));
    expect(container.read(starredLoadFailedProvider), isFalse);
  });

  test('starred 远程失败且缓存命中：重建 StarredResult 返回', () async {
    final repo = _FakeRepo()..failWith(StateError('offline'));
    final cache = _FakeCache()
      ..starred = StarredCache(
        artists: <Artist>[_artist('ar-7')],
        albums: <Album>[],
        songs: <Song>[_song('s7')],
      );
    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    container.listen(starredProvider, (_, __) {});
    final result = await container.read(starredProvider.future);

    expect(result.artists.single.id, 'ar-7');
    expect(result.songs.single.id, 's7');
    expect(cache.calls, contains('read:starred'));
    expect(container.read(starredLoadFailedProvider), isFalse);
  });

  test('starred 活跃库为空时直接返回空收藏', () async {
    final repo = _FakeRepo()..failWith(StateError('must not be called'));
    final cache = _FakeCache();
    final container = _container(repo: repo, cache: cache, hasLibrary: false);
    addTearDown(container.dispose);

    container.listen(starredProvider, (_, __) {});
    final result = await container.read(starredProvider.future);

    expect(result.isEmpty, isTrue);
    expect(cache.calls, isEmpty);
  });
}
