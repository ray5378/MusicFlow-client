// batch35 C 路 —— `lib/features/library/widgets/address_dialog.dart` 补测。
//
// 覆盖点：
//   * 新增/编辑模式标题与表单渲染；
//   * label 为空 / url 为空 / url 非法 → 校验错误文案；
//   * 合法 https 保存 → pop 出 ServerAddress（label trim、默认 priority 10）；
//   * 取消按钮 → pop null；
//   * http（非加密）新增保存 → 二次确认 sheet：仍要保存 → pop 地址；取消 → 不关；
//   * 编辑模式且 url 未变 → 免确认直接保存（保留原 id/priority）；
//   * http 警告图标 → 弹 http 提示 sheet → 「知道了」关闭；
//   * url 输入框键盘提交触发保存。
//
// 踩坑记录：
// #D1 AddressDialog 是公开 widget，入口按生产姿势走 showMusicFlowBottomSheet
//     （Future 只在 sheet pop 时完成，用 unawaited 发起 + Completer 收结果）。
// #D2 确认/提示 sheet 用 useRootNavigator: true，都在根导航器；pump 推进场动画。
// #D3 MusicFlowTextField 内部是普通 TextField，按树中顺序 label 在前 url 在后。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/features/library/widgets/address_dialog.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

late AppLocalizations loc;

class _ResultProbe {
  ServerAddress? saved;
  bool closed = false;
  final Completer<ServerAddress?> completer = Completer<ServerAddress?>();

  void listen(Future<ServerAddress?> future) {
    unawaited(
      future.then((value) {
        saved = value;
        closed = true;
      }),
    );
  }
}

Future<void> openDialog(
  WidgetTester tester, {
  required String libraryId,
  ServerAddress? initialAddress,
}) async {
  final probe = _ResultProbe();
  probe.listen(
    showMusicFlowBottomSheet<ServerAddress>(
      context: tester.element(find.byKey(const ValueKey<String>('host'))),
      builder: (_) => AddressDialog(
        libraryId: libraryId,
        initialAddress: initialAddress,
      ),
    ),
  );
  // 全局 probe 不好直接传出去：挂到 root 的 Element 上再取。
  // 简化：直接用 tester 拿 dialog future —— 通过 host element 发起后，
  // future 在 probe 里；把 probe 存在静态变量里。
  lastProbe = probe;
  await settle(tester);
}

// ignore: library_private_types_in_public_api
late _ResultProbe lastProbe;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpHost(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(520, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: const Scaffold(
        key: ValueKey<String>('host'),
        body: SizedBox.expand(),
      ),
    ),
  );
  await settle(tester, frames: 2);
}

Future<void> enterLabel(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await settle(tester, frames: 2);
}

Future<void> enterUrl(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await settle(tester, frames: 2);
}

Future<void> tapSave(WidgetTester tester) async {
  await tester.tap(find.text(loc.library_save_address));
  await settle(tester);
}

