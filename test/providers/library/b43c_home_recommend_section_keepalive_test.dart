// b43c —— homeRecommendSectionProvider 去 autoDispose（keepAlive）行为钉子。
//
// 与 batch42 四个 provider 同样处理：离开发现页再回来不重拉；
// watch 的依赖（活跃库/客户端）变化时 Riverpod 自动失效重建重拉。
//
// 打法（对齐 b39b 范式）：
//   - listen 后立刻取消监听（模拟离开页面），再读 .future —— keepAlive
//     返回同一份缓存结果（仓库只被调用一次）；若仍是 autoDispose 则会
//     重建并第二次调用仓库，以此作为行为钉。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

class MockRecommendRepository extends Mock implements RecommendRepository {}

ServerAddress _address() => ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: '主线路',
      url: 'http://127.0.0.1:1',
      priority: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('离开页面（取消监听）后再读 → 不重拉，keepAlive 保留缓存结果', () async {
    final repo = MockRecommendRepository();
    when(() => repo.getHomeCards()).thenAnswer((_) async => <HomeCard>[
          HomeCard(
            playlistId: 'c1',
            name: 'card',
            playlistName: '歌单',
            position: 0,
            isCombo: false,
            songCount: 42,
          ),
        ]);

    final container = ProviderContainer(
      overrides: <Override>[
        recommendRepositoryProvider.overrideWithValue(repo),
        activeLibraryProvider.overrideWithValue(null),
        ensureActiveAddressProvider.overrideWith((ref) async => _address()),
        // homeCount=1 且固定卡已有 1 张 → needed=0，跳过随机补位（不触歌单仓）。
        homePlaylistCountProvider.overrideWith((ref) async => 1),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(homeRecommendSectionProvider, (_, _) {});
    final section = await container.read(homeRecommendSectionProvider.future);
    expect(section.fixed, isNotEmpty);

    // 模拟离开页面：取消监听。
    sub.close();

    final again = await container.read(homeRecommendSectionProvider.future);
    expect(identical(again, section), isTrue,
        reason: 'keepAlive provider 应返回同一份缓存结果');
    verify(() => repo.getHomeCards()).called(1);
  });

  test('依赖变化后 invalidate → 重建重拉（Riverpod 自动失效路径仍可用）', () async {
    final repo = MockRecommendRepository();
    when(() => repo.getHomeCards()).thenAnswer((_) async => <HomeCard>[]);

    final container = ProviderContainer(
      overrides: <Override>[
        recommendRepositoryProvider.overrideWithValue(repo),
        activeLibraryProvider.overrideWithValue(null),
        ensureActiveAddressProvider.overrideWith((ref) async => _address()),
        homePlaylistCountProvider.overrideWith((ref) async => 1),
      ],
    );
    addTearDown(container.dispose);

    container.listen(homeRecommendSectionProvider, (_, _) {});
    await container.read(homeRecommendSectionProvider.future);

    // 手动失效等价于依赖变化触发的自动失效：重建时再次走仓库。
    container.invalidate(homeRecommendSectionProvider);
    await container.read(homeRecommendSectionProvider.future);
    verify(() => repo.getHomeCards()).called(2);
  });
}
