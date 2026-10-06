// batch37 C(2) —— `lib/features/library/pages/starred_page.dart` 剩余分支。
//
// 既有 starred_page_cov / b36b / b32c 已覆盖空态/数据态/错误态/下拉刷新/行点击长按。
// 本文件补：
//   * 歌单卡片带 coverArt → 渲染 CoverArtImage（634-651 的 coverArt 分支）；
//   * 「专辑」tab 大字号（≥1.6）→ 走纵向列表分支（327-348）；
//   * 四个 tab 之间切换 strip 不抛（_StarredTabStrip 监听 + 选中态）。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

import '../../player/test_player_notifier.dart';

/// 有界推帧：封面占位骨架是无限动画，不能用 pumpAndSettle。
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

StarredResult _filled() => StarredResult(
      artists: <Artist>[Artist(id: 'artist-1', name: '收藏歌手', albumCount: 3)],
      albums: <Album>[
        Album(id: 'album-1', name: '收藏专辑', artist: '收藏歌手', songCount: 1, duration: 200),
      ],
      songs: <Song>[
        Song(id: 'song-1', title: '收藏歌曲', artist: '收藏歌手', duration: 200),
      ],
    );

Playlist _playlist({String? coverArt}) => Playlist(
      id: 'playlist-1',
      name: '收藏歌单',
      songCount: 8,
      duration: 1600,
      favorite: true,
      coverArt: coverArt,
    );

Future<void> _pump(
  WidgetTester tester, {
  StarredTab initialTab = StarredTab.playlists,
  required List<Override> overrides,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true, textScaler: textScaler),
            child: child!,
          );
        },
        home: StarredPage(initialTab: initialTab),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('歌单卡片带封面 → 渲染 CoverArtImage', (tester) async {
    await _pump(
      tester,
      overrides: <Override>[
        starredProvider.overrideWith((ref) async => _filled()),
        favoritePlaylistsProvider
            .overrideWith((ref) async => <Playlist>[_playlist(coverArt: 'pl-cover-1')]),
      ],
    );
    await tester.pump();

    expect(find.byType(CoverArtImage), findsWidgets);
    expect(find.text('收藏歌单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单卡片无封面 → 走占位图标分支', (tester) async {
    await _pump(
      tester,
      overrides: <Override>[
        starredProvider.overrideWith((ref) async => _filled()),
        favoritePlaylistsProvider
            .overrideWith((ref) async => <Playlist>[_playlist()]),
      ],
    );
    await tester.pump();

    expect(find.text('收藏歌单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('专辑 tab 大字号 → 走纵向列表分支', (tester) async {
    await _pump(
      tester,
      initialTab: StarredTab.albums,
      textScaler: const TextScaler.linear(1.8),
      overrides: <Override>[
        starredProvider.overrideWith((ref) async => _filled()),
        favoritePlaylistsProvider.overrideWith((ref) async => const <Playlist>[]),
      ],
    );
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('starred-albums-list-scroll')),
      findsOneWidget,
      reason: '大字号走列表布局',
    );
    expect(find.text('收藏专辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('四个 tab 切换不抛', (tester) async {
    await _pump(
      tester,
      overrides: <Override>[
        starredProvider.overrideWith((ref) async => _filled()),
        favoritePlaylistsProvider
            .overrideWith((ref) async => <Playlist>[_playlist(coverArt: 'c')]),
      ],
    );
    // 实际文案（l10n）：playlists=歌单 / songs=歌曲 / albums=专辑 / artists=歌手
    for (final label in <String>['歌单', '歌曲', '专辑', '歌手']) {
      await tester.tap(find.text(label));
      await settle(tester, frames: 4);
    }
    expect(tester.takeException(), isNull);
  });
}
