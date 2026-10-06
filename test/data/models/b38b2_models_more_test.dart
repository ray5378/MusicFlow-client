// b38b2 —— `lib/data/models/**` 剩余「容错解析 / copyWith / 派生属性」分支补测。
//
// b38b_models_cov_test.dart 已覆盖大部分主路径；本文件补的是那些只在
// **脏数据**（后端把数字写成字符串、日期缺 T 分隔符、队列快照没有 total）
// 或**派生属性冷门分支**（整小时、仅分钟、非在播端队列标签）才走到的行。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_config.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Song.fromJson 容错', () {
    test('数字字段写成字符串 → 仍能解析', () {
      final song = Song.fromJson(<String, dynamic>{
        'id': 's1',
        'title': 't',
        'duration': '200',
        'size': '123456',
      });
      expect(song.duration, 200);
      expect(song.size, 123456);
    });

    test('布尔字段写成数字 / 字符串 → 仍能解析', () {
      expect(
        Song.fromJson(<String, dynamic>{'id': 's', 'title': 't', 'isVideo': 1})
            .isVideo,
        isTrue,
      );
      expect(
        Song.fromJson(<String, dynamic>{
          'id': 's',
          'title': 't',
          'isVideo': 'true',
        }).isVideo,
        isTrue,
      );
      expect(
        Song.fromJson(<String, dynamic>{'id': 's', 'title': 't'}).isVideo,
        isNull,
        reason: '字段缺失 → 保持「未知」而不是编造 false',
      );
      expect(
        Song.fromJson(<String, dynamic>{
          'id': 's',
          'title': 't',
          'isVideo': 0,
        }).isVideo,
        isFalse,
      );
    });

    test('previewRequestHeaders → 键值统一转字符串', () {
      final song = Song.fromJson(<String, dynamic>{
        'id': 's',
        'title': 't',
        'previewRequestHeaders': <dynamic, dynamic>{'k': 1},
      });
      expect(song.previewRequestHeaders, <String, String>{'k': '1'});
    });
  });

  test('Album.fromJson：数字字段写成字符串 → 仍能解析', () {
    final album = Album.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'n',
      'songCount': '12',
      'duration': '3600',
      'year': '2020',
    });
    expect(album.songCount, 12);
    expect(album.duration, 3600);
    expect(album.year, 2020);
  });

  group('Playlist', () {
    test('durationString：整小时无余分钟 → 走「x 小时」分支', () {
      final p = Playlist(
        id: 'p',
        name: 'n',
        songCount: 1,
        duration: 3600,
      );
      expect(p.durationString, l10nNowCurrent().duration_hours(1));
    });

    test('durationString：不足一小时 → 走「x 分钟」分支', () {
      final p = Playlist(id: 'p', name: 'n', songCount: 1, duration: 600);
      expect(p.durationString, l10nNowCurrent().duration_minutes(10));
    });

    test('日期缺 T 分隔符（"2024-01-01 00:00:00"）仍能解析', () {
      final p = Playlist.fromJson(<String, dynamic>{
        'id': 'p',
        'name': 'n',
        'songCount': 0,
        'duration': 0,
        'created': '2024-01-01 00:00:00',
      });
      expect(p.created, DateTime(2024, 1, 1));
    });
  });

  group('PeerInfo / PeerStatus', () {
    test('列表快照没有 total → 用 items.length 兜底', () {
      final peer = PeerInfo.fromJson(<String, dynamic>{
        'peerId': 'dlna-1',
        'name': 'n',
        'kind': 'dlna',
        'available': true,
        'queue': <String, dynamic>{
          'isActive': true,
          'items': <dynamic>[1, 2, 3],
        },
      });
      expect(peer.queueTotal, 3);
    });

    test('queueLabel：非在播端 → 走「共 N 首」文案', () {
      const peer = PeerInfo(
        peerId: 'dlna-1',
        name: 'n',
        kind: 'dlna',
        available: true,
        queueTotal: 7,
        queueActive: false,
      );
      expect(peer.queueLabel, l10nNowCurrent().peer_queue_total(7));
    });

    test('PeerStatus.copyWith：未传字段保持原值', () {
      const st = PeerStatus(state: 'PLAYING', positionSeconds: 3);
      final next = st.copyWith(active: true);
      expect(next.state, 'PLAYING', reason: '未显式传入的字段沿用原值');
      expect(next.positionSeconds, 3);
      expect(next.active, isTrue);
    });

    test('castQueueItemToSong：无 coverArt 但有 albumId → 回落 al-<id>', () {
      final song = castQueueItemToSong(<String, dynamic>{
        'songId': 's1',
        'title': 't',
        'albumId': 'al9',
      });
      expect(song.coverArt, 'al-al9');
    });
  });

  test('SearchPlaylist.fromLocal：本地歌单转搜索卡片', () {
    final playlist = Playlist(
      id: 'p1',
      name: '我的歌单',
      songCount: 42,
      duration: 3600,
      coverArt: 'pl-1',
    );
    final card = SearchPlaylist.fromLocal(playlist);
    expect(card.id, 'p1');
    expect(card.name, '我的歌单');
    expect(card.cover, 'pl-1');
    expect(card.trackCount, '42');
    expect(card.isLocal, isTrue);
  });

  test('SearchRequest 值相等：不同实例但字段相同 → == 为 true', () {
    final a = SearchRequest(
      kind: SearchEntityKind.song,
      mode: SearchMode.local,
      query: 'q',
      providerId: 'prov',
    );
    final b = SearchRequest(
      kind: SearchEntityKind.song,
      mode: SearchMode.local,
      query: 'q',
      providerId: 'prov',
    );
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(equals(SearchRequest(
        kind: SearchEntityKind.song,
        mode: SearchMode.local,
        query: 'q2',
      ))),
    );
  });

  test('ProviderConfig.copyWith：未传字段保持原值', () {
    final c = ProviderConfig(id: 'i', sourceId: 'src', priority: 0);
    final next = c.copyWith(enabled: false, priority: 2, config: <String, dynamic>{
      'k': 'v',
    });
    expect(next.id, 'i');
    expect(next.sourceId, 'src');
    expect(next.enabled, isFalse);
    expect(next.priority, 2);
    expect(next.config, <String, dynamic>{'k': 'v'});
  });

  test('ServerConfig.copyWith：未传字段保持原值', () {
    const c = ServerConfig(
      serverUrl: 'http://a',
      username: 'u',
      authType: AuthType.token,
    );
    final next = c.copyWith(
      serverUrl: 'http://b',
      isOpenSubsonic: true,
    );
    expect(next.serverUrl, 'http://b');
    expect(next.username, 'u');
    expect(next.isOpenSubsonic, isTrue);
    expect(next.authType, AuthType.token);
  });

  test('HomeSectionLayout.copyWith：未传字段保持原值', () {
    const l = HomeSectionLayout(order: <String>['a']);
    final next = l.copyWith(hidden: <String>['b'], miniPlayerVisible: false);
    expect(next.order, <String>['a']);
    expect(next.hidden, <String>['b']);
    expect(next.miniPlayerVisible, isFalse);
  });

  test('StructuredLyrics.fromJson：没有 line 字段 → 空行列表', () {
    final lyrics = StructuredLyrics.fromJson(<String, dynamic>{
      'displayTitle': 't',
      'synced': false,
    });
    expect(lyrics.lines, isEmpty);
    expect(lyrics.displayTitle, 't');
  });
}
