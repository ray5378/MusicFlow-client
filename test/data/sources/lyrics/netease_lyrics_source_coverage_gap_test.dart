// 网易云歌词源 netease_lyrics_source.dart 的缺口补齐测试。
//
// 该文件几乎所有逻辑都在**私有方法**里(_canSearch / _pickBestMatch / _similarity /
// _durationScore / _asMap / _extractArtistNames / _extractSongDurationSeconds /
// _extractLyricText),而 Dart 的私有是 library 级作用域,测试文件无法直接调用。
// 因此这里全部**通过公开入口 fetchLyrics + Dio 桩 adapter**驱动,
// 用不同的响应体把每条 continue / return 分支都顶出来。
//
// 桩 adapter 实现要点(实测版本 dio 5.11.1):
//   - HttpClientAdapter.fetch 的签名在新版是
//     (options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture),
//     旧的 RequestBodyStreamFunction / HttpClientFunction 已经不存在;
//   - ResponseBody.fromString 不再接受 requestOptions 命名参数;
//   - 造异常用 DioException.connectionTimeout(requestOptions: options) 工厂。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/sources/lyrics/netease_lyrics_source.dart';

/// 最小 dio 桩:按请求顺序返回预设 body,或在第 [throwAt] 个请求上抛连接超时。
// 注意用 implements 而不是 extends:HttpClientAdapter 是带 factory 的抽象类,
// 没有「无参 unnamed 构造」,extends 会在隐式 super() 处编译失败。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.bodies = const <String>[], this.throwAt = -1});

  final List<String> bodies;
  final List<RequestOptions> requests = <RequestOptions>[];
  final int throwAt;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = requests.length;
    requests.add(options);
    if (index == throwAt) {
      throw DioException.connectionTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 1),
        error: 'stub timeout',
      );
    }
    final body = index < bodies.length
        ? bodies[index]
        : (bodies.isEmpty ? 'null' : bodies.last);
    return ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{'content-type': <String>['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

_StubAdapter? _lastAdapter;

NeteaseLyricsSource _source({
  List<String> bodies = const <String>[],
  int throwAt = -1,
}) {
  final dio = Dio(BaseOptions());
  final adapter = _StubAdapter(bodies: bodies, throwAt: throwAt);
  _lastAdapter = adapter;
  dio.httpClientAdapter = adapter;
  return NeteaseLyricsSource(dio);
}

/// 最后一次请求带上的查询参数(第二步是拿 netease id 换歌词)
String? _lastRequestId() => _lastAdapter?.requests.last.queryParameters['id']?.toString();

/// 一首歌:时长单位为毫秒(网易云搜索接口常见字段),艺人名塞进指定字段
Map<String, Object> _song(
  Object id,
  String name,
  String artist, {
  int durationMs = 200000,
  String artistField = 'artists',
}) {
  final song = <String, Object>{
    'id': id,
    'name': name,
    'duration': durationMs,
  };
  if (artistField == 'artist') {
    song['artist'] = artist;
  } else {
    song[artistField] = <Object>[<String, Object>{'name': artist}];
  }
  return song;
}

String _searchBody(Object songs) => jsonEncode(<String, Object>{
  'result': <String, Object>{'songs': songs},
});

String _lyricBody({String? lrc, String? tlyric}) => jsonEncode(<String, Object>{
  if (lrc != null) 'lrc': lrc,
  if (tlyric != null) 'tlyric': tlyric,
});

const String _lrcText = '[00:01.00]第一句歌词\n[00:05.50]第二句歌词';
const String _tlyricText = '[00:01.00]第一句翻译\n[00:05.50]第二句翻译';

/// 一次「搜索 + 歌词」两步响应;默认 lyrics 步正常
List<String> _happyPath({
  required Object songs,
  String? lrc = _lrcText,
  String? tlyric,
  int throwAt = -1,
}) => <String>[
  _searchBody(songs),
  _lyricBody(lrc: lrc, tlyric: tlyric),
];

void main() {
  setUp(() {
    _lastAdapter = null;
  });

  group('基础属性', () {
    test('id 为 netease,不需要用户配置', () {
      final source = _source();
      expect(source.id, 'netease');
      expect(source.requiresConfig, isFalse);
    });
  });

  group('前置拦截(_canSearch):挡掉的请求一个都不会发出去', () {
    for (final artist in <String>['', '   ', 'Unknown Artist', '[Unknown Artist]', '[unknown]']) {
      test('未知艺人名 `$artist` 直接挡掉', () async {
        final source = _source();
        final result = await source.fetchLyrics(
          title: '歌名',
          artist: artist,
          duration: const Duration(seconds: 200),
        );
        expect(result, isNull);
        expect(_lastAdapter!.requests, isEmpty, reason: '被挡掉就不该产生网络请求');
      });
    }

    for (final title in <String>[
      'a/b/c',
      r'a\b\c', // 两个分隔符才触发(源码判断 slashCount >= 2)
      'cdimage',
      'song.mp3',
      'song.flac',
      'x.ape',
      'y.wav',
      'z.m4a',
    ]) {
      test('标题看着像文件/路径 `$title` 直接挡掉', () async {
        final source = _source();
        final result = await source.fetchLyrics(
          title: title,
          artist: '艺人',
          duration: const Duration(seconds: 200),
        );
        expect(result, isNull);
        expect(_lastAdapter!.requests, isEmpty);
      });
    }

    test('空标题挡掉', () async {
      final source = _source();
      final result = await source.fetchLyrics(
        title: '   ',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNull);
      expect(_lastAdapter!.requests, isEmpty);
    });

    test('正常标题+艺人不被前置拦截(确实会去发请求)', () async {
      final source = _source();
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNull, reason: '没给响应体时应空手而归,而不是被前置拦截');
      expect(_lastAdapter!.requests, hasLength(1));
    });
  });

  group('搜索响应异常分支', () {
    test('data 为 null -> null', () async {
      final source = _source(bodies: <String>['null']);
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    test('result 不是 map -> null', () async {
      final source = _source(
        bodies: <String>[jsonEncode(<String, Object>{'result': 'oops'})],
      );
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    test('result 存在但没有 songs -> null', () async {
      final source = _source(
        bodies: <String>[jsonEncode(<String, Object>{'result': <String, Object>{}})],
      );
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    test('songs 是空列表 -> null', () async {
      final source = _source(bodies: <String>[_searchBody(const <Object>[])]);
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    // [D-008] songs 字段类型不对(这里是 map)时,`as List?` 强转会抛 TypeError,
    // 靠最外层 catch 兜住 -> 表现同样是 null,异常对调用方不可见。
    test('songs 字段类型不对时靠 catch 吞掉,对外仍是 null', () async {
      final source = _source(
        bodies: <String>[
          jsonEncode(<String, Object>{
            'result': <String, Object>{'songs': <String, Object>{'a': 1}},
          }),
        ],
      );
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    test('搜索请求本身抛错 -> null,不冒泡', () async {
      final source = _source(throwAt: 0);
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });
  });

  group('匹配打分(_pickBestMatch)的淘汰分支', () {
    test('歌名完全不相关 -> 标题相似度过低被淘汰', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[_song(1, '完全另一首歌', '艺人')]),
      );
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    test('歌名对、艺人对不上 -> 艺术家相似度过低被淘汰', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[_song(1, '歌名', '完全不认识的歌手')]),
      );
      expect(await source.fetchLyrics(title: '歌名', artist: '艺人'), isNull);
    });

    test('歌名/艺人都对,时长差 > 90s -> 时长分 0 被淘汰', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[_song(1, '歌名', '艺人', durationMs: 600000)]),
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNull);
    });

    // 下面三个 token 数是刻意凑的:
    //   titleScore = 3/5 = 0.6(刚好过 0.6 门槛)、artistScore = 3/5 = 0.6(过 0.55)、
    //   时长差 20s -> durationScore 0.8;
    // 加权 0.65*0.6 + 0.25*0.6 + 0.1*0.8 = 0.62 < 0.7 → 源码会 return null。
    test('各项都过门槛但加权分 < 0.7 -> 最终返回 null', () async {
      final source = _source(
        bodies: _happyPath(
          songs: <Object>[
            _song(1, 'x y z p q', 'm n o r s', durationMs: 220000),
          ],
        ),
      );
      final result = await source.fetchLyrics(
        title: 'x y z',
        artist: 'm n o p q',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNull, reason: '三关都过了但总分没到 0.7,应当被 _pickBestMatch 丢掉');
    });
  });

  group('命中路径', () {
    test('无翻译歌词 -> 单条 entry,歌词能解析出行', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[_song(12345, '歌名', '艺人')]),
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNotNull);
      expect(result!.sourceId, 'netease');
      expect(result.entries, hasLength(1));
      expect(result.entries.first.synced, isTrue);
      expect(result.entries.first.lines, isNotEmpty);
    });

    test('带翻译歌词 -> 两条 entry,第一条仍是原文同步歌词', () async {
      final source = _source(
        bodies: _happyPath(
          songs: <Object>[_song(12345, '歌名', '艺人')],
          lrc: _lrcText,
          tlyric: _tlyricText,
        ),
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNotNull);
      expect(result!.entries, hasLength(2));
      expect(result.entries.first.lines.first.value, contains('第一句歌词'));
      expect(result.entries.last.lines.first.value, contains('第一句翻译'));
    });

    test('tlyric 为空字符串 -> 不追加翻译 entry', () async {
      final source = _source(
        bodies: _happyPath(
          songs: <Object>[_song(12345, '歌名', '艺人')],
          lrc: _lrcText,
          tlyric: '',
        ),
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNotNull);
      expect(result!.entries, hasLength(1));
    });

    test('lrc 是 map 包裹(lyric 字段)也能取到', () async {
      final source = _source(
        bodies: <String>[
          _searchBody(<Object>[_song(12345, '歌名', '艺人')]),
          jsonEncode(<String, Object>{'lrc': <String, Object>{'lyric': _lrcText}}),
        ],
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNotNull);
      expect(result!.entries.first.lines, isNotEmpty);
    });

    test('lrc 缺失 -> null', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[_song(12345, '歌名', '艺人')], lrc: null),
      );
      expect(
        await source.fetchLyrics(
          title: '歌名',
          artist: '艺人',
          duration: const Duration(seconds: 200),
        ),
        isNull,
      );
    });

    test('歌名+艺人都一致的多个候选里,时长更接近的那条胜出', () async {
      final source = _source(
        bodies: <String>[
          // 200s vs 250s,期望 200s:两条分数都过 0.7,时长分决定胜负
          _searchBody(<Object>[
            _song('far', '歌名', '艺人', durationMs: 250000),
            _song('near', '歌名', '艺人', durationMs: 200000),
          ]),
          _lyricBody(lrc: _lrcText),
        ],
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNotNull);
      expect(
        _lastRequestId(),
        'near',
        reason: '第二步拿的 netease id 应当是时长更接近那条',
      );
    });

    test('songs 里是 JSON 字符串也能被 _asMap 解析出来', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[jsonEncode(_song(777, '歌名', '艺人'))]),
      );
      final result = await source.fetchLyrics(
        title: '歌名',
        artist: '艺人',
        duration: const Duration(seconds: 200),
      );
      expect(result, isNotNull);
      expect(result!.entries.first.lines, isNotEmpty);
    });

    test('艺人字段三种形态(artists / ar / artist)都能命中', () async {
      for (final field in <String>['artists', 'ar', 'artist']) {
        final source = _source(
          bodies: _happyPath(
            songs: <Object>[_song(1, '歌名', '艺人', artistField: field)],
          ),
        );
        final result = await source.fetchLyrics(
          title: '歌名',
          artist: '艺人',
          duration: const Duration(seconds: 200),
        );
        expect(result, isNotNull, reason: '艺人字段形态 $field 也应当能命中');
      }
    });

    test('歌词那一步抛错 -> null,不冒泡', () async {
      final source = _source(
        bodies: _happyPath(songs: <Object>[_song(12345, '歌名', '艺人')]),
        throwAt: 1,
      );
      expect(
        await source.fetchLyrics(
          title: '歌名',
          artist: '艺人',
          duration: const Duration(seconds: 200),
        ),
        isNull,
      );
    });
  });
}
