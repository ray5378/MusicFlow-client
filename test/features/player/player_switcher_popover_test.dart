import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 桌面端「切换播放器」小弹窗的布局回归防线。
///
/// 真实运行路径:PC 端点迷你播放条的切换按钮 → [showPlayerSwitcherPopover]
/// 把 [PlayerSwitcherPopover] 经 OverlayEntry 插进根 Overlay。
///
/// 根 Overlay(_Theater)只给子级**无界(loose)约束**。历史上本组件用的是
/// 「Stack + Positioned.fill 遮罩」写法,内含 Expanded 的子树拿到无界宽度后
/// 在 debug 下画出 ErrorWidget,表现为主窗口右侧突然多出一列黄底英文告警
/// (2026-09-10 用户反馈「客户端右边有很多奇怪的英文」)。
///
/// 注意:**修掉之后的实现只依赖 Overlay 的无界约束,反而不再依赖
/// Directionality**——直接 `pumpWidget(PlayerSwitcherPopover(...))` 会绕过
/// Overlay、带上 Scaffold 的紧约束,测不出这个 bug。所以这里刻意造一个
/// 裸 Overlay(无 MaterialApp 包裹)来还原真实约束。
void main() {
  /// 把 child 插进一个**裸 Overlay**(模拟根 Overlay 的无界约束),
  /// 同时提供 Directionality / MediaQuery / 主题 / 本地化。
  Widget hostOverlay(Widget child, {Size size = const Size(1200, 800)}) {
    return ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: Theme(
            data: AppTheme.dark(),
            child: Localizations(
              locale: const Locale('zh'),
              delegates: AppLocalizations.localizationsDelegates,
              child: Overlay(
                initialEntries: <OverlayEntry>[
                  OverlayEntry(
                    builder: (overlayContext) => Builder(builder: (_) => child),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpPopover(
    WidgetTester tester, {
    required ValueChanged<String?> onSwitched,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      hostOverlay(PlayerSwitcherPopover(onSwitched: onSwitched)),
    );
    // 首帧 + 设备列表返回后的那一帧都要过一遍。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('弹窗在 Overlay 里渲染不产生布局异常(无 ErrorWidget)',
      (tester) async {
    await pumpPopover(tester, onSwitched: (_) {});

    // 1. 不能有 Flutter framework 异常(无界约束下的布局失败都在此抛出)。
    expect(tester.takeException(), isNull);

    // 2. 不能出现 ErrorWidget 的黄色告警文案。
    //    ErrorWidget 是 private 类,但它的兜底文案是可匹配的特征串。
    final errorTexts = find.byWidgetPredicate((widget) {
      if (widget is! Text) return false;
      final data = widget.data ?? '';
      return data.contains('require an Overlay widget ancestor') ||
          data.contains('BoxConstraints forces an infinite') ||
          data.contains('RenderFlex') ||
          data.contains('overflowed by');
    });
    expect(
      errorTexts,
      findsNothing,
      reason: '弹窗在 Overlay 中渲染出了 ErrorWidget —— '
          '通常是弹窗内部改回了依赖紧约束的 Stack/Positioned 遮罩布局。',
    );

    // 3. 弹窗标题确实渲染出来了(证明不是整块被摘除)。
    expect(find.text('选择播放器'), findsOneWidget);
  });

  testWidgets('点击弹窗外区域触发关闭回调', (tester) async {
    final calls = <String?>[];
    await pumpPopover(tester, onSwitched: calls.add);

    // 点左上角(远离右下角弹窗本体)。
    await tester.tapAt(const Offset(60, 60));
    await tester.pump();

    expect(calls, hasLength(1));
    expect(calls.single, isNull, reason: '纯关闭不带 toast 文案');
  });

  testWidgets('弹窗本体锚定在右下角(MiniPlayer 上方)', (tester) async {
    await pumpPopover(tester, onSwitched: (_) {});

    // 遮罩层铺满整个 Overlay(即关闭热区)。
    final mask = tester.getRect(find.byType(PlayerSwitcherPopover));
    expect(mask.width, 1200);
    expect(mask.height, 800);

    // 弹窗本体锚在右下:标题中心应当落在窗口右半侧、下半侧。
    final title = tester.getCenter(find.text('选择播放器'));
    expect(title.dx, greaterThan(1200 / 2));
    expect(title.dy, greaterThan(800 / 2));
  });
}
