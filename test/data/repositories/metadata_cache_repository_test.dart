import 'dart:io';

import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mf_meta_cache_test');
    JsonFileStore.instance.debugDirectory = tempDir;
  });

  tearDown(() async {
    JsonFileStore.instance.debugDirectory = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('song removal repairs detail and summary caches', () async {
    final repository = MetadataCacheRepository();
    final songs = <Song>[
      Song(id: 'song-a', title: 'A', duration: 100),
      Song(id: 'song-b', title: 'B', duration: 200),
      Song(id: 'song-c', title: 'C', duration: 300),
    ];
    final playlist = Playlist(
      id: 'playlist-1',
      name: 'Cached playlist',
      songCount: songs.length,
      duration: 600,
      songs: songs,
    );
    await repository.cachePlaylistDetail('library-1', playlist);
    await repository.cachePlaylists('library-1', <Playlist>[
      Playlist(
        id: playlist.id,
        name: playlist.name,
        songCount: playlist.songCount,
        duration: playlist.duration,
      ),
    ]);

    await repository.cachePlaylistSongRemoval(
      libraryId: 'library-1',
      playlist: playlist,
      removedIndexes: <int>{1},
    );

    final detail = await repository.getPlaylistDetail('library-1', playlist.id);
    final summaries = await repository.getPlaylists('library-1');
    expect(detail, isNotNull);
    expect(detail!.songs!.map((song) => song.id), <String>['song-a', 'song-c']);
    expect(detail.songCount, 2);
    expect(detail.duration, 400);
    expect(summaries, isNotNull);
    expect(summaries!.single.songCount, 2);
    expect(summaries.single.duration, 400);
  });

  test('file store writes are atomic and readable across instances', () async {
    await JsonFileStore.instance.writeString('k', 'v1');
    expect(await JsonFileStore.instance.readString('k'), 'v1');
    await JsonFileStore.instance.writeString('k', 'v2');
    expect(await JsonFileStore.instance.readString('k'), 'v2');
    await JsonFileStore.instance.remove('k');
    expect(await JsonFileStore.instance.readString('k'), isNull);
    // 不存在的键返回 null 而不是抛错。
    expect(await JsonFileStore.instance.readString('missing'), isNull);
  });
}
