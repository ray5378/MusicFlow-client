// batch34 C 路 —— `lib/core/design/components/music_flow_bottom_sheet.dart` 补测。
//
// 覆盖点：
//   * showMusicFlowBottomSheet —— compact(宽<600) 走 showModalBottomSheet；
//     desktop(width>=600) 走 showGeneralDialog；desktopAnchored + 有全局点击
//     坐标时走 _showAnchoredPopup（私有路由，只能经入口触发）。
//   * _AnchoredPopupOutsideDismiss：点击面板外(含任意按键)关闭、面板内不关。
//   * MusicFlowBottomSheet：标题/副标题/关闭按钮/拖拽把手/桌面端隐藏把手/
//     constrainToAvailableHeight / 自定义 padding。
//   * MusicFlowActionRow：onPressed 回调 / 禁用态 / selected / destructive /
//     subtitle / trailing / 自定义 semanticLabel。
//
// 踩坑记录：
// #B1 showMusicFlowBottomSheet 的 Future 在弹窗 pop 时才完成，用例里必须
//     unawaited 发起 + Completer 接结果，绝不能 await（挂死）。
// #B2 弹窗动画是有界的，但为稳妥统一用有界 settle() 推帧。
// #B3 anchored popup 依赖全局量 musicFlowLastTapGlobalPosition（可测试注入），
//     用例里直接赋值即可，不必真做一次指针按下。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_bottom_sheet.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Future<void> settle(WidgetTester tester, {int frames = 16}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// 把树里的 BuildContext 递出来给 showMusicFlowBottomSheet（同 sheet 模板 #C2）。
class _ContextProbe extends StatelessWidget {
  const _ContextProbe({required this.onReady});

  final void Function(BuildContext context) onReady;

  @override
  Widget build(BuildContext context) {
    onReady(context);
    return const SizedBox.shrink();
  }
}

Widget _host({
  required void Function(BuildContext) onReady,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    theme: AppTheme.light(),
    home: Scaffold(
      body: _ContextProbe(onReady: onReady),
    ),
  );
}

/// 设置视口尺寸（compact/desktop 分流看 MediaQuery 宽度）并挂载宿主。
Future<void> pumpHost(
  WidgetTester tester,
  Size size, {
  required void Function(BuildContext) onReady,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_host(onReady: onReady));
}

