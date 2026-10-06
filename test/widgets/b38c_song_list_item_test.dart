import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

// Route C 补测：lib/widgets/song_list_item.dart（MusicFlowSongRow）
// 覆盖 albumTrack / topRank 变体在 isCurrent 时渲染 equalizer 图标的分支。
void main() {
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: child),
        ),
      );

  testWidgets('albumTrack variant shows equalizer icon when current',
      (tester) async {
    final song = Song(
      id: 's1',
      title: 'Track',
      artist: 'Artist',
      duration: 200,
      track: 3,
    );
    await tester.pumpWidget(
      wrap(
        MusicFlowSongRow(
          song: song,
          variant: MusicFlowSongRowVariant.albumTrack,
          isCurrent: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(AppIcons.equalizer), findsOneWidget);
  });

  testWidgets('topRank variant shows equalizer icon when current',
      (tester) async {
    final song = Song(
      id: 's2',
      title: 'Rank',
      artist: 'Artist',
      duration: 200,
    );
    await tester.pumpWidget(
      wrap(
        MusicFlowSongRow(
          song: song,
          variant: MusicFlowSongRowVariant.topRank,
          rank: 7,
          isCurrent: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(AppIcons.equalizer), findsOneWidget);
  });

  testWidgets('non-current topRank variant shows the rank number',
      (tester) async {
    final song = Song(
      id: 's3',
      title: 'Rank2',
      artist: 'Artist',
      duration: 200,
    );
    await tester.pumpWidget(
      wrap(
        MusicFlowSongRow(
          song: song,
          variant: MusicFlowSongRowVariant.topRank,
          rank: 12,
          isCurrent: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    expect(find.byIcon(AppIcons.equalizer), findsNothing);
  });
}
