// batch35 C 路 —— `lib/features/settings/pages/log_viewer_page.dart` 补测。
//
// 覆盖点：
//   * 空缓冲 → 「暂无日志」空态；
//   * 有日志 → 行渲染 + 汇总行；
//   * 关键字过滤（onChanged 实时 setState）；
//   * 复制全部（有内容 → Clipboard + 已复制 N 行 snackbar；
//     过滤结果为空 → 无内容 snackbar）；
//   * 清空按钮 → 复位空态；
//   * 自动刷新开关：暂停后 1s 轮询不刷、恢复后轮询拉到新日志；
//   * DLNA/SSDP 诊断行着色 tertiary；
//   * 超 _maxShownLines(1500) 截断为最新 1500 行。
//
// 踩坑记录：
// #G1 Logger 默认不抓日志（_loggingEnabled=false），setUp 开启、tearDown 关闭，
//     并清空静态环形缓冲（跨用例残留）。
// #G2 页面有 1s 轮询 Timer：每个用例尾部卸载组件树，避免 pending timer。
// #G3 Clipboard.setData 走 SystemChannels.platform，需 mock handler。
// #G4 1600 行用 Logger.debug（info 会 debugPrint 拖慢控制台）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/features/settings/pages/log_viewer_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

late AppLocalizations loc;

Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> pumpViewer(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1200);
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
      home: const LogViewerPage(),
    ),
  );
  await settle(tester);
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await settle(tester);
}

void main() {
  setUp(() {
    Logger.setLoggingEnabled(true);
    Logger.clearBuffer();
  });
  tearDown(() {
    Logger.setLoggingEnabled(false);
    Logger.clearBuffer();
  });

  testWidgets('空日志 → 空态文案', (tester) async {
    await pumpViewer(tester);

    expect(find.text(loc.settings_log_empty), findsOneWidget);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有日志 → 行渲染 + 汇总显示', (tester) async {
    Logger.info('普通日志甲');
    Logger.info('普通日志乙');
    await pumpViewer(tester);

    expect(find.textContaining('普通日志甲'), findsOneWidget);
    expect(find.textContaining('普通日志乙'), findsOneWidget);
    expect(find.textContaining('2'), findsWidgets, reason: '汇总行应包含缓冲行数');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关键字过滤：只显示匹配行', (tester) async {
    Logger.info('DLNA-AUTO 续播命中');
    Logger.info('普通播放日志');
    await pumpViewer(tester);

    await tester.enterText(find.byType(TextField), 'DLNA');
    await settle(tester);

    // 注意 hint 文本也含 "DLNA-AUTO"，用完整日志片段匹配。
    expect(find.textContaining('DLNA-AUTO 续播命中'), findsOneWidget);
    expect(find.textContaining('普通播放日志'), findsNothing);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复制全部（有内容）→ 写剪贴板并弹已复制提示', (tester) async {
    final clipboard = <String, dynamic>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.addAll(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    Logger.info('剪贴板日志一');
    Logger.info('剪贴板日志二');
    await pumpViewer(tester);

    await tester.tap(find.text(loc.settings_log_copy));
    await settle(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(loc.settings_log_copied(2)), findsOneWidget);
    expect(clipboard['text'], isA<String>().having(
      (t) => t.contains('剪贴板日志一') && t.contains('剪贴板日志二'),
      '剪贴板包含全部行',
      isTrue,
    ));
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复制全部（过滤后无内容）→ 弹无内容提示', (tester) async {
    Logger.info('存在的日志');
    await pumpViewer(tester);

    await tester.enterText(find.byType(TextField), '不存在的关键字');
    await settle(tester);
    await tester.tap(find.text(loc.settings_log_copy));
    await settle(tester);

    expect(find.text(loc.settings_log_no_content), findsOneWidget);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空按钮 → 缓冲复位回到空态', (tester) async {
    Logger.info('将被清空的日志');
    await pumpViewer(tester);

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await settle(tester);

    expect(find.text(loc.settings_log_empty), findsOneWidget);
    expect(Logger.bufferedLineCount, 0);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动刷新暂停：开关切换图标且 1s 轮询不拉新日志', (tester) async {
    Logger.info('暂停前的日志');
    await pumpViewer(tester);

    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tester.tap(find.byIcon(Icons.pause));
    await settle(tester);

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    // 暂停后新日志不出现。
    Logger.info('暂停后的新日志');
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    await settle(tester);
    expect(find.textContaining('暂停后的新日志'), findsNothing);

    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动刷新开启：1s 轮询拉到新日志', (tester) async {
    await pumpViewer(tester);

    expect(find.text(loc.settings_log_empty), findsOneWidget);
    Logger.info('轮询拉到的日志');
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    await settle(tester);

    expect(find.textContaining('轮询拉到的日志'), findsOneWidget);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DLNA/SSDP 诊断行使用 tertiary 强调色', (tester) async {
    Logger.info('DLNA 扫描设备');
    Logger.info('普通行');
    await pumpViewer(tester);

    final theme = AppTheme.light();
    final textWidget = tester.widgetList<Text>(
      find.textContaining('DLNA 扫描设备'),
    ).first;
    expect(textWidget.style?.color, theme.colorScheme.tertiary);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超过 1500 行 → 只显示最新 1500 行（旧行被截断）', (tester) async {
    for (var i = 0; i < 1600; i++) {
      Logger.debug('seq-$i-log-line');
    }
    await pumpViewer(tester);

    // _visibleLines 截断为最新 1500 行：ListView 的 builder delegate childCount=1500。
    final listView = tester.widget<ListView>(find.byType(ListView));
    final delegate = listView.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 1500, reason: '1600 行应截断为最新 1500 行');

    // 视口首行应为 seq-100（最新 1500 行的第一条），seq-99 已被截断。
    expect(find.textContaining('seq-99-log'), findsNothing);
    expect(find.textContaining('seq-100-log'), findsOneWidget);

    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
}
