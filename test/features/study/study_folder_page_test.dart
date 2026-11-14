// 学习歌单「进入文件夹」的界面语义守卫：
//   * 进入某层后**只列这一层**（直属子文件夹 + 直属歌单），孙子层的歌单/文件夹
//     不能摊在同一屏 —— 这正是改造前「点文件夹原地展开」的毛病；
//   * 文件夹行副标题是「N 个歌单 · M 个子文件夹」两段（直属口径，不递归）；
//   * 空文件夹显示空提示而不是一片空白。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/study/pages/study_folder_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

const List<StudyPlaylist> _playlists = <StudyPlaylist>[
  StudyPlaylist(id: 'p1', name: '根歌单', songCount: 3),
  StudyPlaylist(id: 'p2', name: '高数第一讲', songCount: 7, folder: '课程/高数'),
  StudyPlaylist(id: 'p3', name: '英语单词', songCount: 2, folder: '课程/英语'),
  StudyPlaylist(id: 'p4', name: '高数习题', songCount: 5, folder: '课程/高数'),
  StudyPlaylist(id: 'p5', name: '第一章', songCount: 1, folder: '课程/高数/第一章'),
];

const List<String> _folders = <String>['课程/高数', '课程/英语', '空夹'];

Future<void> _pump(WidgetTester tester, String path) async {
  final container = ProviderContainer(
    overrides: <Override>[
      studyPlaylistsProvider.overrideWith((ref) async => _playlists),
      studyPlaylistFoldersProvider.overrideWith((ref) async => _folders),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: StudyFolderPage(path: path),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('进入「课程」只列本层：子文件夹在、孙子歌单不在', (tester) async {
    await _pump(tester, '课程');

    expect(find.text('高数'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);

    // 孙子层的歌单不能出现在父层列表里（改造前的「摊平」行为）。
    expect(find.text('高数第一讲'), findsNothing);
    expect(find.text('高数习题'), findsNothing);
    expect(find.text('英语单词'), findsNothing);
    // 根目录的歌单也不该混进来。
    expect(find.text('根歌单'), findsNothing);
  });

  testWidgets('文件夹行副标题是「N 个歌单 · M 个子文件夹」且只算直属', (tester) async {
    await _pump(tester, '课程');

    // 课程/高数：直属歌曲 2 个 + 子文件夹 1 个；课程/英语：直属歌曲 1 个、无子文件夹。
    expect(find.text('2 个歌单 · 1 个子文件夹'), findsOneWidget);
    expect(find.text('1 个歌单'), findsOneWidget);
  });

  testWidgets('再进一层只列该层直属歌单与子文件夹', (tester) async {
    await _pump(tester, '课程/高数');

    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('高数第一讲'), findsOneWidget);
    expect(find.text('高数习题'), findsOneWidget);
    // 同级的「英语」在上一层，不该出现在这层。
    expect(find.text('英语'), findsNothing);
    // 第一章里只有 p5 一个歌单。
    expect(find.text('1 个歌单'), findsOneWidget);
  });

  testWidgets('空文件夹给出空提示', (tester) async {
    await _pump(tester, '空夹');

    expect(find.text('这个目录是空的'), findsOneWidget);
  });
}
