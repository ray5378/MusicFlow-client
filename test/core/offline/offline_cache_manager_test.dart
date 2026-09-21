import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';

/// 离线缓存管理器单元测试。
///
/// 通过 `rootForTest` 注入临时目录，脱离 path_provider 在纯 VM 环境跑。
///
/// 断言要读落盘结果时（典型：「同根目录重开 manager」用例）一律调
/// `await m.flushIndexNow()` —— 直接绕过 1 秒 debounce 立即写 index.json，
/// 结果确定且不用等墙钟。

void main() {
  late Directory base;
  // 本文件创建过的所有 manager：tearDown 先 dispose（取消 pending debounce
  // 落盘）再删目录。不再依赖 1.3s 墙钟等待 —— 满负载下 Timer 会迟到，
  // 删完目录才落盘即 PathNotFound，异步异常记到无关用例头上随机失败。
  final managers = <OfflineCacheManager>[];

  setUp(() async {
    base = await Directory.systemTemp.createTemp('offline_cache_test');
  });

  tearDown(() async {
    for (final m in managers) {
      m.dispose();
    }
    managers.clear();
    if (await base.exists()) await base.delete(recursive: true);
  });

  OfflineCacheManager newManager() {
    final m = OfflineCacheManager(rootForTest: base);
    managers.add(m);
    return m;
  }

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

    await m.flushIndexNow();
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

    await m.flushIndexNow();
  });

  test('putLyrics 后 lyricsCached 与 lyrics 读取一致', () async {
    final m = newManager();
    await m.init();
    const text = '[00:00.00]测试歌词第一行\n[00:05.00]第二行';
    await m.putLyrics('s1', text);

    expect(m.lyricsCached('s1'), isTrue);
    expect(await m.lyrics('s1'), text);

    await m.flushIndexNow();
  });

  test('putPlaylistCover 后 hasPlaylistCover 生效', () async {
    final m = newManager();
    await m.init();
    await m.putPlaylistCover('p1', Uint8List.fromList(List.filled(24, 5)));

    expect(m.hasPlaylistCover('p1'), isTrue);
    expect(m.playlistCoverFile('p1')!.existsSync(), isTrue);
    expect(m.countByKind()[OfflineCacheKind.playlistCover], 1);

    await m.flushIndexNow();
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

    await m.flushIndexNow();
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
    await first.flushIndexNow();

    final second = newManager();
    await second.init();

    expect(second.hasSong('s1'), isTrue);
    expect(second.songFile('s1')!.existsSync(), isTrue);
    expect(second.cachedSongs.single.title, '持久化的歌');
    expect(second.hasCover('c1'), isTrue);
    expect(second.lyricsCached('s1'), isTrue);

    await second.flushIndexNow();
  });

  test('cachedSongs 按 lastAccess 新→旧排序', () async {
    final m = newManager();
    await m.init();
    await m.putSong('a', Uint8List.fromList(List.filled(10, 1)));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await m.putSong('b', Uint8List.fromList(List.filled(10, 2)));

    expect(m.cachedSongs.map((s) => s.songId).toList(), ['b', 'a']);

    await m.flushIndexNow();
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

    await m.flushIndexNow();
  });

  test('关闭 + clearAll 后磁盘无缓存文件（设置层「关闭并清除」路径）', () async {
    final m = newManager();
    await m.init();
    await m.putSong('s1', Uint8List.fromList(List.filled(8, 1)));
    await m.putCover('c1', Uint8List.fromList(List.filled(8, 2)),
        owners: ['s1']);
    await m.flushIndexNow();

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

    await m.flushIndexNow();
  });

  test('dispose 后删目录再等过 debounce：pending 落盘不抛异常（回归）', () async {
    // 回归：debounce 落盘 Timer 若在 tearDown 删目录后才触发，_atomicPromote
    // 抛 PathNotFound，异步异常记到当时正在跑的用例头上 → 全量满负载下随机失败。
    // 修法双保险：dispose 取消 Timer；_flushIndex 遇目录消失静默跳过。
    final dir = await Directory.systemTemp.createTemp('offline_cache_dispose');
    final m = OfflineCacheManager(rootForTest: dir);
    await m.init();
    await m.putSong('s1', Uint8List.fromList(List.filled(8, 1)));
    m.dispose();
    await dir.delete(recursive: true);
    // 等过 debounce 窗口：若修法失效，这里会抛 PathNotFound 使本用例变红。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(m.hasSong('s1'), isTrue); // 内存态不受影响
  });

}
