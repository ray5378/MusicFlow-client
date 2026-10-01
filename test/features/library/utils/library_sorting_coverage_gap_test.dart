import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/player/server_shuffle_sequence.dart';
import 'package:musicflow_client/core/utils/structured_lyrics_parser.dart';
import 'package:musicflow_client/core/utils/subsonic_auth.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/features/library/utils/library_sorting.dart';

Song _song(
  String id,
  String title, {
  String? artist,
  int? duration,
  DateTime? created,
}) =>
    Song(
      id: id,
      title: title,
      artist: artist,
      duration: duration,
      created: created,
    );

Playlist _playlist(
  String id,
  String name, {
  String? owner,
  int? duration,
  DateTime? created,
  DateTime? changed,
}) =>
    Playlist(
      id: id,
      name: name,
      owner: owner,
      duration: duration ?? 0,
      songCount: 0,
      created: created,
      changed: changed,
    );

void main() {
  group('SongSortOption / PlaylistSortOption', () {
    test('alphabeticalAsc 才挂字母索引条,升降序都不挂', () {
      expect(SongSortOption.alphabeticalAsc.usesAlphabeticalIndexBar, isTrue);
      expect(SongSortOption.alphabeticalDesc.usesAlphabeticalIndexBar, isFalse);
      expect(SongSortOption.defaultOrder.usesAlphabeticalIndexBar, isFalse);
    });

    test('可选排序项枚举齐全（UI 下拉不能少项）', () {
      expect(
        selectableSongSortOptions,
        unorderedEquals(SongSortOption.values),
      );
      expect(
        selectablePlaylistSortOptions,
        unorderedEquals(PlaylistSortOption.values),
      );
    });
  });

  group('createSharedPinyinResolver', () {
    test('同一文本重复解析结果恒定（缓存键生效）', () {
      final resolver = createSharedPinyinResolver();
      final first = resolver('重复文本');
      expect(resolver('重复文本'), first);
      expect(resolver('重复文本'), first);
    });

    test('不同文本得到不同拼音（字典确实生效）', () {
      final resolver = createSharedPinyinResolver();
      expect(resolver('abc'), isNot(resolver('abd')));
      expect(resolver('中国'), isNot(resolver('中看')));
    });

    test('空字符串不抛异常', () {
      final resolver = createSharedPinyinResolver();
      expect(resolver(''), isNotNull);
    });
  });

  group('sortSongs', () {
    test('defaultOrder 原样返回副本,不重排不改原列表', () {
      final songs = <Song>[_song('1', 'B'), _song('2', 'A')];
      final out = sortSongs(songs, SongSortOption.defaultOrder);
      expect(out.map((s) => s.id).toList(), ['1', '2']);
      expect(out, isNot(same(songs)));
      expect(songs.map((s) => s.id).toList(), ['1', '2']);
    });

    test('空列表/单首直接返回副本', () {
      expect(sortSongs(<Song>[], SongSortOption.alphabeticalAsc), isEmpty);
      final single = <Song>[_song('1', 'A')];
      expect(sortSongs(single, SongSortOption.alphabeticalAsc).length, 1);
    });

    test('按标题升序/降序', () {
      final songs = <Song>[
        _song('1', 'Charlie'),
        _song('2', 'alpha'),
        _song('3', 'Bravo'),
      ];
      final asc = sortSongs(songs, SongSortOption.alphabeticalAsc);
      expect(asc.map((s) => s.title.toLowerCase()), ['alpha', 'bravo', 'charlie']);
      final desc = sortSongs(songs, SongSortOption.alphabeticalDesc);
      expect(desc.map((s) => s.title.toLowerCase()), ['charlie', 'bravo', 'alpha']);
    });

    test('按时长升序/降序,时长相同回退到标题序（升/降各自的回退方向）', () {
      final songs = <Song>[
        _song('1', 'b', duration: 300),
        _song('2', 'c', duration: 100),
        _song('3', 'a', duration: 300),
      ];
      // 升序:100 -> 300 并列(标题 a 先于 b) -> 100
      expect(
        sortSongs(songs, SongSortOption.durationAsc).map((s) => s.id),
        ['2', '3', '1'],
      );
      // 降序:300 并列 -> 100（并列时回退仍是标题升序）
      expect(
        sortSongs(songs, SongSortOption.durationDesc).map((s) => s.id),
        ['3', '1', '2'],
      );
    });

    test('时长缺省(-1)排在最前,不会抛异常', () {
      final songs = <Song>[
        _song('1', 'a', duration: 200),
        _song('2', 'b'),
      ];
      final asc = sortSongs(songs, SongSortOption.durationAsc);
      expect(asc.first.id, '2');
    });

    test('按更新时间升序/降序,时间缺省回退到标题序', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      final songs = <Song>[
        _song('1', 'b', created: base),
        _song('2', 'c', created: base.add(const Duration(days: 3))),
        _song('3', 'a', created: base),
      ];
      final asc = sortSongs(songs, SongSortOption.updatedAsc);
      expect(asc.map((s) => s.id), ['3', '1', '2']);
      final desc = sortSongs(songs, SongSortOption.updatedDesc);
      expect(desc.map((s) => s.id), ['2', '3', '1']);
    });

    test('不修改入参列表', () {
      final songs = <Song>[_song('1', 'B'), _song('2', 'A')];
      final original = songs.map((s) => s.id).toList();
      sortSongs(songs, SongSortOption.alphabeticalAsc);
      expect(songs.map((s) => s.id).toList(), original);
    });
  });

  group('compareSongsForSort', () {
    test('非缓存版与缓存版同序', () {
      final left = _song('1', 'Bravo', artist: 'z');
      final right = _song('2', 'alpha', artist: 'a');
      final resolver = createSharedPinyinResolver();
      expect(
        compareSongsForSort(left, right, SongSortOption.alphabeticalAsc),
        compareSongsForSortCached(left, right, SongSortOption.alphabeticalAsc, resolver),
      );
    });

    test('标题与作者都相同时返回 0（稳定排序语义）', () {
      final a = _song('1', 'same', artist: 'x');
      final b = _song('2', 'same', artist: 'x');
      expect(compareSongsForSort(a, b, SongSortOption.alphabeticalAsc), 0);
      expect(compareSongsForSort(a, b, SongSortOption.defaultOrder), 0);
    });

    test('作者兜底:标题拼音相同但作者不同时按作者排', () {
      final a = _song('1', 'same', artist: 'b');
      final b = _song('2', 'same', artist: 'a');
      expect(compareSongsForSort(a, b, SongSortOption.alphabeticalAsc), greaterThan(0));
    });

    test('作者为 null 时按空串处理,不抛异常', () {
      final a = _song('1', 'same');
      final b = _song('2', 'same', artist: 'a');
      expect(compareSongsForSort(a, b, SongSortOption.alphabeticalAsc), lessThan(0));
    });

    test('durationAsc 显式传参分支与 cached 一致', () {
      final left = _song('1', 'a', duration: 5);
      final right = _song('2', 'b', duration: 9);
      final resolver = createSharedPinyinResolver();
      expect(
        compareSongsForSort(left, right, SongSortOption.durationAsc),
        compareSongsForSortCached(left, right, SongSortOption.durationAsc, resolver),
      );
    });

    test('updatedDesc 走 cached 分支（构造传入）', () {
      final base = DateTime.fromMillisecondsSinceEpoch(0);
      final left = _song('1', 'a', created: base);
      final right = _song('2', 'b', created: base.add(const Duration(hours: 1)));
      final resolver = createSharedPinyinResolver();
      expect(
        compareSongsForSort(left, right, SongSortOption.updatedDesc),
        compareSongsForSortCached(left, right, SongSortOption.updatedDesc, resolver),
      );
    });
  });

  group('sortPlaylists', () {
    test('defaultOrder 原样返回副本', () {
      final playlists = <Playlist>[_playlist('1', 'B'), _playlist('2', 'A')];
      final out = sortPlaylists(playlists, PlaylistSortOption.defaultOrder);
      expect(out.map((p) => p.id), ['1', '2']);
      expect(out, isNot(same(playlists)));
    });

    test('按名称升降序,大小写不敏感', () {
      final playlists = <Playlist>[
        _playlist('1', 'Zed'),
        _playlist('2', 'apple'),
      ];
      expect(
        sortPlaylists(playlists, PlaylistSortOption.alphabeticalAsc).map((p) => p.id),
        ['2', '1'],
      );
      expect(
        sortPlaylists(playlists, PlaylistSortOption.alphabeticalDesc).map((p) => p.id),
        ['1', '2'],
      );
    });

    test('按时长升降序,时长相同回退名称序', () {
      final playlists = <Playlist>[
        _playlist('1', 'b', duration: 10),
        _playlist('2', 'a', duration: 10),
        _playlist('3', 'c', duration: 1),
      ];
      expect(
        sortPlaylists(playlists, PlaylistSortOption.durationAsc).map((p) => p.id),
        ['3', '2', '1'],
      );
      expect(
        sortPlaylists(playlists, PlaylistSortOption.durationDesc).map((p) => p.id),
        ['2', '1', '3'],
      );
    });

    test('按更新时间升降序:changed 优先于 created,都缺省回退名称序', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000);
      final playlists = <Playlist>[
        _playlist('1', 'b', created: base),
        _playlist('2', 'a', created: base, changed: base.add(const Duration(days: 1))),
        _playlist('3', 'c'),
      ];
      expect(
        sortPlaylists(playlists, PlaylistSortOption.updatedAsc).map((p) => p.id),
        ['3', '1', '2'],
      );
      // 更新时间降序:changed 优先 -> 无 changed 的回落 created -> 都缺则为 -1 垫底。
      expect(
        sortPlaylists(playlists, PlaylistSortOption.updatedDesc).map((p) => p.id),
        ['2', '1', '3'],
      );
    });

    test('单元素/空列表直接返回', () {
      expect(sortPlaylists(<Playlist>[], PlaylistSortOption.durationAsc), isEmpty);
      expect(
        sortPlaylists(<Playlist>[_playlist('1', 'a')], PlaylistSortOption.durationAsc),
        hasLength(1),
      );
    });
  });

  group('comparePlaylistsForSortCached', () {
    test('名称相同、owner 不同时按 owner 兜底', () {
      final a = _playlist('1', 'same', owner: 'b');
      final b = _playlist('2', 'same', owner: 'a');
      final resolver = createSharedPinyinResolver();
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.alphabeticalAsc, resolver),
        greaterThan(0),
      );
    });

    test('owner 缺省按空串,不抛异常', () {
      final a = _playlist('1', 'same');
      final b = _playlist('2', 'same', owner: 'a');
      final resolver = createSharedPinyinResolver();
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.alphabeticalAsc, resolver),
        lessThan(0),
      );
    });
  });

  group('StructuredLyricsParser', () {
    test('解析结构化歌词列表', () {
      final parsed = StructuredLyricsParser.parse([
        {
          'displayArtist': 'Artist',
          'displayTitle': 'Title',
          'lang': 'en',
          'offset': 12,
          'synced': true,
          'line': <Object?>[
            {'start': 1.0, 'value': 'line1'},
          ],
        },
      ]);
      expect(parsed, hasLength(1));
      final first = parsed.first;
      expect(first.displayArtist, 'Artist');
      expect(first.displayTitle, 'Title');
      expect(first.lang, 'en');
      expect(first.offsetMs, 12);
      expect(first.synced, isTrue);
      expect(first.lines, hasLength(1));
      expect(first.lines.first.value, 'line1');
    });

    test('空列表返回空结果', () {
      expect(StructuredLyricsParser.parse(<dynamic>[]), isEmpty);
    });
  });

  group('SubsonicAuth', () {
    test('generateToken 与 MD5(password+salt) 标准向量一致', () {
      expect(SubsonicAuth.generateToken('abc', ''),
          '900150983cd24fb0d6963f7d28e17f72');
      expect(SubsonicAuth.generateToken('pw', 'salt'),
          SubsonicAuth.generateToken('pw', 'salt'));
    });

    test('generateSalt 返回 16 位且两次不同', () {
      final a = SubsonicAuth.generateSalt();
      final b = SubsonicAuth.generateSalt();
      expect(a.length, 16);
      expect(a, isNot(b));
    });

    test('generateTokenAuthParams 产出完整 token/salt 认证参数', () {
      final params = SubsonicAuth.generateTokenAuthParams(
        username: 'u',
        password: 'p',
        version: '1.16.1',
        clientName: 'MusicFlow',
        format: 'json',
      );
      expect(params.keys.toSet(), {'u', 't', 's', 'v', 'c', 'f'});
      expect(params['u'], 'u');
      expect(params['v'], '1.16.1');
      expect(params['c'], 'MusicFlow');
      expect(params['f'], 'json');
      expect(params['t'], SubsonicAuth.generateToken('p', params['s']!));
    });

    test('generateApiKeyAuthParams 只用 apiKey,不泄露密码', () {
      final params = SubsonicAuth.generateApiKeyAuthParams(
        apiKey: 'k',
        version: '1.16.1',
        clientName: 'MusicFlow',
        format: 'json',
      );
      expect(params.keys.toSet(), {'apiKey', 'v', 'c', 'f'});
      expect(params['apiKey'], 'k');
    });
  });

  group('ServerShuffleSequence.advance', () {
    test('正常往后推一首', () {
      expect(ServerShuffleSequence.advance([0, 1, 2], 0, (_) => false), 1);
    });

    test('startPos=-1 视为从序列头开始', () {
      expect(ServerShuffleSequence.advance([0, 1, 2], -1, (_) => false), 0);
    });

    test('跳过已知死链', () {
      expect(
        ServerShuffleSequence.advance(
          [0, 1, 2],
          0,
          (i) => i == 1,
        ),
        2,
      );
    });

    test('未知(不可判定)一律照常播,不跳过', () {
      expect(
        ServerShuffleSequence.advance(
          [0, 1, 2],
          0,
          (i) => false,
        ),
        1,
      );
    });

    test('越过序列尾返回 null（触发重洗）', () {
      expect(ServerShuffleSequence.advance([0, 1], 1, (_) => false), isNull);
    });

    test('剩余全是死链返回 null', () {
      expect(
        ServerShuffleSequence.advance([0, 1, 2], 0, (i) => i != 0),
        isNull,
      );
    });

    test('序列为空返回 null', () {
      expect(ServerShuffleSequence.advance(<int>[], 0, (_) => false), isNull);
    });

    test('startPos < -1 返回 null（防御）', () {
      expect(ServerShuffleSequence.advance([0, 1], -2, (_) => false), isNull);
    });
  });
}
