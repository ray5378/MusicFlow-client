// b38b3 —— Route B：设计令牌（tokens）与 MusicFlowDesignContext 剩余缺口补测。
//
// 覆盖 lcov 显示仍未命中的行：
//   * MusicFlowSpacing.copyWith / lerp
//   * MusicFlowRadii.copyWith(control 默认分支) / lerp
//   * MusicFlowMotion.copyWith
//   * MusicFlowInteraction.copyWith
//   * MusicFlowBreakpoints.copyWith(medium 默认分支)
//   * MusicFlowTypography.copyWith(title 默认分支)
//   * MusicFlowColors._flatten(半透明色) 与 copyWith(accent 默认分支)
//   * MusicFlowDesignContext.musicFlowColors 的暗色回退分支
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_breakpoints.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_colors.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_interaction.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_motion.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_radii.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_spacing.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_typography.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MusicFlowSpacing', () {
    test('copyWith 全量 / 缺省 与 lerp', () {
      const s = MusicFlowSpacing.standard;
      final full = s.copyWith(
        xxs: 1,
        xs: 2,
        sm: 3,
        md: 4,
        lg: 5,
        xl: 6,
        xxl: 7,
      );
      expect(
        <double>[full.xxs, full.xs, full.sm, full.md, full.lg, full.xl, full.xxl],
        <double>[1, 2, 3, 4, 5, 6, 7],
      );

      final partial = s.copyWith(md: 99);
      expect(partial.md, 99);
      expect(partial.lg, s.lg, reason: '未提供的字段应保留原值');

      final lerped = s.lerp(
        const MusicFlowSpacing(xxs: 1, xs: 1, sm: 1, md: 1, lg: 1, xl: 1, xxl: 1),
        0.5,
      );
      expect(lerped.xxs, closeTo(2.5, 1e-9));
      expect(identical(s.lerp(null, 0.5), s), isTrue, reason: 'other 为 null 时返回自身');
    });
  });

  group('MusicFlowRadii', () {
    test('copyWith 与 lerp', () {
      const r = MusicFlowRadii.standard;
      final full = r.copyWith(
        detail: BorderRadius.zero,
        control: BorderRadius.zero,
        surface: BorderRadius.zero,
        scene: BorderRadius.zero,
        pill: BorderRadius.zero,
      );
      expect(full.control, BorderRadius.zero);

      final partial = r.copyWith(control: BorderRadius.circular(3));
      expect(partial.control, BorderRadius.circular(3));
      expect(partial.scene, r.scene);

      final lerped = r.lerp(r, 0.5);
      expect(lerped.pill, r.pill);
      expect(identical(r.lerp(null, 0.5), r), isTrue);
    });
  });

  group('MusicFlowMotion', () {
    test('copyWith 与 lerp', () {
      const m = MusicFlowMotion.standard;
      expect(m.copyWith().feedback, m.feedback);

      final full = m.copyWith(
        feedback: Duration.zero,
        state: Duration.zero,
        scene: Duration.zero,
        easeOut: Curves.linear,
        sceneCurve: Curves.linear,
      );
      expect(full.feedback, Duration.zero);
      expect(full.easeOut, Curves.linear);

      final lerped = m.lerp(
        const MusicFlowMotion(
          feedback: Duration(milliseconds: 100),
          state: Duration(milliseconds: 100),
          scene: Duration(milliseconds: 100),
          easeOut: Curves.linear,
          sceneCurve: Curves.linear,
        ),
        0.5,
      );
      expect(lerped.feedback.inMilliseconds, 130);
      expect(identical(m.lerp(null, 0.5), m), isTrue);
    });
  });

  group('MusicFlowInteraction', () {
    test('copyWith 与 lerp + minimumTouchSize', () {
      const i = MusicFlowInteraction.standard;
      expect(i.copyWith().minimumTouchTarget, i.minimumTouchTarget);
      expect(i.minimumTouchSize, Size.square(i.minimumTouchTarget));

      final partial = i.copyWith(buttonHeight: 40);
      expect(partial.buttonHeight, 40);
      expect(partial.inputHeight, i.inputHeight);

      final lerped = i.lerp(i, 0.25);
      expect(lerped.pressedScale, i.pressedScale);
      expect(identical(i.lerp(null, 0.5), i), isTrue);
    });
  });

  group('MusicFlowBreakpoints', () {
    test('copyWith 与 classify 边界', () {
      const b = MusicFlowBreakpoints.standard;
      expect(b.copyWith().medium, b.medium);

      final partial = b.copyWith(medium: 111);
      expect(partial.medium, 111);
      expect(partial.expanded, b.expanded);

      expect(b.classify(0), MusicFlowWindowClass.compact);
      expect(b.classify(b.medium), MusicFlowWindowClass.medium);
      expect(b.classify(b.expanded), MusicFlowWindowClass.expanded);

      final lerped = b.lerp(b, 0.5);
      expect(lerped.maxContentWidth, b.maxContentWidth);
      expect(identical(b.lerp(null, 0.5), b), isTrue);
    });
  });

  group('MusicFlowTypography', () {
    test('copyWith 与 lerp', () {
      final colors = MusicFlowColors.light();
      final t = MusicFlowTypography.standard(colors);
      expect(t.copyWith().title.fontSize, t.title.fontSize);

      final partial = t.copyWith(title: const TextStyle(fontSize: 99));
      expect(partial.title.fontSize, 99);
      expect(partial.body.fontSize, t.body.fontSize);

      final lerped = t.lerp(t, 0.5);
      expect(lerped.display.fontSize, t.display.fontSize);
      expect(identical(t.lerp(null, 0.5), t), isTrue);
      expect(MusicFlowTypography.fontFamily, 'HarmonyOS Sans SC');
    });
  });

  group('MusicFlowColors', () {
    test('light/dark 构造与 copyWith(accent)', () {
      final light = MusicFlowColors.light();
      final dark = MusicFlowColors.dark(accent: const Color(0xFF102030));
      expect(light.canvas, MusicFlowColors.dayCanvas);
      expect(dark.canvas, MusicFlowColors.nightCanvas);

      final recolored = light.copyWith(accent: const Color(0xFF123456));
      expect(recolored.accent, const Color(0xFF123456));
      // 覆盖 copyWith 中 accent 的 `?? this.accent` 默认分支。
      expect(light.copyWith().accent, light.accent);

      final lerped = light.lerp(dark, 0.5);
      expect(lerped.canvas, isNotNull);
      expect(identical(light.lerp(null, 0.5), light), isTrue);
    });

    test('_flatten 对半透明前景做合成（WCAG 助手）', () {
      // 半透明色 → 触发 _flatten 的 Color.alphaBlend 分支。
      final ratio = MusicFlowColors.contrastRatio(
        const Color(0x80FFFFFF),
        Colors.black,
      );
      expect(ratio, greaterThan(1));

      expect(
        MusicFlowColors.readableOn(const Color(0xFFFFFFFF)),
        Colors.black,
      );
      expect(
        MusicFlowColors.ensureColorContrast(
          Colors.white,
          background: Colors.white,
          minimumRatio: 4.5,
        ),
        isNot(Colors.white),
        reason: '白底白字不可读，应被调整',
      );
      expect(
        MusicFlowColors.ensureColorContrastAcross(
          light_error,
          backgrounds: const <Color>[Colors.white, Colors.black],
        ),
        isNotNull,
      );
      expect(
        MusicFlowColors.ensureForegroundContrast(
          Colors.white,
          foreground: Colors.black,
        ),
        isNotNull,
      );
    });
  });

  group('MusicFlowDesignContext', () {
    testWidgets('缺少扩展时按亮/暗主题回退到 light/dark 调色板', (tester) async {
      late MusicFlowColors resolved;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: ThemeData(brightness: Brightness.dark),
            child: Builder(
              builder: (context) {
                resolved = context.musicFlowColors;
                // 同时驱动其余扩展的回退 getter。
                context.musicFlowTypography;
                context.musicFlowSpacing;
                context.musicFlowRadii;
                context.musicFlowMotion;
                context.musicFlowInteraction;
                context.musicFlowBreakpoints;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(resolved.ink, MusicFlowColors.dark().ink, reason: '暗色主题回退到 dark()');

      late MusicFlowColors lightResolved;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: ThemeData(brightness: Brightness.light),
            child: Builder(
              builder: (context) {
                lightResolved = context.musicFlowColors;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(lightResolved.ink, MusicFlowColors.light().ink);
    });

    testWidgets('musicFlowWindowClass / 页面水平内边距随宽度分类', (tester) async {
      late MusicFlowWindowClass klass;
      late double pad;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                klass = context.musicFlowWindowClass;
                pad = context.musicFlowPageHorizontalPadding;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(klass, MusicFlowWindowClass.compact);
      expect(pad, MusicFlowSpacing.standard.md);
    });
  });
}

// ignore: constant_identifier_names
const Color light_error = Color(0xFFB84B48);
