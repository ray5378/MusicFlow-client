// b38c3 —— add_to_playlist_sheet.dart 剩余可达分支补测（Route C）。
//
// 两处缺口都是「重试」按钮的 onAction 闭包体（expression-bodied closure 只有被
// 真正点下去才计命中）：
//   * line 45  歌单为空且 loadFailed 时空态的 `onAction` → ref.invalidate(playlistsProvider)；
//   * line 99  歌单加载报错时错误态的 `onAction` → ref.invalidate(playlistsProvider)。
// 既有 b38c3_add_to_playlist_sheet_extra_test 只验证了这两种态「渲染出来」，没点重试。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/add_to_playlist_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

Song _song() => Song(id: 's1', title: '测试曲目', artist: '测试艺术家');

Future<AppLocalizations> _pump(
  WidgetTester tester,
  List<Override> overrides,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(520, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  late AppLocalizations loc;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: Builder(
          builder: (BuildContext hostContext) => Scaffold(
            body: AddToPlaylistSheet(hostContext: hostContext, song: _song()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return loc;
}

void main() {
  testWidgets('歌单为空且加载失败 → 点重试重新拉取（line 45）', (tester) async {
    final loc = await _pump(tester, <Override>[
      playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
      playlistsLoadFailedProvider.overrideWith((ref) => true),
    ]);

    expect(find.text(loc.widgets_retry), findsOneWidget);

    await tester.tap(find.text(loc.widgets_retry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 重试仍为空 → 空态保持，无异常。
    expect(find.text(loc.song_option_playlist_load_failed), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单加载报错 → 点重试重新拉取（line 99）', (tester) async {
    final loc = await _pump(tester, <Override>[
      playlistsProvider.overrideWith(
        (ref) => Future<List<Playlist>>.error(StateError('playlists boom')),
      ),
    ]);

    expect(find.text(loc.widgets_retry), findsOneWidget);

    await tester.tap(find.text(loc.widgets_retry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(loc.song_option_playlist_load_failed), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
