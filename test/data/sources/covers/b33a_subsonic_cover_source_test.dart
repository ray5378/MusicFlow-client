import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/sources/covers/subsonic_cover_source.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

/// 覆盖 SubsonicCoverSource：属性 + fetchCoverUrl 各分支
/// （缺 coverArtId/已配置库返回 URL/含 size/未配置库返回 null）。
/// 注意：getCoverArtUrl 仅做 URL 拼装，不发网络请求，故用真实 SubsonicApiClient。
void main() {
  late SubsonicApiClient client;

  setUp(() {
    client = SubsonicApiClient(dio: Dio());
    client.setLibrary(
      MusicLibrary(
        id: 'lib1',
        name: 'Test',
        authType: MusicLibraryAuthType.token,
        username: 'u',
        password: 'p',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
      ),
    );
    client.dio.options.baseUrl = 'http://server.test/';
  });

  test('属性：id/displayName/requiresConfig', () {
    final source = SubsonicCoverSource(client);
    expect(source.id, 'subsonic');
    expect(source.requiresConfig, isFalse);
    expect(source.displayName, isNotEmpty);
  });

  test('fetchCoverUrl 返回 null 当 coverArtId 为 null', () async {
    final source = SubsonicCoverSource(client);
    expect(
      await source.fetchCoverUrl(artist: 'A', coverArtId: null),
      isNull,
    );
  });

  test('fetchCoverUrl 返回 null 当 coverArtId 为空串', () async {
    final source = SubsonicCoverSource(client);
    expect(
      await source.fetchCoverUrl(artist: 'A', coverArtId: ''),
      isNull,
    );
  });

  test('fetchCoverUrl 已配置库时返回非空的 getCoverArt URL', () async {
    final source = SubsonicCoverSource(client);
    final url = await source.fetchCoverUrl(
      artist: 'A',
      coverArtId: 'ca123',
    );
    expect(url, isNotNull);
    expect(url, contains('getCoverArt'));
    expect(url, contains('ca123'));
  });

  test('fetchCoverUrl 带 size 时 URL 包含 size 参数', () async {
    final source = SubsonicCoverSource(client);
    final url = await source.fetchCoverUrl(
      artist: 'A',
      coverArtId: 'ca123',
      size: 300,
    );
    expect(url, contains('size=300'));
  });

  test('fetchCoverUrl 未配置库（无 library）时返回 null', () async {
    final unconfigured = SubsonicApiClient(dio: Dio());
    unconfigured.dio.options.baseUrl = 'http://server.test/';
    final source = SubsonicCoverSource(unconfigured);
    expect(
      await source.fetchCoverUrl(artist: 'A', coverArtId: 'ca123'),
      isNull,
    );
  });
}
