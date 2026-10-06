// b38b3 —— 设计层小组件剩余缺口补测。
//
// 覆盖（230 lcov 未覆盖行）：
//   music_flow_scaffold.dart:88   MusicFlowTopBar.back 的 leading onPressed
//                                 （Navigator.maybePop）——必须真正点击才执行。
//   music_flow_scaffold.dart:103  showDivider=true 时的底部 Border。
//   music_flow_page_header.dart:39-43  description 分支。
//   music_flow_page_header.dart:85-86/88  primaryAction 分支。
//   music_flow_bottom_sheet.dart:259  锚点弹窗右越界 → 向左收拢。
//   music_flow_bottom_sheet.dart:263  锚点弹窗下越界 → 向上收拢。
//   music_flow_context.dart:52-55    无 MediaQuery 时 reduce-motion 回退到
//                                    platformDispatcher.accessibilityFeatures。
//
// 产品代码零改动；只读 lib。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/components/music_flow_bottom_sheet.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_page_header.dart';
import 'package:musicflow_client/core/design/components/music_flow_scaffold.dart';
import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  group('MusicFlowScaffold / MusicFlowTopBar', () {
    testWidgets('showDivider=true 时顶栏渲染底部边框', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: MusicFlowTopBar(title: '标题', showDivider: true),
      )));

      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.text('标题'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final deco = box.decoration as BoxDecoration;
      expect(deco.border, isNotNull, reason: 'showDivider=true → 应有底部边框');
    });

    testWidgets('showDivider=false（默认）时顶栏无边框', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: MusicFlowTopBar(title: '标题'),
      )));
      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.text('标题'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final deco = box.decoration as BoxDecoration;
      expect(deco.border, isNull);
    });

    testWidgets('MusicFlowTopBar.back 的后退按钮点击触发 Navigator.maybePop', (tester) async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Scaffold(
          body: MusicFlowTopBar.back(context: context, title: '子页'),
        ),
      )));
      expect(find.byType(MusicFlowIconButton), findsOneWidget);
      await tester.tap(find.byType(MusicFlowIconButton));
      await tester.pumpAndSettle();
      // 返回栈已空 → maybePop 安全无操作；仅验证点击闭包被执行且不抛。
      expect(find.text('子页'), findsOneWidget);
    });
  });

  group('MusicFlowPageHeader', () {
    testWidgets('description 与 primaryAction 均渲染', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: MusicFlowPageHeader(
          title: '页面标题',
          description: '这是描述文字',
          primaryAction: Text('主要操作'),
        ),
      )));

      expect(find.text('页面标题'), findsOneWidget);
      expect(find.text('这是描述文字'), findsOneWidget);
      expect(find.text('主要操作'), findsOneWidget);
    });

    testWidgets('仅 title 时不渲染描述/主操作块', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: MusicFlowPageHeader(title: '只有标题'),
      )));
      expect(find.text('只有标题'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MusicFlowPageHeader),
          matching: find.byType(Align),
        ),
        findsNothing,
        reason: '无 primaryAction 时不应渲染 Align 块',
      );
    });
  });

  group('锚点弹窗定位收拢', () {
    testWidgets('锚点在右下角时向左/向上收拢，不溢出屏幕', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(
        builder: (context) {
          ctx = context;
          return const Scaffold(body: SizedBox.expand());
        },
      )));

      // 宽 1200 → expanded（非 compact），desktopAnchored 走 _AnchoredPopupPosition。
      // 锚点贴近右下角 → panel 右越界（259）+ 下越界（263）。
      musicFlowLastTapGlobalPosition = const Offset(1190, 890);
      addTearDown(() => musicFlowLastTapGlobalPosition = null);

      unawaited(showMusicFlowBottomSheet<void>(
        context: ctx,
        desktopAnchored: true,
        builder: (_) => const SizedBox(
          width: 200,
          height: 120,
          child: Text('锚点面板'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('锚点面板'), findsOneWidget);
      // 面板应完全落在 [0,0,1200,900] 内（收拢生效，无越界溢出）。
      final rect = tester.getRect(find.text('锚点面板'));
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.top, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(1200.0));
      expect(rect.bottom, lessThanOrEqualTo(900.0));
    });
  });

  group('MusicFlowDesignContext.musicFlowReduceMotion', () {
    testWidgets('无 MediaQuery 祖先时回退到 platformDispatcher.accessibilityFeatures',
        (tester) async {
      bool? resolved;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          resolved = context.musicFlowReduceMotion;
          return const SizedBox();
        }),
      ));

      final expected = WidgetsBinding
          .instance.platformDispatcher.accessibilityFeatures.disableAnimations;
      expect(resolved, expected,
          reason: '无 MediaQuery 时应回退读 platformDispatcher 而非崩溃');
    });
  });
}
