import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/providers/effective_playback_provider.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

void main() {
  // 回归(v3.4.61):DiscoverPlaylistCard 的封面右下角既叠加
  // NowPlayingCoverOverlay(竖条组)又叠加 _PlaylistCoverPlayButton(播放按钮),
  // 两者都锚定右下角。点击「正在播放的歌单」卡片时,半透明播放按钮不应显示,
  // 否则与跳动竖条完全重叠。
  group('DiscoverPlaylistCard cover overlays:', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      required bool isNowPlaying,
      VoidCallback? onPlay,
    }) async {
      // 强制 390 宽 compact 屏:
      // _PlaylistCoverPlayButton 在 compact 常驻显示,在 medium/expanded 仅
      // hover 才显。默认测试表面是 800×600(medium) 导致按钮被收起,无法验。
      await tester.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // v3.4.66:NowPlayingCoverOverlay 的跳动竖条改为播放状态门控
      // (ConsumerStatefulWidget),测试须包 ProviderScope 并 override 播放状态,
      // 绕开真实 dlna/player provider 链条;isNowPlaying 正好映射门控语义。
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            effectiveIsPlayingProvider.overrideWith((ref) => isNowPlaying),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: DiscoverPlaylistCard(
                  title: '正在播放的歌单',
                  // 不指定 coverArtId/coverUrl → 占位图标分支,不触发网络封面,
                  // 让 widget 测试独立于 CoverArtImage 的副作用。
                  onPressed: () {},
                  onPlay: onPlay,
                  isNowPlaying: isNowPlaying,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'shows cover play button when not currently playing',
      (tester) async {
        await pumpCard(tester, isNowPlaying: false, onPlay: () {});

        // 卡片整体的 Semantics(container: false)把内层按钮的语义合并上来,
        // 所以不能直接 find.bySemanticsLabel('播放歌单')。改用 IconButton
        // 实体类型来定位 _PlaylistCoverPlayButton 内嵌的按钮。
        expect(find.byType(MusicFlowIconButton), findsOneWidget);
        expect(find.byType(NowPlayingCoverOverlay), findsNothing);
      },
    );

    testWidgets(
      'hides cover play button when card is currently playing '
      '(no overlap with jumping bars)',
      (tester) async {
        await pumpCard(tester, isNowPlaying: true, onPlay: () {});

        // NowPlayingCoverOverlay 必须渲染(代表正在播放)。
        expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
        // 重叠 bug 的修复点:isNowPlaying=true 时不应再渲染播放按钮。
        expect(
          find.byType(MusicFlowIconButton),
          findsNothing,
          reason: '正在播放的歌单卡片不应再显示右下角播放按钮,'
              '避免与 NowPlayingCoverOverlay(右下角跳动竖条)重叠',
        );
      },
    );

    testWidgets(
      'omits play button entirely when onPlay is null in either state',
      (tester) async {
        await pumpCard(tester, isNowPlaying: false, onPlay: null);
        expect(find.byType(MusicFlowIconButton), findsNothing);

        await pumpCard(tester, isNowPlaying: true, onPlay: null);
        expect(find.byType(MusicFlowIconButton), findsNothing);
        // onPlay=null 仍可能显示播放指示器(由上游决定是否传 isNowPlaying)。
        // 这里 isNowPlaying=true → 仍显示竖条组。
        expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
      },
    );
  });
}
