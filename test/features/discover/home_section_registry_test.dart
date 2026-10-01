import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/features/discover/home_section_registry.dart';

void main() {
  group('normalizeRecommendSectionOrder', () {
    test('platform-recommend 在 local-recommend 之前时对调', () {
      final result = normalizeRecommendSectionOrder(<String>[
        'random-songs',
        'platform-recommend',
        'local-recommend',
      ]);
      expect(result, <String>[
        'random-songs',
        'local-recommend',
        'platform-recommend',
      ]);
    });

    test('local-recommend 已在 platform-recommend 之前时保持不变', () {
      final keys = <String>['local-recommend', 'platform-recommend'];
      expect(normalizeRecommendSectionOrder(keys), same(keys));
    });

    test('仅其一存在时不调整', () {
      final onlyPlatform = <String>['platform-recommend'];
      expect(normalizeRecommendSectionOrder(onlyPlatform), same(onlyPlatform));
      final onlyLocal = <String>['local-recommend'];
      expect(normalizeRecommendSectionOrder(onlyLocal), same(onlyLocal));
    });
  });

  group('applyHomeSectionLayout', () {
    final base = <String>[
      'random-songs',
      'recent-playlists',
      'home-recommend',
      'local-recommend',
      'platform-recommend',
    ];

    test('空布局原样返回(完全遵循服务端清单)', () {
      final result = applyHomeSectionLayout(base, HomeSectionLayout.empty);
      expect(result, base);
    });

    test('用户排序覆盖服务端顺序(全部已知分区重排)', () {
      const layout = HomeSectionLayout(
        order: <String>[
          'platform-recommend',
          'random-songs',
          'recent-playlists',
          'home-recommend',
          'local-recommend',
        ],
      );
      expect(applyHomeSectionLayout(base, layout), <String>[
        'platform-recommend',
        'random-songs',
        'recent-playlists',
        'home-recommend',
        'local-recommend',
      ]);
    });

    test('用户 order 中已下线的分区被淘汰,不在 order 的分区按服务端顺序追加尾部', () {
      // layout.order 含废弃 key 'legacy' 与未出现在服务端清单的分区。
      const layout = HomeSectionLayout(
        order: <String>['local-recommend', 'legacy', 'random-songs'],
      );
      expect(applyHomeSectionLayout(base, layout), <String>[
        'local-recommend',
        'random-songs',
        // 服务端新增/未排过的分区按 sortOrder 追加尾部。
        'recent-playlists',
        'home-recommend',
        'platform-recommend',
      ]);
    });

    test('用户隐藏的分区不渲染(隐藏后不拉取)', () {
      const layout = HomeSectionLayout(
        hidden: <String>['home-recommend', 'platform-recommend'],
      );
      expect(applyHomeSectionLayout(base, layout), <String>[
        'random-songs',
        'recent-playlists',
        'local-recommend',
      ]);
    });

    test('隐藏 + 排序叠加生效', () {
      const layout = HomeSectionLayout(
        order: <String>['local-recommend', 'random-songs'],
        hidden: <String>['recent-playlists'],
      );
      expect(applyHomeSectionLayout(base, layout), <String>[
        'local-recommend',
        'random-songs',
        'home-recommend',
        'platform-recommend',
      ]);
    });
  });

  group('injectClientOwnedSection', () {
    final legacy = <String>[
      'random-songs',
      'recent-playlists',
      'home-recommend',
      'local-recommend',
      'platform-recommend',
    ];

    test('服务端清单不含该 key 时注入到首位', () {
      final result = injectClientOwnedSection(legacy);
      expect(result, hasLength(6));
      expect(result.first, kRemoteControlSectionKey);
      expect(result.sublist(1), legacy);
    });

    test('清单已含该 key 时幂等返回原 list', () {
      final keys = <String>[kRemoteControlSectionKey, ...legacy];
      expect(injectClientOwnedSection(keys), same(keys));
    });

    test('空清单也能注入(清单未就绪时不至于拿不到该块)', () {
      expect(injectClientOwnedSection(<String>[]), <String>[
        kRemoteControlSectionKey,
      ]);
    });
  });

  group('hoistClientOwnedSection', () {
    test('空布局(新装用户)→ 该块置顶', () {
      final result = hoistClientOwnedSection(
        <String>['random-songs', kRemoteControlSectionKey, 'recent-playlists'],
        HomeSectionLayout.empty,
      );
      expect(result, <String>[
        kRemoteControlSectionKey,
        'random-songs',
        'recent-playlists',
      ]);
    });

    test('老用户 order 不含该 key → 覆盖「未排过追加尾部」语义,强制置顶', () {
      // applyHomeSectionLayout 会把未排过的 key 追加尾部,本函数专门兜这个。
      final sunk = <String>[
        'random-songs',
        'recent-playlists',
        kRemoteControlSectionKey,
      ];
      const layout = HomeSectionLayout(
        order: <String>['random-songs', 'recent-playlists'],
      );
      expect(hoistClientOwnedSection(sunk, layout), <String>[
        kRemoteControlSectionKey,
        'random-songs',
        'recent-playlists',
      ]);
    });

    test('用户排过该 key → 原样返回,尊重用户位置', () {
      final keys = <String>['random-songs', kRemoteControlSectionKey];
      const layout = HomeSectionLayout(
        order: <String>['random-songs', kRemoteControlSectionKey],
      );
      expect(hoistClientOwnedSection(keys, layout), same(keys));
    });

    test('用户隐藏该 key(base 里已剔除)→ 原样返回', () {
      final keys = <String>['random-songs', 'recent-playlists'];
      const layout = HomeSectionLayout(hidden: <String>[
        kRemoteControlSectionKey,
      ]);
      expect(hoistClientOwnedSection(keys, layout), same(keys));
    });
  });

  group('buildHomeSectionEditOrder', () {
    test('空布局回落客户端默认清单', () {
      expect(
        buildHomeSectionEditOrder(HomeSectionLayout.empty),
        kDefaultHomeSectionKeys,
      );
    });

    test('用户排过的在前,未排过的按默认顺序追加,order 内未知 key 忽略', () {
      const layout = HomeSectionLayout(
        order: <String>['platform-recommend', 'legacy', 'random-songs'],
      );
      expect(buildHomeSectionEditOrder(layout), <String>[
        'platform-recommend',
        'random-songs',
        // 未排过的按 kDefaultHomeSectionKeys 顺序追加(客户端自治的
        // 「播放控制」块在该常量首位,故排在最前)。
        kRemoteControlSectionKey,
        'recent-playlists',
        'home-recommend',
        'local-recommend',
      ]);
    });
  });
}
