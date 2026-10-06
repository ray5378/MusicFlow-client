import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';

void main() {
  late Directory root;
  late OfflineCacheManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('b34b_cache_');
    manager = OfflineCacheManager(rootForTest: root);
    await manager.init();
  });

  tearDown(() async {
    manager.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('putSongFromFile', () {
    test('磁盘源文件拷入缓存，元数据可读回，字节数正确', () async {
      final src = File('${root.path}/src_s1.mp3');
      await src.writeAsBytes(List<int>.generate(100, (i) => i % 256));
      await manager.putSongFromFile('s1', src, meta: {
        'songId': 's1',
        'title': 'Song One',
        'artist': 'Artist',
        'album': 'Album',
        'duration': 180,
        'coverArt': 'cov1',
      });
      expect(manager.hasSong('s1'), isTrue);
      expect(manager.totalBytes, 100);
      final info = manager.cachedSong('s1');
      expect(info, isNotNull);
      expect(info!.title, 'Song One');
      expect(info.artist, 'Artist');
      expect(info.album, 'Album');
      expect(info.durationSeconds, 180);
      expect(info.coverArt, 'cov1');
      expect(info.size, 100);
      final file = manager.songFile('s1');
      expect(file, isNotNull);
      expect(await file!.length(), 100);
    });

    test('重复写入同一歌曲：总量按新文件计（不叠加旧条目）', () async {
      final srcA = File('${root.path}/a.mp3');
      await srcA.writeAsBytes(List<int>.filled(100, 1));
      final srcB = File('${root.path}/b.mp3');
      await srcB.writeAsBytes(List<int>.filled(300, 2));
      await manager.putSongFromFile('s1', srcA);
      expect(manager.totalBytes, 100);
      await manager.putSongFromFile('s1', srcB);
      expect(manager.totalBytes, 300);
      expect(manager.hasSong('s1'), isTrue);
    });

    test('源文件不存在 / 空文件 / 关闭开关 → 均为 no-op', () async {
      await manager.putSongFromFile('ghost', File('${root.path}/missing.mp3'));
      expect(manager.hasSong('ghost'), isFalse);

      final empty = File('${root.path}/empty.mp3');
      await empty.writeAsBytes(const <int>[]);
      await manager.putSongFromFile('empty', empty);
      expect(manager.hasSong('empty'), isFalse);

      manager.setEnabled(false);
      final src = File('${root.path}/x.mp3');
      await src.writeAsBytes(List<int>.filled(10, 9));
      await manager.putSongFromFile('off', src);
      expect(manager.hasSong('off'), isFalse);
      expect(manager.totalBytes, 0);
    });
  });

  group('歌词键与歌词读写', () {
    test('lyricsKey：带 libraryId 拼接隔离，空 libraryId 回退裸 songId', () {
      expect(OfflineCacheManager.lyricsKey('lib1', 's1'), 'lib1:s1');
      expect(OfflineCacheManager.lyricsKey('', 's1'), 's1');
    });

    test('evictSong 连同带 libraryId 前缀的歌词一并删除', () async {
      await manager.putSong('s1', List<int>.filled(10, 1));
      await manager.putLyrics(
        OfflineCacheManager.lyricsKey('lib1', 's1'),
        'hello lyrics',
      );
      expect(manager.lyricsCached('lib1:s1'), isTrue);
      await manager.evictSong('s1');
      expect(manager.hasSong('s1'), isFalse);
      expect(manager.lyricsCached('lib1:s1'), isFalse);
      expect(await manager.lyrics('lib1:s1'), isNull);
    });

    test('空文本 / 空键不写入；写入后读回一致', () async {
      await manager.putLyrics('s1', '');
      expect(manager.lyricsCached('s1'), isFalse);
      await manager.putLyrics('', 'text');
      expect(manager.lyricsCached(''), isFalse);

      await manager.putLyrics('s2', '中文歌词内容');
      expect(await manager.lyrics('s2'), '中文歌词内容');
    });
  });

  group('封面归属（owners）', () {
    test('空 owner 被过滤；仅归属该歌的封面随 evictSong 删除，共享封面保留',
        () async {
      await manager.putCover('c1', List<int>.filled(10, 1), owners: ['', 'x']);
      await manager.putCover('c2', List<int>.filled(10, 1),
          owners: ['y', 'x']);
      await manager.putCover('c3', List<int>.filled(10, 1), owners: ['z']);
      await manager.evictSong('x');
      expect(manager.hasCover('c1'), isFalse, reason: 'c1 过滤后仅归属 x');
      expect(manager.hasCover('c2'), isTrue, reason: 'c2 同时归属 y，保留');
      expect(manager.hasCover('c3'), isTrue);
      expect(manager.coverFile('c2'), isNotNull);
    });

    test('空 coverKey / 空 bytes 不写入', () async {
      await manager.putCover('', List<int>.filled(5, 1));
      expect(manager.hasCover(''), isFalse);
      await manager.putCover('empty', const <int>[]);
      expect(manager.hasCover('empty'), isFalse);
      await manager.putPlaylistCover('', List<int>.filled(5, 1));
      expect(manager.hasPlaylistCover(''), isFalse);
    });
  });

  group('LRU 轮转', () {
    test('cachedSong 访问会 touch 条目，使其在容量紧张时免于淘汰', () async {
      await manager.putSong('s1', List<int>.filled(100, 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putSong('s2', List<int>.filled(100, 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      manager.cachedSong('s1'); // touch s1 → s1 变为新
      await manager.setMaxBytes(150);
      expect(manager.hasSong('s1'), isTrue);
      expect(manager.hasSong('s2'), isFalse);
    });

    test('非歌曲条目（封面/歌单封面）按 LRU 直接删除', () async {
      await manager.putCover('c1', List<int>.filled(100, 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putPlaylistCover('p1', List<int>.filled(100, 1));
      await manager.setMaxBytes(150);
      expect(manager.hasCover('c1'), isFalse, reason: 'c1 更早写入先淘汰');
      expect(manager.hasPlaylistCover('p1'), isTrue);
      expect(manager.playlistCoverFile('p1'), isNotNull);
    });

    test('setMaxBytes 非法值回退默认容量', () async {
      await manager.setMaxBytes(0);
      expect(manager.maxBytes, 2 * 1024 * 1024 * 1024);
      await manager.setMaxBytes(-5);
      expect(manager.maxBytes, 2 * 1024 * 1024 * 1024);
      await manager.setMaxBytes(4096);
      expect(manager.maxBytes, 4096);
    });
  });

  group('索引持久化', () {
    test('flushIndexNow 立即落盘：重开 manager 无需等 debounce 即可恢复', () async {
      await manager.putSong('s1', List<int>.filled(64, 7));
      await manager.putLyrics('s1', 'lyr');
      await manager.flushIndexNow();

      final reopened = OfflineCacheManager(rootForTest: root);
      await reopened.init();
      expect(reopened.hasSong('s1'), isTrue);
      // 歌曲文件 64 字节 + 歌词 'lyr' 3 字节。
      expect(reopened.totalBytes, 67);
      expect(reopened.lyricsCached('s1'), isTrue);
      reopened.dispose();
    });

    test('索引损坏 → 清空重建不抛异常，之后可正常写入', () async {
      manager.dispose();
      await File('${root.path}/offline_cache/index.json')
          .writeAsString('{corrupt json!!!');
      final fresh = OfflineCacheManager(rootForTest: root);
      await fresh.init();
      expect(fresh.totalBytes, 0);
      expect(fresh.cachedSongs, isEmpty);
      await fresh.putSong('s1', List<int>.filled(10, 1));
      expect(fresh.hasSong('s1'), isTrue);
      fresh.dispose();
    });

    test('索引里指向已丢失文件的条目被跳过（不虚增 totalBytes）', () async {
      await manager.putSong('s1', List<int>.filled(64, 1));
      await manager.putCover('c1', List<int>.filled(32, 1));
      await manager.flushIndexNow();
      manager.dispose();

      // 删除歌曲数据文件，模拟「有索引无文件」孤儿。
      final songFile = manager.songFile('s1')!;
      await songFile.delete();

      final reopened = OfflineCacheManager(rootForTest: root);
      await reopened.init();
      expect(reopened.hasSong('s1'), isFalse);
      expect(reopened.hasCover('c1'), isTrue);
      expect(reopened.totalBytes, 32);
      reopened.dispose();
    });
  });

  group('safeName 安全化', () {
    test('路径分隔符/非法字符替换为下划线，连续下划线折叠', () {
      expect(OfflineCacheManager.safeName('a/b\\c:d*e'), 'a_b_c_d_e');
      expect(OfflineCacheManager.safeName('a__b___c'), 'a_b_c');
      expect(OfflineCacheManager.safeName('  spaced  '), 'spaced');
      expect(OfflineCacheManager.safeName('ok-name.1_2'), 'ok-name.1_2');
    });

    test('空串返回占位符；超长截断到 120', () {
      expect(OfflineCacheManager.safeName(''), '_');
      expect(OfflineCacheManager.safeName('///'), '_');
      final long = 'x' * 300;
      expect(OfflineCacheManager.safeName(long).length, 120);
    });
  });

  group('clearAll / countByKind / cachedSongs', () {
    test('clearAll 清空内存索引与磁盘文件', () async {
      await manager.putSong('s1', List<int>.filled(10, 1));
      await manager.putCover('c1', List<int>.filled(10, 1));
      await manager.putLyrics('s1', 'text');
      await manager.putPlaylistCover('p1', List<int>.filled(10, 1));
      expect(manager.countByKind(), {
        OfflineCacheKind.song: 1,
        OfflineCacheKind.cover: 1,
        OfflineCacheKind.lyric: 1,
        OfflineCacheKind.playlistCover: 1,
      });

      await manager.clearAll();
      expect(manager.totalBytes, 0);
      expect(manager.hasSong('s1'), isFalse);
      expect(manager.hasCover('c1'), isFalse);
      expect(manager.lyricsCached('s1'), isFalse);
      expect(manager.hasPlaylistCover('p1'), isFalse);
      expect(manager.cachedSongs, isEmpty);
      for (final kind in OfflineCacheKind.values) {
        final dir = Directory(
          '${root.path}/offline_cache/${_subdir(kind)}',
        );
        if (await dir.exists()) {
          expect(await dir.list().isEmpty, isTrue, reason: '$kind 目录应为空');
        }
      }
    });

    test('cachedSongs 无 meta 时用 songId 兜底标题、空 artist', () async {
      await manager.putSong('raw1', List<int>.filled(8, 1));
      final list = manager.cachedSongs;
      expect(list, hasLength(1));
      expect(list.single.songId, 'raw1');
      expect(list.single.title, 'raw1');
      expect(list.single.artist, '');
      expect(list.single.size, 8);
    });
  });

  group('json 索引往返（_CacheEntry 序列化）', () {
    test('owners/meta/kind 在落盘重开后保持', () async {
      await manager.putSong('s1', List<int>.filled(16, 1), meta: {
        'songId': 's1',
        'title': 'T',
      });
      await manager.putCover('cov', List<int>.filled(16, 1),
          owners: ['s1', 's2']);
      await manager.flushIndexNow();
      manager.dispose();

      final raw = jsonDecode(
              await File('${root.path}/offline_cache/index.json')
                  .readAsString())
          as Map<String, dynamic>;
      expect(raw['version'], 1);
      final entries = (raw['entries'] as List).cast<Map<String, dynamic>>();
      final coverEntry = entries.firstWhere((e) => e['kind'] == 'cover');
      expect(coverEntry['owners'], ['s1', 's2']);
      final songEntry = entries.firstWhere((e) => e['kind'] == 'song');
      expect(songEntry['meta']['title'], 'T');

      final reopened = OfflineCacheManager(rootForTest: root);
      await reopened.init();
      expect(reopened.cachedSong('s1')!.title, 'T');
      expect(reopened.hasCover('cov'), isTrue);
      reopened.dispose();
    });
  });
}

String _subdir(OfflineCacheKind kind) => switch (kind) {
      OfflineCacheKind.song => 'songs',
      OfflineCacheKind.cover => 'covers',
      OfflineCacheKind.lyric => 'lyrics',
      OfflineCacheKind.playlistCover => 'playlist_covers',
    };
