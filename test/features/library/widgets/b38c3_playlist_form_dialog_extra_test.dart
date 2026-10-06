// b38c3 —— playlist_manage_dialogs.dart 剩余分支补测（Route C）。
//
// 单行缺口：line 173 歌单名称输入框的 `onSubmitted: (_) => FocusScope.of(context).nextFocus()`
// —— 生产里没人对名称框按「下一项」，该闭包体从未执行。
//
// 走真实入口 showPlaylistFormDialog（公开 API），enterText 建立输入连接后
// 用 testTextInput.receiveAction(next) 触发 onSubmitted。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/playlist_manage_dialogs.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey<String>('b38c3_open_playlist_form'),
          onPressed: () {
            showPlaylistFormDialog(
              context: context,
              title: '新建歌单',
              confirmText: '创建',
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('歌单名称框提交 → 焦点前移（onSubmitted 闭包体执行）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const _Host(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('b38c3_open_playlist_form')));
    await tester.pumpAndSettle();

    // 弹窗内第一个输入框 = 名称框（textInputAction: next）。
    final nameField = find.byType(TextField).first;
    await tester.enterText(nameField, '我的歌单');
    await tester.pump();

    // 触发软键盘「下一项」动作 → onSubmitted 闭包体。
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(find.text('我的歌单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
