import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_pressable.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// Windows 桌面端右上角的系统窗口控制区（最小化/最大化/关闭）。
///
/// 该区域由 [WindowsWindowChrome] 覆盖在内容之上，页面自己的任何可点击
/// 控件一旦进入这个矩形，就会出现「自定义按钮和系统关闭按钮重叠」的问题。
Rect windowsWindowControlRect(
  double viewportWidth, {
  double chromeHeight = kWindowsWindowControlsHeight,
}) {
  return Rect.fromLTWH(
    viewportWidth - kWindowsWindowControlsWidth,
    0,
    kWindowsWindowControlsWidth,
    chromeHeight,
  );
}

/// 断言当前页面没有任何可点击控件侵入 Windows 右上角系统窗口控制区。
///
/// 用法：在 `debugDefaultTargetPlatformOverride = TargetPlatform.windows`
/// 渲染完页面后调用。已经排除 [WindowsWindowChrome] 自身的三个按钮，
/// 因此可以在完整 app（含 MainScaffold）上直接使用。
void expectNoWindowsWindowControlOverlap(
  WidgetTester tester, {
  required double viewportWidth,
  double chromeHeight = kWindowsWindowControlsHeight,
}) {
  final zone = windowsWindowControlRect(
    viewportWidth,
    chromeHeight: chromeHeight,
  );
  final offenders = <String>[];

  final clickableFinders = <Finder>[
    find.byType(MusicFlowPressable),
    find.byType(IconButton),
    find.byType(TextButton),
    find.byType(FilledButton),
    find.byType(OutlinedButton),
    find.byType(ElevatedButton),
    find.byType(InkWell),
    find.byType(InkResponse),
  ];

  for (final finder in clickableFinders) {
    for (final element in finder.evaluate()) {
      final key = element.widget.key;
      if (key is ValueKey<String> &&
          key.value.startsWith(kWindowControlButtonKeyPrefix)) {
        continue; // 系统窗口按钮本身不算侵入。
      }
      final rect = tester.getRect(find.byWidget(element.widget));
      final overlaps =
          rect.right > zone.left &&
          rect.left < zone.right &&
          rect.bottom > zone.top &&
          rect.top < zone.bottom;
      if (overlaps) {
        offenders.add(
          '${element.widget.runtimeType}($rect) 侵入 $zone',
        );
      }
    }
  }

  expect(
    offenders,
    isEmpty,
    reason: 'Windows 无自绘标题栏，右上角 ${zone.width}×${zone.height} 区域'
        '被系统窗口控制按钮占用，页面控件不得进入：\n${offenders.join('\n')}',
  );
}
