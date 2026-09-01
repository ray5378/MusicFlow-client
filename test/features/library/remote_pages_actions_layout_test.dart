// 平台歌单/专辑预览页加入库按钮窄屏溢出回归(用户截图反馈驱动):
// 双按钮"播放全部"+"加入库"在窄屏(< 340px 或字号放大)必须垂直堆叠,
// 不允许右侧按钮被裁;宽屏仍水平 Row 各占一半。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/design/components/music_flow_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/remote_album_page.dart';
import 'package:musicflow_client/features/library/pages/remote_playlist_page.dart';
import 'package:musicflow_client/providers/search_provider.dart';

import '../../helpers/mocks.dart';

SearchPlaylist _playlist() => SearchPlaylist(
      id: 'p-1',
      source: 'douyin',
      name: '2026短视频网络热门最火歌曲',
      providerId: 'douyin',
      trackCount: '70',
    );

SearchAlbum _album() => SearchAlbum(
      id: 'a-1',
      source: 'douyin',
      name: '抖音热曲精选专辑',
      providerId: 'douyin',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late SearchRepository repo;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    api = MockSubsonicApiClient();
    repo = SearchRepository(api);
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => {
          'items': <Map<String, dynamic>>[
            {
              'source': 'douyin',
              'id': 's-1',
              'name': '陪我过个冬',
              'artist': '李嘉熹',
              'duration': 147,
            },
          ],
        });
    // buildRemoteSong 会调 getRemoteStreamUrl 拼远程流 URL,Mock 默认未 stub
    // 会抛 MissingStubError 让 FutureBuilder 走 error 分支。
    when(() => api.getRemoteStreamUrl(
          provider: any(named: 'provider'),
          source: any(named: 'source'),
          id: any(named: 'id'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
          cover: any(named: 'cover'),
        )).thenReturn('https://example.test/stream-remote?song=s-1');
  });

  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    required Widget Function() pageBuilder,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(disableAnimations: true),
              child: child!,
            );
          },
          home: Scaffold(body: pageBuilder()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'RemotePlaylistPage 窄屏 320dp:播放全部/加入库垂直堆叠,两个按钮都可见',
    (tester) async {
      await pumpAt(
        tester,
        const Size(320, 900),
        pageBuilder: () =>
            RemotePlaylistPage(playlist: _playlist(), providerId: 'douyin'),
      );

      expect(find.text('播放全部'), findsOneWidget);
      expect(find.text('加入库'), findsOneWidget);
      // 垂直堆叠:两个按钮的垂直位置不同
      final playRect = tester.getRect(find.text('播放全部'));
      final libRect = tester.getRect(find.text('加入库'));
      expect(playRect.top, lessThan(libRect.top));
      // 都在屏内,未被裁剪
      expect(libRect.right, lessThanOrEqualTo(320));
      // 没有渲染异常
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RemotePlaylistPage 宽屏 800dp:双按钮水平排列,文字都显示全',
    (tester) async {
      await pumpAt(
        tester,
        const Size(800, 600),
        pageBuilder: () =>
            RemotePlaylistPage(playlist: _playlist(), providerId: 'douyin'),
      );

      expect(find.text('播放全部'), findsOneWidget);
      expect(find.text('加入库'), findsOneWidget);
      final playRect = tester.getRect(find.text('播放全部'));
      final libRect = tester.getRect(find.text('加入库'));
      // 水平排列:垂直位置对齐
      expect(playRect.top, equals(libRect.top));
      // 播放全部在加入库左侧
      expect(playRect.right, lessThanOrEqualTo(libRect.left));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RemoteAlbumPage 窄屏 320dp:播放全部/加入库垂直堆叠',
    (tester) async {
      await pumpAt(
        tester,
        const Size(320, 900),
        pageBuilder: () =>
            RemoteAlbumPage(album: _album(), providerId: 'douyin'),
      );

      expect(find.text('播放全部'), findsOneWidget);
      expect(find.text('加入库'), findsOneWidget);
      final playRect = tester.getRect(find.text('播放全部'));
      final libRect = tester.getRect(find.text('加入库'));
      expect(playRect.top, lessThan(libRect.top));
      expect(libRect.right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );
}