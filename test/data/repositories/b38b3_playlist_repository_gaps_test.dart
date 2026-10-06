// b38b3 —— `lib/data/repositories/playlist_repository.dart` 补测。
//
// 未覆盖行（230 lcov）：162 —— `_parseSongs` 的「跳过损坏单曲」catch。
// 该容忍性解析是为修「一首坏数据整页崩」而加（见方法注释），但既有用例
// 都喂了完整合法数据，catch 从未命中。
//
// 复用 test/helpers/mocks.dart 的 MockSubsonicApiClient；喂一条合法 + 一条
// 字段类型不兼容（isPreview 非 bool）的曲目，验证坏条目被跳过、好条目保留。
// 产品代码零改动；只读 lib。

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/repositories/playlist_repository.dart';

import '../../helpers/mocks.dart';

void main() {
  late MockSubsonicApiClient api;
  late PlaylistRepository repo;

  setUp(() {
    api = MockSubsonicApiClient();
    repo = PlaylistRepository(api);
  });

  test('getPlaylistTracksPage 跳过字段类型不兼容的单曲，保留好条目（命中 162）', () async {
    when(() => api.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
        )).thenAnswer((_) async => <String, dynamic>{
          'entries': <dynamic>[
            <String, dynamic>{'id': 's1', 'title': '好曲目'},
            // `json['isPreview'] as bool?` 遇到非 bool 非 null → TypeError 抛出，
            // 被 _parseSongs 逐条 try/catch 吞掉并跳过（line 162）。
            <String, dynamic>{'id': 's2', 'title': '坏曲目', 'isPreview': 'oops'},
          ],
          'total': 2,
        });

    final res = await repo.getPlaylistTracksPage('pl-1', 1, 50);

    expect(res.items.length, 1, reason: '坏条目应被跳过，只保留合法曲目');
    expect(res.items.single.id, 's1');
    expect(res.items.single.title, '好曲目');
    expect(res.total, 2, reason: 'total 取服务端值，不受跳过影响');
  });

  test('全部为坏条目时返回空列表且不抛（容忍性解析）', () async {
    when(() => api.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
        )).thenAnswer((_) async => <String, dynamic>{
          'entries': <dynamic>[
            <String, dynamic>{'id': 'b1', 'isPreview': 123},
            <String, dynamic>{'id': 'b2', 'previewPicId': 456},
          ],
        });

    final res = await repo.getPlaylistTracksPage('pl-2', 1, 50);
    expect(res.items, isEmpty);
  });
}
