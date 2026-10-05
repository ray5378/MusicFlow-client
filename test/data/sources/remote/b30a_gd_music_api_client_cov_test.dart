
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/data/sources/remote/gd_music_api_client.dart';

/// 用「真实 Dio + 拦截器 resolve」的假客户端：按 queryParameters['types'] 返回
/// 固定数据或抛 DioException，避免真实网络；同时记录每次 RequestOptions 供断言。
Dio _baseDio({String base = 'https://music-api.gdstudio.xyz'}) =>
    Dio(BaseOptions(baseUrl: base));

Interceptor _fake({
  required dynamic Function(RequestOptions) responder,
  required List<RequestOptions> captured,
}) => InterceptorsWrapper(
  onRequest: (options, handler) async {
    captured.add(options);
    try {
      final data = await responder(options);
      handler.resolve(
        Response<dynamic>(data: data, statusCode: 200, requestOptions: options),
      );
    } on DioException catch (e) {
      handler.reject(e);
    } catch (e) {
      handler.reject(DioException(requestOptions: options, error: e));
    }
  },
);

dynamic _list(List<Map<String, dynamic>> rows) => rows;

void main() {
  group('GdMusicApiClient.searchSongs 边界与解析', () {
    test('空/空白 keyword 直接返回 []（不发请求）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => throw StateError('不应被调用'),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(await client.searchSongs(keyword: '   '), isEmpty);
      expect(await client.searchSongs(keyword: ''), isEmpty);
      expect(captured, isEmpty);
    });

    test('空白 source 回退为 netease，并正常解析', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 't1',
                'name': 'S',
                'artist': 'A',
                'album': 'Al',
              },
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchSongs(keyword: 'x', source: '   ');
      expect(songs, hasLength(1));
      expect(songs.first.previewSource, 'netease');
      expect(songs.first.id, 'gd_netease_t1');
    });

    test('响应非 List 时返回 []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'foo': 'bar'},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(await client.searchSongs(keyword: 'x'), isEmpty);
    });

    test('跳过空 trackId，其余字段完整解析', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{'id': '', 'name': 'NoId'},
              <String, dynamic>{
                'id': 't1',
                'name': 'Song',
                'artist': 'A',
                'album': 'Al',
                'source': 'qq',
              },
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchSongs(keyword: 'x');
      expect(songs, hasLength(1));
      expect(songs.first.id, 'gd_qq_t1');
      expect(songs.first.title, 'Song');
      expect(songs.first.artist, 'A');
      expect(songs.first.album, 'Al');
    });

    test('artist 为字符串列表 → 用 " / " 拼接；album 为字符串', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 't1',
                'name': 'Song',
                'artist': <String>['A', 'B'],
                'album': 'StrAlbum',
              },
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchSongs(keyword: 'x');
      expect(songs.first.artist, 'A / B');
      expect(songs.first.album, 'StrAlbum');
    });

    test('artist/album 为 Map，title 空 → 未知歌曲，artist 空 → 未知歌手', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 't1',
                'name': '',
                'artist': <Map<String, dynamic>>[
                  <String, dynamic>{'artistName': 'Y'},
                ],
                'album': <String, dynamic>{'name': 'ObjAlbum'},
              },
              <String, dynamic>{'id': 't2', 'name': 'HasTitle', 'artist': null},
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchSongs(keyword: 'x');
      expect(songs, hasLength(2));
      expect(songs[0].title, l10nNowCurrent().unknown_song);
      expect(songs[0].artist, 'Y');
      expect(songs[0].album, 'ObjAlbum');
      expect(songs[1].artist, l10nNowCurrent().unknown_artist);
    });

    test('source 带 _album / _artist 后缀 → 归一化后用于 id 前缀', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 't1',
                'name': 'S1',
                'source': 'netease_album',
              },
              <String, dynamic>{
                'id': 't2',
                'name': 'S2',
                'source': 'netease_artist',
              },
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchSongs(keyword: 'x');
      expect(songs[0].id, 'gd_netease_t1');
      expect(songs[1].id, 'gd_netease_t2');
    });

    test('lyric_id / pic_id 透传', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 't1',
                'name': 'S',
                'lyric_id': 'L1',
                'pic_id': 'P1',
              },
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchSongs(keyword: 'x');
      expect(songs.first.previewLyricId, 'L1');
      expect(songs.first.previewPicId, 'P1');
    });
  });

  group('GdMusicApiClient.searchPlaylist 边界与解析', () {
    test('空/空白 playlistId 返回 []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => throw StateError('不应被调用'),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(await client.searchPlaylist(playlistId: ''), isEmpty);
      expect(await client.searchPlaylist(playlistId: '  '), isEmpty);
      expect(captured, isEmpty);
    });

    test('响应非 List 返回 []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'x': 1},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(await client.searchPlaylist(playlistId: 'p1'), isEmpty);
    });

    test('正常解析（artist 为 Map、album 为字符串）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => _list(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 't1',
                'name': 'S',
                'artist': <String, dynamic>{'name': 'A'},
                'album': 'Al',
              },
              <String, dynamic>{'id': '', 'name': 'skip'},
            ]),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final songs = await client.searchPlaylist(playlistId: 'p1');
      expect(songs, hasLength(1));
      expect(songs.first.previewSource, 'netease');
      expect(songs.first.artist, 'A');
      expect(songs.first.album, 'Al');
    });
  });

  group('GdMusicApiClient.resolveSongUrl 多候选与错误', () {
    test('成功：返回 url/br/size/suffix/requiredHeaders', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (o) => <String, dynamic>{
              'url': 'http://x/a/b.mp3',
              'br': 320,
              'size': '1234',
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.resolveSongUrl(source: 'netease', trackId: 't1');
      expect(r.url, 'http://x/a/b.mp3');
      expect(r.bitRateKbps, 320);
      expect(r.sizeBytes, 1234);
      expect(r.suffix, 'mp3');
      expect(
        r.requiredHeaders,
        containsPair('Referer', 'https://music.163.com/'),
      );
    });

    test('请求携带 br 参数；无 br 时 size/br 为 null', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (o) {
              expect(o.queryParameters['br'], 192);
              return <String, dynamic>{'url': 'http://x/s.mp3'};
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.resolveSongUrl(
        source: 'netease',
        trackId: 't1',
        br: 192,
      );
      expect(r.url, 'http://x/s.mp3');
      expect(r.bitRateKbps, isNull);
      expect(r.sizeBytes, isNull);
    });

    test('空 url → 跳过候选；全部空 → 抛异常', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'url': ''},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(
        () => client.resolveSongUrl(source: 'netease', trackId: 't1'),
        throwsA(isA<Exception>()),
      );
    });

    test('首个候选抛错（lastError）后其余空 url → 抛带原因的异常', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (o) {
              if (o.queryParameters['source'] == 'netease') {
                throw DioException(
                  requestOptions: o,
                  type: DioExceptionType.connectionError,
                );
              }
              return <String, dynamic>{'url': ''};
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      // source=netease_artist → 候选 [netease, netease_artist]：前者抛错，后者空 url
      expect(
        () => client.resolveSongUrl(source: 'netease_artist', trackId: 't1'),
        throwsA(isA<Exception>()),
      );
    });

    test('空 source → 候选回退为 netease 且成功', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (o) {
              expect(o.queryParameters['source'], 'netease');
              return <String, dynamic>{'url': 'http://x/s.mp3'};
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.resolveSongUrl(source: '', trackId: 't1');
      expect(r.url, 'http://x/s.mp3');
    });

    test('各音源 requiredHeaders 分支：bilibili/kuwo/joox/默认', () async {
      Future<Map<String, String>> headersFor(String source) async {
        final captured = <RequestOptions>[];
        final dio = _baseDio()
          ..interceptors.add(
            _fake(
              responder: (_) => <String, dynamic>{'url': 'http://x/s.mp3'},
              captured: captured,
            ),
          );
        final client = GdMusicApiClient(dio);
        final r = await client.resolveSongUrl(source: source, trackId: 't1');
        return r.requiredHeaders;
      }

      expect(
        await headersFor('bilibili'),
        containsPair('Referer', 'https://www.bilibili.com'),
      );
      expect(
        await headersFor('kuwo'),
        containsPair('Referer', 'https://www.kuwo.cn/'),
      );
      expect(
        await headersFor('joox'),
        containsPair('Referer', 'https://y.qq.com/'),
      );
      expect(await headersFor('qq'), isEmpty);
    });
  });

  group('GdMusicApiClient.resolveCoverUrl / fetchLyrics', () {
    test('空 picId 直接返回 null（不发请求）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(responder: (_) => throw StateError('no'), captured: captured),
        );
      final client = GdMusicApiClient(dio);
      expect(
        await client.resolveCoverUrl(source: 'netease', picId: '  '),
        isNull,
      );
      expect(
        await client.resolveCoverUrl(source: 'netease', picId: ''),
        isNull,
      );
      expect(captured, isEmpty);
    });

    test('所有候选抛错 → 返回 null', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => throw DioException(
              requestOptions: RequestOptions(path: '/api.php'),
              type: DioExceptionType.connectionError,
            ),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(
        await client.resolveCoverUrl(source: 'netease', picId: 'p1'),
        isNull,
      );
    });

    test('成功返回封面 url（含 HTML 实体清理）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{
              'url': 'http://x/c.jpg?a=1&amp;b=2',
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final url = await client.resolveCoverUrl(source: 'netease', picId: 'p1');
      expect(url, 'http://x/c.jpg?a=1&b=2');
    });

    test('空 lyricId 直接返回 null（不发请求）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(responder: (_) => throw StateError('no'), captured: captured),
        );
      final client = GdMusicApiClient(dio);
      expect(await client.fetchLyrics(source: 'netease', lyricId: ''), isNull);
      expect(
        await client.fetchLyrics(source: 'netease', lyricId: '  '),
        isNull,
      );
      expect(captured, isEmpty);
    });

    test('成功返回歌词与翻译', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'lyric': 'L', 'tlyric': 'T'},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.fetchLyrics(source: 'netease', lyricId: 'l1');
      expect(r?.lyric, 'L');
      expect(r?.translation, 'T');
    });

    test('lyric 为空 → 跳过候选；全部空 → null', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'lyric': '  '},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(
        await client.fetchLyrics(source: 'netease', lyricId: 'l1'),
        isNull,
      );
    });

    test('所有候选抛错 → null', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => throw DioException(
              requestOptions: RequestOptions(path: '/api.php'),
              type: DioExceptionType.connectionError,
            ),
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      expect(
        await client.fetchLyrics(source: 'netease', lyricId: 'l1'),
        isNull,
      );
    });

    test('响应为 JSON 字符串 → 解码为 Map（_asMap string 分支）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => '{"lyric":"fromString","tlyric":""}',
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.fetchLyrics(source: 'netease', lyricId: 'l1');
      expect(r?.lyric, 'fromString');
    });

    test('响应为 List（非 Map）→ _asMap 返回 null → 无 lyric → null', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(responder: (_) => <dynamic>[1, 2, 3], captured: captured),
        );
      final client = GdMusicApiClient(dio);
      expect(
        await client.fetchLyrics(source: 'netease', lyricId: 'l1'),
        isNull,
      );
    });
  });

  group('GdMusicApiClient GdSongUrlResult.qualityLabel', () {
    test('bitRate 为 null / <=0 → 未知音质', () {
      expect(
        const GdSongUrlResult(url: 'u').qualityLabel,
        l10nNowCurrent().unknown_audio_quality,
      );
      expect(
        const GdSongUrlResult(url: 'u', bitRateKbps: 0).qualityLabel,
        l10nNowCurrent().unknown_audio_quality,
      );
      expect(
        const GdSongUrlResult(url: 'u', bitRateKbps: -1).qualityLabel,
        l10nNowCurrent().unknown_audio_quality,
      );
    });

    test('bitRate > 0 → "Nkbps"', () {
      expect(
        const GdSongUrlResult(url: 'u', bitRateKbps: 320).qualityLabel,
        '320kbps',
      );
    });
  });

  group('GdMusicApiClient 默认构造与 Map 兼容', () {
    test('默认 Dio 构造后空搜索不发网络请求并返回空列表', () async {
      final client = GdMusicApiClient();
      expect(await client.searchSongs(keyword: '   '), isEmpty);
    });

    test('非 String 泛型 Map 响应可转换并解析歌词', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <Object?, Object?>{
              'lyric': 'from-cast-map',
              'tlyric': '',
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final result = await client.fetchLyrics(source: 'netease', lyricId: 'l1');
      expect(result?.lyric, 'from-cast-map');
      expect(result?.translation, isNull);
      expect(captured, hasLength(1));
    });
  });

  group('GdMusicApiClient 私有解析辅助（_extractSuffix / _sanitizeUrl）', () {
    test('url 含扩展名 → 返回小写后缀', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'url': 'http://x/a/b.flac'},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.resolveSongUrl(source: 'netease', trackId: 't1');
      expect(r.suffix, 'flac');
    });

    test('url 无扩展名 → suffix 为 null', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{'url': 'http://x/a/b'},
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.resolveSongUrl(source: 'netease', trackId: 't1');
      expect(r.suffix, isNull);
    });

    test('sanitizeUrl：清理 HTML 实体', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio()
        ..interceptors.add(
          _fake(
            responder: (_) => <String, dynamic>{
              'url': 'http://x/s.mp3?a=1&amp;b=2&#x27;c&#x27;&quot;d&quot;',
            },
            captured: captured,
          ),
        );
      final client = GdMusicApiClient(dio);
      final r = await client.resolveSongUrl(source: 'netease', trackId: 't1');
      expect(r.url, "http://x/s.mp3?a=1&b=2'c'\"d\"");
    });
  });
}
