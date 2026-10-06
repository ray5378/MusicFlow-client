// b39b —— Route B：UI provider 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * palette_provider.dart:27-28   MediaPaletteRequest.previewUrl 命名构造
//   * palette_provider.dart:64      空 key 的 ArgumentError 守卫
//   * palette_provider.dart:165/169 预览曲 → previewUrl 请求并 await 调色板
//   * palette_provider.dart:222     无活跃库时回退 activeAddress.url 作 sourceId
//   * app_visibility_provider.dart:74-75  原生窗口可见性通道回调
//   * home_section_layout_provider.dart:16 已保存布局非空时直接采用
//
// 产品代码零改动；仅新增 test/。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/app_visibility_provider.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

import '../../helpers/mocks.dart';
import '../../features/player/test_player_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaPaletteRequest 命名构造与缓存守卫', () {
    test('previewUrl 命名构造（line 27-28）与相等性', () {
      // 非 const 调用：确保命名构造函数在运行时执行。
      final preview = MediaPaletteRequest.previewUrl('http://x/cover.jpg');
      expect(preview.kind, MediaPaletteSourceKind.previewUrl);
      expect(preview.reference, 'http://x/cover.jpg');

      final cover = MediaPaletteRequest.coverReference('c-1');
      expect(cover.kind, MediaPaletteSourceKind.coverReference);
      expect(cover == preview, isFalse);
    });

    test('BoundedAsyncCache.getOrLoad 空 key 抛 ArgumentError（line 64）', () {
      final cache = BoundedAsyncCache<int>(capacity: 2);
      expect(
        () => cache.getOrLoad('', () async => 1),
        throwsArgumentError,
      );
    });
  });

  group('currentSongPaletteProvider 预览曲路径', () {
    test('预览曲带封面 URL → previewUrl 请求并 await（line 165/169）', () async {
      final song = Song(
        id: 's-preview',
        title: '预览',
        isPreview: true,
        previewCoverUrl: 'http://127.0.0.1:1/preview.jpg',
      );
      final player = TestPlayerNotifier(PlayerState(currentSong: song));
      final container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith((ref) => player),
          // 用即时返回 null 的加载器替身：避免真实图片解码在测试环境挂起，
          // 同时完整执行 currentSongPaletteProvider 的请求与 await 分支。
          mediaPaletteLoaderProvider.overrideWithValue(
            (imageProvider) async => null,
          ),
        ],
      );
      addTearDown(container.dispose);

      // 网络图在测试环境被拦截 → 调色板兜底 null；关键是请求与 await 分支被执行。
      final result = await container
          .read(currentSongPaletteProvider.future)
          .timeout(const Duration(seconds: 10));
      expect(result, isNull);
    });
  });

  group('_resolvePaletteResource 源标识回退', () {
    test('无活跃库时用 activeAddress.url 作 sourceId（line 222）', () async {
      final client = MockSubsonicApiClient();
      when(
        () => client.getCoverArtUrl(any(), size: any(named: 'size')),
      ).thenReturn('http://127.0.0.1:1/cover.jpg');

      final address = ServerAddress(
        id: 'addr-1',
        libraryId: 'lib-1',
        label: '主线路',
        url: 'http://127.0.0.1:1',
        priority: 0,
      );

      final container = ProviderContainer(
        overrides: <Override>[
          subsonicApiClientProvider.overrideWithValue(client),
          activeLibraryProvider.overrideWithValue(null),
          activeAddressProvider.overrideWith((ref) => address),
          mediaPaletteLoaderProvider.overrideWithValue(
            (imageProvider) async => null,
          ),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(
            mediaPaletteProvider(
              MediaPaletteRequest.coverReference('cover-1'),
            ).future,
          )
          .timeout(const Duration(seconds: 10));
      expect(result, isNull);
      verify(
        () => client.getCoverArtUrl(any(), size: any(named: 'size')),
      ).called(1);
    });
  });

  group('AppVisibilityScope 窗口可见性通道', () {
    testWidgets('原生上报 window-visible=false → windowOccluded 置 false（line 74-75）',
        (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: AppVisibilityScope(child: SizedBox.shrink()),
          ),
        ),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppVisibilityScope)),
        listen: false,
      );
      expect(container.read(windowOccludedProvider), isTrue);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'com.musicflow.app/window-visible',
        const StringCodec().encodeMessage('false'),
        (ByteData? _) {},
      );
      await tester.pump();

      expect(container.read(windowOccludedProvider), isFalse);
    });
  });

  group('homeSectionLayoutProvider 读取已保存布局', () {
    test('布局非空时直接采用（line 16）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'home_section_layout_v1': jsonEncode(<String, dynamic>{
          'order': <String>['discover', 'library'],
          'hidden': <String>['radio'],
          'miniPlayerVisible': false,
        }),
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final layout =
          await container.read(homeSectionLayoutProvider.future);
      expect(layout.order, <String>['discover', 'library']);
      expect(layout.hidden, <String>['radio']);
      expect(layout.miniPlayerVisible, isFalse);
      expect(layout.isEmpty, isFalse);
    });
  });
}
