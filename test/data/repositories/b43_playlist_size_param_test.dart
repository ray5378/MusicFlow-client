// b43 —— PlaylistRepository.getPlaylists(size:) 分页参数行覆盖率补测。
//
// playlist_repository.dart:129（`{'size': size.toString()}` 分支）在
// batch42 引入 size 分页参数后仅走 null 分支被覆盖；本用例钉住 size=50
// 时确实把分页参数传给服务端。
import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

void main() {
  test('getPlaylists(size: 50) → 以 size=50 字符串参数请求服务端', () async {
    final apiClient = MockSubsonicApiClient();
    final repository = PlaylistRepository(apiClient);
    when(
      () => apiClient.get(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => <String, dynamic>{
        'playlists': <String, dynamic>{
          'playlist': <dynamic>[],
        },
      },
    );

    final result = await repository.getPlaylists(size: 50);
    expect(result, isEmpty);

    verify(
      () => apiClient.get(
        ApiConstants.getPlaylists,
        queryParameters: <String, dynamic>{'size': '50'},
      ),
    ).called(1);
  });
}
