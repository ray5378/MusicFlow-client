import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/data/sources/lyrics/subsonic_lyrics_source.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

import '../../../helpers/b33a_stub_dio.dart';

/// 覆盖 SubsonicLyricsSource：属性 + fetchLyrics 各分支
/// （getLyricsBySongId 优先 / 扩展缺失兼容 / 回退 legacy getLyrics /
///  extensions 不含 songLyrics 直接走 legacy / 全部失败返回 null）。
///
/// 通过 stubDio 的 handler 按请求 path 返回对应的 subsonic-response。
/// 注意：SubsonicApiClient.get 要求 subsonic-response.status=='ok'，否则抛异常。
Response<dynamic> _resp(RequestOptions options, Map<String, dynamic> inner) =>
    Response<dynamic>(
      requestOptions: options,
      data: {'subsonic-response': {'status': 'ok', ...inner}},
      statusCode: 200,
    );

void main() {
  test('属性：id/displayName/requiresConfig', () {
    final source = SubsonicLyricsSource(SubsonicApiClient(dio: Dio()));
    expect(source.id, 'subsonic');
    expect(source.requiresConfig, isFalse);
    expect(source.displayName, isNotEmpty);
  });

  test('fetchLyrics 优先用 getLyricsBySongId 结构化歌词', () async {
    final stub = stubDio(
      handler: (options) => _resp(options, {
        'lyricsList': {
          'structuredLyrics': [
            {
              'line': [
                {'value': 'hi', 'start': 1000},
              ],
              'lang': 'en',
              'synced': true,
            },
          ],
        },
      }),
    );
    final source = SubsonicLyricsSource(
      SubsonicApiClient(dio: stub),
      ['songLyrics'],
    );
    final lyrics = await source.fetchLyrics(
      title: 'T',
      artist: 'A',
      songId: 's1',
    );
    expect(lyrics, isNotNull);
    expect(lyrics!.sourceId, 'subsonic');
    expect(lyrics.entries.first.synced, isTrue);
  });

  test('fetchLyrics extensions 为空时也尝试 getLyricsBySongId', () async {
    final stub = stubDio(
      handler: (options) => _resp(options, {
        'lyricsList': {
          'structuredLyrics': [
            {
              'line': [
                {'value': 'x', 'start': 0},
              ],
              'synced': false,
            },
          ],
        },
      }),
    );
    final source = SubsonicLyricsSource(
      SubsonicApiClient(dio: stub),
      const [],
    );
    final lyrics = await source.fetchLyrics(
      title: 'T',
      artist: 'A',
      songId: 's1',
    );
    expect(lyrics, isNotNull);
    expect(lyrics!.entries.first.synced, isFalse);
  });

  test('fetchLyrics getLyricsBySongId 缺 structuredLyrics 回退 legacy', () async {
    final stub = stubDio(
      handler: (options) {
        if (options.path == ApiConstants.getLyricsBySongId) {
          return _resp(options, {'lyricsList': null});
        }
        return _resp(options, {
          'lyrics': {'value': '[00:01.00]legacy line'},
        });
      },
    );
    final source = SubsonicLyricsSource(
      SubsonicApiClient(dio: stub),
      ['songLyrics'],
    );
    final lyrics = await source.fetchLyrics(
      title: 'T',
      artist: 'A',
      songId: 's1',
    );
    expect(lyrics, isNotNull);
    expect(lyrics!.entries.first.lines.first.value, 'legacy line');
  });

  test('fetchLyrics 无 songId 直接走 legacy getLyrics', () async {
    final stub = stubDio(
      handler: (options) => _resp(options, {
        'lyrics': {'value': '[00:02.00]only legacy'},
      }),
    );
    final source = SubsonicLyricsSource(SubsonicApiClient(dio: stub));
    final lyrics = await source.fetchLyrics(title: 'T', artist: 'A');
    expect(lyrics, isNotNull);
    expect(lyrics!.entries.first.lines.first.value, 'only legacy');
  });

  test('fetchLyrics extensions 不含 songLyrics 跳过 BySongId 走 legacy', () async {
    final stub = stubDio(
      handler: (options) {
        // 若错误打到 getLyricsBySongId 则让测试失败。
        if (options.path == ApiConstants.getLyricsBySongId) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
          );
        }
        return _resp(options, {
          'lyrics': {'value': '[00:01.00]via legacy'},
        });
      },
    );
    final source = SubsonicLyricsSource(
      SubsonicApiClient(dio: stub),
      ['other'],
    );
    final lyrics = await source.fetchLyrics(
      title: 'T',
      artist: 'A',
      songId: 's1',
    );
    expect(lyrics, isNotNull);
    expect(lyrics!.entries.first.lines.first.value, 'via legacy');
  });

  test('fetchLyrics 两次请求都失败返回 null', () async {
    final stub = stubDioThrowing(Exception('boom'));
    final source = SubsonicLyricsSource(
      SubsonicApiClient(dio: stub),
      ['songLyrics'],
    );
    expect(
      await source.fetchLyrics(
        title: 'T',
        artist: 'A',
        songId: 's1',
      ),
      isNull,
    );
  });
}
