// playlist_manage_dialogs.dart 的缺口补齐测试。
//
// 这个文件有两个公开入口(showPlaylistFormDialog / showDeletePlaylistConfirmDialog),
// 弹的是 MusicFlow 自己的 bottom sheet(带进场动画 + ThemeExtension 依赖)。测试树里必须给全:
//   1. AppLocalizations —— 文案全是 loc 键;
//   2. AppTheme.light() —— musicFlowTypography / motion / spacing / radii 都是 ThemeExtension;
//   3. 两个入口都用 useRootNavigator,挂在 root Navigator 上,MaterialApp 默认 root 即可。
//
// 三个必须踩过的坑:
//   a) _open 是 async 函数,直接 `final f = await _open(...)` 拿到的是**弹窗的返回值**(T),
//      不是弹窗 Future 本身;要同时拿到 Future 又保证 pumpWidget 完成,只能
//      `late Future<T> f; await _open(t, (ctx) { f = 发起弹窗(); return f; });`。
//   b) WidgetTester 的 pumpWidget / expect / enterText 都是 guarded API,
//      没 await 前一个就调下一个会直接报 Guarded function conflict。
//   c) sheet 里带 AnimatedPadding / AnimatedContainer,pumpAndSettle 有时等不到静止,
//      统一改成有界 pump 循环(_settle);另外入口返回的 Future 只靠 Navigator.pop 完成,
//      点击一旦没命中就永远 pending,所以一律用 _awaitResult 带 2s 超时哨兵,避免用例挂死。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/playlist_manage_dialogs.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

late AppLocalizations loc;

/// 有界 settle:连 pump 24 帧(约 800ms),足够 bottom sheet 进场动画跑完。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 33));
  }
}

/// 等弹窗返回值,最多 2 秒;超时返回哨兵 '<pending>'。
Future<Object?> _awaitResult<T>(Future<T> future) async {
  try {
    return await future.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    return '<pending>';
  }
}

/// 建好「能弹 sheet」的测试树,执行 [action] 发起弹窗,并保证 pumpWidget 已完成。
///
/// 返回值刻意是 void(不是弹窗的 Future):调用方  不应该等
/// 弹窗关闭 —— 弹窗 future 只由 Navigator.pop 完成,await 它会把用例挂死。
/// 想拿返回值就用调用方自己的 holder(见各个用例的 )。
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
  // 故意不 await:发起弹窗即可,返回的是一个 pending future。
  action(context);
  await _settle(tester);
  return context;
}

Finder _nameField() => find.byType(TextField).first;

Finder _confirm(String label) => find.text(label);

