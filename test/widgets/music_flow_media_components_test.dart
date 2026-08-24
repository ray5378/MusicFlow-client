import 'dart:ui' show Tristate;

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/widgets/music_flow_artwork.dart';
import 'package:musicflow_client/widgets/music_flow_media_actions.dart';
import 'package:musicflow_client/widgets/music_flow_metadata_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('artwork owns shape, Hero tag, and accessible cover label', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Row(
              children: <Widget>[
                MusicFlowArtwork(
                  coverArtId: null,
                  semanticLabel: '星海专辑封面',
                  size: 64,
                  heroTag: 'album-starlight',
                ),
                MusicFlowArtwork(
                  coverArtId: null,
                  semanticLabel: '演奏者头像',
                  size: 64,
                  shape: MusicFlowArtworkShape.circle,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Hero), findsOneWidget);
    expect(find.byType(ClipRRect), findsOneWidget);
    expect(find.byType(ClipOval), findsOneWidget);
    expect(find.bySemanticsLabel('星海专辑封面'), findsOneWidget);
    expect(find.bySemanticsLabel('演奏者头像'), findsOneWidget);
  });

  testWidgets('circular artwork requires an explicit square size', (
    tester,
  ) async {
    expect(
      () => MusicFlowArtwork(
        coverArtId: null,
        semanticLabel: '演奏者头像',
        shape: MusicFlowArtworkShape.circle,
      ),
      throwsAssertionError,
    );
  });

  testWidgets('metadata filters blanks and wraps at 200 percent text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 150,
              child: MusicFlowMetadataLine(
                items: <String?>['A very long artist name', '  ', '03:27'],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('A very long artist name · 03:27'), findsOneWidget);
    expect(
      find.bySemanticsLabel('A very long artist name，03:27'),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byType(MusicFlowMetadataLine)).height,
      greaterThan(32),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('media actions keep primary hierarchy without narrow overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var playCount = 0;
    var shuffleCount = 0;
    var favoriteCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MusicFlowMediaActions(
                onPlay: () => playCount += 1,
                onShuffle: () => shuffleCount += 1,
                secondaryActions: <MusicFlowMediaAction>[
                  MusicFlowMediaAction(
                    icon: AppIcons.heartOutline,
                    label: '收藏',
                    onPressed: () => favoriteCount += 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(MusicFlowButton), findsNWidgets(2));
    expect(find.byType(MusicFlowIconButton), findsOneWidget);
    expect(find.bySemanticsLabel('播放'), findsOneWidget);
    expect(find.bySemanticsLabel('随机播放'), findsOneWidget);
    expect(find.bySemanticsLabel('收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel('播放'));
    await tester.tap(find.bySemanticsLabel('随机播放'));
    await tester.tap(find.bySemanticsLabel('收藏'));
    expect((playCount, shuffleCount, favoriteCount), (1, 1, 1));
  });

  testWidgets('shuffle can remain visible while disabled', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: MusicFlowMediaActions(
            onPlay: null,
            onShuffle: null,
            showShuffle: true,
          ),
        ),
      ),
    );

    expect(find.byType(MusicFlowButton), findsNWidgets(2));
    final shuffleSemantics = tester
        .getSemantics(find.bySemanticsLabel('随机播放'))
        .getSemanticsData();
    expect(shuffleSemantics.flagsCollection.isEnabled, Tristate.isFalse);
  });
}
