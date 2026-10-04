import 'dart:convert';
import 'dart:io';

import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// batch29-B：`lib/data/repositories/metadata_cache_repository.dart`
/// 补测（覆盖率 79/202 = 39.11%）。
///
/// 打法：该仓库只依赖 [JsonFileStore]（文件 KV）与 [Isolate.run]，没有 DB、
/// 没有网络，因此把 `debugDirectory` 指向临时目录即可跑到真落盘路径；
/// 所有「字段缺失 / 坏条目 / 空列表」分支都用**直接写原始 JSON 文件**构造，
/// 走的是与线上完全相同的 `_readMap` 读取链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String lib = 'b29b';

  late Directory tempDir;
  late MetadataCacheRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mf_b29b_meta_cache');
    JsonFileStore.instance.debugDirectory = tempDir;
    repo = MetadataCacheRepository();
  });

  tearDown(() async {
    JsonFileStore.instance.debugDirectory = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 复刻私有 `_key(libraryId, scope)`，用于直接往文件里塞畸形缓存。
  String _key(String scope) => 'metadata_cache_v1_${lib}_$scope';

  Future<void> _writeRaw(String scope, String content) =>
      JsonFileStore.instance.writeString(_key(scope), content);

  /// 直接写任意缓存键（用于构造 [MetadataCacheRepository._lastLibraryKey]
  /// 这类不带 scope 的键）。
  Future<void> _writeRawKey(String fullKey, String content) =>
      JsonFileStore.instance.writeString(fullKey, content);

  Song _song(String id, {int duration = 60}) =>
      Song(id: id, title: 'T$id', duration: duration);

  Playlist _playlist(String id, List<Song> songs, {int duration = 600}) =>
      Playlist(
        id: id,
        name: 'P$id',
        songCount: songs.length,
        duration: duration,
        created: DateTime.fromMillisecondsSinceEpoch(1600000000000),
        changed: DateTime.fromMillisecondsSinceEpoch(1600000000000),
        songs: songs,
      );

  Album _album(String id) => Album(
    id: id,
    name: 'A$id',
    songCount: 1,
    duration: 100,
  );

  Artist _artist(String id) => Artist(id: id, name: 'R$id');

  // ---------------------------------------------------------------------------
  // last library id
  // ---------------------------------------------------------------------------

  test('setLastLibraryId 收到空 id 直接返回，不落任何文件', () async {
    await repo.setLastLibraryId('');

    expect(await repo.getLastLibraryId(), isNull);
    expect(
      tempDir.listSync(recursive: true).where((f) => f.path.endsWith('.json')),
      isEmpty,
    );
  });

  test('setLastLibraryId / getLastLibraryId 往返一致', () async {
    await repo.setLastLibraryId('lib-9');

    expect(await repo.getLastLibraryId(), 'lib-9');
  });

  test('getLastLibraryId 读到空字符串时视为未缓存', () async {
    await _writeRawKey('metadata_cache_v1_last_library', '');

    expect(await repo.getLastLibraryId(), isNull);
  });

  // ---------------------------------------------------------------------------
  // _readMap
  // ---------------------------------------------------------------------------

  test('_readMap 读到非法 JSON 时只告警并返回 null（不抛出）', () async {
    await _writeRaw('home_random_songs', '{not-a-json');

    expect(await repo.getRandomSongs(lib), isNull);
  });

  test('_readMap 读到空字符串视为未命中', () async {
    await _writeRaw('home_random_songs', '');

    expect(await repo.getRandomSongs(lib), isNull);
  });

  // ---------------------------------------------------------------------------
  // random songs
  // ---------------------------------------------------------------------------

  test('cacheRandomSongs 后 getRandomSongs 能还原歌曲列表', () async {
    await repo.cacheRandomSongs(lib, <Song>[_song('r1'), _song('r2')]);

    final songs = await repo.getRandomSongs(lib);
    expect(songs!.map((s) => s.id).toList(), <String>['r1', 'r2']);
  });

  test('cacheRandomSongs 会把 libraryId 记成最近使用库', () async {
    await repo.cacheRandomSongs(lib, <Song>[_song('r1')]);

    expect(await repo.getLastLibraryId(), lib);
  });

  test('getRandomSongs 缓存里是空歌曲列表时返回 null', () async {
    await repo.cacheRandomSongs(lib, const <Song>[]);

    expect(await repo.getRandomSongs(lib), isNull);
  });

  test('getRandomSongsWithMeta 返回歌曲与缓存写入时间', () async {
    await repo.cacheRandomSongs(lib, <Song>[_song('m1'), _song('m2')]);

    final meta = await repo.getRandomSongsWithMeta(lib);
    expect(meta!.songs.map((s) => s.id).toList(), <String>['m1', 'm2']);
    expect(meta.cachedAt.millisecondsSinceEpoch, greaterThan(0));
  });

  test('getRandomSongsWithMeta 缓存缺失时返回 null', () async {
    expect(await repo.getRandomSongsWithMeta(lib), isNull);
  });

  test('getRandomSongsWithMeta 缓存歌曲为空时返回 null', () async {
    await repo.cacheRandomSongs(lib, const <Song>[]);

    expect(await repo.getRandomSongsWithMeta(lib), isNull);
  });

  test('_parseCachedSongs 跳过非 Map 与空 Map 条目', () async {
    await _writeRaw(
      'home_random_songs',
      '''{"songs":[{"id":"ok1","title":"OK1"},"i-am-a-string",{},null],"cachedAt":1700000000000}''',
    );

    final songs = await repo.getRandomSongs(lib);
    expect(songs!.map((s) => s.id).toList(), <String>['ok1']);
  });

  test('getRandomSongsWithMeta 对坏条目同样容忍', () async {
    await _writeRaw(
      'home_random_songs',
      '''{"songs":[{"id":"ok1"},null],"cachedAt":1700000000000}''',
    );

    final meta = await repo.getRandomSongsWithMeta(lib);
    expect(meta!.songs.map((s) => s.id).toList(), <String>['ok1']);
    expect(meta.cachedAt.millisecondsSinceEpoch, 1700000000000);
  });

  // ---------------------------------------------------------------------------
  // recent / frequent albums
  // ---------------------------------------------------------------------------

  test('cacheRecentAlbums / getRecentAlbums 往返', () async {
    await repo.cacheRecentAlbums(lib, <Album>[_album('rec1'), _album('rec2')]);

    final albums = await repo.getRecentAlbums(lib);
    expect(albums!.map((a) => a.id).toList(), <String>['rec1', 'rec2']);
  });

  test('getRecentAlbums 缓存未命中时返回 null', () async {
    expect(await repo.getRecentAlbums(lib), isNull);
  });

  test('getRecentAlbums 用兼容解析跳过坏条目', () async {
    await _writeRaw(
      'home_recent_albums',
      '''{"albums":[{"id":"good","name":"G"},{"id":7,"name":"BAD"},"junk"],"cachedAt":1700000000000}''',
    );

    final albums = await repo.getRecentAlbums(lib);
    expect(albums!.map((a) => a.id).toList(), <String>['good']);
  });

  test('cacheFrequentAlbums / getFrequentAlbums 往返', () async {
    await repo.cacheFrequentAlbums(lib, <Album>[_album('fr1')]);

    final albums = await repo.getFrequentAlbums(lib);
    expect(albums!.map((a) => a.id).toList(), <String>['fr1']);
  });

  test('getFrequentAlbums 读到 albums 为 null 时返回 null', () async {
    await _writeRaw('home_frequent_albums', '{"albums":null,"cachedAt":1}');

    expect(await repo.getFrequentAlbums(lib), isNull);
  });

  // ---------------------------------------------------------------------------
  // all songs / all albums
  // ---------------------------------------------------------------------------

  test('cacheAllSongs / getAllSongs 往返', () async {
    await repo.cacheAllSongs(lib, <Song>[_song('s1'), _song('s2')]);

    final songs = await repo.getAllSongs(lib);
    expect(songs!.map((s) => s.id).toList(), <String>['s1', 's2']);
  });

  test('getAllSongs 读到 songs 为 null 时返回 null', () async {
    await _writeRaw('all_songs', '{"songs":null,"cachedAt":1}');

    expect(await repo.getAllSongs(lib), isNull);
  });

  test('cacheAllAlbums / getAllAlbums 往返', () async {
    await repo.cacheAllAlbums(lib, <Album>[_album('al1')]);

    final albums = await repo.getAllAlbums(lib);
    expect(albums!.map((a) => a.id).toList(), <String>['al1']);
  });

  test('getAllAlbums 读到 albums 为 null 时返回 null', () async {
    await _writeRaw('all_albums', '{"albums":null,"cachedAt":1}');

    expect(await repo.getAllAlbums(lib), isNull);
  });

  // ---------------------------------------------------------------------------
  // album detail
  // ---------------------------------------------------------------------------

  test('cacheAlbumDetail / getAlbumDetail 往返', () async {
    final detail = AlbumDetail(
      album: _album('dt1'),
      songs: <Song>[_song('dt1-1'), _song('dt1-2')],
    );
    await repo.cacheAlbumDetail(lib, detail);

    final got = await repo.getAlbumDetail(lib, 'dt1');
    expect(got!.album.id, 'dt1');
    expect(got.songs.map((s) => s.id).toList(), <String>['dt1-1', 'dt1-2']);
  });

  test('getAlbumDetail 缓存缺失时返回 null', () async {
    expect(await repo.getAlbumDetail(lib, 'nope'), isNull);
  });

  test('getAlbumDetail 只有 songs 字段时返回 null', () async {
    await _writeRaw(
      'album_detail_nope',
      '{"album":null,"songs":[],"cachedAt":1}',
    );

    expect(await repo.getAlbumDetail(lib, 'nope'), isNull);
  });

  test('getAlbumDetail 只有 album 字段时返回 null', () async {
    await _writeRaw(
      'album_detail_half',
      '{"album":{"id":"h","name":"H"},"songs":null,"cachedAt":1}',
    );

    expect(await repo.getAlbumDetail(lib, 'half'), isNull);
  });

  // ---------------------------------------------------------------------------
  // playlists
  // ---------------------------------------------------------------------------

  test('cachePlaylists / getPlaylists 往返', () async {
    await repo.cachePlaylists(lib, <Playlist>[_playlist('pl1', <Song>[])]);

    final playlists = await repo.getPlaylists(lib);
    expect(playlists!.single.id, 'pl1');
  });

  test('getPlaylists 读到 playlists 为 null 时返回 null', () async {
    await _writeRaw('playlists', '{"playlists":null,"cachedAt":1}');

    expect(await repo.getPlaylists(lib), isNull);
  });

  test('cachePlaylistDetail / getPlaylistDetail 往返', () async {
    await repo.cachePlaylistDetail(
      lib,
      _playlist('pd1', <Song>[_song('pd1-1')]),
    );

    final got = await repo.getPlaylistDetail(lib, 'pd1');
    expect(got!.songCount, 1);
    expect(got.songs!.single.id, 'pd1-1');
  });

  test('getPlaylistDetail 缓存缺失时返回 null', () async {
    expect(await repo.getPlaylistDetail(lib, 'nope'), isNull);
  });

  test('getPlaylistDetail 只有 cachedAt 时返回 null', () async {
    await _writeRaw('playlist_detail_nope', '{"cachedAt":1}');

    expect(await repo.getPlaylistDetail(lib, 'nope'), isNull);
  });

  // ---------------------------------------------------------------------------
  // cachePlaylistSongRemoval
  // ---------------------------------------------------------------------------

  test('cachePlaylistSongRemoval 在 songs 为 null 时直接返回', () async {
    // [Playlist] 是普通类（不是 freezed），只能靠 fromJson 构造出 songs == null
    // 的实例——这也是线上唯一能造出该分支的路径：兼容解析删掉全部歌曲后落盘。
    // 先落一份正常明细作为「基准」，再验证 removal 提前 return 时它没被改写。
    final cached = _playlist('rm-null', <Song>[_song('k1')]);
    await repo.cachePlaylistDetail(lib, cached);

    final playlist = Playlist.fromJson(
      jsonDecode('{"id":"rm-null","name":"N","songCount":3,"duration":30}')
          as Map<String, dynamic>,
    );
    expect(playlist.songs, isNull);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{0},
    );

    final got = await repo.getPlaylistDetail(lib, 'rm-null');
    expect(got!.songCount, 1);
    expect(got.songs!.single.id, 'k1');
  });

  test('cachePlaylistSongRemoval 在 removedIndexes 为空时直接返回', () async {
    final playlist = _playlist('rm-empty', <Song>[_song('e1')]);
    await repo.cachePlaylistDetail(lib, playlist);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{},
    );

    final got = await repo.getPlaylistDetail(lib, 'rm-empty');
    expect(got!.songCount, 1);
  });

  test('cachePlaylistSongRemoval 在索引全部越界时直接返回', () async {
    final playlist = _playlist('rm-oob', <Song>[_song('o1')]);
    await repo.cachePlaylistDetail(lib, playlist);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{-1, 9},
    );

    final got = await repo.getPlaylistDetail(lib, 'rm-oob');
    expect(got!.songCount, 1);
  });

  test('cachePlaylistSongRemoval 正常移除并同时修好列表视图与明细', () async {
    final songs = <Song>[_song('x1', duration: 10), _song('x2', duration: 20)];
    final playlist = _playlist('rm-ok', songs, duration: 30);
    await repo.cachePlaylistDetail(lib, playlist);
    await repo.cachePlaylists(lib, <Playlist>[playlist]);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{0},
    );

    final detail = await repo.getPlaylistDetail(lib, 'rm-ok');
    expect(detail!.songs!.map((s) => s.id).toList(), <String>['x2']);
    expect(detail.songCount, 1);
    expect(detail.duration, 20);

    final list = await repo.getPlaylists(lib);
    expect(list!.single.songCount, 1);
    expect(list.single.duration, 20);
  });

  test('cachePlaylistSongRemoval 扣减时长为负数时钳制为 0', () async {
    final songs = <Song>[_song('n1', duration: 90), _song('n2', duration: 90)];
    final playlist = _playlist('rm-neg', songs, duration: 100);
    await repo.cachePlaylistDetail(lib, playlist);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{0, 1},
    );

    final detail = await repo.getPlaylistDetail(lib, 'rm-neg');
    expect(detail!.duration, 0);
    expect(detail.songs!.isEmpty, isTrue);
  });

  test('cachePlaylistSongRemoval 列表缓存未命中时只修明细', () async {
    final playlist = _playlist('rm-nolist', <Song>[_song('q1')]);
    await repo.cachePlaylistDetail(lib, playlist);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{0},
    );

    expect(await repo.getPlaylistDetail(lib, 'rm-nolist'), isNotNull);
    expect(await repo.getPlaylists(lib), isNull);
  });

  test('cachePlaylistSongRemoval 列表缓存里没有该歌单时只修明细', () async {
    final playlist = _playlist('rm-other', <Song>[_song('z1')]);
    await repo.cachePlaylistDetail(lib, playlist);
    await repo.cachePlaylists(lib, <Playlist>[_playlist('pl-other', <Song>[])]);

    await repo.cachePlaylistSongRemoval(
      libraryId: lib,
      playlist: playlist,
      removedIndexes: <int>{0},
    );

    final list = await repo.getPlaylists(lib);
    expect(list!.single.songCount, 0);
  });

  test('clearPlaylistCaches 清掉明细与列表两处缓存', () async {
    final playlist = _playlist('clr', <Song>[_song('c1')]);
    await repo.cachePlaylistDetail(lib, playlist);
    await repo.cachePlaylists(lib, <Playlist>[playlist]);

    await repo.clearPlaylistCaches(lib, 'clr');

    expect(await repo.getPlaylistDetail(lib, 'clr'), isNull);
    expect(await repo.getPlaylists(lib), isNull);
  });

  // ---------------------------------------------------------------------------
  // newest albums / all artists
  // ---------------------------------------------------------------------------

  test('cacheNewestAlbums / getNewestAlbums 往返', () async {
    await repo.cacheNewestAlbums(lib, <Album>[_album('nw1')]);

    final albums = await repo.getNewestAlbums(lib);
    expect(albums!.map((a) => a.id).toList(), <String>['nw1']);
  });

  test('getNewestAlbums 读到 albums 为 null 时返回 null', () async {
    await _writeRaw('newest_albums', '{"albums":null,"cachedAt":1}');

    expect(await repo.getNewestAlbums(lib), isNull);
  });

  test('cacheAllArtists / getAllArtists 往返', () async {
    await repo.cacheAllArtists(lib, <Artist>[_artist('ar1'), _artist('ar2')]);

    final artists = await repo.getAllArtists(lib);
    expect(artists!.map((a) => a.id).toList(), <String>['ar1', 'ar2']);
  });

  test('getAllArtists 读到 artists 为 null 时返回 null', () async {
    await _writeRaw('all_artists', '{"artists":null,"cachedAt":1}');

    expect(await repo.getAllArtists(lib), isNull);
  });

  // ---------------------------------------------------------------------------
  // artist detail
  // ---------------------------------------------------------------------------

  test('cacheArtistDetail / getArtistDetail 往返', () async {
    await repo.cacheArtistDetail(
      lib,
      _artist('adt1'),
      <Album>[_album('adt1-al')],
      <Song>[_song('adt1-s')],
    );

    final got = await repo.getArtistDetail(lib, 'adt1');
    expect(got!.artist.id, 'adt1');
    expect(got.albums.single.id, 'adt1-al');
    expect(got.songs.single.id, 'adt1-s');
  });

  test('getArtistDetail 缓存缺失时返回 null', () async {
    expect(await repo.getArtistDetail(lib, 'nope'), isNull);
  });

  test('getArtistDetail 缺少 artist 字段时返回 null', () async {
    await _writeRaw('artist_detail_half', '{"album":[],"cachedAt":1}');

    expect(await repo.getArtistDetail(lib, 'half'), isNull);
  });

  test('getArtistDetail albums 为 null 时返回 null', () async {
    await _writeRaw(
      'artist_detail_noalbums',
      '{"artist":{"id":"na","name":"NA"},"albums":null,"cachedAt":1}',
    );

    expect(await repo.getArtistDetail(lib, 'noalbums'), isNull);
  });

  test('getArtistDetail songs 为 null 时退化为空歌曲列表', () async {
    await _writeRaw(
      'artist_detail_nosongs',
      '{"artist":{"id":"ns","name":"NS"},"albums":[],"cachedAt":1}',
    );

    final got = await repo.getArtistDetail(lib, 'nosongs');
    expect(got!.artist.id, 'ns');
    expect(got.songs, isEmpty);
  });

  // ---------------------------------------------------------------------------
  // starred
  // ---------------------------------------------------------------------------

  test('cacheStarred / getStarred 往返', () async {
    await repo.cacheStarred(
      lib,
      artists: <Artist>[_artist('st-a')],
      albums: <Album>[_album('st-al')],
      songs: <Song>[_song('st-s')],
    );

    final got = await repo.getStarred(lib);
    expect(got!.artists.single.id, 'st-a');
    expect(got.albums.single.id, 'st-al');
    expect(got.songs.single.id, 'st-s');
  });

  test('getStarred 缓存缺失时返回 null', () async {
    expect(await repo.getStarred(lib), isNull);
  });

  test('getStarred 三个列表任一为 null 时返回 null', () async {
    await _writeRaw('starred', '{"artists":null,"albums":[],"songs":[]}');

    expect(await repo.getStarred(lib), isNull);
  });

  test('getStarred 容忍单条坏数据（兼容解析）', () async {
    await _writeRaw(
      'starred',
      '''{"artists":[{"id":5,"name":"BAD"}],"albums":[{"id":"ba","name":"BA"}],"songs":[{"id":"bs","title":"BS"}]}''',
    );

    final got = await repo.getStarred(lib);
    expect(got!.albums.single.id, 'ba');
    expect(got.songs.single.id, 'bs');
    expect(got.artists, isEmpty);
  });
}
