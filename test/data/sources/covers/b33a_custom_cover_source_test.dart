import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/covers/custom_cover_source.dart';

import '../../../helpers/b33a_stub_dio.dart';

/// 覆盖 CustomCoverSource：属性 + fetchCoverUrl 各分支
/// （空模板/HEAD 200 命中/HEAD 非 200/异常/模板占位符替换）。
void main() {
  test('属性：id/requiresConfig', () {
    final source = CustomCoverSource(
      urlTemplate: 'http://x/{artist}',
      dio: stubDio(),
    );
    expect(source.id, 'custom');
    expect(source.requiresConfig, isTrue);
    expect(source.displayName, isNotEmpty);
  });

  test('fetchCoverUrl 模板为空时返回 null', () async {
    final source = CustomCoverSource(
      urlTemplate: '',
      dio: stubDio(),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A', album: 'B'),
      isNull,
    );
  });

  test('fetchCoverUrl HEAD 200 时返回构建出的 url', () async {
    final source = CustomCoverSource(
      urlTemplate: 'http://x/{artist}/{album}/{mbid}',
      dio: stubDioRespond(null, statusCode: 200),
    );
    final url = await source.fetchCoverUrl(
      artist: 'A B',
      album: 'C D',
      musicBrainzId: 'mb1',
    );
    expect(url, 'http://x/A%20B/C%20D/mb1');
  });

  test('fetchCoverUrl HEAD 非 200 时返回 null', () async {
    final source = CustomCoverSource(
      urlTemplate: 'http://x/{artist}',
      dio: stubDioRespond(null, statusCode: 404),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A'),
      isNull,
    );
  });

  test('fetchCoverUrl HEAD 异常时返回 null', () async {
    final source = CustomCoverSource(
      urlTemplate: 'http://x/{artist}',
      dio: stubDioThrowing(Exception('boom')),
    );
    expect(
      await source.fetchCoverUrl(artist: 'A'),
      isNull,
    );
  });
}
