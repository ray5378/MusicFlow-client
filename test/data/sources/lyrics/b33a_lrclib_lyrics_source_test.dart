import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/lyrics/lrclib_lyrics_source.dart';

import '../../../helpers/b33a_stub_dio.dart';

/// 覆盖 LrclibLyricsSource：属性 + fetchLyrics 各分支
/// （同步优先/纯文本回退/都为空/非 200/异常/album+duration 参数构建）。
void main() {
  test('属性：id/displayName/requiresConfig', () {
    final source = LrclibLyricsSource(stubDio());
    expect(source.id, 'lrclib');
    expect(source.displayName, 'LRCLIB');
    expect(source.requiresConfig, isFalse);
  });

  test('fetchLyrics 同步歌词优先并被解析为 synced', () async {
    final data = {
      'syncedLyrics': '[00:01.00]hello\n[00:02.00]world',
      'plainLyrics': 'plain fallback',
    };
    final source = LrclibLyricsSource(stubDioRespond(data));
    final lyrics = await source.fetchLyrics(title: 'T', artist: 'A');
    expect(lyrics, isNotNull);
    expect(lyrics!.sourceId, 'lrclib');
    expect(lyrics.entries.first.synced, isTrue);
    expect(lyrics.entries.first.lines.length, 2);
  });

  test('fetchLyrics 仅纯文本时回退解析', () async {
    final data = {
      'syncedLyrics': '',
      'plainLyrics': 'just a line',
    };
    final source = LrclibLyricsSource(stubDioRespond(data));
    final lyrics = await source.fetchLyrics(title: 'T', artist: 'A');
    expect(lyrics, isNotNull);
    expect(lyrics!.entries.first.synced, isFalse);
    expect(lyrics.entries.first.lines.first.value, 'just a line');
  });

  test('fetchLyrics 同步与纯文本都为空时返回 null', () async {
    final data = {'syncedLyrics': '', 'plainLyrics': ''};
    final source = LrclibLyricsSource(stubDioRespond(data));
    expect(await source.fetchLyrics(title: 'T', artist: 'A'), isNull);
  });

  test('fetchLyrics 非 200 响应返回 null', () async {
    final source = LrclibLyricsSource(
      stubDioRespond(null, statusCode: 404),
    );
    expect(await source.fetchLyrics(title: 'T', artist: 'A'), isNull);
  });

  test('fetchLyrics 请求异常时返回 null', () async {
    final source = LrclibLyricsSource(stubDioThrowing(Exception('boom')));
    expect(await source.fetchLyrics(title: 'T', artist: 'A'), isNull);
  });

  test('fetchLyrics 携带 album 与 duration 时正常返回', () async {
    final data = {
      'syncedLyrics': '[00:01.00]hi',
      'plainLyrics': '',
    };
    final source = LrclibLyricsSource(stubDioRespond(data));
    final lyrics = await source.fetchLyrics(
      title: 'T',
      artist: 'A',
      album: 'AL',
      duration: const Duration(seconds: 180),
    );
    expect(lyrics, isNotNull);
  });
}
