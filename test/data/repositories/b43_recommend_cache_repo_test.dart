// b43 —— RecommendCacheRepository 覆盖率补测。
//
// batch42 新增的推荐类首页数据缓存仓库（drift KV-JSON 表 recommend_caches），
// lcov 实测 40 行未覆盖。本文件补齐：
//   - homeCards / recommend / local_recommend 三类 scope 的读写 roundtrip；
//   - 读取容忍性：payload 非 JSON、条目损坏/空 Map/非 Map 逐条跳过；
//   - providerId 缺省回落空串；
//   - scope 按 libraryId 隔离。
// 打法：对齐 b42c 迁移测试范式 —— mock path_provider 通道指向临时目录，
// 用真实 AppDatabase（内存外真落盘路径）跑真 drift 读写链路。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/repositories/recommend_cache_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late RecommendCacheRepository repo;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('mf_b43_rec_cache');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => tempDir.path,
    );
    db = AppDatabase();
    repo = RecommendCacheRepository(db);
  });

  tearDownAll(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  HomeCard card(String id, {String? coverArt}) => HomeCard(
        playlistId: id,
        name: 'n-$id',
        playlistName: 'p-$id',
        position: 0,
        isCombo: false,
        songCount: 42,
        coverArt: coverArt,
      );

  /// 直接塞一行任意 payload（构造损坏/畸形缓存，走与线上一致的读取链路）。
  Future<void> insertRaw(String scope, String payload) async {
    await db.into(db.recommendCaches).insertOnConflictUpdate(
          RecommendCachesCompanion.insert(
            scope: scope,
            payload: payload,
            cachedAt: 0,
          ),
        );
  }

  group('homeCards', () {
    test('读写 roundtrip：coverArt 有/无两态均保真', () async {
      await repo.saveHomeCards('libA', [card('c1', coverArt: 'co-1'), card('c2')]);
      final got = await repo.getHomeCards('libA');
      expect(got, isNotNull);
      expect(got!.length, 2);
      expect(got[0].playlistId, 'c1');
      expect(got[0].coverArt, 'co-1');
      expect(got[1].coverArt, isNull);
    });

    test('无缓存 scope → null', () async {
      expect(await repo.getHomeCards('lib-none'), isNull);
    });

    test('payload 损坏 JSON → 容忍返回 null（不抛异常）', () async {
      await insertRaw('home_cards:lib-bad', '{not json');
      expect(await repo.getHomeCards('lib-bad'), isNull);
    });

    test('空 payload → null', () async {
      await insertRaw('home_cards:lib-empty', '');
      expect(await repo.getHomeCards('lib-empty'), isNull);
    });

    test('cards 条目损坏/空 Map/非 Map 逐条跳过，不阻断整组', () async {
      await insertRaw(
        'home_cards:lib-mixed',
        '{"cards":[{"playlistId":"ok","songCount":5},{},{},'
        '"junk",null,{"playlistId":"ok2","songCount":6}]}',
      );
      final got = await repo.getHomeCards('lib-mixed');
      expect(got!.map((e) => e.playlistId), <String>['ok', 'ok2']);
    });
  });

  group('recommend result', () {
    test('读写 roundtrip：providerId 与频道/歌单嵌套保真', () async {
      final result = RecommendResult(
        providerId: 'netease',
        channels: [
          RecommendChannel(
            source: 'netease',
            name: '网易云',
            count: 1,
            playlists: [
              RecommendPlaylist(
                id: 'p1',
                source: 'netease',
                name: '歌单',
                creator: 'u',
                cover: 'c',
                trackCount: '10',
                link: 'l',
                imported: false,
              ),
            ],
          ),
        ],
      );
      await repo.saveRecommendResult('libR', result);
      final got = await repo.getRecommendResult('libR');
      expect(got!.providerId, 'netease');
      expect(got.channels.single.name, '网易云');
      expect(got.channels.single.playlists.single.id, 'p1');
    });

    test('providerId 缺失 → 回落空串；channels 键缺失 → 空列表', () async {
      await insertRaw('recommend:lib-nop', '{"other":1}');
      final got = await repo.getRecommendResult('lib-nop');
      expect(got!.providerId, '');
      expect(got.channels, isEmpty);
    });

    test('channels 条目损坏逐条跳过', () async {
      await insertRaw(
        'recommend:lib-mixed',
        '{"providerId":"x","channels":['
        '{"source":"ok","name":"n","count":1,"playlists":[]},{},"junk"]}',
      );
      final got = await repo.getRecommendResult('lib-mixed');
      expect(got!.channels.single.source, 'ok');
    });
  });

  group('localRecommendChannels', () {
    test('读写 roundtrip：subtag/tagline/coverArt 有/无两态均保真', () async {
      final ch1 = LocalRecommendChannel(
        source: 's1',
        name: '平台一',
        count: 1,
        playlists: [
          LocalRecommendPlaylist(id: 'p', name: '歌单', songCount: 3),
        ],
      );
      final ch2 = LocalRecommendChannel(
        source: 's2',
        name: '平台二',
        count: 2,
        subtag: '每日更新',
        tagline: '副标题',
        playlists: [
          LocalRecommendPlaylist(
              id: 'p2', name: '歌单2', coverArt: 'c2', songCount: 4),
        ],
      );
      await repo.saveLocalRecommendChannels('libL', [ch1, ch2]);
      final got = await repo.getLocalRecommendChannels('libL');
      expect(got!.length, 2);
      expect(got[0].subtag, isNull);
      expect(got[0].tagline, isNull);
      expect(got[1].subtag, '每日更新');
      expect(got[1].tagline, '副标题');
      expect(got[1].playlists.single.coverArt, 'c2');
    });

    test('无缓存 scope → null；损坏条目逐条跳过', () async {
      expect(await repo.getLocalRecommendChannels('lib-none'), isNull);
      await insertRaw(
        'local_recommend:lib-mixed',
        '{"channels":[{"source":"ok","name":"n","count":1,"playlists":[]},'
        '{},{},"junk",null]}',
      );
      final got = await repo.getLocalRecommendChannels('lib-mixed');
      expect(got!.single.source, 'ok');
    });
  });

  test('scope 按库隔离：同 kind 不同 libraryId 互不可见', () async {
    await repo.saveHomeCards('libX', [card('x1')]);
    expect(await repo.getHomeCards('libY'), isNull);
    expect((await repo.getHomeCards('libX'))!.single.playlistId, 'x1');
  });
}
