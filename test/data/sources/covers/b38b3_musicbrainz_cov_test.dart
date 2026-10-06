// b38b3 —— `lib/data/sources/covers/musicbrainz_cover_source.dart` 补测。
//
// 未覆盖行（230 lcov）：55-57 —— `size <= 500` 时缩略图优先级链
//   `thumbnails?['500'] ?? thumbnails?['large'] ?? imageData['image']`
// 的「没有 500 但有 large」和「500/large 都缺、回落全尺寸 image」两条兜底。
//
// 用 Dio 的内存 adapter 桩直接喂 JSON，不碰真网络。
// 产品代码零改动；只读 lib。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/covers/musicbrainz_cover_source.dart';

/// 只回一个固定 JSON 的 HttpClientAdapter 桩。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body, {this.status = 200});

  final Object body;
  final int status;
  int calls = 0;
  String? lastPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastPath = options.path;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

MusicbrainzCoverSource _source(Object body, {int status = 200}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://coverartarchive.org'));
  dio.httpClientAdapter = _StubAdapter(body, status: status);
  return MusicbrainzCoverSource(dio);
}

Map<String, dynamic> _release(Map<String, dynamic> frontImage) => <String, dynamic>{
      'images': <dynamic>[
        <String, dynamic>{'front': true, ...frontImage},
      ],
    };

void main() {
  test('size<=500 且无 500 键：回落到 large 缩略图', () async {
    final src = _source(_release(<String, dynamic>{
      'image': 'https://img/full.jpg',
      'thumbnails': <String, dynamic>{
        'large': 'https://img/large.jpg',
        'small': 'https://img/small.jpg',
      },
    }));

    final url = await src.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mbid-1',
      size: 500,
    );
    expect(url, 'https://img/large.jpg', reason: '无 500 时应取 large 缩略图');
  });

  test('size<=500 且 500/large 都缺：回落全尺寸 image', () async {
    final src = _source(_release(<String, dynamic>{
      'image': 'https://img/full.jpg',
      'thumbnails': <String, dynamic>{'small': 'https://img/small.jpg'},
    }));

    final url = await src.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mbid-1',
      size: 250,
    );
    expect(url, 'https://img/full.jpg', reason: '500/large 都缺 → 回落 image');
  });

  test('对照：有 500 键时优先 500', () async {
    final src = _source(_release(<String, dynamic>{
      'image': 'https://img/full.jpg',
      'thumbnails': <String, dynamic>{
        '500': 'https://img/500.jpg',
        'large': 'https://img/large.jpg',
      },
    }));

    final url = await src.fetchCoverUrl(
      artist: 'A',
      musicBrainzId: 'mbid-1',
      size: 500,
    );
    expect(url, 'https://img/500.jpg');
  });
}
