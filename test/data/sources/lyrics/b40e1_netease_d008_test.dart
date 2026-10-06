// b40e1 —— D-008 补充用例：netease 歌词源 `songs` 字段类型异常时判型安全返回。
//
// 修复前 `result['songs'] as List?` 在字段是 map/string 时抛 TypeError，
// 被最外层 catch 整块吞掉（静默为空，错误不进 warn 日志）。
// 修复后先 `is List` 判型，判型失败记 warn 并对外返回 null。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/lyrics/netease_lyrics_source.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.bodies);

  final List<String> bodies;
  int served = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final i = served++;
    final body = i < bodies.length ? bodies[i] : 'null';
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
  group('[D-008] songs 字段判型', () {
    test('songs 是 map → 判型安全返回 null,不抛异常', () async {
      final source = _source(<String>[
        jsonEncode(<String, Object>{
          'result': <String, Object>{'songs': <String, Object>{'a': 1}},
        }),
      ]);
      expect(
        await source.fetchLyrics(title: '歌名', artist: '艺人'),
        isNull,
      );
    });

    test('songs 是字符串 → 判型安全返回 null,不抛异常', () async {
      final source = _source(<String>[
        jsonEncode(<String, Object>{
          'result': <String, Object>{'songs': 'not-a-list'},
        }),
      ]);
      expect(
        await source.fetchLyrics(title: '歌名', artist: '艺人'),
        isNull,
      );
    });
  });
}
