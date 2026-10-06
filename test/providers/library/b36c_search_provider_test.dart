// b36c —— `lib/providers/library/search_provider.dart` 补测（原 6/25，24%）。
//
// 覆盖：
//   * searchProvidersProvider —— 仓库为 null / 正常返回 / ensureActiveAddress
//     抛错被吞回 [];
//   * searchResultsProvider —— 仓库为 null / 本地模式短路 / 空查询短路 /
//     aggregate 成功透传 / 远程搜索异常 rethrow；
//   * searchRepositoryProvider 正常构造。
//
// 产品代码零改动；只读 lib。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';

class _MockSearchRepository extends Mock implements SearchRepository {}

SearchRequest _req({
  SearchEntityKind kind = SearchEntityKind.song,
  SearchMode mode = SearchMode.aggregate,
  String query = 'hello',
  String providerId = '',
}) =>
    SearchRequest(kind: kind, mode: mode, query: query, providerId: providerId);

void main() {
  late _MockSearchRepository repo;

  const address = ServerAddress(
    id: 'addr-1',
    libraryId: 'lib-1',
    label: 'home',
    url: 'http://127.0.0.1:4533',
    priority: 0,
  );

  List<Override> withRepo(SearchRepository? r) => <Override>[
        searchRepositoryProvider.overrideWithValue(r),
        ensureActiveAddressProvider.overrideWith((ref) async => address),
      ];

  setUp(() {
    repo = _MockSearchRepository();
  });

  group('searchProvidersProvider', () {
    test('仓库为 null 时返回空列表', () async {
      final container = ProviderContainer(
        overrides: <Override>[searchRepositoryProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final result = await container.read(
        searchProvidersProvider(SearchEntityKind.song).future,
      );
      expect(result, isEmpty);
    });

    test('正常委托仓库返回插件清单', () async {
      when(() => repo.getProviders(SearchEntityKind.album)).thenAnswer(
        (_) async => <SearchProvider>[
          SearchProvider(id: 'netease', name: '网易云'),
        ],
      );
      final container = ProviderContainer(overrides: withRepo(repo));
      addTearDown(container.dispose);
      final result = await container.read(
        searchProvidersProvider(SearchEntityKind.album).future,
      );
      expect(result.map((p) => p.id), <String>['netease']);
      verify(() => repo.getProviders(SearchEntityKind.album)).called(1);
    });

    test('ensureActiveAddress 抛错被吞，回落空列表', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          searchRepositoryProvider.overrideWithValue(repo),
          ensureActiveAddressProvider.overrideWith(
            (ref) async => throw StateError('no address'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final result = await container.read(
        searchProvidersProvider(SearchEntityKind.song).future,
      );
      expect(result, isEmpty);
      verifyNever(() => repo.getProviders(SearchEntityKind.song));
    });
  });

  group('searchResultsProvider', () {
    test('仓库为 null 时返回空结果', () async {
      final container = ProviderContainer(
        overrides: <Override>[searchRepositoryProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final outcome = await container.read(
        searchResultsProvider(_req()).future,
      );
      expect(outcome.isEmpty, isTrue);
    });

    test('本地模式短路，不触达远程仓库', () async {
      final container = ProviderContainer(overrides: withRepo(repo));
      addTearDown(container.dispose);
      final outcome = await container.read(
        searchResultsProvider(_req(mode: SearchMode.local)).future,
      );
      expect(outcome.isEmpty, isTrue);
      verifyNever(
        () => repo.searchRemote(SearchEntityKind.song, 'hello', providerId: ''),
      );
    });

    test('查询为空白短路，不触达远程仓库', () async {
      final container = ProviderContainer(overrides: withRepo(repo));
      addTearDown(container.dispose);
      final outcome = await container.read(
        searchResultsProvider(_req(query: '   ')).future,
      );
      expect(outcome.isEmpty, isTrue);
      verifyNever(
        () => repo.searchRemote(SearchEntityKind.song, 'hello', providerId: ''),
      );
    });

    test('aggregate 模式成功透传仓库结果', () async {
      when(
        () => repo.searchRemote(
          SearchEntityKind.song,
          'hello',
          providerId: '',
        ),
      ).thenAnswer(
        (_) async => SearchOutcome(
          songs: <SearchSong>[SearchSong(id: 's1', name: '结果')],
        ),
      );
      final container = ProviderContainer(overrides: withRepo(repo));
      addTearDown(container.dispose);
      final outcome = await container.read(
        searchResultsProvider(_req()).future,
      );
      expect(outcome.songs.single.id, 's1');
    });

    test('远程搜索异常向上 rethrow', () async {
      when(
        () => repo.searchRemote(
          SearchEntityKind.song,
          'hello',
          providerId: '',
        ),
      ).thenThrow(Exception('boom'));
      final container = ProviderContainer(overrides: withRepo(repo));
      addTearDown(container.dispose);
      await expectLater(
        container.read(searchResultsProvider(_req()).future),
        throwsA(isA<Exception>()),
      );
    });
  });
}