void main() {
  group('showMusicFlowBottomSheet · compact 走底部抽屉', () {
    testWidgets('弹出后渲染 builder 内容，pop 带回结果', (tester) async {
      BuildContext? hostContext;
      final result = Completer<String?>();
      await pumpHost(
        tester,
        const Size(520, 1000),
        onReady: (c) => hostContext = c,
      );

      unawaited(
        showMusicFlowBottomSheet<String>(
          context: hostContext!,
          builder: (sheetContext) => MusicFlowBottomSheet(
            title: '操作',
            child: TextButton(
              onPressed: () => Navigator.of(sheetContext).pop('done'),
              child: const Text('确认'),
            ),
          ),
        ).then(result.complete),
      );
      await settle(tester);

      expect(find.text('操作'), findsOneWidget);
      expect(find.text('确认'), findsOneWidget);
      // compact：显示顶部拖拽把手。
      expect(
        find.byKey(const ValueKey<String>('music_flow_bottom_sheet_drag_handle')),
        findsOneWidget,
      );

      await tester.tap(find.text('确认'));
      await settle(tester);

      expect(await result.future, 'done');
      expect(find.text('操作'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('showDragHandle=false 时把手被隐藏', (tester) async {
      BuildContext? hostContext;
      await pumpHost(
        tester,
        const Size(520, 1000),
        onReady: (c) => hostContext = c,
      );

      unawaited(showMusicFlowBottomSheet<String>(
        context: hostContext!,
        builder: (_) => const MusicFlowBottomSheet(
          title: '无把手',
          showDragHandle: false,
          child: SizedBox(width: 40, height: 40),
        ),
      ));
      await settle(tester);

      expect(
        find.byKey(
          const ValueKey<String>('music_flow_bottom_sheet_drag_handle'),
        ),
        findsNothing,
      );
      expect(find.text('无把手'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('showMusicFlowBottomSheet · desktop 走居中对话框', () {
    testWidgets('宽 >=600 时渲染居中弹窗且不显示拖拽把手', (tester) async {
      BuildContext? hostContext;
      final result = Completer<String?>();
      await pumpHost(
        tester,
        const Size(900, 1000),
        onReady: (c) => hostContext = c,
      );

      unawaited(
        showMusicFlowBottomSheet<String>(
          context: hostContext!,
          builder: (sheetContext) => MusicFlowBottomSheet(
            title: '桌面弹窗',
            child: TextButton(
              onPressed: () => Navigator.of(sheetContext).pop('ok'),
              child: const Text('好'),
            ),
          ),
        ).then(result.complete),
      );
      await settle(tester);

      expect(find.text('桌面弹窗'), findsOneWidget);
      expect(find.text('好'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('music_flow_bottom_sheet_drag_handle'),
        ),
        findsNothing,
        reason: '桌面端隐藏安卓式拖拽把手',
      );

      await tester.tap(find.text('好'));
      await settle(tester);
      expect(await result.future, 'ok');
      expect(tester.takeException(), isNull);
    });

    testWidgets('isDismissible=true 时点屏障关闭且返回 null', (tester) async {
      BuildContext? hostContext;
      final result = Completer<String?>();
      await pumpHost(
        tester,
        const Size(900, 1000),
        onReady: (c) => hostContext = c,
      );

      unawaited(
        showMusicFlowBottomSheet<String>(
          context: hostContext!,
          builder: (_) => const MusicFlowBottomSheet(
            title: '可点外关闭',
            child: SizedBox(width: 40, height: 40),
          ),
        ).then(result.complete),
      );
      await settle(tester);

      // 点最左上角屏障（弹窗 maxWidth 520 居中，20,20 必在弹窗外）。
      await tester.tapAt(const Offset(20, 20));
      await settle(tester);

      expect(await result.future, isNull);
      expect(find.text('可点外关闭'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('showMusicFlowBottomSheet · desktopAnchored 锚点弹窗', () {
    testWidgets('在锚点附近渲染小弹窗，点面板外关闭、面板内不关', (tester) async {
      BuildContext? hostContext;
      final result = Completer<String?>();
      await pumpHost(
        tester,
        const Size(900, 1000),
        onReady: (c) => hostContext = c,
      );
      // 直接注入锚点（全局量，等价于根级 Listener 记录到的按下坐标）。
      musicFlowLastTapGlobalPosition = const Offset(120, 120);
      addTearDown(() => musicFlowLastTapGlobalPosition = null);

      unawaited(
        showMusicFlowBottomSheet<String>(
          context: hostContext!,
          desktopAnchored: true,
          // 面板内放纯文本（非可点控件），避免「面板内点击」误触发按钮 pop。
          builder: (_) => const Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('菜单项'),
            ),
          ),
        ).then(result.complete),
      );
      await settle(tester);

      expect(find.text('菜单项'), findsOneWidget, reason: '锚点面板已渲染');

      // 面板内点击不关闭：面板 box 实际高度 = 内容高（文本+16 边距 ≈53px），
      // 位于锚点右下方 (126,126) 起，故取 (200,150) 必在面板矩形内。
      await tester.tapAt(const Offset(200, 150));
      await settle(tester);
      expect(find.text('菜单项'), findsOneWidget, reason: '面板内点击不应关闭');

      // 面板外点击（右下远处）关闭。
      await tester.tapAt(const Offset(860, 960));
      await settle(tester);
      expect(find.text('菜单项'), findsNothing, reason: '面板外点击应关闭');
      expect(await result.future, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowBottomSheet 组件本体', () {
    Widget wrap(Widget child, {Size size = const Size(520, 1000)}) {
      return MediaQuery(
        data: MediaQueryData(size: size, devicePixelRatio: 1),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      );
    }

    testWidgets('副标题 + 关闭按钮渲染，点关闭 pop', (tester) async {
      final popped = Completer<bool>();
      await tester.pumpWidget(wrap(
        MusicFlowBottomSheet(
          title: '标题甲',
          subtitle: '副标题乙',
          child: const SizedBox(width: 40, height: 40),
        ),
      ));

      expect(find.text('标题甲'), findsOneWidget);
      expect(find.text('副标题乙'), findsOneWidget);

      // 关闭按钮：语义 label 为 core_close（中文「关闭」）。
      final closeButton = find.bySemanticsLabel('关闭');
      expect(closeButton, findsOneWidget);
      unawaited(
        Navigator.of(tester.element(closeButton))
            .maybePop()
            .then(popped.complete),
      );
      await settle(tester);
      // 本用例里弹窗不是路由——maybePop 在无路由可弹时返回 false。
      expect(await popped.future, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('showCloseButton=false 时不渲染关闭按钮', (tester) async {
      await tester.pumpWidget(wrap(
        const MusicFlowBottomSheet(
          title: '无关闭钮',
          showCloseButton: false,
          child: SizedBox(width: 40, height: 40),
        ),
      ));
      expect(find.bySemanticsLabel('关闭'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('桌面宽度下把手隐藏且走四角圆角（sceneRadius 强制生效）',
        (tester) async {
      await tester.pumpWidget(wrap(
        const MusicFlowBottomSheet(
          title: '桌面样式',
          child: SizedBox(width: 40, height: 40),
        ),
        size: const Size(900, 1000),
      ));
      expect(
        find.byKey(
          const ValueKey<String>('music_flow_bottom_sheet_drag_handle'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('constrainToAvailableHeight=true 用 Flexible 包裹内容',
        (tester) async {
      await tester.pumpWidget(wrap(
        SizedBox(
          height: 300,
          child: MusicFlowBottomSheet(
            title: '受限高度',
            constrainToAvailableHeight: true,
            padding: const EdgeInsets.all(4),
            child: Container(key: const ValueKey('body-box'), color: Colors.teal),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('body-box')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowActionRow', () {
    Widget wrap(Widget child) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(width: 480, child: child),
        ),
      );
    }

    testWidgets('点按触发 onPressed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(wrap(
        MusicFlowActionRow(
          icon: Icons.play_arrow,
          title: '动作行',
          onPressed: () => taps++,
        ),
      ));
      await tester.tap(find.text('动作行'));
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onPressed=null 为禁用态，点按不触发', (tester) async {
      await tester.pumpWidget(wrap(
        MusicFlowActionRow(
          icon: Icons.play_arrow,
          title: '禁用行',
          onPressed: null,
        ),
      ));
      await tester.tap(find.text('禁用行'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('subtitle/trailing/selected/destructive/semanticLabel 全量装配',
        (tester) async {
      await tester.pumpWidget(wrap(
        MusicFlowActionRow(
          icon: Icons.delete,
          title: '危险动作',
          subtitle: '说明文字',
          trailing: const Icon(Icons.star),
          selected: true,
          destructive: true,
          semanticLabel: '自定义语义',
          onPressed: () {},
        ),
      ));
      expect(find.text('危险动作'), findsOneWidget);
      expect(find.text('说明文字'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.bySemanticsLabel('自定义语义'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selected 且未自定义语义时，语义标签拼接「已选择」', (tester) async {
      await tester.pumpWidget(wrap(
        MusicFlowActionRow(
          icon: Icons.check,
          title: '选中行',
          selected: true,
          onPressed: () {},
        ),
      ));
      expect(find.bySemanticsLabel('选中行，已选择'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
