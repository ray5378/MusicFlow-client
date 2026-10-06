// b38b3 —— Route B：LyricsRepository 回退/外部源门禁剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * 27  非外部可用时跳过来自非 subsonic 的提供商
//   * 31  await source.fetchLyrics(...)
//   * 38  命中非空歌词即返回
//   * 42  单个提供商抛错被吞、继续下一个
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/data/repositories/lyrics_repository.dart';
import 'package:musicflow_client/data/sources/lyrics/lyrics_source.dart';

class _FakeSource implements LyricsSource {
  _FakeSource(this.id, {this.result, this.throws = false, this.empty = false});

  @override
  final String id;

  final Lyrics? result;
  final bool throws;
  final bool empty;

  int calls = 0;

  @override
  String get displayName => id;

  @override
  bool get requiresConfig => false;

  @override
  Future<Lyrics?> fetchLyrics({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? songId,
  }) async {
    calls++;
    if (throws) throw StateError('provider $id boom');
    if (empty) {
      return Lyrics(sourceId: id, entries: <StructuredLyrics>[]);
    }
    return result;
  }
}

Lyrics _lyrics(String sourceId) => Lyrics(
      sourceId: sourceId,
      entries: <StructuredLyrics>[
        StructuredLyrics.fromJson(<String, dynamic>{
          'synced': false,
          'line': <Map<String, dynamic>>[
            <String, dynamic>{'value': 'la la'},
          ],
        }),
      ],
    );

void main() {
  test('首个提供商命中非空歌词即返回（27/31/38）', () async {
    final first = _FakeSource('netease', result: _lyrics('netease'));
    final repo = LyricsRepository(sources: <LyricsSource>[first]);

    final lyrics = await repo.getLyrics(songId: 's1', title: 'Song', artist: 'Artist');
    expect(lyrics, isNotNull);
    expect(lyrics!.sourceId, 'netease');
    expect(first.calls, 1);
  });

  test('提供商抛错被吞、空歌词跳过、继续向下（38/42）', () async {
    final throwing = _FakeSource('netease', throws: true);
    final empty = _FakeSource('kugou', empty: true);
    final ok = _FakeSource('subsonic', result: _lyrics('subsonic'));
    final repo = LyricsRepository(sources: <LyricsSource>[throwing, empty, ok]);

    final lyrics = await repo.getLyrics(songId: 's2', title: 'Song', artist: 'Artist');
    expect(lyrics, isNotNull);
    expect(lyrics!.sourceId, 'subsonic');
    expect(throwing.calls, 1);
    expect(empty.calls, 1);
    expect(ok.calls, 1);
  });

  test('未知歌手 → 门禁拦下外部提供商（27）', () async {
    final external = _FakeSource('netease', result: _lyrics('netease'));
    final subsonic = _FakeSource('subsonic', result: _lyrics('subsonic'));
    final repo = LyricsRepository(sources: <LyricsSource>[external, subsonic]);

    final lyrics = await repo.getLyrics(
      songId: 's3',
      title: 'Song',
      artist: 'Unknown Artist',
    );
    expect(external.calls, 0, reason: '未知歌手不应查询外部提供商');
    expect(lyrics!.sourceId, 'subsonic');
  });

  test('路径样式标题 → 门禁拦下外部提供商，全部落空返回 null', () async {
    final external = _FakeSource('netease', result: _lyrics('netease'));
    final repo = LyricsRepository(sources: <LyricsSource>[external]);

    final lyrics = await repo.getLyrics(
      songId: 's4',
      title: 'disc1/track2/cdimage.flac',
      artist: 'Real Artist',
    );
    expect(lyrics, isNull);
    expect(external.calls, 0);
  });
}
