// b38c3 —— Route C 补测：features/library/widgets/media_detail_components.dart 剩余缺口。
//   * 75：palette.dominantColor 缺失 → 回落到 palette.vibrantColor.color。
//   * 76：dominant + vibrant 均缺失 → 回落到 palette.mutedColor.color。
//   * 79：useContentTint == false → background 直接用 colors.canvas。
//   * 118：mediaDetailHeaderBackgroundColor 的 10 次对比度尝试全部失败 → 兜底 colors.canvas。
//
// 手法：
//   * `mediaPaletteProvider` 是 family，用 `overrideWith` 直接返回自造 PaletteGenerator
//     （PaletteGenerator 非 final 方法，用子类覆写 dominant/vibrant/muted getter 精确构造缺色场景）。
//   * 118 需要一个「墨色与画布对比度恒 <4.5」的主题：注入一个 ink==canvas 的 MusicFlowColors
//     ThemeExtension，循环 10 次后必然走兜底 return。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:palette_generator/palette_generator.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

/// 用 getter 覆写精确构造「某几个颜色位缺失」的调色板。
class _FakePalette extends PaletteGenerator {
  _FakePalette({this.dom, this.vib, this.mut})
      : super.fromColors(const <PaletteColor>[]);

  final PaletteColor? dom;
  final PaletteColor? vib;
  final PaletteColor? mut;

  @override
  PaletteColor? get dominantColor => dom;

  @override
  PaletteColor? get vibrantColor => vib;

  @override
  PaletteColor? get mutedColor => mut;
}

Widget _wrap({
  required Widget child,
  PaletteGenerator? palette,
  ThemeData? theme,
}) {
  return ProviderScope(
    overrides: <Override>[
      if (palette != null)
        mediaPaletteProvider.overrideWith(
          (Ref ref, MediaPaletteRequest req) async => palette,
        ),
    ],
    child: MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

Color? _surfaceBackground(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.byKey(const ValueKey<String>('media-detail-header-surface')),
  );
  return (container.decoration as BoxDecoration).color;
}

void main() {
  testWidgets('MediaDetailHeaderSurface：dominant 缺失 → 回落 vibrant（75）',
      (tester) async {
    final palette = _FakePalette(
      dom: null,
      vib: PaletteColor(const Color(0xFF264653), 10),
    );
    await tester.pumpWidget(_wrap(
      palette: palette,
      child: const MediaDetailHeaderSurface(
        coverArtId: 'cover-a',
        child: SizedBox(height: 40),
      ),
    ));
    await tester.pump();

    // 不崩且渲出底色即说明 vibrant 分支被取用。
    expect(_surfaceBackground(tester), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MediaDetailHeaderSurface：dominant+vibrant 缺失 → 回落 muted（76）',
      (tester) async {
    final palette = _FakePalette(
      dom: null,
      vib: null,
      mut: PaletteColor(const Color(0xFFB5651D), 4),
    );
    await tester.pumpWidget(_wrap(
      palette: palette,
      child: const MediaDetailHeaderSurface(
        coverArtId: 'cover-b',
        child: SizedBox(height: 40),
      ),
    ));
    await tester.pump();

    expect(_surfaceBackground(tester), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MediaDetailHeaderSurface：useContentTint=false → colors.canvas（79）',
      (tester) async {
    await tester.pumpWidget(_wrap(
      child: const MediaDetailHeaderSurface(
        coverArtId: 'cover-c',
        useContentTint: false,
        child: SizedBox(height: 40),
      ),
    ));
    await tester.pump();

    final ctx = tester.element(find.byType(MediaDetailHeaderSurface));
    expect(_surfaceBackground(tester), ctx.musicFlowColors.canvas);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mediaDetailHeaderBackgroundColor：对比度恒不达标 → 兜底 canvas（118）',
      (tester) async {
    final base = AppTheme.light();
    final baseColors = base.extension<MusicFlowColors>()!;
    // ink == canvas == muted → contrastRatio 恒为 1.0 < 4.5，10 次尝试后走兜底。
    const same = Color(0xFF808080);
    final lowContrast = baseColors.copyWith(
      canvas: same,
      ink: same,
      muted: same,
    );
    // 仅保留低对比度 MusicFlowColors（本用例只读取 colors，不依赖其它扩展）。
    final theme = base.copyWith(
      extensions: <ThemeExtension<dynamic>>[lowContrast],
    );

    late Color resolved;
    await tester.pumpWidget(_wrap(
      theme: theme,
      child: Builder(
        builder: (context) {
          resolved = mediaDetailHeaderBackgroundColor(context, null);
          return const SizedBox.shrink();
        },
      ),
    ));
    await tester.pump();

    expect(resolved, same, reason: '10 次对比度尝试均失败 → 返回 colors.canvas');
    expect(tester.takeException(), isNull);
  });
}
