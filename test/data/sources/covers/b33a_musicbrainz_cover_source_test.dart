import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/covers/musicbrainz_cover_source.dart';

import '../../../helpers/b33a_stub_dio.dart';

/// 覆盖 MusicbrainzCoverSource：属性 + fetchCoverUrl 各分支
/// （缺 mbid/优先 front/缩略图选择/无 front 取首个/非 200/异常）。
void main() {
  test('属性：id/displayName/requiresConfig', () {
    final source = MusicbrainzCoverSource(stubDio());
    expect(source.id, 'musicbrainz');
    expect(source.displayName, 'MusicBrainz');
    expect(source.requiresConfig, isFalse);
  });

  test('fetchCoverUrl 返回 null 当 musicBrainzId 为 null', () async {
    final source = MusicbrainzCoverSource(stubDio());
    expect(await source.fetchCoverUrl(artist: 'A'), isNull);
  });

  test('fetchCoverUrl 返回 null 当 musicBrainzId 为空串', () async {
    final source = MusicbrainzCoverSource(stubDio());
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: ''),
      isNull,
    );
  });

  test('fetchCoverUrl front=true 且 size<=500 优先返回 500 缩略图', () async {
    final data = {
      'images': [
        {
          'front': true,
          'image': 'http://img/full.png',
          'thumbnails': {
            '500': 'http://img/thumb500.png',
            'large': 'http://img/large.png',
          },
        },
      ],
    };
    final source = MusicbrainzCoverSource(stubDioRespond(data));
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
      size: 250,
    );
    expect(url, 'http://img/thumb500.png');
  });

  test('fetchCoverUrl front=true 且 size>500 返回全尺寸图', () async {
    final data = {
      'images': [
        {
          'front': true,
          'image': 'http://img/full.png',
          'thumbnails': {'500': 'http://img/thumb500.png'},
        },
      ],
    };
    final source = MusicbrainzCoverSource(stubDioRespond(data));
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
      size: 1000,
    );
    expect(url, 'http://img/full.png');
  });

  test('fetchCoverUrl 未指定 size 时 front 返回全尺寸图', () async {
    final data = {
      'images': [
        {
          'front': true,
          'image': 'http://img/full.png',
          'thumbnails': {'500': 'http://img/thumb500.png'},
        },
      ],
    };
    final source = MusicbrainzCoverSource(stubDioRespond(data));
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
    );
    expect(url, 'http://img/full.png');
  });

  test('fetchCoverUrl 没有 front 标记时返回首个 image', () async {
    final data = {
      'images': [
        {'front': false, 'image': 'http://img/first.png'},
        {'front': false, 'image': 'http://img/second.png'},
      ],
    };
    final source = MusicbrainzCoverSource(stubDioRespond(data));
    final url = await source.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mb1',
    );
    expect(url, 'http://img/first.png');
  });

  test('fetchCoverUrl 无 images 时返回 null', () async {
    final source = MusicbrainzCoverSource(stubDioRespond({'images': []}));
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });

  test('fetchCoverUrl 非 200 响应返回 null', () async {
    final source = MusicbrainzCoverSource(
      stubDioRespond(null, statusCode: 500),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });

  test('fetchCoverUrl 请求异常时返回 null', () async {
    final source = MusicbrainzCoverSource(
      stubDioThrowing(Exception('boom')),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A', musicBrainzId: 'mb1'),
      isNull,
    );
  });
}
