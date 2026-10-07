// b43 —— recommend.dart 六个模型类 toJson 覆盖率补测。
//
// batch42 为六个模型类补齐 toJson 后 lcov 实测 37 行未覆盖
// （HomeCard / RecommendPlaylist / RecommendResult / LocalRecommendPlaylist /
//   LocalRecommendChannel / RecommendChannel）。
// 本文件补 toJson/fromJson 对称 roundtrip 用例：全字段断言，
// 可空字段覆盖 null / 非 null 两态，并断言 toJson 的「null 不落键」行为。
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/recommend.dart';

void main() {
  group('HomeCard', () {
    test('roundtrip：全字段含 coverArt 非 null', () {
      final obj = HomeCard(
        playlistId: 'p1',
        name: '卡名',
        playlistName: '歌单名',
        position: 3,
        isCombo: true,
        songCount: 42,
        coverArt: 'co-1',
      );
      final json = obj.toJson();
      expect(json['coverArt'], 'co-1');
      final back = HomeCard.fromJson(json);
      expect(back.playlistId, 'p1');
      expect(back.name, '卡名');
      expect(back.playlistName, '歌单名');
      expect(back.position, 3);
      expect(back.isCombo, isTrue);
      expect(back.songCount, 42);
      expect(back.coverArt, 'co-1');
    });

    test('coverArt 为 null → toJson 不落键，roundtrip 保持 null', () {
      final obj = HomeCard(
        playlistId: 'p2',
        name: 'n',
        playlistName: 'pn',
        position: 0,
        isCombo: false,
        songCount: 1,
      );
      expect(obj.toJson().containsKey('coverArt'), isFalse);
      expect(HomeCard.fromJson(obj.toJson()).coverArt, isNull);
    });
  });

  group('RecommendPlaylist', () {
    test('roundtrip：全字段含 cover 非 null', () {
      final obj = RecommendPlaylist(
        id: 'id1',
        source: 'netease',
        name: '歌单',
        creator: 'u1',
        cover: 'c1',
        trackCount: '12',
        link: 'http://l',
        imported: true,
      );
      final json = obj.toJson();
      expect(json['cover'], 'c1');
      final back = RecommendPlaylist.fromJson(json);
      expect(back.id, 'id1');
      expect(back.source, 'netease');
      expect(back.name, '歌单');
      expect(back.creator, 'u1');
      expect(back.cover, 'c1');
      expect(back.trackCount, '12');
      expect(back.link, 'http://l');
      expect(back.imported, isTrue);
    });

    test('cover 为 null → toJson 不落键，roundtrip 保持 null', () {
      final obj = RecommendPlaylist(
        id: 'id2',
        source: 'qq',
        name: 'n',
        creator: 'c',
        trackCount: '1',
        link: 'l',
        imported: false,
      );
      expect(obj.toJson().containsKey('cover'), isFalse);
      expect(RecommendPlaylist.fromJson(obj.toJson()).cover, isNull);
    });
  });

  group('RecommendResult', () {
    // 注意：RecommendResult 无 fromJson（读取侧由
    // RecommendCacheRepository.getRecommendResult 手工组装），roundtrip
    // 采取 toJson → 手工镜像组装的方式断言。
    RecommendResult fromJsonMirror(Map<String, dynamic> json) => RecommendResult(
          providerId: json['providerId'] as String,
          channels: (json['channels'] as List)
              .map((e) => RecommendChannel.fromJson(e as Map<String, dynamic>))
              .toList(),
        );

    test('toJson：providerId 与嵌套频道/歌单序列化保真', () {
      final obj = RecommendResult(
        providerId: 'netease',
        channels: [
          RecommendChannel(
            source: 's',
            name: 'n',
            count: 1,
            playlists: [
              RecommendPlaylist(
                id: 'p',
                source: 's',
                name: 'n',
                creator: 'c',
                trackCount: '2',
                link: 'l',
                imported: false,
              ),
            ],
          ),
        ],
      );
      final back = fromJsonMirror(obj.toJson());
      expect(back.providerId, 'netease');
      expect(back.channels.single.source, 's');
      expect(back.channels.single.playlists.single.id, 'p');
    });

    test('空频道列表 toJson → 手工镜像组装', () {
      final obj = RecommendResult(providerId: '', channels: []);
      final back = fromJsonMirror(obj.toJson());
      expect(back.providerId, isEmpty);
      expect(back.channels, isEmpty);
    });
  });

  group('LocalRecommendPlaylist', () {
    test('roundtrip：含 coverArt 非 null', () {
      final obj = LocalRecommendPlaylist(
        id: 'p1',
        name: '本地歌单',
        coverArt: 'co',
        songCount: 9,
      );
      expect(obj.toJson()['coverArt'], 'co');
      final back = LocalRecommendPlaylist.fromJson(obj.toJson());
      expect(back.id, 'p1');
      expect(back.name, '本地歌单');
      expect(back.coverArt, 'co');
      expect(back.songCount, 9);
    });

    test('coverArt 为 null → toJson 不落键，roundtrip 保持 null', () {
      final obj = LocalRecommendPlaylist(id: 'p2', name: 'n', songCount: 1);
      expect(obj.toJson().containsKey('coverArt'), isFalse);
      expect(LocalRecommendPlaylist.fromJson(obj.toJson()).coverArt, isNull);
    });
  });

  group('LocalRecommendChannel', () {
    test('roundtrip：subtag/tagline 非 null + 嵌套歌单保真', () {
      final obj = LocalRecommendChannel(
        source: 's1',
        name: '平台',
        count: 2,
        subtag: '每日更新',
        tagline: '副标题',
        playlists: [
          LocalRecommendPlaylist(id: 'p1', name: 'a', songCount: 1),
          LocalRecommendPlaylist(id: 'p2', name: 'b', coverArt: 'c', songCount: 2),
        ],
      );
      final json = obj.toJson();
      expect(json['subtag'], '每日更新');
      expect(json['tagline'], '副标题');
      final back = LocalRecommendChannel.fromJson(json);
      expect(back.source, 's1');
      expect(back.name, '平台');
      expect(back.count, 2);
      expect(back.subtag, '每日更新');
      expect(back.tagline, '副标题');
      expect(back.playlists.length, 2);
      expect(back.playlists[1].coverArt, 'c');
    });

    test('subtag/tagline 为 null → toJson 不落键，roundtrip 保持 null', () {
      final obj = LocalRecommendChannel(
        source: 's2',
        name: '平台',
        count: 0,
        playlists: [],
      );
      final json = obj.toJson();
      expect(json.containsKey('subtag'), isFalse);
      expect(json.containsKey('tagline'), isFalse);
      final back = LocalRecommendChannel.fromJson(json);
      expect(back.subtag, isNull);
      expect(back.tagline, isNull);
      expect(back.playlists, isEmpty);
    });
  });

  group('RecommendChannel', () {
    test('roundtrip：全字段与嵌套歌单保真', () {
      final obj = RecommendChannel(
        source: 's1',
        name: '频道',
        count: 3,
        playlists: [
          RecommendPlaylist(
            id: 'p1',
            source: 's1',
            name: '歌单',
            creator: 'c',
            cover: 'cv',
            trackCount: '5',
            link: 'l',
            imported: true,
          ),
        ],
      );
      final back = RecommendChannel.fromJson(obj.toJson());
      expect(back.source, 's1');
      expect(back.name, '频道');
      expect(back.count, 3);
      expect(back.playlists.single.cover, 'cv');
      expect(back.playlists.single.imported, isTrue);
    });

    test('playlists 为空列表 roundtrip', () {
      final obj = RecommendChannel(source: 's', name: 'n', count: 0, playlists: []);
      final back = RecommendChannel.fromJson(obj.toJson());
      expect(back.playlists, isEmpty);
    });
  });
}
