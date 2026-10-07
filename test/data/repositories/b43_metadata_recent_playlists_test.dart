// b43 —— MetadataCacheRepository cacheRecentPlaylists/getRecentPlaylists
// 一族覆盖率补测（batch42 新增，lcov 实测 8 行未覆盖）。
//
// 打法对齐 b29b：仓库只依赖 JsonFileStore（文件 KV），把 debugDirectory
// 指向临时目录跑到真落盘路径；「键缺失 / 字段缺失 / 坏条目」分支直接写
// 原始 JSON 构造，走与线上完全相同的读取链路。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String lib = 'b43meta';

  late Directory tempDir;
  late MetadataCacheRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mf_b43_meta_cache');
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
  Future<void> writeRaw(String scope, String content) =>
      JsonFileStore.instance
          .writeString('metadata_cache_v1_${lib}_$scope', content);

  Song song(String id) => Song(id: id, title: 'T$id', duration: 60);

  Playlist playlist(String id) => Playlist(
        id: id,
        name: 'P$id',
        songCount: 1,
        duration: 600,
        created: DateTime.fromMillisecondsSinceEpoch(1600000000000),
        changed: DateTime.fromMillisecondsSinceEpoch(1600000000000),
        songs: [song('$id-s1')],
      );

  test('cacheRecentPlaylists → getRecentPlaylists roundtrip', () async {
    await repo.cacheRecentPlaylists(lib, [playlist('p1'), playlist('p2')]);
    final got = await repo.getRecentPlaylists(lib);
    expect(got, isNotNull);
    expect(got!.length, 2);
    expect(got[0].id, 'p1');
    expect(got[1].id, 'p2');
    expect(got[0].songs!.single.id, 'p1-s1');
  });

  test('无缓存 scope → null', () async {
    expect(await repo.getRecentPlaylists(lib), isNull);
  });

  test('缓存存在但无 playlists 键 → null', () async {
    await writeRaw('recent_playlists', jsonEncode({'other': 1}));
    expect(await repo.getRecentPlaylists(lib), isNull);
  });

  test('playlists 条目损坏/空 Map/非 Map 逐条跳过，不阻断整组', () async {
    final valid = playlist('ok').toJson();
    await writeRaw(
      'recent_playlists',
      jsonEncode(<String, dynamic>{
        'playlists': <dynamic>[
          valid,
          <String, dynamic>{},
          'junk',
          null,
          playlist('ok2').toJson(),
        ],
      }),
    );
    final got = await repo.getRecentPlaylists(lib);
    expect(got!.map((e) => e.id), <String>['ok', 'ok2']);
  });
}
