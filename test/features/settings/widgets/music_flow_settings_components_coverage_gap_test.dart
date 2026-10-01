import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              height: size.height,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 开关是组件私有的 `_MusicFlowToggle`,内部是 AnimatedContainer(外层 52x30 的
/// 底槽 + 内层 AnimatedAlign 的滑块),按类型会匹配到 3 个,所以按尺寸把它挑出来。
Finder _toggleFinder() {
  // AnimatedContainer 没暴露 width/height getter,只能靠「非 AnimatedAlign」
  // 排除掉内层滑块;外层底槽是父节点,pre-order 里排第一。
  return find
      .byWidgetPredicate(
        (Widget w) =>
            w is AnimatedContainer &&
            w is! AnimatedAlign &&
            w.decoration is BoxDecoration,
      )
      .first;
}

void main() {
  group('MusicFlowSettingsSection', () {
    testWidgets('带标题/描述/子元素可渲染', (tester) async {
      await _pump(
        tester,
        MusicFlowSettingsSection(
          title: '通用',
          description: '全局偏好',
          children: <Widget>[
            const MusicFlowSettingRow(
              icon: AppIcons.music,
              title: '项一',
            ),
          ],
        ),
      );
      expect(find.text('通用'), findsWidgets);
      expect(find.text('全局偏好'), findsWidgets);
      expect(find.text('项一'), findsOneWidget);
    });

    testWidgets('不给描述时也能渲染', (tester) async {
      await _pump(
        tester,
        const MusicFlowSettingsSection(
          title: '无描述',
          children: <Widget>[],
        ),
      );
      expect(find.text('无描述'), findsWidgets);
    });
  });

  group('MusicFlowSettingRow', () {
    testWidgets('onPressed 为空(只读行)不崩', (tester) async {
      await _pump(
        tester,
        const MusicFlowSettingRow(
          icon: AppIcons.music,
          title: '只读行',
          value: '当前值',
        ),
      );
      expect(find.text('只读行'), findsOneWidget);
      expect(find.text('当前值'), findsWidgets);
    });

    testWidgets('点击触发 onPressed', (tester) async {
      var tapped = 0;
      await _pump(
        tester,
        MusicFlowSettingRow(
          icon: AppIcons.music,
          title: '可点行',
          onPressed: () => tapped++,
        ),
      );
      await tester.tap(find.text('可点行'));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('selected + destructive 组合可渲染', (tester) async {
      await _pump(
        tester,
        MusicFlowSettingRow(
          icon: AppIcons.delete,
          title: '删除我',
          selected: true,
          destructive: true,
          semanticLabel: '删除',
          trailing: const Icon(Icons.check),
          onPressed: () {},
        ),
      );
      expect(find.text('删除我'), findsOneWidget);
    });
  });

  group('MusicFlowToggleSettingRow', () {
    testWidgets('初始开/关两种值都能渲染,点击翻转', (tester) async {
      final colors = <Color?>[];
      for (final start in <bool>[true, false]) {
        var value = start;
        await _pump(
          tester,
          MusicFlowToggleSettingRow(
            icon: AppIcons.music,
            title: '开关行',
            value: value,
            onChanged: (bool next) {
              value = next;
            },
          ),
        );
        expect(find.text('开关行'), findsOneWidget);
        // 开关是组件私有的 _MusicFlowToggle(AnimatedContainer),只能按类型瞄。
        final toggleFinder = _toggleFinder();
        final deco = tester.widget<AnimatedContainer>(toggleFinder).decoration;
        colors.add(deco is BoxDecoration ? deco.color : null);
        await tester.tap(toggleFinder);
        await tester.pump();
        expect(value, isNot(start), reason: '点击后 onChanged 应收到相反值');
      }
      expect(colors[0], isNot(colors[1]), reason: '开/关两态的底色应不同');
    });
  });

  group('MusicFlowChoiceRow', () {
    testWidgets('选中行渲染选中态,点击回调触发', (tester) async {
      var pressed = 0;
      await _pump(
        tester,
        MusicFlowChoiceRow(
          title: '选项A',
          selected: true,
          icon: AppIcons.radio,
          onPressed: () => pressed++,
        ),
      );
      expect(find.text('选项A'), findsOneWidget);
      await tester.tap(find.text('选项A'));
      await tester.pump();
      expect(pressed, 1);
    });
  });

  group('MusicFlowProviderSettingRow', () {
    testWidgets('启用态与停用态都可渲染', (tester) async {
      for (final enabled in <bool>[true, false]) {
        await _pump(
          tester,
          MusicFlowProviderSettingRow(
            index: 1,
            title: '插件一',
            description: '说明文本',
            enabled: enabled,
            onChanged: (_) {},
          ),
        );
        expect(find.text('插件一'), findsOneWidget);
        expect(find.text('说明文本'), findsWidgets);
      }
    });

    testWidgets('点击开关触发 onChanged', (tester) async {
      await _pump(
        tester,
        MusicFlowProviderSettingRow(
          index: 0,
          title: '插件二',
          description: '',
          enabled: true,
          onChanged: (_) {},
        ),
      );
      // 只锁「开关热区能被点中且不崩」;具体 onChanged 已在 ToggleSettingRow 组验证。
      await tester.tap(_toggleFinder());
      await tester.pump();
    });
  });

  group('MusicFlowProviderListSkeleton', () {
    testWidgets('默认 4 条骨架可渲染', (tester) async {
      // ListView.builder 需要有限高度,这里给个固定高度盒子兜住。
      await _pump(
        tester,
        SizedBox(
          height: 600,
          child: MusicFlowProviderListSkeleton(),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('可指定条数与 padding', (tester) async {
      await _pump(
        tester,
        SizedBox(
          height: 600,
          child: MusicFlowProviderListSkeleton(
            count: 2,
            padding: const EdgeInsets.all(8),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowMetricBlock', () {
    testWidgets('带/不带 detail 都能渲染', (tester) async {
      await _pump(
        tester,
        const MusicFlowMetricBlock(
          icon: AppIcons.music,
          label: '指标',
          value: '12',
        ),
      );
      expect(find.text('指标'), findsOneWidget);
      expect(find.text('12'), findsWidgets);

      await _pump(
        tester,
        const MusicFlowMetricBlock(
          icon: AppIcons.music,
          label: '指标2',
          value: '34',
          detail: '较上次 +1',
        ),
      );
      expect(find.text('较上次 +1'), findsWidgets);
    });
  });
}
