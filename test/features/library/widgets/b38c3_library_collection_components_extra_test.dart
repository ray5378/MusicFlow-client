// b38c3 —— Route C 补测：library_collection_components.dart 剩余缺口。
//   * 329：MusicFlowLibrarySectionLabel 的构造函数（生产里 const 实例化 → 构造行不计命中）。
//   * 439：MusicFlowAzIndexReveal 的 Listener.onPointerCancel → _endPointer()
//          （需先在右缘按下（dx ≥ width-40）置 _pointerActive，再发 PointerCancel）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('MusicFlowLibrarySectionLabel 非 const 实例化（构造行 329）', (tester) async {
    final label = 'A-F ${DateTime.now().microsecond % 9}';
    await tester.pumpWidget(_host(MusicFlowLibrarySectionLabel(label: label)));
    await settle(tester);

    expect(find.byType(MusicFlowLibrarySectionLabel), findsOneWidget);
    expect(find.text(label), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AzIndexReveal 右缘按下后指针取消 → onPointerCancel 走 _endPointer（439）',
      (tester) async {
    final visibles = <bool>[];
    await tester.pumpWidget(_host(SizedBox(
      width: 300,
      height: 300,
      child: MusicFlowAzIndexReveal(
        builder: (BuildContext context, double opacity, bool visible) {
          visibles.add(visible);
          // 需要可命中的渲染对象，否则 Listener(deferToChild) 收不到指针事件。
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          );
        },
      ),
    )));
    await settle(tester);

    // 在右缘 40dp 命中区内按下 → _beginPointer 置 _pointerActive 并 reveal。
    final rect = tester.getRect(find.byType(MusicFlowAzIndexReveal));
    final g = await tester.startGesture(Offset(rect.right - 5, rect.center.dy));
    // 等 reveal 的 TweenAnimationBuilder 淡入完成（linger 1200ms 未到）。
    await settle(tester, frames: 5);
    expect(visibles.isNotEmpty, isTrue);
    expect(visibles.last, isTrue, reason: '右缘按下应 reveal 字母条');

    // 指针取消（非 up）→ 走 onPointerCancel 分支。
    await g.cancel();
    await settle(tester, frames: 3);
    expect(visibles.last, isTrue, reason: '取消后仍保持 reveal（linger 定时器未到）');
    expect(tester.takeException(), isNull);

    // 让 linger 定时器到点，避免 pending Timer。
    await tester.pump(const Duration(milliseconds: 1300));
    await settle(tester);
  });
}
