import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/player/widgets/song_options_sheet.dart';
import 'package:musicflow_client/providers/library_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'test_player_notifier.dart';

class _MockLibraryRepository extends Mock implements LibraryRepository {}

void main() {
  late LibraryRepository libraryRepository;

  setUp(() {
    libraryRepository = _MockLibraryRepository();
    when(
      () => libraryRepository.watchLibraries(),
    ).thenAnswer((_) => Stream.value(const <MusicLibrary>[]));
  });

  final song = Song(
    id: 'song',
    title: 'A long song title used by the action sheet',
    artist: 'Artist name',
    album: 'Album name',
  );

  testWidgets('full mode exposes the established business actions', (
    tester,
  ) async {
    final notifier = TestPlayerNotifier(
      PlayerState(currentSong: song, queue: <Song>[song]),
    );
    late BuildContext hostContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(libraryRepository),
          playerProvider.overrideWith((ref) => notifier),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                hostContext = context;
                return TextButton(
                  onPressed: () =>
                      showSongOptionsSheet(context: context, song: song),
                  child: const Text('打开操作'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开操作'));
    await tester.pumpAndSettle();

    expect(find.text('红心'), findsOneWidget);
    expect(find.text('添加到歌单'), findsOneWidget);
    expect(find.text('歌手：Artist name'), findsOneWidget);
    expect(find.text('专辑：Album name'), findsOneWidget);
    expect(hostContext.mounted, isTrue);
  });

  testWidgets(
    'preview mode keeps queue actions but hides library-only actions',
    (tester) async {
      final currentSong = Song(id: 'current', title: 'Current song');
      final previewSong = Song(
        id: 'gd_netease_preview',
        title: 'Preview song',
        artist: 'Remote artist',
        album: 'Remote album',
        isPreview: true,
        previewSource: 'netease',
        previewTrackId: 'preview',
        previewCoverUrl: 'https://images.example.test/preview.jpg',
      );
      final notifier = TestPlayerNotifier(
        PlayerState(currentSong: currentSong, queue: <Song>[currentSong]),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(libraryRepository),
            playerProvider.overrideWith((ref) => notifier),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showSongOptionsSheet(context: context, song: previewSong),
                  child: const Text('打开试听操作'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开试听操作'));
      await tester.pumpAndSettle();

      expect(find.text('试听歌曲操作'), findsOneWidget);
      expect(find.text('下一曲播放'), findsOneWidget);
      expect(find.text('红心'), findsNothing);
      expect(find.text('添加到歌单'), findsNothing);
      expect(find.text('下载'), findsNothing);

      await tester.tap(find.text('下一曲播放'));
      await tester.pumpAndSettle();

      expect(notifier.state.queue, <Song>[currentSong, previewSong]);
    },
  );
}
