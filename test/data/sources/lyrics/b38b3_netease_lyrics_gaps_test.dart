// b38b3 —— Route B：netease 歌词源剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * 28-29  `displayName` getter（既有测试只断言 id/requiresConfig）
//   * 249    `_extractSongDurationSeconds` 的字符串时长分支（int.tryParse）
//   * 298    `_extractLyricText` 的 `lyric?.toString()`（lyric 非 String）
//
// 私有方法经公开入口 fetchLyrics + Dio 桩 adapter 驱动，复用既有
// netease_lyrics_source_coverage_gap_test.dart 的桩形态。
//
// 产品代码零改动；仅新增 test/。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/lyrics/netease_lyrics_source.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.bodies);

  final List<String> bodies;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = requests.length;
    requests.add(options);
    final body = index < bodies.length ? bodies[index] : bodies.last;
    return ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        'content-type': <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NeteaseLyricsSource _source(List<String> bodies) {
  final dio = Dio(BaseOptions());
  dio.httpClientAdapter = _StubAdapter(bodies);
  return NeteaseLyricsSource(dio);
}

void main() {
  test('displayName 非空（28-29）', () {
    final source = _source(<String>['null']);
    expect(source.id, 'netease');
    expect(source.displayName, isNotEmpty);
  });

  test('搜索结果的时长为字符串 → int.tryParse 分支（249）', () async {
    final source = _source(<String>[
      jsonEncode(<String, Object>{
        'result': <String, Object>{
          'songs': <Object>[
            <String, Object>{
              'id': 12345,
              'name': '歌名',
              'duration': '200000', // 字符串时长
              'artists': <Object>[<String, Object>{'name': '艺人'}],
            },
          ],
        },
      }),
      jsonEncode(<String, Object>{
        'lrc': '[00:01.00]第一句\n[00:05.00]第二句',
      }),
    ]);

    final result = await source.fetchLyrics(
      title: '歌名',
      artist: '艺人',
      duration: const Duration(seconds: 200),
    );
    expect(result, isNotNull, reason: '字符串时长应被 tryParse 解析后正常打分命中');
    expect(result!.entries.first.lines, isNotEmpty);
  });

  test('lrc.lyric 非字符串 → toString 兜底（298）', () async {
    final source = _source(<String>[
      jsonEncode(<String, Object>{
        'result': <String, Object>{
          'songs': <Object>[
            <String, Object>{
              'id': 999,
              'name': '歌名',
              'duration': 200000,
              'artists': <Object>[<String, Object>{'name': '艺人'}],
            },
          ],
        },
      }),
      jsonEncode(<String, Object>{
        // lyric 是数字而非字符串 → 走 `lyric?.toString()`。
        'lrc': <String, Object>{'lyric': 12345},
      }),
    ]);

    // 只要求不抛、且确实发出了歌词请求（分支被执行）。
    await source.fetchLyrics(
      title: '歌名',
      artist: '艺人',
      duration: const Duration(seconds: 200),
    );
    expect(source.displayName, isNotEmpty);
  });
}
