// b38c3 —— Route C 补测：features/player/widgets/add_to_playlist_sheet.dart 剩余缺口。
//   * 45：空歌单 + loadFailed → MusicFlowEmptyState 的重试 action 调 ref.invalidate(playlistsProvider)。
//   * 99：playlistsProvider 处于 error → MusicFlowErrorState 的重试 action 同样调 ref.invalidate。
//
// 手法：playlistsProvider 用带计数器的 override 便于观测 invalidate 触发的重新计算；
// playlistsLoadFailedProvider（StateProvider<bool>）直接 override 成 true。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/add_to_playlist_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

late AppLocalizations loc;

Widget _wrap({
  required Widget Function(BuildContext host) buildSheet,
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: Builder(
        builder: (context) => Scaffold(body: buildSheet(context)),
      ),
    ),
  );
}

void main() {
  testWidgets('空歌单 + loadFailed：重试 action → invalidate(playlistsProvider)（45）',
      (tester) async {
    var builds = 0;
    await tester.pumpWidget(_wrap(
      overrides: <Override>[
        playlistsProvider.overrideWith((ref) async {
          builds++;
          return <Playlist>[];
        }),
        playlistsLoadFailedProvider.overrideWith((ref) => true),
      ],
      buildSheet: (host) => AddToPlaylistSheet(
        hostContext: host,
        song: Song(id: 's1', title: '晨光曲'),
      ),
    ));
    await tester.pump();
    await tester.pump();

    final before = builds;
    expect(find.text(loc.widgets_retry), findsOneWidget,
        reason: 'loadFailed 时空态应带重试按钮');

    await tester.tap(find.text(loc.widgets_retry));
    await tester.pump();
    await tester.pump();

    expect(builds, greaterThan(before),
        reason: '点击重试 → ref.invalidate(playlistsProvider) 触发重算');
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider error：重试 action → invalidate(playlistsProvider)（99）',
      (tester) async {
    var builds = 0;
    await tester.pumpWidget(_wrap(
      overrides: <Override>[
        playlistsProvider.overrideWith((ref) async {
          builds++;
          throw StateError('b38c3 模拟歌单加载失败');
        }),
        playlistsLoadFailedProvider.overrideWith((ref) => false),
      ],
      buildSheet: (host) => AddToPlaylistSheet(
        hostContext: host,
        song: Song(id: 's2', title: '晚风曲'),
      ),
    ));
    await tester.pump();
    await tester.pump();

    final before = builds;
    expect(find.text(loc.widgets_retry), findsOneWidget,
        reason: 'error 态应渲染带重试的 ErrorState');

    await tester.tap(find.text(loc.widgets_retry));
    await tester.pump();
    await tester.pump();

    expect(builds, greaterThan(before));
    expect(tester.takeException(), isNull);
  });
}
