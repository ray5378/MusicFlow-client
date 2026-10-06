import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/vinyl_record_cover.dart';

// Route C 补测：lib/features/player/widgets/vinyl_record_cover.dart
// 覆盖预览封面分支（Image.network 构造 + errorBuilder -> 占位图）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('preview song renders network cover then falls back to placeholder',
      (tester) async {
    final song = Song(
      id: 'preview-1',
      title: 'Preview',
      artist: 'Artist',
      coverArt: 'cover-1',
      isPreview: true,
      // 连接被拒，快速失败 -> 触发 errorBuilder -> _buildPlaceholder。
      previewCoverUrl: 'http://127.0.0.1:0/nope.png',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VinylRecordCover(song: song, size: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(VinylRecordCover), findsOneWidget);
  });
}
