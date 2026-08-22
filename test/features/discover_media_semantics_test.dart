import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final song = Song(
    id: 'song-1',
    title: '晨光',
    artist: '示例歌手',
    album: '清晨',
    duration: 204,
  );

  Widget app(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(child: SizedBox(width: 360, child: child)),
        ),
      ),
    );
  }

  testWidgets('Discover song keeps its more action as a separate node', (
    tester,
  ) async {
    var rowPresses = 0;
    var actionPresses = 0;

    await tester.pumpWidget(
      app(
        DiscoverSongTile(
          song: song,
          onPressed: () => rowPresses++,
          onOpenActions: () => actionPresses++,
        ),
      ),
    );

    expect(find.bySemanticsLabel('晨光，示例歌手，03:24'), findsOneWidget);
    expect(find.bySemanticsLabel('晨光 操作'), findsOneWidget);
    expect(find.bySemanticsLabel('晨光 封面'), findsNothing);
    expect(find.bySemanticsLabel('晨光'), findsNothing);

    await tester.tap(find.bySemanticsLabel('晨光 操作'));
    expect(actionPresses, 1);
    expect(rowPresses, 0);
  });

}