void main() {
  setUp(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('PlaylistFormResult', () {
    testWidgets('三个字段原样带回来', (WidgetTester tester) async {
      const result = PlaylistFormResult(name: 'n', comment: 'c', isPublic: true);
      expect(result.name, 'n');
      expect(result.comment, 'c');
      expect(result.isPublic, isTrue);
    });
  });

  group('showPlaylistFormDialog', () {
    testWidgets('能弹出表单,含名称/备注两个输入与取消/确认按钮',
        (WidgetTester tester) async {
      late Future<PlaylistFormResult?> future;
      await _open<PlaylistFormResult?>(
        tester,
        (ctx) {
          future = showPlaylistFormDialog(
            context: ctx,
            title: '新建歌单',
            confirmText: '创建',
          );
          return future;
        },
      );

      print('DBG opened');
      expect(find.text('新建歌单'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2), reason: '名称 + 备注');
      expect(_confirm(loc.settings_cancel), findsOneWidget);
      expect(_confirm('创建'), findsOneWidget);

      final cancel = _confirm(loc.settings_cancel);
      expect(cancel, findsOneWidget);
      print('DBG expects done');
      await tester.tap(cancel);
      print('DBG tapped');
      await _settle(tester);
      print('DBG settled');
      expect(find.byType(TextField), findsNothing, reason: '取消后 sheet 应当关掉');
      expect(await _awaitResult(future), isNull);
    });

    testWidgets('名称留空点确认 -> 校验拦截,不返回结果', (WidgetTester tester) async {
      late Future<PlaylistFormResult?> future;
      await _open<PlaylistFormResult?>(
        tester,
        (ctx) {
          future = showPlaylistFormDialog(
            context: ctx,
            title: '新建歌单',
            confirmText: '创建',
          );
          return future;
        },
      );

      await tester.enterText(_nameField(), '   ');
      await tester.tap(_confirm('创建'));
      await _settle(tester);

      expect(
        find.text(loc.library_playlist_name_required),
        findsOneWidget,
        reason: '名称为空应当把必填错误顶出来',
      );
      await tester.tap(_confirm(loc.settings_cancel));
      await _settle(tester);
      expect(await _awaitResult(future), isNull);
    });

    testWidgets('填名称与备注 -> 返回 trim 后的结果,默认不公开',
        (WidgetTester tester) async {
      late Future<PlaylistFormResult?> future;
      await _open<PlaylistFormResult?>(
        tester,
        (ctx) {
          future = showPlaylistFormDialog(
            context: ctx,
            title: '新建歌单',
            confirmText: '创建',
          );
          return future;
        },
      );

      await tester.enterText(_nameField(), '  我的歌单  ');
      await tester.enterText(find.byType(TextField).last, ' 备注 ');
      await tester.tap(_confirm('创建'));
      await _settle(tester);

      final result = (await _awaitResult(future)) as PlaylistFormResult?;
      expect(result, isNotNull);
      expect(result!.name, '我的歌单', reason: '名称/备注都要 trim');
      expect(result.comment, '备注');
      expect(result.isPublic, isFalse);
    });

    testWidgets('初值回顾:名称/备注预填,没动开关就还是 false',
        (WidgetTester tester) async {
      late Future<PlaylistFormResult?> future;
      await _open<PlaylistFormResult?>(
        tester,
        (ctx) {
          future = showPlaylistFormDialog(
            context: ctx,
            title: '编辑歌单',
            confirmText: '保存',
            initialName: '旧名字',
            initialComment: '旧备注',
          );
          return future;
        },
      );

      final nameField = tester.widget<TextField>(find.byType(TextField).first);
      expect(nameField.controller!.text, '旧名字');
      expect(find.text('旧备注'), findsOneWidget, reason: '备注初值应回显');

      await tester.tap(_confirm('保存'));
      await _settle(tester);

      final result = (await _awaitResult(future)) as PlaylistFormResult?;
      expect(result, isNotNull);
      expect(result!.name, '旧名字');
      expect(result.comment, '旧备注');
      expect(result.isPublic, isFalse);
    });

    testWidgets('公开开关点一下 -> 结果里 isPublic 翻转成 true',
        (WidgetTester tester) async {
      late Future<PlaylistFormResult?> future;
      await _open<PlaylistFormResult?>(
        tester,
        (ctx) {
          future = showPlaylistFormDialog(
            context: ctx,
            title: '新建歌单',
            confirmText: '创建',
          );
          return future;
        },
      );

      // 开关是 _MusicFlowToggleRow(包了一层 MusicFlowPressable)
      final toggle = find.ancestor(
        of: find.text(loc.library_playlist_private_desc),
        matching: find.byType(MusicFlowPressable),
      );
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await _settle(tester);
      expect(find.text(loc.library_playlist_public_desc), findsOneWidget);

      await tester.enterText(_nameField(), '公开歌单');
      await tester.tap(_confirm('创建'));
      await _settle(tester);

      final result = (await _awaitResult(future)) as PlaylistFormResult?;
      expect(result, isNotNull);
      expect(result!.isPublic, isTrue);
    });
  });

  group('showDeletePlaylistConfirmDialog', () {
    testWidgets('确认文案带上歌单名,取消 -> false', (WidgetTester tester) async {
      late Future<bool> future;
      await _open<bool>(
        tester,
        (ctx) {
          future = showDeletePlaylistConfirmDialog(
            context: ctx,
            playlistName: '我的歌单',
          );
          return future;
        },
      );

      expect(
        find.text(loc.library_delete_playlist_confirm('我的歌单')),
        findsOneWidget,
      );

      await tester.tap(_confirm(loc.settings_cancel));
      await _settle(tester);
      expect(await _awaitResult(future), false);
    });

    testWidgets('点删除 -> true', (WidgetTester tester) async {
      late Future<bool> future;
      await _open<bool>(
        tester,
        (ctx) {
          future = showDeletePlaylistConfirmDialog(
            context: ctx,
            playlistName: '我的歌单',
          );
          return future;
        },
      );

      await tester.tap(_confirm(loc.common_delete));
      await _settle(tester);
      expect(await _awaitResult(future), true);
    });

    // [D-009] 弹窗被外部 pop 掉(返回键/滑动关闭)时,showDeletePlaylistConfirmDialog
    // 把确认结果兜底成 false —— 这里记录:没点按钮也算「没删」。
    testWidgets('弹窗被直接 pop 掉 -> 兜底为 false(不会误删)',
        (WidgetTester tester) async {
      late Future<bool> future;
      final BuildContext ctx = await _open<bool>(
        tester,
        (ctx) {
          future = showDeletePlaylistConfirmDialog(
            context: ctx,
            playlistName: '我的歌单',
          );
          return future;
        },
      );

      // 模拟「外部把弹窗关掉」(返回键/滑动关闭):pageBack() 需要树上有
      // CupertinoNavigationBarBackButton,这里直接 pop 最上层 route 等效。
      Navigator.of(ctx).pop();
      await _settle(tester);
      expect(
        await _awaitResult(future),
        false,
        reason: '空返回值被 ?? false 兜住',
      );
    });
  });
}
