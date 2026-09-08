import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';

/// 离线缓存管理器单元测试。
///
/// 通过 `rootForTest` 注入临时目录，脱离 path_provider 在纯 VM 环境跑。
/// 所有变更缓存的用例都在最后写入后调用 [settleIndexFlush]（等待 1 秒
/// debounce 定时器到期并把 index.json 落盘），保证持久化断言确定、
/// 且测试收尾时不留 pending 定时器。
Future<void> settleIndexFlush() =>
    Future.delayed(const Duration(milliseconds: 1300));

void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('offline_cache_test');
  });

  tearDown(() async {
    // 先等 debounce 定时器把 index.json 落盘，再删临时目录，避免用例中断时
    // pending 写盘撞上目录已删除而抛异步 PathNotFound 污染测试结果。
    await settleIndexFlush();
    if (await base.exists()) await base.delete(recursive: true);
  });

  OfflineCacheManager newManager() =>
      OfflineCacheManager(rootForTest: base);

  test('putSong 写入后 hasSong/cachedSongs/count/songFile 均生效', () async {
    final m = newManager();
    await m.init();
    final bytes = Uint8List.fromList(List.filled(16, 7));
    await m.putSong('s1', bytes,
        meta: {
          'songId': 's1',
          'title': '春江花月夜',
          'artist': '测试',
          'album': '碟',
          'duration': 180,
        });

    expect(m.hasSong('s1'), isTrue);
    expect(m.countByKind()[OfflineCacheKind.song], 1);

    final file = m.songFile('s1');
    expect(file, isNotNull);
    expect(file!.existsSync(), isTrue);

    final cached = m.cachedSongs.single;
    expect(cached.title, '春江花月夜');
    expect(cached.artist, '测试');
    expect(cached.size, bytes.length);

    await settleIndexFlush();
  });

  test('putCover 写入后封面在索引中且 owners 归属正确（防 owners bug 回归）',
      () async {
    final m = newManager();
    await m.init();
    // 旧 bug 下 owners 在 const [] 上调 addAll 抛 UnsupportedError，导致
    // 封面条目永远进不了索引、封面计数恒为 0。这里断言 hasCover 与计数，
    // 正是对旧 bug 可观测行为的防回归。
    await m.putCover('c1', Uint8List.fromList(List.filled(32, 9)),
        owners: ['s1', 's2', '']);

    expect(m.hasCover('c1'), isTrue);
    expect(m.countByKind()[OfflineCacheKind.cover], 1);
    expect(m.coverFile('c1')!.existsSync(), isTrue);

    await m.putCover('c2', Uint8List.fromList(List.filled(16, 1)),
        owners: ['s9']);
    expect(m.countByKind()[OfflineCacheKind.cover], 2);

    await settleIndexFlush();
  });

  test('putLyrics 后 lyricsCached 与 lyrics 读取一致', () async {
    final m = newManager();
    await m.init();
    const text = '[00:00.00]测试歌词第一行\n[00:05.00]第二行';
    await m.putLyrics('s1', text);

    expect(m.lyricsCached('s1'), isTrue);
    expect(await m.lyrics('s1'), text);

    await settleIndexFlush();
  });

  test('putPlaylistCover 后 hasPlaylistCover 生效', () async {
    final m = newManager();
    await m.init();
    await m.putPlaylistCover('p1', Uint8List.fromList(List.filled(24, 5)));

    expect(m.hasPlaylistCover('p1'), isTrue);
    expect(m.playlistCoverFile('p1')!.existsSync(), isTrue);
    expect(m.countByKind()[OfflineCacheKind.playlistCover], 1);

    await settleIndexFlush();
  });

  test('evictSong 删歌+歌词+仅归属该歌的封面，共享封面保留', () async {
    final m = newManager();
    await m.init();
    await m.putSong('s1', Uint8List.fromList(List.filled(8, 1)));
    await m.putSong('s2', Uint8List.fromList(List.filled(8, 2)));
    await m.putLyrics('s1', 'x');
    await m.putCover('only-s1', Uint8List.fromList(List.filled(4, 3)),
        owners: ['s1']);
    await m.putCover('shared', Uint8List.fromList(List.filled(4, 4)),
        owners: ['s1', 's2']);
    await m.putCover('only-s2', Uint8List.fromList(List.filled(4, 5)),
        owners: ['s2']);

    await m.evictSong('s1');

    expect(m.hasSong('s1'), isFalse);
    expect(m.lyricsCached('s1'), isFalse);
    expect(m.hasCover('only-s1'), isFalse);
    // 共享封面保留，仅归属 s2 的封面也保留。
    expect(m.hasCover('shared'), isTrue);
    expect(m.hasCover('only-s2'), isTrue);
    expect(m.countByKind()[OfflineCacheKind.cover], 2);

    await settleIndexFlush();
  });

  test('setMaxBytes 超容量时 LRU 轮转最久未最近访问者(歌曲 evict 不死锁)', () async {
    final m = newManager();
    await m.init();

    // 用歌曲条目触发 evict：经 _writeBytes 的串行化上下文进入 _evictToFit 的
    // 歌曲分支。回归守护提防 _evictSongInternal 仍包 _synchronized 导致的嵌套
    // 自锁死锁（修复前此用例会挂到超时）。
    await m.setMaxBytes(42);
    await m.putSong('a', Uint8List.fromList(List.filled(20, 1)));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await m.putSong('b', Uint8List.fromList(List.filled(20, 2)));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await m.putSong('c', Uint8List.fromList(List.filled(20, 3)));

    expect(m.hasSong('a'), isFalse,
        reason: '最久未访问的 a 应被 LRU 轮转清掉');
    expect(m.hasSong('b'), isTrue);
    expect(m.hasSong('c'), isTrue);
    expect(m.countByKind()[OfflineCacheKind.song], 2);
  });

  test('持久化：同根目录重开 manager 后条目与索引仍在', () async {
    final first = newManager();
    await first.init();
    await first.putSong('s1', Uint8List.fromList(List.filled(12, 1)),
        meta: {'songId': 's1', 'title': '持久化的歌', 'artist': 'a'});
    await first.putCover('c1', Uint8List.fromList(List.filled(8, 2)),
        owners: ['s1']);
    await first.putLyrics('s1', 'lyric');
    await settleIndexFlush();

    final second = newManager();
    await second.init();

    expect(second.hasSong('s1'), isTrue);
    expect(second.songFile('s1')!.existsSync(), isTrue);
    expect(second.cachedSongs.single.title, '持久化的歌');
    expect(second.hasCover('c1'), isTrue);
    expect(second.lyricsCached('s1'), isTrue);

    await settleIndexFlush();
  });

  test('cachedSongs 按 lastAccess 新→旧排序', () async {
    final m = newManager();
    await m.init();
    await m.putSong('a', Uint8List.fromList(List.filled(10, 1)));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await m.putSong('b', Uint8List.fromList(List.filled(10, 2)));

    expect(m.cachedSongs.map((s) => s.songId).toList(), ['b', 'a']);

    await settleIndexFlush();
  });

  test('关闭后所有 put* 均不落盘，重新开启恢复写入', () async {
    final m = newManager();
    await m.init();

    // 先正常写入一条作为「已有缓存」基线。
    await m.putSong('kept', Uint8List.fromList(List.filled(8, 1)));
    expect(m.hasSong('kept'), isTrue);

    // 关闭：写入全部 no-op。
    m.setEnabled(false);
    expect(m.enabled, isFalse);
    await m.putSong('blocked', Uint8List.fromList(List.filled(8, 2)));
    await m.putCover('c-blocked', Uint8List.fromList(List.filled(8, 3)),
        owners: ['blocked']);
    await m.putLyrics('blocked', 'lyric');
    await m.putPlaylistCover('p-blocked', Uint8List.fromList(List.filled(8, 4)));
    await m.putSongFromFile('blocked2', File('definitely_missing_file.bin'));

    expect(m.hasSong('blocked'), isFalse);
    expect(m.hasCover('c-blocked'), isFalse);
    expect(m.lyricsCached('blocked'), isFalse);
    expect(m.hasPlaylistCover('p-blocked'), isFalse);
    expect(m.countByKind()[OfflineCacheKind.song], 1);
    // 关闭前的内容不被主动清除（清除由设置层调 clearAll）。
    expect(m.hasSong('kept'), isTrue);

    // 重新开启：写入恢复。
    m.setEnabled(true);
    await m.putSong('again', Uint8List.fromList(List.filled(8, 5)));
    expect(m.hasSong('again'), isTrue);

    await settleIndexFlush();
  });

  test('关闭 + clearAll 后磁盘无缓存文件（设置层「关闭并清除」路径）', () async {
    final m = newManager();
    await m.init();
    await m.putSong('s1', Uint8List.fromList(List.filled(8, 1)));
    await m.putCover('c1', Uint8List.fromList(List.filled(8, 2)),
        owners: ['s1']);
    await settleIndexFlush();

    m.setEnabled(false);
    await m.clearAll();

    expect(m.totalBytes, 0);
    expect(m.countByKind().values.every((c) => c == 0), isTrue);
    // index.json 是空索引清单（非缓存内容），数据子目录不应残留任何文件。
    final root = Directory('${base.path}${Platform.pathSeparator}offline_cache');
    if (await root.exists()) {
      await for (final entity in root.list(recursive: true)) {
        if (entity is File && entity.parent.path != root.path) {
          fail('关闭清空后不应残留缓存数据文件: ${entity.path}');
        }
      }
    }

    await settleIndexFlush();
  });
}