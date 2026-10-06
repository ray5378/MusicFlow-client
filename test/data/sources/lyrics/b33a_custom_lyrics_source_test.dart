import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/lyrics/custom_lyrics_source.dart';

import '../../../helpers/b33a_stub_dio.dart';

/// 覆盖 CustomLyricsSource：属性 + fetchLyrics 各分支
/// （空模板/GET 200 解析/非 200/异常/占位符替换）。
void main() {
  test('属性：id/requiresConfig', () {
    final source = CustomLyricsSource(
      urlTemplate: 'http://x/{title}',
      dio: stubDio(),
    );
    expect(source.id, 'custom');
    expect(source.requiresConfig, isTrue);
    expect(source.displayName, isNotEmpty);
  });

  test('fetchLyrics 模板为空时返回 null', () async {
    final source = CustomLyricsSource(urlTemplate: '', dio: stubDio());
    expect(
      await source.fetchLyrics(title: 'T', artist: 'A'),
      isNull,
    );
  });

  test('fetchLyrics GET 200 且内容为 LRC 时解析为 synced', () async {
    final source = CustomLyricsSource(
      urlTemplate: 'http://x/{title}/{artist}/{album}',
      dio: stubDioRespond('[00:01.00]line one\n[00:02.00]line two'),
    );
    final lyrics = await source.fetchLyrics(
      title: 'A B',
      artist: 'C D',
      album: 'E F',
    );
    expect(lyrics, isNotNull);
    expect(lyrics!.entries.first.synced, isTrue);
    expect(lyrics.entries.first.lines.length, 2);
  });

  test('fetchLyrics 模板占位符被 URL 编码替换', () async {
    String? capturedUrl;
    final stub = stubDio(
      handler: (options) {
        capturedUrl = options.uri.toString();
        return Response<dynamic>(
          requestOptions: options,
          data: '[00:01.00]x',
          statusCode: 200,
        );
      },
    );
    final source = CustomLyricsSource(
      urlTemplate: 'http://x/{title}/{artist}/{album}',
      dio: stub,
    );
    await source.fetchLyrics(title: 'A B', artist: 'C D', album: 'E F');
    expect(capturedUrl, 'http://x/A%20B/C%20D/E%20F');
  });

  test('fetchLyrics GET 非 200 时返回 null', () async {
    final source = CustomLyricsSource(
      urlTemplate: 'http://x/{title}',
      dio: stubDioRespond(null, statusCode: 500),
    );
    expect(await source.fetchLyrics(title: 'T', artist: 'A'), isNull);
  });

  test('fetchLyrics GET 异常时返回 null', () async {
    final source = CustomLyricsSource(
      urlTemplate: 'http://x/{title}',
      dio: stubDioThrowing(Exception('boom')),
    );
    expect(await source.fetchLyrics(title: 'T', artist: 'A'), isNull);
  });
}
