// b36c —— `lib/core/design/media/music_flow_media_visuals.dart` 补测（原 28 miss）。
//
// 纯 Dart 取色管线：覆盖 fromPalette 的空/单色/亮色/暗色/低饱和/极端明度
// 调色板分支、fallback 工厂、ensureAccentContrast / lyricAccentFor 对比度
// 收敛，以及核心不变量（所有面板不透明；正文 ≥4.5:1；强调色 ≥3:1）。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:palette_generator/palette_generator.dart';

import 'package:musicflow_client/core/design/media/music_flow_media_visuals.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_colors.dart';

PaletteColor _pc(int argb, int population) =>
    PaletteColor(Color(argb), population);

PaletteGenerator _palette(List<PaletteColor> colors) =>
    PaletteGenerator.fromColors(colors, targets: PaletteTarget.baseTargets);

List<Color> _surfaces(MusicFlowMediaVisuals v) => <Color>[
      v.stageBase,
      v.stageGlow,
      v.stageBottom,
      v.miniSurface,
      v.panelSurface,
    ];

void _expectOpaque(MusicFlowMediaVisuals v) {
  for (final c in <Color>[
    v.stageBase,
    v.stageGlow,
    v.stageBottom,
    v.foreground,
    v.mutedForeground,
    v.controlAccent,
    v.miniSurface,
    v.panelSurface,
  ]) {
    expect(c.a, 1.0);
  }
}

void _expectReadable(MusicFlowMediaVisuals v) {
  for (final s in _surfaces(v)) {
    expect(
      MusicFlowColors.contrastRatio(v.foreground, s),
      greaterThanOrEqualTo(4.5 - 0.001),
      reason: '正文应 ≥4.5:1',
    );
    expect(
      MusicFlowColors.contrastRatio(v.mutedForeground, s),
      greaterThanOrEqualTo(4.5 - 0.001),
      reason: '次要正文应 ≥4.5:1',
    );
    expect(
      MusicFlowColors.contrastRatio(v.controlAccent, s),
      greaterThanOrEqualTo(3 - 0.001),
      reason: '强调色应 ≥3:1',
    );
  }
}

void main() {
  group('fromPalette 空/缺失调色板', () {
    test('null 调色板回落到稳定内容底色', () {
      final v = MusicFlowMediaVisuals.fromPalette(null);
      _expectOpaque(v);
      _expectReadable(v);
      expect(v, MusicFlowMediaVisuals.fallback());
    });

    test('空调色板等同于 null', () {
      final v = MusicFlowMediaVisuals.fromPalette(
        PaletteGenerator.fromColors(<PaletteColor>[]),
      );
      _expectOpaque(v);
      _expectReadable(v);
      expect(v, MusicFlowMediaVisuals.fallback());
    });

    test('自定义 fallbackSeed 生效且与默认不同', () {
      final custom = MusicFlowMediaVisuals.fallback(seed: const Color(0xFF00AAFF));
      final dflt = MusicFlowMediaVisuals.fallback();
      expect(custom == dflt, isFalse);
      expect(custom.hashCode == dflt.hashCode, isFalse);
    });
  });

  group('fromPalette 单色 / 亮色 / 暗色', () {
    test('单色（无 vibrant/muted 目标可选）仍稳定可读', () {
      final v = MusicFlowMediaVisuals.fromPalette(
        _palette(<PaletteColor>[_pc(0xFF336699, 100)]),
      );
      _expectOpaque(v);
      _expectReadable(v);
    });

    test('明亮的饱和调色板：前景为深色墨、面板可读', () {
      final v = MusicFlowMediaVisuals.fromPalette(
        _palette(<PaletteColor>[
          _pc(0xFFFFEB3B, 120),
          _pc(0xFFFF9800, 90),
          _pc(0xFFFFFFFF, 60),
          _pc(0xFFE91E63, 40),
        ]),
      );
      _expectOpaque(v);
      _expectReadable(v);
    });

    test('暗色调色板：前景自动转为浅色墨', () {
      final v = MusicFlowMediaVisuals.fromPalette(
        _palette(<PaletteColor>[
          _pc(0xFF101318, 120),
          _pc(0xFF1B1F27, 80),
          _pc(0xFF2A2F3A, 50),
          _pc(0xFF0A0C10, 30),
        ]),
      );
      _expectOpaque(v);
      _expectReadable(v);
      // 暗底 → 前景应偏亮。
      expect(v.foreground.computeLuminance() > 0.5, isTrue);
    });

    test('低饱和 / 中等明度的“灰调”调色板：去模糊带后仍可读', () {
      final v = MusicFlowMediaVisuals.fromPalette(
        _palette(<PaletteColor>[
          _pc(0xFF6F6B70, 100),
          _pc(0xFF7A767B, 60),
          _pc(0xFF646066, 40),
        ]),
      );
      _expectOpaque(v);
      _expectReadable(v);
    });

    test('极端明度（近黑近白混色）不溢出、不抛', () {
      final v = MusicFlowMediaVisuals.fromPalette(
        _palette(<PaletteColor>[
          _pc(0xFF000000, 100),
          _pc(0xFFFFFFFF, 90),
        ]),
      );
      _expectOpaque(v);
      _expectReadable(v);
    });
  });

  group('ensureAccentContrast / lyricAccentFor', () {
    test('候选色已达标时原样返回', () {
      const candidate = Color(0xFFFFC233);
      final result = MusicFlowMediaVisuals.ensureAccentContrast(
        candidate,
        target: const Color(0xFF101316),
        backgrounds: const <Color>[Color(0xFF0A0C10)],
      );
      expect(result, candidate);
    });

    test('候选色不达标时向 target 收敛直到通过', () {
      const candidate = Color(0xFFFFF59D);
      const target = Color(0xFF101316);
      const background = Color(0xFFF5F5F5);
      final result = MusicFlowMediaVisuals.ensureAccentContrast(
        candidate,
        target: target,
        backgrounds: const <Color>[background],
        minimumRatio: 4.5,
      );
      expect(
        MusicFlowColors.contrastRatio(result, background),
        greaterThanOrEqualTo(4.5 - 0.001),
      );
    });

    test('warmLyricYellow 基线常量固定', () {
      expect(MusicFlowMediaVisuals.warmLyricYellow, const Color(0xFFFFC233));
    });

    test('lyricAccentFor 在暗底保持纯黄、亮底加深', () {
      final dark = MusicFlowMediaVisuals.fallback(seed: const Color(0xFF0A0C10));
      final darkAccent = MusicFlowMediaVisuals.lyricAccentFor(
        dark,
        backgrounds: <Color>[dark.stageBase, dark.stageBottom],
      );
      expect(darkAccent, MusicFlowMediaVisuals.warmLyricYellow);

      final light = MusicFlowMediaVisuals.fallback(seed: const Color(0xFFF7F9FA));
      final lightAccent = MusicFlowMediaVisuals.lyricAccentFor(
        light,
        backgrounds: <Color>[light.stageBase, light.stageBottom],
      );
      expect(
        MusicFlowColors.contrastRatio(lightAccent, light.stageBase),
        greaterThanOrEqualTo(4.5 - 0.001),
      );
    });
  });

  group('相等性与 hashCode', () {
    test('相同输入产生相等对象', () {
      final a = MusicFlowMediaVisuals.fallback(seed: const Color(0xFF556F60));
      final b = MusicFlowMediaVisuals.fallback(seed: const Color(0xFF556F60));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('与不同类型不相等', () {
      final a = MusicFlowMediaVisuals.fallback();
      expect(a == Object(), isFalse);
    });
  });
}