void main() {
  testWidgets('新增模式：标题 + label/url 表单 + 保存/取消按钮', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    expect(find.text(loc.library_add_address), findsOneWidget);
    expect(find.text(loc.library_label), findsOneWidget);
    // TextField label 与 sheet subtitle 文案相同（服务器地址）。
    expect(find.text(loc.library_server_address), findsWidgets);
    expect(find.text(loc.library_save_address), findsOneWidget);
    expect(find.text(loc.settings_cancel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('label 为空提交 → 显示必填错误', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterUrl(tester, 'https://a.example.com');
    await tapSave(tester);

    expect(find.text(loc.library_label_required), findsOneWidget);
    expect(lastProbe.closed, isFalse, reason: '校验失败不应关闭弹窗');
    expect(tester.takeException(), isNull);
  });

  testWidgets('url 为空 / 非法 → 分别显示必填与格式错误', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterLabel(tester, '家里');
    await tapSave(tester);
    expect(find.text(loc.library_server_required), findsOneWidget);

    await enterUrl(tester, 'not-a-url');
    await tapSave(tester);
    expect(find.text(loc.library_url_invalid), findsOneWidget);
    expect(lastProbe.closed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('合法 https 保存 → pop 出 trim 后的 ServerAddress', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterLabel(tester, '  家里  ');
    await enterUrl(tester, 'https://a.example.com');
    await tapSave(tester);
    await settle(tester);

    expect(lastProbe.closed, isTrue);
    final saved = lastProbe.saved!;
    expect(saved.label, '家里');
    expect(saved.url, 'https://a.example.com');
    expect(saved.libraryId, 'lib-1');
    expect(saved.priority, 10);
    expect(saved.id, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消按钮 → pop null 不保存', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterLabel(tester, '家里');
    await tester.tap(find.text(loc.settings_cancel));
    await settle(tester);

    expect(lastProbe.closed, isTrue);
    expect(lastProbe.saved, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('http 新增保存 → 弹安全确认，点「仍要保存」返回 http 地址', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterLabel(tester, '家里');
    await enterUrl(tester, 'http://192.168.1.10:4533');
    await tapSave(tester);

    expect(find.text(loc.library_save_insecure_http_title), findsOneWidget);
    expect(find.text(loc.library_save_anyway), findsOneWidget);

    await tester.tap(find.text(loc.library_save_anyway));
    await settle(tester);

    expect(lastProbe.closed, isTrue);
    expect(lastProbe.saved!.url, 'http://192.168.1.10:4533');
    expect(tester.takeException(), isNull);
  });

  testWidgets('http 新增保存 → 确认 sheet 点「取消」→ 弹窗保持打开', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterLabel(tester, '家里');
    await enterUrl(tester, 'http://192.168.1.10:4533');
    await tapSave(tester);

    expect(find.text(loc.library_save_insecure_http_title), findsOneWidget);
    // 确认 sheet 里的取消按钮。
    await tester.tap(find.text(loc.settings_cancel).last);
    await settle(tester);

    expect(lastProbe.closed, isFalse, reason: '确认取消后编辑弹窗应保持打开');
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑模式：标题与预填正确，保存保留原 id/priority', (tester) async {
    await pumpHost(tester);
    await openDialog(
      tester,
      libraryId: 'lib-1',
      initialAddress: ServerAddress(
        id: 'addr-9',
        libraryId: 'lib-1',
        label: '旧地址',
        url: 'https://old.example.com',
        priority: 3,
      ),
    );

    expect(find.text(loc.library_edit_address), findsOneWidget);
    expect(find.text('旧地址'), findsOneWidget);
    expect(find.text('https://old.example.com'), findsOneWidget);

    await enterUrl(tester, 'https://new.example.com');
    await tapSave(tester);
    await settle(tester);

    final saved = lastProbe.saved!;
    expect(saved.id, 'addr-9', reason: '编辑模式应保留原 id');
    expect(saved.priority, 3, reason: '编辑模式应保留原 priority');
    expect(saved.url, 'https://new.example.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑模式 url 未变 → 免确认直接保存', (tester) async {
    await pumpHost(tester);
    await openDialog(
      tester,
      libraryId: 'lib-1',
      initialAddress: ServerAddress(
        id: 'addr-9',
        libraryId: 'lib-1',
        label: '旧地址',
        url: 'http://old.example.com',
        priority: 3,
      ),
    );

    await tapSave(tester);
    await settle(tester);

    expect(find.text(loc.library_save_insecure_http_title), findsNothing,
        reason: 'url 未变不应弹安全确认');
    expect(lastProbe.closed, isTrue);
    expect(lastProbe.saved!.url, 'http://old.example.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('http 警告图标 → 点开提示 sheet，「知道了」关闭提示', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    // 输入 http url 触发警告图标出现。
    await enterUrl(tester, 'http://192.168.1.10:4533');
    expect(find.byIcon(AppIcons.warning), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.warning));
    await settle(tester);

    expect(find.text(loc.library_http_hint), findsWidgets);
    await tester.tap(find.text(loc.library_got_it));
    await settle(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('url 输入框键盘提交触发保存', (tester) async {
    await pumpHost(tester);
    await openDialog(tester, libraryId: 'lib-1');

    await enterLabel(tester, '家里');
    await enterUrl(tester, 'https://kb.example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(lastProbe.closed, isTrue);
    expect(lastProbe.saved!.url, 'https://kb.example.com');
    expect(tester.takeException(), isNull);
  });
}
