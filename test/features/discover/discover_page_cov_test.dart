import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

void main() {
  testWidgets('首页标题、推荐频道标题与卡片高度按平台和字号解析', (tester) async {
    await _pumpSection(
      tester,
      Builder(
        builder: (context) {
          final loc = AppLocalizations.of(context);
          expect(playlistRailHeight(context), 224);
          expect(
            localChannelTitle(
              loc,
              LocalRecommendChannel(
                source: 'netease',
                name: '网易云音乐',
                count: 0,
                subtag: '每日更新',
                playlists: const <LocalRecommendPlaylist>[],
              ),
            ),
            '网易云·每日更新',
          );
          expect(
            localChannelTitle(
              loc,
              LocalRecommendChannel(
                source: 'qq',
                name: 'QQ',
                count: 0,
                playlists: const <LocalRecommendPlaylist>[],
              ),
            ),
            'QQ·平台推荐',
          );

          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          expect(resolveMusicFlowHomeTitle(loc), 'MusicFlow');
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          expect(resolveMusicFlowHomeTitle(loc), '');
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          expect(resolveMusicFlowHomeTitle(loc), loc.discover_music_flow_title);
          debugDefaultTargetPlatformOverride = null;
          return const SizedBox.shrink();
        },
      ),
      textScale: 2,
    );
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最近歌单覆盖数据、空数据失败标记与刷新分支', (tester) async {
    var loads = 0;
    await _pumpSection(
      tester,
      const RecentPlaylistsSection(),
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith((ref) async {
          loads += 1;
          return <Playlist>[_playlist('最近歌单')];
        }),
      ],
    );

    expect(find.text('最近歌单'), findsOneWidget);
    expect(find.byType(DiscoverPlaylistCard), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('刷新最近更新歌单'));
    await tester.pumpAndSettle();
    expect(loads, 2);

    await _pumpSection(
      tester,
      const RecentPlaylistsSection(),
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith((ref) async => const <Playlist>[]),
        recentPlaylistsLoadFailedProvider.overrideWith((ref) => true),
      ],
    );
    expect(find.text('歌单暂时不可用'), findsOneWidget);
    expect(find.bySemanticsLabel('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个推荐分区的空数据失败标记均渲染本地错误态', (tester) async {
    await _pumpSection(
      tester,
      const FixedRecommendSection(),
      overrides: <Override>[
        homeRecommendSectionProvider.overrideWith(
          (ref) async => const HomeRecommendSection(
            fixed: <HomeCard>[],
            random: <Playlist>[],
          ),
        ),
        homeCardsLoadFailedProvider.overrideWith((ref) => true),
      ],
    );
    expect(find.text('为你推荐暂时不可用'), findsOneWidget);

    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(providerId: '', channels: const []),
        ),
        recommendChannelsLoadFailedProvider.overrideWith((ref) => true),
      ],
    );
    expect(find.text('插件推荐暂时不可用'), findsOneWidget);

    await _pumpSection(
      tester,
      const LocalPlatformRecommendSection(),
      overrides: <Override>[
        localRecommendChannelsProvider.overrideWith(
          (ref) async => const <LocalRecommendChannel>[],
        ),
        localRecommendChannelsLoadFailedProvider.overrideWith((ref) => true),
      ],
    );
    expect(find.text('平台推荐暂时不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('四个列表分区 loading 分支各渲染四个骨架卡', (tester) async {
    await _pumpSection(
      tester,
      const RecentPlaylistsSection(),
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith(
          (ref) => Completer<List<Playlist>>().future,
        ),
      ],
      settle: false,
    );
    expect(find.byType(DiscoverPlaylistCardLoading), findsNWidgets(4));

    await _pumpSection(
      tester,
      const FixedRecommendSection(),
      overrides: <Override>[
        homeRecommendSectionProvider.overrideWith(
          (ref) => Completer<HomeRecommendSection>().future,
        ),
      ],
      settle: false,
    );
    expect(find.byType(DiscoverPlaylistCardLoading), findsNWidgets(4));

    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        recommendChannelsProvider.overrideWith(
          (ref) => Completer<RecommendResult>().future,
        ),
      ],
      settle: false,
    );
    expect(find.byType(DiscoverPlaylistCardLoading), findsNWidgets(4));

    await _pumpSection(
      tester,
      const LocalPlatformRecommendSection(),
      overrides: <Override>[
        localRecommendChannelsProvider.overrideWith(
          (ref) => Completer<List<LocalRecommendChannel>>().future,
        ),
      ],
      settle: false,
    );
    expect(find.byType(DiscoverPlaylistCardLoading), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('四个列表分区 Future 异常各渲染远端错误态', (tester) async {
    await _pumpSection(
      tester,
      const RecentPlaylistsSection(),
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith(
          (ref) => Future<List<Playlist>>.error(StateError('recent failed')),
        ),
      ],
    );
    expect(find.text('最近更新歌单加载失败'), findsOneWidget);

    await _pumpSection(
      tester,
      const FixedRecommendSection(),
      overrides: <Override>[
        homeRecommendSectionProvider.overrideWith(
          (ref) =>
              Future<HomeRecommendSection>.error(StateError('fixed failed')),
        ),
      ],
    );
    expect(find.text('为你推荐加载失败'), findsOneWidget);

    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        recommendChannelsProvider.overrideWith(
          (ref) => Future<RecommendResult>.error(StateError('plugin failed')),
        ),
      ],
    );
    expect(find.text('插件推荐加载失败'), findsOneWidget);

    await _pumpSection(
      tester,
      const LocalPlatformRecommendSection(),
      overrides: <Override>[
        localRecommendChannelsProvider.overrideWith(
          (ref) => Future<List<LocalRecommendChannel>>.error(
            StateError('local failed'),
          ),
        ),
      ],
    );
    expect(find.text('平台推荐加载失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定推荐合并固定卡和随机歌单', (tester) async {
    await _pumpSection(
      tester,
      const FixedRecommendSection(),
      overrides: <Override>[
        homeRecommendSectionProvider.overrideWith(
          (ref) async => HomeRecommendSection(
            fixed: <HomeCard>[
              HomeCard(
                playlistId: 'fixed-1',
                name: '固定卡',
                playlistName: '',
                position: 0,
                isCombo: false,
                songCount: 35,
              ),
            ],
            random: <Playlist>[_playlist('随机补位')],
          ),
        ),
      ],
    );

    expect(find.byType(DiscoverPlaylistCard), findsNWidgets(2));
    expect(find.text('固定卡'), findsOneWidget);
    expect(find.text('随机补位'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('插件推荐覆盖多频道、空曲数与导入中状态', (tester) async {
    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(
            providerId: 'netease',
            channels: <RecommendChannel>[
              RecommendChannel(
                source: 'empty',
                name: '空频道',
                count: 0,
                playlists: const <RecommendPlaylist>[],
              ),
              RecommendChannel(
                source: 'netease',
                name: '有内容频道',
                count: 2,
                playlists: <RecommendPlaylist>[
                  _recommendPlaylist('导入中歌单', trackCount: '', id: 'loading'),
                  _recommendPlaylist('可打开歌单', trackCount: '42', id: 'ready'),
                ],
              ),
            ],
          ),
        ),
        recommendImportingProvider.overrideWith((ref) => 'loading'),
      ],
      settle: false,
    );

    expect(find.text('空频道'), findsOneWidget);
    expect(find.text('有内容频道'), findsOneWidget);
    expect(find.text('导入中歌单'), findsOneWidget);
    expect(find.text('可打开歌单'), findsOneWidget);
    expect(find.byType(DiscoverPlaylistCard), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('可打开歌单'));
    await tester.pump();
    expect(find.text('未连接到音乐库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地平台推荐覆盖后缀、说明和多频道卡片', (tester) async {
    await _pumpSection(
      tester,
      const LocalPlatformRecommendSection(),
      overrides: <Override>[
        localRecommendChannelsProvider.overrideWith(
          (ref) async => <LocalRecommendChannel>[
            LocalRecommendChannel(
              source: 'netease',
              name: '网易云音乐',
              count: 1,
              subtag: '每日更新',
              tagline: '按你的曲库随机推荐',
              playlists: <LocalRecommendPlaylist>[
                LocalRecommendPlaylist(
                  id: 'local-1',
                  name: '网易本地歌单',
                  songCount: 31,
                ),
              ],
            ),
            LocalRecommendChannel(
              source: 'qq',
              name: 'QQ',
              count: 1,
              playlists: <LocalRecommendPlaylist>[
                LocalRecommendPlaylist(
                  id: 'local-2',
                  name: 'QQ 本地歌单',
                  songCount: 32,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    expect(find.text('网易云·每日更新'), findsOneWidget);
    expect(find.text('按你的曲库随机推荐'), findsOneWidget);
    expect(find.text('QQ·平台推荐'), findsOneWidget);
    expect(find.text('网易本地歌单'), findsOneWidget);
    expect(find.text('QQ 本地歌单'), findsOneWidget);
    expect(find.byType(DiscoverPlaylistCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpSection(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  bool settle = true,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1000);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          );
        },
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Playlist _playlist(String name) => Playlist(
  id: 'playlist-${name.hashCode}',
  name: name,
  songCount: 40,
  duration: 1800,
);

RecommendPlaylist _recommendPlaylist(
  String name, {
  required String trackCount,
  required String id,
}) => RecommendPlaylist(
  id: id,
  source: 'netease',
  name: name,
  creator: '官方',
  trackCount: trackCount,
  link: '',
  imported: false,
);
