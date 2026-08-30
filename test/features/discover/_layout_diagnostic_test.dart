import 'package:dio/dio.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/music_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:musicflow_client/providers/playlist_provider.dart';
import 'package:musicflow_client/providers/recommend_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/test_player_notifier.dart';

// 临时诊断测试：输出首页各按钮/图标的真实渲染矩形，用于排查布局问题。
void main() {
  testWidgets('DIAGNOSTIC dump home header positions', (tester) async {
    await _pumpDiscover(tester, const Size(390, 1400));

    final randTitle = tester.getRect(find.text('随机歌曲'));
    final recentTitle = tester.getRect(find.text('最近更新的歌单'));

    Rect iconRect(String label) => tester.getRect(
          find.descendant(
            of: find.bySemanticsLabel(label),
            matching: find.byType(Icon),
          ),
        );
    Rect buttonRect(String label) =>
        tester.getRect(find.bySemanticsLabel(label));

    final randRefreshIcon = iconRect('换一批随机歌曲');
    final playIcon = iconRect('播放随机歌曲');
    final recentRefreshIcon = iconRect('刷新最近更新歌单');
    final playBtn = buttonRect('播放随机歌曲');

    // Row / Align / Expanded 探针。
    final headers = find.byType(MusicFlowSectionHeader);
    // ignore: avoid_print
    print('MusicFlowSectionHeader count: ${headers.evaluate().length}');
    for (var i = 0; i < headers.evaluate().length; i++) {
      final rect = tester.getRect(headers.at(i));
      // ignore: avoid_print
      print('header#$i: $rect');
    }
    final rows = find.descendant(
      of: find.byType(MusicFlowSectionHeader),
      matching: find.byType(Row),
    );
    // ignore: avoid_print
    print('header Row count: ${rows.evaluate().length}');
    for (var i = 0; i < rows.evaluate().length; i++) {
      final w = tester.widget<Row>(rows.at(i));
      // ignore: avoid_print
      print(
        'headerRow#$i: ${tester.getRect(rows.at(i))} mainAxisSize=${w.mainAxisSize} children=${w.children.length}',
      );
      for (final c in w.children) {
        // ignore: avoid_print
        print('  child: ${c.runtimeType}'
            '${c is Flexible ? ' fit=${c.fit} flex=${c.flex}' : ''}');
      }
    }
    final aligns = find.descendant(
      of: find.byType(MusicFlowSectionHeader),
      matching: find.byType(Align),
    );
    for (var i = 0; i < aligns.evaluate().length; i++) {
      // ignore: avoid_print
      print('headerAlign#$i: ${tester.getRect(aligns.at(i))}');
    }
    final spacers = find.byType(Spacer);
    // ignore: avoid_print
    print('Spacer count: ${spacers.evaluate().length}');
    for (var i = 0; i < spacers.evaluate().length; i++) {
      // ignore: avoid_print
      print('spacer#$i: ${tester.getRect(spacers.at(i))}');
    }
    final shifts = find.byType(_SectionShiftPublic);
    // ignore: avoid_print
    print('_SectionShift count: ${shifts.evaluate().length}');

    // 随机歌曲区块最外层 Padding（key: discover-random-mix）。
    final mixRect = tester.getRect(find.byKey(const Key('discover-random-mix')));
    // ignore: avoid_print
    print('random-mix section: $mixRect');

    // ignore: avoid_print
    print('=== DIAGNOSTIC (screen 390) ===');
    // ignore: avoid_print
    print('随机歌曲 title: $randTitle');
    // ignore: avoid_print
    print('随机歌曲 refresh icon: $randRefreshIcon');
    // ignore: avoid_print
    print(
      '随机歌曲 refresh icon.left - title.right = ${randRefreshIcon.left - randTitle.right}',
    );
    // ignore: avoid_print
    print('play icon: $playIcon');
    // ignore: avoid_print
    print('play icon: screen(390) - right = ${390 - playIcon.right}');
    // ignore: avoid_print
    print('play btn box: $playBtn, screen - box.right = ${390 - playBtn.right}');
    // ignore: avoid_print
    print('最近更新的歌单 title: $recentTitle');
    // ignore: avoid_print
    print('recent refresh icon: $recentRefreshIcon');
    // ignore: avoid_print
    print(
      'recent refresh icon.left - title.right = ${recentRefreshIcon.left - recentTitle.right}',
    );
    expect(tester.takeException(), isNull);
  });
}

class _SectionShiftPublic {
  const _SectionShiftPublic();
}

Future<void> _pumpDiscover(
  WidgetTester tester,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final connectivity = ConnectivityMonitor(AddressPool(Dio()));
  addTearDown(connectivity.stop);
  final overrides = <Override>[
    connectivityMonitorProvider.overrideWithValue(connectivity),
    ensureActiveAddressProvider.overrideWith(
      (ref) async => ServerAddress(
        id: 'server-1',
        libraryId: 'library-1',
        label: 'Test server',
        url: 'https://example.test',
        priority: 0,
      ),
    ),
    playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
    homeSectionsProvider.overrideWith((ref) async => const <HomeSection>[]),
    randomSongsProvider.overrideWith((ref) async => _songs()),
    playlistsProvider.overrideWith(
      (ref) async => <Playlist>[_playlist()],
    ),
    recentPlaylistsProvider.overrideWith(
      (ref) async => <Playlist>[_playlist(), _playlist('第二歌单')],
    ),
    homeCardsProvider.overrideWith((ref) async => <HomeCard>[
          HomeCard(
            playlistId: 'pl-card',
            name: '每日推荐',
            playlistName: '每日推荐',
            position: 0,
            isCombo: false,
            songCount: 12,
          ),
        ]),
    recommendChannelsProvider.overrideWith(
      (ref) async => RecommendResult(
        providerId: 'netease',
        channels: [
          RecommendChannel(
            source: 'netease',
            name: '网易云音乐',
            count: 1,
            playlists: [
              RecommendPlaylist(
                id: 'r-1',
                source: 'netease',
                name: '平台推荐歌单',
                creator: '官方',
                trackCount: '30',
                link: '',
                imported: false,
              ),
            ],
          ),
        ],
      ),
    ),
    recommendProviderIdProvider.overrideWithValue(AsyncValue.data('netease')),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: const DiscoverPage(),
      ),
    ),
  );
  await tester.pump();
  notifyRandomSongsChanged();
  await tester.pumpAndSettle();
}

Playlist _playlist([String name = '默认歌单']) => Playlist(
      id: 'pl-' + name.hashCode.toString(),
      name: name,
      songCount: 8,
      duration: 1800,
    );

List<Song> _songs({String titlePrefix = '歌曲', int count = 8}) {
  return List<Song>.generate(
    count,
    (index) => Song(
      id: 'song-$index',
      title: '$titlePrefix ${index + 1}',
      artist: '歌手 ${index + 1}',
      duration: 180 + index,
    ),
  );
}
