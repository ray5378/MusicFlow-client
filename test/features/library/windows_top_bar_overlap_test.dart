import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_scaffold.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/edit_library_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/providers/music_provider.dart';
import 'package:musicflow_client/providers/playlist_provider.dart';

import '../../helpers/windows_overlap.dart';

void main() {
  const double viewportWidth = 1200;

  Widget app({
    required Widget home,
    List<Override> overrides = const <Override>[],
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: AppTheme.dark(), home: home),
    );
  }

  /// 断言页面确实渲染了带操作按钮的顶栏——否则重叠检测就是空转。
  void expectTopBarWithActions(WidgetTester tester) {
    expect(find.byType(MusicFlowTopBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MusicFlowTopBar),
        matching: find.byType(MusicFlowIconButton),
      ),
      findsWidgets,
      reason: '顶栏必须存在操作按钮，否则本组测试无法验证避让效果。',
    );
  }

  group('library pages keep top-bar actions clear of Windows window controls', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('AlbumDetailPage', (tester) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        app(
          overrides: <Override>[
            albumDetailProvider('album-1').overrideWith((ref) async => null),
          ],
          home: const AlbumDetailPage(albumId: 'album-1'),
        ),
      );
      await tester.pump();

      expectTopBarWithActions(tester);
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('ArtistDetailPage', (tester) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        app(
          overrides: <Override>[
            artistDetailProvider('artist-1').overrideWith((ref) async => null),
          ],
          home: const ArtistDetailPage(artistId: 'artist-1'),
        ),
      );
      await tester.pump();

      expectTopBarWithActions(tester);
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('PlaylistDetailPage', (tester) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        app(
          overrides: <Override>[
            playlistDetailProvider('playlist-1').overrideWith(
              (ref) async => null,
            ),
          ],
          home: const PlaylistDetailPage(playlistId: 'playlist-1'),
        ),
      );
      await tester.pump();

      expectTopBarWithActions(tester);
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('SongListPage', (tester) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(app(home: const SongListPage()));
      await tester.pump();

      expectTopBarWithActions(tester);
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('EditLibraryPage', (tester) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        app(home: const EditLibraryPage(libraryId: 'library-1')),
      );
      await tester.pump();

      expectTopBarWithActions(tester);
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
