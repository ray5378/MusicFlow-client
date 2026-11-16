// b43a —— 连接状态心跳提示「组件」的行为测试。
//
// 覆盖 lib/widgets/music_flow_app_shell/connection_beacon.dart：
//   1) 灰态：文案 == connecting，中心点用 colors.muted 且**绝不用 colors.error**，
//      并且真的在心跳（扩散环直径随时间从 8 长到 ~24，中心点常亮不缩放）；
//   2) 绿态：文案 == connected，中心点用 colors.accent；
//   3) 减少动效：扩散环整个不渲染，只留静态中心点；
//   4) 无障碍：胶囊整体摘出无障碍树（b43a 最终结论：liveRegion 去除后真机
//      v5.16.1 双黄线仍在 —— 线是系统侧服务对 Semantics 文本节点本身的高亮，
//      摘出后服务没有可标注节点），且视觉文案不变；
//   5) hidden：只渲染 SizedBox.shrink，没有可见胶囊。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/app_visibility_provider.dart';
import 'package:musicflow_client/providers/ui/connection_beacon_provider.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/connection_beacon.dart';

/// 固定状态的控制器：widget 用例不需要跑状态机。
class _StubBeacon extends ConnectionBeaconController {
  _StubBeacon(this.initial);

  final ConnectionBeaconState initial;

  @override
  ConnectionBeaconState build() => initial;
}

/// 中心点直径（组件内 `_dotSize`）。
const double _dotSize = 8;

/// 一次心跳周期（组件内 `_pulseDuration`，1600ms）。
const Duration _pulseDuration = Duration(milliseconds: 1600);

/// 扩散阶段的**中段**：45% 的扩散期里走到一半（360ms），
/// 此时环直径约 22px（远大于 8）。
const Duration _pulseHalf = Duration(milliseconds: 360);

/// 中心点 = 唯一「圆形 + 实心有色 + 无描边」的 `DecoratedBox`。
final Finder _dot = find.descendant(
  of: find.byType(ConnectionBeacon),
  matching: find.byWidgetPredicate(
    (Widget widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      if (decoration is! BoxDecoration) return false;
      return decoration.shape == BoxShape.circle &&
          decoration.color != null &&
          decoration.border == null;
    },
    description: '心跳中心点（圆形实心 DecoratedBox）',
  ),
);

/// 扩散环 = 唯一「圆形 + 只有描边没有填充」的 `DecoratedBox`。
final Finder _ring = find.descendant(
  of: find.byType(ConnectionBeacon),
  matching: find.byWidgetPredicate(
    (Widget widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      if (decoration is! BoxDecoration) return false;
      return decoration.shape == BoxShape.circle &&
          decoration.color == null &&
          decoration.border != null;
    },
    description: '扩散环（圆形描边 DecoratedBox）',
  ),
);

Future<void> _pumpBeacon(
  WidgetTester tester,
  ConnectionBeaconState state, {
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: <Override>[
      connectionBeaconProvider.overrideWith(() => _StubBeacon(state)),
      isRenderingActiveProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 800),
            disableAnimations: disableAnimations,
          ),
          child: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ConnectionBeacon(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(ConnectionBeacon)));

Color _dotColor(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(_dot.first);
  return (box.decoration as BoxDecoration).color!;
}

/// 渲染宽度（环靠真实直径扩张，不是 Transform.scale）。
double _renderedWidth(WidgetTester tester, Finder finder) =>
    tester.getRect(finder.first).width;

