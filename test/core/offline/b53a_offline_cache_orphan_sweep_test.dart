import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';

/// b53a（T07）：离线缓存**孤儿回收**回归。
///
/// 背景：索引是缓存的唯一权威，但 `init()` 过去只做 `_loadIndex()`，没有反向
/// 清理。索引一旦损坏就被清空重建，此刻磁盘上全部数据文件都变成孤儿；再加上
/// 「写完文件、1s debounce 未到被杀」与「删条目后文件删除失败」两条路径，孤儿
/// 只涨不消（`covers` 是容量大头），泄漏到用户的存储配额上。本用例把「启动即
/// 以索引为准回收孤儿」钉死，同时守住「不误删已在索引里的正常缓存」。
void main() {
  late Directory root;
  late OfflineCacheManager manager;

  Directory cacheRoot() => Directory('${root.path}/offline_cache');
  Directory sub(String name) => Directory('${cacheRoot().path}/$name');

  Future<void> reopen() async {
    manager.dispose();
    manager = OfflineCacheManager(rootForTest: root);
    await manager.init();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('b53a_cache_');
    manager = OfflineCacheManager(rootForTest: root);
    await manager.init();
  });

  tearDown(() async {
    manager.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('有文件无索引的数据文件启动即清，且不误删已索引的正常缓存', () async {
    await manager.putSong('keep', List<int>.filled(10, 1));
    await manager.flushIndexNow();

    // 手工造孤儿：绕开 put*，直接落盘（等价于「写完文件、索引没落」）。
    final songGhost = File('${sub('songs').path}/ghost');
    final coverGhost = File('${sub('covers').path}/ghostcov');
    await songGhost.writeAsBytes(List<int>.filled(5, 9));
    await coverGhost.writeAsBytes(List<int>.filled(5, 9));
    expect(await songGhost.exists(), isTrue);

    await reopen();

    expect(await songGhost.exists(), isFalse, reason: '孤儿数据文件必须被清掉');
    expect(await coverGhost.exists(), isFalse);
    expect(manager.hasSong('keep'), isTrue, reason: '已索引缓存不能被误删');
    expect(manager.songFile('keep')!.existsSync(), isTrue);
    expect(manager.totalBytes, 10);
  });

  test('索引损坏（清空重建）后，数据文件不再残留为孤儿', () async {
    await manager.putSong('s1', List<int>.filled(100, 1));
    await manager.putSong('s2', List<int>.filled(100, 2));
    await manager.flushIndexNow();
    manager.dispose();

    // 模拟「索引写一半被杀」：index.json 不是合法 JSON。
    await File('${cacheRoot().path}/index.json').writeAsString('{"entries": [');

    manager = OfflineCacheManager(rootForTest: root);
    await manager.init();

    expect(manager.hasSong('s1'), isFalse);
    expect(manager.hasSong('s2'), isFalse);
    expect(
      await sub('songs').list().toList(),
      isEmpty,
      reason: '索引权威已清空 → 数据文件必须一并回收，不能只涨不消',
    );
  });

  test('.part 中间产物一并清掉（原子写被杀的残留）', () async {
    await manager.putSong('s1', List<int>.filled(10, 1));
    await manager.flushIndexNow();

    final part = File('${sub('songs').path}/s1.part');
    await part.writeAsBytes(List<int>.filled(3, 7));

    await reopen();

    expect(await part.exists(), isFalse);
    expect(manager.hasSong('s1'), isTrue, reason: '本体文件仍被索引认账，须保留');
  });

  test('key 含非法字符时按 safeName 对齐，正例不被误判为孤儿', () async {
    await manager.putCover('a/b:c', List<int>.filled(10, 1));
    await manager.putPlaylistCover('pl:c/1', List<int>.filled(10, 2));
    await manager.flushIndexNow();

    await reopen();

    expect(manager.hasCover('a/b:c'), isTrue);
    expect(manager.hasPlaylistCover('pl:c/1'), isTrue);
    expect(await File('${sub('covers').path}/a_b_c').exists(), isTrue);
    expect(await File('${sub('playlist_covers').path}/pl_c_1').exists(), isTrue);
    expect(manager.totalBytes, 20);
  });

  test('歌词目录的孤儿同样回收，合法歌词键（含 libraryId 前缀）保留', () async {
    await manager.putLyrics('lib1:song1', 'hello');
    await manager.flushIndexNow();

    final ghost = File('${sub('lyrics').path}/ghost');
    await ghost.writeAsBytes(List<int>.filled(5, 9));

    await reopen();

    expect(await ghost.exists(), isFalse);
    expect(manager.lyricsCached('lib1:song1'), isTrue);
    expect(await manager.lyrics('lib1:song1'), 'hello');
  });
}
