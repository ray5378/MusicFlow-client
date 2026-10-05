import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/repositories/cover_repository.dart';
import 'package:musicflow_client/data/sources/covers/cover_source.dart';

class _FakeCoverSource implements CoverSource {
  _FakeCoverSource(this.id, {this.url, this.error});

  @override
  final String id;

  final String? url;
  final Object? error;

  int calls = 0;
  String? lastArtist;
  String? lastAlbum;
  int? lastSize;

  @override
  String get displayName => 'source-$id';

  @override
  bool get requiresConfig => false;

  @override
  Future<String?> fetchCoverUrl({
    required String artist,
    String? album,
    String? musicBrainzId,
    String? coverArtId,
    int? size,
  }) async {
    calls++;
    lastArtist = artist;
    lastAlbum = album;
    lastSize = size;
    final current = error;
    if (current != null) throw current;
    return url;
  }
}

void main() {
  test('第一个源命中即返回，并带上 sourceId', () async {
    final first = _FakeCoverSource('first', url: 'https://a.test/cover.jpg');
    final second = _FakeCoverSource('second', url: 'https://b.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first, second]);

    final result = await repo.getCoverUrlWithSource(
      artist: 'Artist',
      album: 'Album',
      size: 300,
    );

    expect(result, isNotNull);
    expect(result!.sourceId, 'first');
    expect(result.url, 'https://a.test/cover.jpg');
    expect(first.calls, 1);
    expect(second.calls, 0);
    expect(first.lastArtist, 'Artist');
    expect(first.lastAlbum, 'Album');
    expect(first.lastSize, 300);
  });

  test('前一个源返回 null 时继续回落到下一个源', () async {
    final first = _FakeCoverSource('first');
    final second = _FakeCoverSource('second', url: 'https://b.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first, second]);

    final result = await repo.getCoverUrlWithSource(artist: 'Artist');

    expect(result!.sourceId, 'second');
    expect(first.calls, 1);
    expect(second.calls, 1);
  });

  test('源抛异常时跳过并继续下一个源', () async {
    final first = _FakeCoverSource('first', error: StateError('boom'));
    final second = _FakeCoverSource('second', url: 'https://b.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first, second]);

    final result = await repo.getCoverUrlWithSource(artist: 'Artist');

    expect(result!.sourceId, 'second');
    expect(second.calls, 1);
  });

  test('startAfterSourceId 从指定源之后开始尝试', () async {
    final first = _FakeCoverSource('first', url: 'https://a.test/cover.jpg');
    final second = _FakeCoverSource('second', url: 'https://b.test/cover.jpg');
    final third = _FakeCoverSource('third', url: 'https://c.test/cover.jpg');
    final repo = CoverRepository(
      sources: <CoverSource>[first, second, third],
    );

    final result = await repo.getCoverUrlWithSource(
      artist: 'Artist',
      startAfterSourceId: 'first',
    );

    expect(result!.sourceId, 'second');
    expect(first.calls, 0);
    expect(second.calls, 1);
    expect(third.calls, 0);
  });

  test('startAfterSourceId 未知时从第一个源开始', () async {
    final first = _FakeCoverSource('first', url: 'https://a.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first]);

    final result = await repo.getCoverUrlWithSource(
      artist: 'Artist',
      startAfterSourceId: 'does-not-exist',
    );

    expect(result!.sourceId, 'first');
    expect(first.calls, 1);
  });

  test('空字符串的 startAfterSourceId 不跳过任何源', () async {
    final first = _FakeCoverSource('first', url: 'https://a.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first]);

    final result = await repo.getCoverUrlWithSource(
      artist: 'Artist',
      startAfterSourceId: '',
    );

    expect(result!.sourceId, 'first');
  });

  test('空白 URL 视为未命中并继续回落', () async {
    final first = _FakeCoverSource('first', url: '   ');
    final second = _FakeCoverSource('second', url: 'https://b.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first, second]);

    final result = await repo.getCoverUrlWithSource(artist: 'Artist');

    expect(result!.sourceId, 'second');
  });

  test('全部源都失败时返回 null', () async {
    final first = _FakeCoverSource('first', error: StateError('boom'));
    final second = _FakeCoverSource('second');
    final repo = CoverRepository(sources: <CoverSource>[first, second]);

    expect(await repo.getCoverUrlWithSource(artist: 'Artist'), isNull);
    expect(first.calls, 1);
    expect(second.calls, 1);
  });

  test('没有任何源时返回 null', () async {
    final repo = CoverRepository(sources: const <CoverSource>[]);

    expect(await repo.getCoverUrlWithSource(artist: 'Artist'), isNull);
  });

  test('getCoverUrl 返回命中源的 URL', () async {
    final first = _FakeCoverSource('first', url: 'https://a.test/cover.jpg');
    final repo = CoverRepository(sources: <CoverSource>[first]);

    expect(
      await repo.getCoverUrl(artist: 'Artist', musicBrainzId: 'mb-1'),
      'https://a.test/cover.jpg',
    );
  });

  test('getCoverUrl 未命中返回 null', () async {
    final repo = CoverRepository(sources: const <CoverSource>[]);

    expect(await repo.getCoverUrl(artist: 'Artist'), isNull);
  });
}
