import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/utils/lrc_parser.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/offline_cache_size.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_config.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';

/// 覆盖率缺口补齐 —— 数据模型 / 纯解析逻辑。
///
/// 约定：用例断言的是**当前实现行为**。若行为本身是缺陷，用 `// [D-xxx]` 标注并
/// 记入 docs/客户端覆盖率与缺陷统计.md，待统一修复时同步翻转断言。
void main() {
  group('ServerConfig', () {
    test('fromJson 全字段 + toJson 往返', () {
      final c = ServerConfig.fromJson({
        'serverUrl': 'http://a.b',
        'username': 'u',
        'password': 'p',
        'apiKey': 'k',
        'authType': 'apiKey',
        'isOpenSubsonic': true,
        'serverType': 'navidrome',
        'serverVersion': '1.2.3',
        'extensions': ['a', 'b'],
      });
      expect(c.serverUrl, 'http://a.b');
      expect(c.authType, AuthType.apiKey);
      expect(c.isOpenSubsonic, isTrue);
      expect(c.extensions, ['a', 'b']);

      final j = c.toJson();
      expect(j['authType'], 'apiKey');
      expect(ServerConfig.fromJson(j).serverVersion, '1.2.3');
    });

    test('fromJson 缺省：authType 回落 token，extensions 回落空表', () {
      final c = ServerConfig.fromJson({'serverUrl': 'x', 'username': 'u'});
      expect(c.authType, AuthType.token);
      expect(c.isOpenSubsonic, isFalse);
      expect(c.extensions, isEmpty);
      expect(c.password, isNull);
    });

    test('authType 未知字符串回落 token', () {
      final c = ServerConfig.fromJson({
        'serverUrl': 'x',
        'username': 'u',
        'authType': 'no-such',
      });
      expect(c.authType, AuthType.token);
    });

    // [D-001] serverUrl/username 缺失时是硬 cast，会抛 CastError 而非回落空串。
    test('[D-001] 缺失 serverUrl 会抛异常（当前行为：硬 cast）', () {
      expect(
        () => ServerConfig.fromJson({'username': 'u'}),
        throwsA(isA<TypeError>()),
      );
    });

    test('copyWith 覆盖与保留', () {
      const c = ServerConfig(
        serverUrl: 'http://a',
        username: 'u',
        authType: AuthType.token,
        extensions: ['x'],
      );
      final c2 = c.copyWith(serverUrl: 'http://b', isOpenSubsonic: true);
      expect(c2.serverUrl, 'http://b');
      expect(c2.username, 'u');
      expect(c2.isOpenSubsonic, isTrue);
      expect(c2.extensions, ['x']);
      expect(c2.authType, AuthType.token);
    });
  });

  group('OfflineCacheSize', () {
    test('maxBytes 各档位', () {
      const mb = 1024 * 1024;
      final gb = 1024 * mb;
      expect(OfflineCacheSize.m512.maxBytes, 512 * mb);
      expect(OfflineCacheSize.g1.maxBytes, gb);
      expect(OfflineCacheSize.g10.maxBytes, 10 * gb);
      for (var i = 1; i < OfflineCacheSize.values.length; i++) {
        expect(OfflineCacheSize.values[i].maxBytes, i * gb);
      }
    });

    test('isGigabyte / gigabyteCount', () {
      expect(OfflineCacheSize.m512.isGigabyte, isFalse);
      expect(OfflineCacheSize.m512.gigabyteCount, 0);
      expect(OfflineCacheSize.g1.isGigabyte, isTrue);
      expect(OfflineCacheSize.g1.gigabyteCount, 1);
      expect(OfflineCacheSize.g7.gigabyteCount, 7);
      expect(OfflineCacheSize.g10.gigabyteCount, 10);
    });

    test('displayName 含单位', () {
      expect(OfflineCacheSize.g2.displayName, contains('2'));
      expect(OfflineCacheSize.m512.displayName, contains('512'));
    });

    test('fromName 命中与未命中回落 g2', () {
      expect(OfflineCacheSize.fromName('g5'), OfflineCacheSize.g5);
      expect(OfflineCacheSize.fromName('nope'), OfflineCacheSize.g2);
      expect(OfflineCacheSize.fromName(null), OfflineCacheSize.g2);
    });

    test('fromBytesFloor 取不超过给定字节的最大档位', () {
      const mb = 1024 * 1024;
      final gb = 1024 * mb;
      expect(OfflineCacheSize.fromBytesFloor(600 * mb), OfflineCacheSize.m512);
      expect(OfflineCacheSize.fromBytesFloor(gb), OfflineCacheSize.g1);
      expect(OfflineCacheSize.fromBytesFloor(gb + 1), OfflineCacheSize.g1);
      expect(OfflineCacheSize.fromBytesFloor(3 * gb), OfflineCacheSize.g3);
      // 超过最大档位 -> 仍是 g10
      expect(OfflineCacheSize.fromBytesFloor(99 * gb), OfflineCacheSize.g10);
    });

    // [D-002] 语义与命名不符：<=0 时返回 g2(2GB) 默认档，而不是最小档/边界档。
    test('[D-002] 非正数字节回落默认档 g2', () {
      expect(OfflineCacheSize.fromBytesFloor(0), OfflineCacheSize.g2);
      expect(OfflineCacheSize.fromBytesFloor(-1), OfflineCacheSize.g2);
    });
  });

  group('LyricsLine', () {
    test('fromJson 数值/字符串/浮点 start 容错', () {
      expect(LyricsLine.fromJson({'start': 1200, 'value': 'a'}).startMs, 1200);
      expect(LyricsLine.fromJson({'start': 12.9, 'value': 'a'}).startMs, 12);
      expect(LyricsLine.fromJson({'start': '3400', 'value': 'a'}).startMs, 3400);
      expect(LyricsLine.fromJson({'start': 'x', 'value': 'a'}).startMs, isNull);
      expect(LyricsLine.fromJson({'value': 'a'}).startMs, isNull);
    });

    test('fromJson value 非字符串回落空串', () {
      expect(LyricsLine.fromJson({'value': 12}).value, '');
    });

    test('toJson 无 start 时省略该键', () {
      expect(LyricsLine(value: 'a').toJson(), {'value': 'a'});
      expect(LyricsLine(startMs: 5, value: 'a').toJson(), {
        'start': 5,
        'value': 'a',
      });
    });
  });

  group('StructuredLyrics', () {
    test('fromJson 解析行与 offset 容错', () {
      final s = StructuredLyrics.fromJson({
        'displayArtist': 'A',
        'displayTitle': 'T',
        'lang': 'zh',
        'offset': '250',
        'synced': true,
        'line': [
          {'start': 0, 'value': 'x'},
          {'start': 100, 'value': 'y'},
        ],
      });
      expect(s.displayArtist, 'A');
      expect(s.displayTitle, 'T');
      expect(s.lang, 'zh');
      expect(s.offsetMs, 250);
      expect(s.synced, isTrue);
      expect(s.lines.length, 2);
      expect(s.lines.first.value, 'x');
    });

    test('fromJson 脏数据：非法行类型被过滤、offset 缺失回落 0', () {
      final s = StructuredLyrics.fromJson({
        'line': ['not-a-map', {'start': 1, 'value': 'ok'}],
        'offset': 'abc',
      });
      expect(s.lines.length, 1);
      expect(s.lines.single.value, 'ok');
      expect(s.offsetMs, 0);
      expect(s.synced, isFalse);
      expect(s.lang, isNull);
      expect(s.displayArtist, isNull);
    });

    test('toJson 省略空字段、始终带 offset/synced/line', () {
      final j = StructuredLyrics(synced: false, lines: [
        LyricsLine(startMs: 1, value: 'a'),
      ]).toJson();
      expect(j.containsKey('displayArtist'), isFalse);
      expect(j.containsKey('lang'), isFalse);
      expect(j['offset'], 0);
      expect(j['synced'], false);
      expect((j['line'] as List).length, 1);
    });
  });

  group('Lyrics', () {
    StructuredLyrics mk(String lang, bool synced) => StructuredLyrics(
          lang: lang,
          synced: synced,
          lines: [LyricsLine(startMs: 0, value: 'v')],
        );

    test('空表：getBest 返回 null 且 isEmpty', () {
      final l = Lyrics(sourceId: 's', entries: const []);
      expect(l.getBest(), isNull);
      expect(l.isEmpty, isTrue);
      expect(l.hasSynced, isFalse);
    });

    test('优先同步歌词', () {
      final l = Lyrics(sourceId: 's', entries: [mk('zh', false), mk('en', true)]);
      expect(l.getBest()!.synced, isTrue);
      expect(l.hasSynced, isTrue);
    });

    test('指定语言优先于系统语言与顺序', () {
      final l = Lyrics(
        sourceId: 's',
        entries: [mk('ja', true), mk('zh', true)],
      );
      expect(l.getBest(preferredLang: 'zh')!.lang, 'zh');
    });

    test('未指定语言时回落候选首项', () {
      final l = Lyrics(sourceId: 's', entries: [mk('ja', true), mk('xx', true)]);
      expect(l.getBest()!.lang, 'ja');
    });

    test('toJson/fromJson 往返', () {
      final l = Lyrics(sourceId: 'src', entries: [mk('zh', true)]);
      final back = Lyrics.fromJson(l.toJson());
      expect(back.sourceId, 'src');
      expect(back.entries.length, 1);
      expect(back.entries.first.lang, 'zh');
    });

    test('fromJson 空/缺字段回落', () {
      final back = Lyrics.fromJson({});
      expect(back.sourceId, '');
      expect(back.entries, isEmpty);
    });
  });

  group('LrcParser', () {
    test('基础 [mm:ss.xx] 解析与排序', () {
      final s = LrcParser.parse(
        '[00:02.50]second\n[00:01.00]first\n',
      );
      expect(s.synced, isTrue);
      expect(s.lines.length, 2);
      expect(s.lines.first.value, 'first');
      expect(s.lines.first.startMs, 1000);
      expect(s.lines.last.startMs, 2500);
    });

    test('三位毫秒按毫秒直读，两位毫秒 ×10', () {
      final s = LrcParser.parse('[00:01.500]a\n[00:02.25]b\n');
      expect(s.lines.first.startMs, 1500);
      expect(s.lines.last.startMs, 2250);
    });

    test('分钟换算', () {
      final s = LrcParser.parse('[01:30.00]a');
      expect(s.lines.single.startMs, 90000);
    });

    test('元数据行 [ti:] [ar:] [al:] 被跳过', () {
      final s = LrcParser.parse('[ti:T]\n[ar:A]\n[al:AL]\n[00:01.00]x');
      expect(s.lines.length, 1);
      expect(s.lines.single.value, 'x');
    });

    test('空行被忽略', () {
      final s = LrcParser.parse('\n\n  \n[00:01.00]x\n\n');
      expect(s.lines.length, 1);
    });

    test('一行多时间戳共享同一文本', () {
      final s = LrcParser.parse('[00:01.00][00:05.00]chorus');
      expect(s.lines.length, 2);
      expect(s.lines[0].value, 'chorus');
      expect(s.lines[1].value, 'chorus');
      expect(s.lines[0].startMs, 1000);
      expect(s.lines[1].startMs, 5000);
    });

    test('增强型逐字标签 <mm:ss.xx> 被剥离', () {
      final s = LrcParser.parse('<00:01.00>[00:01.00]hello<00:01.50> world');
      expect(s.lines.single.value, 'hello world');
    });

    test('纯文本无时间戳：synced=false 且保留原序', () {
      final s = LrcParser.parse('line one\nline two');
      expect(s.synced, isFalse);
      expect(s.lines.map((e) => e.value).toList(), ['line one', 'line two']);
      expect(s.lines.every((e) => e.startMs == null), isTrue);
    });

    // [D-003] 混排时无时间戳的行 startMs=null，排序用 `?? 0` 会被顶到最前。
    test('[D-003] 混排文本行被排到最前（当前行为）', () {
      final s = LrcParser.parse('[00:01.00]a\nplain\n[00:02.00]b');
      expect(s.synced, isTrue);
      expect(s.lines.first.value, 'plain');
      expect(s.lines.first.startMs, isNull);
    });

    // [D-004] 一位毫秒（[00:01.5]）不被正则接受，整行被当作无时间戳文本丢弃文本标签。
    test('[D-004] 一位毫秒时间标签不被识别（当前行为）', () {
      final s = LrcParser.parse('[00:01.5]a');
      expect(s.synced, isFalse);
      // 该行以 '[' 开头 -> 被判定为标签行整体跳过
      expect(s.lines, isEmpty);
    });

    test('只有空文本的时间戳行仍生成空 value 条目', () {
      final s = LrcParser.parse('[00:01.00]');
      expect(s.lines.single.value, '');
      expect(s.lines.single.startMs, 1000);
    });

    test('未知 [xxx] 标签（非时间）被跳过', () {
      final s = LrcParser.parse('[offset:500]\n[00:01.00]ok');
      expect(s.lines.length, 1);
      expect(s.lines.single.value, 'ok');
    });
  });

  group('ProviderConfig', () {
    test('默认 enabled=true，copyWith 覆盖', () {
      final p = ProviderConfig(id: 'i', sourceId: 's', priority: 1);
      expect(p.enabled, isTrue);
      expect(p.config, isNull);

      final p2 = p.copyWith(enabled: false, priority: 9, config: {'k': 'v'});
      expect(p2.enabled, isFalse);
      expect(p2.priority, 9);
      expect(p2.config, {'k': 'v'});
      expect(p2.id, 'i');
      expect(p2.sourceId, 's');
    });
  });

  group('HomeSectionLayout', () {
    test('empty 常量与 isEmpty', () {
      expect(HomeSectionLayout.empty.isEmpty, isTrue);
      expect(HomeSectionLayout(order: ['a']).isEmpty, isFalse);
      expect(HomeSectionLayout(hidden: ['a']).isEmpty, isFalse);
    });

    test('copyWith 覆盖/保留', () {
      const l = HomeSectionLayout(order: ['a'], hidden: ['b']);
      final l2 = l.copyWith(order: ['c']);
      expect(l2.order, ['c']);
      expect(l2.hidden, ['b']);
    });

    test('fromJson 过滤非字符串与空串', () {
      final l = HomeSectionLayout.fromJson({
        'order': ['a', 1, '', 'b'],
        'hidden': null,
      });
      expect(l.order, ['a', 'b']);
      expect(l.hidden, isEmpty);
    });

    test('toJson/fromJson 往返', () {
      final l = HomeSectionLayout(order: ['x'], hidden: ['y']);
      expect(HomeSectionLayout.fromJson(l.toJson()).order, ['x']);
    });
  });

  group('SearchProvider.fromJson', () {
    test('解析平台与标签', () {
      final p = SearchProvider.fromJson({
        'id': 'netease',
        'name': '网易云',
        'platforms': ['android'],
        'platformLabels': {'android': '安卓'},
      });
      expect(p.id, 'netease');
      expect(p.platforms, ['android']);
      expect(p.platformLabels['android'], '安卓');
    });

    test('缺字段回落空值', () {
      final p = SearchProvider.fromJson({'id': 'x', 'name': ''});
      expect(p.platforms, isEmpty);
      expect(p.platformLabels, isEmpty);
    });

    test('platformLabels 键值强转字符串', () {
      final p = SearchProvider.fromJson({
        'id': 'x',
        'name': 'n',
        'platformLabels': {1: 2},
      });
      expect(p.platformLabels, {'1': '2'});
    });
  });

  group('SearchSong', () {
    test('fromRemoteJson：providerId 覆盖优先于条目自带', () {
      final s = SearchSong.fromRemoteJson(
        {'id': '1', 'providerId': 'inner', 'duration': 12.9},
        providerId: 'outer',
      );
      expect(s.providerId, 'outer');
      expect(s.duration, 12);
      expect(s.isLocal, isFalse);
    });

    test('fromRemoteJson：外层为空时回落条目 providerId', () {
      expect(
        SearchSong.fromRemoteJson({'id': '1', 'providerId': 'inner'})
            .providerId,
        'inner',
      );
      expect(
        SearchSong.fromRemoteJson({'id': '1'}, providerId: '').providerId,
        '',
      );
    });

    test('fromRemoteJson：platformLabel 回落 source', () {
      final s = SearchSong.fromRemoteJson({'id': '1', 'source': 'wy'});
      expect(s.platformLabel, 'wy');
      final s2 = SearchSong.fromRemoteJson(
        {'id': '1', 'source': 'wy', 'platformLabel': 'L'},
      );
      expect(s2.platformLabel, 'L');
    });

    test('fromLocal 由 Song 构造', () {
      final s = SearchSong.fromLocal(Song(
        id: 's1',
        title: 'T',
        artist: 'A',
        album: 'AL',
        duration: 100,
        coverArt: 'c',
        suffix: 'mp3',
      ));
      expect(s.id, 's1');
      expect(s.name, 'T');
      expect(s.isLocal, isTrue);
      expect(s.duration, 100);
      expect(s.suffix, 'mp3');
    });

    test('fromLocal：Song 空字段回落', () {
      final s = SearchSong.fromLocal(Song(id: 's1', title: 'T'));
      expect(s.artist, '');
      expect(s.album, '');
      expect(s.cover, '');
      expect(s.duration, 0);
    });
  });

  group('SearchAlbum', () {
    test('fromRemoteJson：数字字段 toString 与 providerId 覆盖', () {
      final a = SearchAlbum.fromRemoteJson(
        {
          'id': 'a1',
          'trackCount': 12,
          'year': 2020,
          'providerId': 'inner',
          'source': 'qq',
        },
        providerId: 'outer',
      );
      expect(a.trackCount, '12');
      expect(a.year, '2020');
      expect(a.providerId, 'outer');
      expect(a.platformLabel, 'qq');
    });

    test('fromLocal 由 Album 构造', () {
      final a = SearchAlbum.fromLocal(Album(
        id: 'al1',
        name: 'N',
        artist: 'A',
        coverArt: 'c',
        songCount: 7,
        duration: 300,
      ));
      expect(a.id, 'al1');
      expect(a.name, 'N');
      expect(a.trackCount, '7');
      expect(a.isLocal, isTrue);
    });
  });

  group('SearchArtist', () {
    test('fromRemoteJson：avatar 回落 cover，计数 toString', () {
      final a = SearchArtist.fromRemoteJson({
        'id': 'ar1',
        'cover': 'c',
        'albumCount': 3,
        'songCount': 30,
        'source': 'wy',
      });
      expect(a.avatar, 'c');
      expect(a.albumCount, '3');
      expect(a.songCount, '30');
      expect(a.platformLabel, 'wy');
    });

    test('fromLocal 由 Artist 构造', () {
      final a = SearchArtist.fromLocal(
        Artist(id: 'ar1', name: 'N', coverArt: 'c', albumCount: 4),
      );
      expect(a.id, 'ar1');
      expect(a.avatar, 'c');
      expect(a.albumCount, '4');
      expect(a.isLocal, isTrue);
      // [D-005] fromLocal 未填 songCount（Artist 模型本身也没有该字段），恒为空串。
      expect(a.songCount, '');
    });
  });

  group('Artist.fromJson starred 判定', () {
    // [D-006] `json['starred'] != null`：服务端显式下发 false 会被判为已收藏。
    test('[D-006] starred=false 被误判为 true（当前行为）', () {
      expect(Artist.fromJson({'id': '1', 'name': 'n', 'starred': false}).starred,
          isTrue);
    });

    test('starred 字段缺失时为 false', () {
      expect(Artist.fromJson({'id': '1', 'name': 'n'}).starred, isFalse);
    });

    test('albumCount 支持数字与字符串', () {
      expect(Artist.fromJson({'id': '1', 'name': 'n', 'albumCount': '5'}).albumCount, 5);
      expect(Artist.fromJson({'id': '1', 'name': 'n', 'albumCount': 5.9}).albumCount, 5);
      expect(Artist.fromJson({'id': '1', 'name': 'n', 'albumCount': 'x'}).albumCount,
          isNull);
    });
  });
}
