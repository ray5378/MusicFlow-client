// batch41 E1 —— D-009 行为变更验证：showDeletePlaylistConfirmDialog 三态返回。
//
// 修复前：Future<bool>，外部 pop 时被 `?? false` 兜底，与「用户点取消」不可区分。
// 修复后：Future<bool?> —— true=确认删除 / false=用户主动取消 / null=外部 pop。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/playlist_manage_dialogs.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

late AppLocalizations loc;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 33));
  }
}

Future<Object?> _awaitResult<T>(Future<T> future) async {
  try {
    return await future.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    return '<pending>';
  }
}

Future<BuildContext> _open<T>(
  WidgetTester tester,
  Future<T> Function(BuildContext) action,
) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: Builder(
        builder: (BuildContext c) {
          context = c;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await _settle(tester);
  action(context);
  await _settle(tester);
  return context;
}

void main() {
  setUp(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('showDeletePlaylistConfirmDialog 三态 [D-009]', () {
    testWidgets('点删除 -> true', (WidgetTester tester) async {
      late Future<bool?> future;
      await _open<bool?>(
        tester,
        (ctx) {
          future = showDeletePlaylistConfirmDialog(
            context: ctx,
            playlistName: '我的歌单',
          );
          return future;
        },
      );

      await tester.tap(find.text(loc.common_delete));
      await _settle(tester);
      expect(await _awaitResult(future), isTrue);
    });

    testWidgets('点取消 -> false（主动放弃）', (WidgetTester tester) async {
      late Future<bool?> future;
      await _open<bool?>(
        tester,
        (ctx) {
          future = showDeletePlaylistConfirmDialog(
            context: ctx,
            playlistName: '我的歌单',
          );
          return future;
        },
      );

      await tester.tap(find.text(loc.settings_cancel));
      await _settle(tester);
      expect(await _awaitResult(future), isFalse);
    });

    testWidgets('外部 pop -> null（未选择，与主动取消可区分）',
        (WidgetTester tester) async {
      late Future<bool?> future;
      final BuildContext ctx = await _open<bool?>(
        tester,
        (c) {
          future = showDeletePlaylistConfirmDialog(
            context: c,
            playlistName: '我的歌单',
          );
          return future;
        },
      );

      // 模拟返回键/滑动关闭：直接 pop 最上层 route，不带结果。
      Navigator.of(ctx).pop();
      await _settle(tester);
      expect(
        await _awaitResult(future),
        isNull,
        reason: '[D-009] 外部关闭弹窗返回 null，调用方用 `!= true` 兜底不会误删',
      );
    });
  });
}
