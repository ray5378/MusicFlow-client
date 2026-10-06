// b38b3 —— 设计令牌 `copyWith()` 缺省参数回退补测。
//
// 230 lcov 未覆盖（每文件 1 行）：各 ThemeExtension 的 `copyWith` 里
// `param ?? this.param` 的**回退分支**（此前用例都传了显式值，RHS 未被求值）：
//   music_flow_spacing.dart:50     (md ?? this.md)
//   music_flow_radii.dart:39       (control ?? this.control)
//   music_flow_motion.dart:50      (feedback ?? this.feedback)
//   music_flow_interaction.dart:63 (minimumTouchTarget ?? this.minimumTouchTarget)
//   music_flow_breakpoints.dart:44 (medium ?? this.medium)
//   music_flow_typography.dart:96  (title ?? this.title)
//
// 用「无参 copyWith()」一次性求值全部回退分支，并断言回退值与原值一致。
// 产品代码零改动；只读 lib。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/tokens/music_flow_breakpoints.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_colors.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_interaction.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_motion.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_radii.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_spacing.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_typography.dart';

void main() {
  test('MusicFlowSpacing.copyWith() 无参：全部回退到原值', () {
    const s = MusicFlowSpacing.standard;
    final c = s.copyWith();
    expect(c.xxs, s.xxs);
    expect(c.md, s.md);
    expect(c.xxl, s.xxl);
  });

  test('MusicFlowSpacing.copyWith() 部分覆盖：其余回退', () {
    const s = MusicFlowSpacing.standard;
    final c = s.copyWith(md: 999);
    expect(c.md, 999);
    expect(c.xxs, s.xxs, reason: '未传入的字段应回退到原值');
  });

  test('MusicFlowRadii.copyWith() 无参：全部回退到原值', () {
    const r = MusicFlowRadii.standard;
    final c = r.copyWith();
    expect(c.detail, r.detail);
    expect(c.control, r.control);
    expect(c.pill, r.pill);
  });

  test('MusicFlowMotion.copyWith() 无参：全部回退到原值', () {
    const m = MusicFlowMotion.standard;
    final c = m.copyWith();
    expect(c.feedback, m.feedback);
    expect(c.state, m.state);
    expect(c.scene, m.scene);
    expect(c.easeOut, m.easeOut);
    expect(c.sceneCurve, m.sceneCurve);
  });

  test('MusicFlowInteraction.copyWith() 无参：全部回退到原值', () {
    const i = MusicFlowInteraction.standard;
    final c = i.copyWith();
    expect(c.minimumTouchTarget, i.minimumTouchTarget);
    expect(c.buttonHeight, i.buttonHeight);
    expect(c.disabledOpacity, i.disabledOpacity);
  });

  test('MusicFlowBreakpoints.copyWith() 无参：全部回退到原值', () {
    const b = MusicFlowBreakpoints.standard;
    final c = b.copyWith();
    expect(c.medium, b.medium);
    expect(c.expanded, b.expanded);
    expect(c.maxContentWidth, b.maxContentWidth);
  });

  test('MusicFlowTypography.copyWith() 无参：全部回退到原值', () {
    final t = MusicFlowTypography.standard(MusicFlowColors.light());
    final c = t.copyWith();
    expect(c.display, t.display);
    expect(c.headline, t.headline);
    expect(c.title, t.title);
    expect(c.body, t.body);
    expect(c.label, t.label);
    expect(c.metadata, t.metadata);
  });
}
