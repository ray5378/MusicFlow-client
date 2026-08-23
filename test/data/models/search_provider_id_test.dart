import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/search.dart';

/// 回归锁：库搜索「聚合搜索 → providerId 兜底 → 试听可播」的关键契约。
///
/// 历史教训（2026-08-23）：
/// - 后端单插件搜索条目不带 providerId，必须由仓库层传入；
/// - 聚合搜索条目自带 providerId，请求参数为空串时**不能**用空串覆盖，
///   否则 /rest/stream-remote?provider= 为空 → 试听/播放/入库全挂。
/// 这段逻辑被锁定，改动需同步更新本测试。
void main() {
  group('SearchSong.fromRemoteJson providerId 兜底', () {
    const itemJson = <String, dynamic>{
      'id': '15195332',
      'source': 'kuwo',
      'name': '光年之外',
      'artist': 'G.E.M. 邓紫棋',
      'album': '光年之外',
      'duration': 235,
      'cover': '',
      'suffix': '',
      'platformLabel': '酷我',
    };

    test('单插件搜索：优先用仓库层传入的 providerId', () {
      final s = SearchSong.fromRemoteJson(
        itemJson,
        providerId: 'go-music-dl',
      );
      expect(s.providerId, 'go-music-dl');
    });

    test('聚合搜索：传入空串时回退条目自带的 providerId（试听可播的关键）', () {
      final s = SearchSong.fromRemoteJson(
        <String, dynamic>{...itemJson, 'providerId': 'go-music-dl'},
        providerId: '',
      );
      expect(s.providerId, 'go-music-dl');
    });

    test('条目无 providerId 且未传参：为空（不抛错）', () {
      final s = SearchSong.fromRemoteJson(itemJson);
      expect(s.providerId, '');
    });

    test('显式传入非空 providerId 优先于条目自带值', () {
      final s = SearchSong.fromRemoteJson(
        <String, dynamic>{...itemJson, 'providerId': 'other-plugin'},
        providerId: 'go-music-dl',
      );
      expect(s.providerId, 'go-music-dl');
    });
  });

  group('SearchPlaylist.fromRemoteJson providerId 兜底', () {
    const playlistJson = <String, dynamic>{
      'id': '6792103822',
      'source': 'netease',
      'name': '周杰伦精选',
      'creator': 'Buradarrr',
      'cover': '',
      'trackCount': '139',
      'link': '',
    };

    test('聚合搜索：回退条目自带 providerId', () {
      final p = SearchPlaylist.fromRemoteJson(
        <String, dynamic>{...playlistJson, 'providerId': 'go-music-dl'},
        providerId: '',
      );
      expect(p.providerId, 'go-music-dl');
    });

    test('单插件搜索：用传入 providerId', () {
      final p = SearchPlaylist.fromRemoteJson(
        playlistJson,
        providerId: 'go-music-dl',
      );
      expect(p.providerId, 'go-music-dl');
    });
  });
}