void main() {
  testWidgets('灰态：连接中… + 圆点是 muted 而不是 error，且真的在心跳', (tester) async {
    await _pumpBeacon(
      tester,
      const ConnectionBeaconState(
        phase: ConnectionBeaconPhase.waiting,
        reason: ConnectionBeaconReason.coldStart,
      ),
    );
    final loc = _locOf(tester);
    final colors = tester.element(find.byType(ConnectionBeacon)).musicFlowColors;

    expect(find.text(loc.connection_beacon_connecting), findsOneWidget);
    expect(_dot, findsOneWidget);

    final color = _dotColor(tester);
    expect(color, colors.muted, reason: '未连接一律灰点');
    expect(color, isNot(colors.error), reason: '用户明确要求不出现红色');

    // 心跳：环从中心点的直径起扩散，半个扩散段后明显变大。
    expect(_ring, findsOneWidget, reason: '正常模式必须渲染扩散环');
    expect(_renderedWidth(tester, _ring), moreOrLessEquals(_dotSize));
    await tester.pump(_pulseHalf);
    expect(
      _renderedWidth(tester, _ring),
      greaterThan(12),
      reason: '心跳动画必须真的在扩散（8px → 24px）',
    );

    // 中心点全程常亮且**不缩放**，只有环在动。
    expect(_renderedWidth(tester, _dot), moreOrLessEquals(_dotSize));

    // 扩散段（前 45%）结束后进入静默段：环还在树上但完全透明，
    // 直径停在最大 24px（= 中心点 3 倍）。
    await tester.pump(const Duration(milliseconds: 520));
    final ringOpacity = tester.widget<Opacity>(
      find
          .descendant(
            of: find.byType(ConnectionBeacon),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(ringOpacity.opacity, 0, reason: '静默段环必须完全透明');
    expect(
      _renderedWidth(tester, _ring),
      moreOrLessEquals(_dotSize * 3),
      reason: '静默段直径停在最大值（_ringMaxScale = 3）',
    );
  });

  testWidgets('灰态：失联时文案换成「正在重连」', (tester) async {
    await _pumpBeacon(
      tester,
      const ConnectionBeaconState(
        phase: ConnectionBeaconPhase.waiting,
        reason: ConnectionBeaconReason.lost,
      ),
    );
    final loc = _locOf(tester);

    expect(find.text(loc.connection_beacon_reconnecting), findsOneWidget);
    expect(find.text(loc.connection_beacon_connecting), findsNothing);
  });

  testWidgets('绿态：已连接 + 圆点是 accent', (tester) async {
    await _pumpBeacon(
      tester,
      const ConnectionBeaconState(phase: ConnectionBeaconPhase.connected),
    );
    final loc = _locOf(tester);
    final colors = tester.element(find.byType(ConnectionBeacon)).musicFlowColors;

    expect(find.text(loc.connection_beacon_connected), findsOneWidget);
    expect(_dotColor(tester), colors.accent);
    expect(_dotColor(tester), isNot(colors.error));
  });

  testWidgets('减少动效：扩散环整个不渲染，只留静态中心点', (tester) async {
    await _pumpBeacon(
      tester,
      const ConnectionBeaconState(
        phase: ConnectionBeaconPhase.waiting,
        reason: ConnectionBeaconReason.coldStart,
      ),
      disableAnimations: true,
    );

    expect(_dot, findsOneWidget);
    expect(_renderedWidth(tester, _dot), moreOrLessEquals(_dotSize));
    expect(
      _ring,
      findsNothing,
      reason: 'disableAnimations 时环整个不渲染（静止的环看起来像脏点）',
    );

    // 推几个半周期：普通模式下这里环早就长到 20+，减少动效必须纹丝不动。
    for (var i = 0; i < 4; i++) {
      await tester.pump(_pulseDuration ~/ 2);
      expect(_ring, findsNothing);
      expect(_renderedWidth(tester, _dot), moreOrLessEquals(_dotSize));
    }
  });

  testWidgets('胶囊整体摘出无障碍树（系统服务无高亮目标）且视觉文案不变', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pumpBeacon(
      tester,
      const ConnectionBeaconState(
        phase: ConnectionBeaconPhase.waiting,
        reason: ConnectionBeaconReason.coldStart,
      ),
    );
    final loc = _locOf(tester);

    // b43a 最终结论（真机 v5.16.1）：liveRegion 去除后双黄线仍在 —— 线是
    // 系统侧服务对 Semantics 文本节点本身的高亮（`liveRegion` 只控制自动
    // 播报，不阻止服务发现并标注该节点）。胶囊整体摘出无障碍树后，服务
    // 再也没有可标注的节点。整棵树不得存在任何带该文案的 Semantics 节点。
    expect(
      find.bySemanticsLabel(loc.connection_beacon_connecting),
      findsNothing,
      reason: '胶囊必须整体摘出无障碍树（ExcludeSemantics），无高亮目标',
    );
    // 视觉不丢：文案仍正常显示在胶囊 Text 上。
    expect(find.text(loc.connection_beacon_connecting), findsOneWidget);

    handle.dispose();
  });

  testWidgets('hidden：只渲染占位，没有可见胶囊', (tester) async {
    await _pumpBeacon(tester, const ConnectionBeaconState());

    expect(
      find.byKey(const ValueKey<String>('connection-beacon-hidden')),
      findsOneWidget,
    );
    expect(_dot, findsNothing);
    expect(_ring, findsNothing);
    expect(find.byType(MusicFlowSurface), findsNothing);
  });
}
