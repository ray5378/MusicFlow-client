// b38b3 —— Route B：设计组件（components）剩余缺口补测。
//
// 覆盖 lcov 显示仍未命中的行：
//   * MusicFlowButton 默认构造 + trailingIcon 分支
//   * MusicFlowDivider 垂直轴分支
//   * MusicFlowPageRoute 的 RTL 方向(-1) 与 Windows Fade-only 分支
//   * MusicFlowSurface.canvas 构造 + modal 默认圆角
//   * MusicFlowTopBar.back 工厂 + showDivider
//   * MusicFlowTextField didUpdateWidget 的 focusNode 归属切换
//   * MusicFlowDesktopDialog 关闭按钮
//   * MusicFlowPressable 无限高度约束 + 键盘激活脉冲
//   * MusicFlowPageHeader description / primaryAction 分支
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_desktop_dialog.dart';
import 'package:musicflow_client/core/design/components/music_flow_divider.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_page_header.dart';
import 'package:musicflow_client/core/design/components/music_flow_page_route.dart';
import 'package:musicflow_client/core/design/components/music_flow_pressable.dart';
import 'package:musicflow_client/core/design/components/music_flow_scaffold.dart';
import 'package:musicflow_client/core/design/components/music_flow_surface.dart';
import 'package:musicflow_client/core/design/components/music_flow_text_field.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  Widget app(Widget child) {
    return MaterialApp(
      theme: AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: child),
    );
  }

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('MusicFlowButton', () {
    testWidgets('默认构造 + 各变体 + leading/trailing 图标 + 禁用', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        app(
          Column(
            children: <Widget>[
              MusicFlowButton(
                label: 'primary',
                onPressed: () => taps++,
                trailingIcon: Icons.arrow_forward,
              ),
              MusicFlowButton.secondary(
                label: 'secondary',
                onPressed: () {},
                leadingIcon: Icons.add,
              ),
              MusicFlowButton.ghost(label: 'ghost', onPressed: () {}),
              MusicFlowButton.destructive(label: 'danger', onPressed: () {}),
              const MusicFlowButton(label: 'disabled', onPressed: null),
              MusicFlowButton(
                label: 'expand',
                onPressed: () {},
                expand: true,
                height: 40,
                minimumWidth: 10,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('primary'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward), findsOneWidget, reason: 'trailingIcon 分支');
      expect(find.byIcon(Icons.add), findsOneWidget, reason: 'leadingIcon 分支');

      await tester.tap(find.text('primary'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('无界宽度下不包裹 Flexible', (tester) async {
      await tester.pumpWidget(
        app(
          Row(
            children: <Widget>[
              MusicFlowButton(label: 'unbounded', onPressed: () {}),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('unbounded'), findsOneWidget);
    });
  });

  group('MusicFlowDivider', () {
    testWidgets('水平 / 垂直两轴', (tester) async {
      await tester.pumpWidget(
        app(
          Row(
            children: const <Widget>[
              Expanded(child: MusicFlowDivider(inset: 2, endInset: 3)),
              SizedBox(
                height: 40,
                child: MusicFlowDivider(axis: Axis.vertical, inset: 1),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MusicFlowDivider), findsNWidgets(2));
    });
  });

  group('MusicFlowSurface', () {
    testWidgets('canvas 构造与 modal 默认圆角', (tester) async {
      await tester.pumpWidget(
        app(
          Column(
            children: const <Widget>[
              MusicFlowSurface.canvas(child: Text('canvas')),
              MusicFlowSurface(
                level: MusicFlowSurfaceLevel.modal,
                child: Text('modal'),
              ),
              MusicFlowSurface(
                level: MusicFlowSurfaceLevel.floating,
                child: Text('floating'),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('canvas'), findsOneWidget);
      expect(find.text('modal'), findsOneWidget);
      expect(find.text('floating'), findsOneWidget);
    });
  });

  group('MusicFlowTopBar', () {
    testWidgets('back 工厂 + showDivider', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) {
              captured = context;
              return MusicFlowTopBar.back(
                context: context,
                title: '详情',
                subtitle: '副标题',
              );
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text('详情'), findsOneWidget);

      // 触发 back 按钮的 pop 回调。
      await tester.tap(find.byType(MusicFlowIconButton));
      await tester.pump();
      expect(captured.mounted, isTrue);

      await tester.pumpWidget(
        app(const MusicFlowTopBar(title: '带分隔线', showDivider: true)),
      );
      await tester.pump();
      expect(find.text('带分隔线'), findsOneWidget);
    });
  });

  group('MusicFlowDesktopDialog', () {
    testWidgets('渲染标题 + 关闭按钮', (tester) async {
      await tester.pumpWidget(
        app(
          const MusicFlowDesktopDialog(
            title: '发现新版本',
            subtitle: '副标题',
            icon: Icons.system_update,
            child: Text('正文'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);

      await tester.tap(find.byType(MusicFlowIconButton));
      await tester.pump();
    });
  });

  group('MusicFlowPageHeader', () {
    testWidgets('description 与 primaryAction 分支', (tester) async {
      await tester.pumpWidget(
        app(
          const MusicFlowPageHeader(
            title: '标题',
            description: '描述文字',
            leading: Icon(Icons.menu),
            trailing: Icon(Icons.sort),
            primaryAction: Text('主操作'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('描述文字'), findsOneWidget);
      expect(find.text('主操作'), findsOneWidget);
    });
  });

  group('MusicFlowTextFieldsFocusNode', () {
    testWidgets('didUpdateWidget 切换 focusNode 归属', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final external = FocusNode();
      addTearDown(external.dispose);

      Widget build(FocusNode? node) => app(
            MusicFlowTextField(
              controller: controller,
              label: '字段',
              focusNode: node,
            ),
          );

      // 1) 内部持有 → 2) 外部注入（释放内部）→ 3) 再回到内部（新建）。
      await tester.pumpWidget(build(null));
      await tester.pump();
      await tester.pumpWidget(build(external));
      await tester.pump();
      await tester.pumpWidget(build(null));
      await tester.pump();

      expect(find.text('字段'), findsOneWidget);
    });
  });

  group('MusicFlowPressable', () {
    testWidgets('无限高度约束', (tester) async {
      await tester.pumpWidget(
        app(
          MusicFlowPressable(
            minimumSize: const Size(48, double.infinity),
            onPressed: () {},
            child: const Text('无限高'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('无限高'), findsOneWidget);
    });

    testWidgets('键盘激活触发按压缩放脉冲', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        app(
          MusicFlowPressable(
            autofocus: true,
            onPressed: () => pressed++,
            child: const Text('键盘'),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(pressed, 1, reason: 'Enter 应经 ActivateIntent 触发 onPressed');
    });
  });

  group('MusicFlowPageRoute', () {
    Future<void> pushRoute(
      WidgetTester tester, {
      required TargetPlatform platform,
      required TextDirection direction,
    }) async {
      debugDefaultTargetPlatformOverride = platform;
      final navKey = GlobalKey<NavigatorState>();
      late BuildContext navContext;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Directionality(
            textDirection: direction,
            child: Navigator(
              key: navKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (context) {
                  navContext = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      navKey.currentState!.push(
        MusicFlowPageRoute<void>(
          context: navContext,
          builder: (_) => const Text('routed'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('RTL 下方向取负', (tester) async {
      await pushRoute(
        tester,
        platform: TargetPlatform.linux,
        direction: TextDirection.rtl,
      );
      expect(find.text('routed'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows 走 Fade-only 分支', (tester) async {
      await pushRoute(
        tester,
        platform: TargetPlatform.windows,
        direction: TextDirection.ltr,
      );
      expect(find.text('routed'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
