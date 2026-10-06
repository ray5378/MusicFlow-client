import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/covers/fanart_cover_source.dart';

import '../../../helpers/b33a_stub_dio.dart';

/// 覆盖 FanartCoverSource：属性 + fetchCoverUrl 的各分支
/// （缺参/缺 key/专辑封面优先/歌手背景回退/空封面/非 200/异常）。
void main() {
  test('属性：id/displayName/requiresConfig', () {
    final source = FanartCoverSource(apiKey: 'k', dio: stubDio());
    expect(source.id, 'fanart');
    expect(source.displayName, 'Fanart.tv');
    expect(source.requiresConfig, isTrue);
  });

  test('fetchCoverUrl 返回 null 当 musicBrainzId 为 null', () async {
    final source = FanartCoverSource(apiKey: 'k', dio: stubDio());
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: null),
      isNull,
    );
  });

  test('fetchCoverUrl 返回 null 当 musicBrainzId 为空串', () async {
    final source = FanartCoverSource(apiKey: 'k', dio: stubDio());
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: ''),
      isNull,
    );
  });

  test('fetchCoverUrl 返回 null 当 apiKey 为 null', () async {
    final source = FanartCoverSource(dio: stubDio());
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });

  test('fetchCoverUrl 返回 null 当 apiKey 为空串', () async {
    final source = FanartCoverSource(apiKey: '', dio: stubDio());
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });

  test('fetchCoverUrl 优先返回专辑封面 url', () async {
    final data = {
      'albums': {
        'a1': {
          'albumcover': [
            {'url': 'http://cover/album.png'},
          ],
        },
      },
      'artistbackground': [
        {'url': 'http://cover/artist.png'},
      ],
    };
    final source = FanartCoverSource(
      apiKey: 'k',
      dio: stubDioRespond(data),
    );
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
    );
    expect(url, 'http://cover/album.png');
  });

  test('fetchCoverUrl 无专辑封面时回退到歌手背景图', () async {
    final data = {
      'albums': {
        'a1': {'albumcover': []},
      },
      'artistbackground': [
        {'url': 'http://cover/artist.png'},
      ],
    };
    final source = FanartCoverSource(
      apiKey: 'k',
      dio: stubDioRespond(data),
    );
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
    );
    expect(url, 'http://cover/artist.png');
  });

  test('fetchCoverUrl 既无专辑也无背景图时返回 null', () async {
    final data = {
      'albums': {'a1': {'albumcover': []}},
      'artistbackground': [],
    };
    final source = FanartCoverSource(
      apiKey: 'k',
      dio: stubDioRespond(data),
    );
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
    );
    expect(url, isNull);
  });

  test('fetchCoverUrl 非 200 响应返回 null', () async {
    final source = FanartCoverSource(
      apiKey: 'k',
      dio: stubDioRespond(null, statusCode: 404),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });

  test('fetchCoverUrl 请求异常时返回 null', () async {
    final source = FanartCoverSource(
      apiKey: 'k',
      dio: stubDioThrowing(Exception('boom')),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });
}
