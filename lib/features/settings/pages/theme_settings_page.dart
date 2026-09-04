import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/theme/color_scheme.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/theme_provider.dart';
import '../widgets/music_flow_settings_components.dart';

class ThemeSettingsPage extends ConsumerWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(themeSettingsProvider);
    final notifier = ref.read(themeSettingsProvider.notifier);
    final loc = AppLocalizations.of(context);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: loc.settings_theme),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.sm,
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
            ),
            children: <Widget>[
              MusicFlowSettingsSection(
                title: loc.settings_theme_appearance,
                description: loc.settings_theme_appearance_desc,
                children: <Widget>[
                  MusicFlowChoiceRow(
                    title: loc.settings_theme_follow_system,
                    description: loc.settings_theme_follow_system_desc,
                    selected: settings.mode == ThemeMode.system,
                    onPressed: () => notifier.setThemeMode(ThemeMode.system),
                    icon: AppIcons.settings,
                  ),
                  MusicFlowChoiceRow(
                    title: loc.settings_theme_light,
                    description: loc.settings_theme_light_desc,
                    selected: settings.mode == ThemeMode.light,
                    onPressed: () => notifier.setThemeMode(ThemeMode.light),
                    icon: AppIcons.image,
                  ),
                  MusicFlowChoiceRow(
                    title: loc.settings_theme_dark,
                    description: loc.settings_theme_dark_desc,
                    selected: settings.mode == ThemeMode.dark,
                    onPressed: () => notifier.setThemeMode(ThemeMode.dark),
                    icon: AppIcons.album,
                  ),
                ],
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: loc.settings_theme_accent,
                description: loc.settings_theme_accent_desc,
                children: <Widget>[
                  MusicFlowSurface(
                    level: MusicFlowSurfaceLevel.raised,
                    borderColor: context.musicFlowColors.controlBoundary,
                    padding: EdgeInsets.all(context.musicFlowSpacing.md),
                    child: Row(
                      children: <Widget>[
                        _ColorSwatch(color: settings.seedColor, size: 48),
                        SizedBox(width: context.musicFlowSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                loc.settings_theme_current_accent,
                                style: context.musicFlowTypography.label,
                              ),
                              SizedBox(height: context.musicFlowSpacing.xxs),
                              Text(
                                _toHex(settings.seedColor),
                                style: context.musicFlowTypography.body.copyWith(
                                  color: context.musicFlowColors.muted,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: context.musicFlowSpacing.md),
                  Wrap(
                    spacing: context.musicFlowSpacing.xs,
                    runSpacing: context.musicFlowSpacing.xs,
                    children: <Widget>[
                      for (final color in _presetColors)
                        _PresetColorButton(
                          color: color,
                          selected:
                              settings.seedColor.toARGB32() == color.toARGB32(),
                          onPressed: () => notifier.setSeedColor(color),
                        ),
                    ],
                  ),
                  SizedBox(height: context.musicFlowSpacing.md),
                  Wrap(
                    spacing: context.musicFlowSpacing.sm,
                    runSpacing: context.musicFlowSpacing.sm,
                    children: <Widget>[
                      MusicFlowButton.primary(
                        label: loc.settings_theme_fine_tune,
                        leadingIcon: AppIcons.palette,
                        onPressed: () =>
                            _openColorPicker(context, ref, settings.seedColor),
                      ),
                      MusicFlowButton.secondary(
                        label: loc.settings_theme_reset_default,
                        onPressed: notifier.resetSeedColor,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openColorPicker(
    BuildContext context,
    WidgetRef ref,
    Color initialColor,
  ) async {
    final selected = await showMusicFlowBottomSheet<Color>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => _ColorPickerSheet(initialColor: initialColor),
    );
    if (selected != null) {
      ref.read(themeSettingsProvider.notifier).setSeedColor(selected);
    }
  }
}

const List<Color> _presetColors = <Color>[
  AppColorScheme.defaultSeedColor,
  MusicFlowColors.legacyGreenAccent,
  Color(0xFF3D7188),
  Color(0xFF6B6F9A),
  Color(0xFF8A633D),
  Color(0xFF8B4F53),
  Color(0xFF7A5576),
  Color(0xFF39796F),
  Color(0xFF626A72),
];

class _ColorPickerSheet extends StatefulWidget {
  const _ColorPickerSheet({required this.initialColor});

  final Color initialColor;

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final loc = AppLocalizations.of(context);

    return MusicFlowBottomSheet(
      title: loc.settings_theme_color_picker_title,
      subtitle: loc.settings_theme_color_picker_subtitle,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(child: _ColorSwatch(color: color, size: 72)),
              SizedBox(height: context.musicFlowSpacing.sm),
              Text(
                _toHex(color),
                textAlign: TextAlign.center,
                style: context.musicFlowTypography.title.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.lg),
              _ColorSliderLine(
                label: loc.settings_theme_hue,
                valueLabel: '${_hsv.hue.round()}°',
                value: _hsv.hue,
                min: 0,
                max: 360,
                activeColor: HSVColor.fromAHSV(
                  1,
                  _hsv.hue,
                  0.72,
                  0.78,
                ).toColor(),
                onChanged: (value) =>
                    setState(() => _hsv = _hsv.withHue(value)),
              ),
              _ColorSliderLine(
                label: loc.settings_theme_saturation,
                valueLabel: '${(_hsv.saturation * 100).round()}%',
                value: _hsv.saturation,
                min: 0,
                max: 1,
                activeColor: color,
                onChanged: (value) =>
                    setState(() => _hsv = _hsv.withSaturation(value)),
              ),
              _ColorSliderLine(
                label: loc.settings_theme_brightness,
                valueLabel: '${(_hsv.value * 100).round()}%',
                value: _hsv.value,
                min: 0,
                max: 1,
                activeColor: color,
                onChanged: (value) =>
                    setState(() => _hsv = _hsv.withValue(value)),
              ),
              SizedBox(height: context.musicFlowSpacing.lg),
              Row(
                children: <Widget>[
                  Expanded(
                    child: MusicFlowButton.secondary(
                      label: loc.settings_cancel,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SizedBox(width: context.musicFlowSpacing.sm),
                  Expanded(
                    child: MusicFlowButton.primary(
                      label: loc.settings_theme_apply,
                      onPressed: () => Navigator.of(context).pop(color),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorSliderLine extends StatelessWidget {
  const _ColorSliderLine({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.activeColor,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final Color activeColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.musicFlowSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: context.musicFlowTypography.label)),
              Text(
                valueLabel,
                style: context.musicFlowTypography.metadata.copyWith(
                  color: context.musicFlowColors.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          MusicFlowSlider(
            value: value,
            min: min,
            max: max,
            activeColor: activeColor,
            thumbColor: activeColor,
            semanticLabel: label,
            semanticValue: valueLabel,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _PresetColorButton extends StatelessWidget {
  const _PresetColorButton({
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final hex = _toHex(color);
    final loc = AppLocalizations.of(context);
    return MusicFlowPressable(
      semanticLabel: selected
          ? loc.settings_theme_color_selected(hex)
          : loc.settings_theme_color(hex),
      selected: selected,
      onPressed: onPressed,
      minimumSize: const Size.square(48),
      borderRadius: context.musicFlowRadii.pill,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            _ColorSwatch(color: color, size: 36, selected: selected),
            if (selected)
              Icon(
                AppIcons.check,
                size: 18,
                color: MusicFlowColors.readableOn(color),
              ),
          ],
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.size,
    this.selected = false,
  });

  final Color color;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? context.musicFlowColors.ink
              : context.musicFlowColors.controlBoundary,
          width: selected ? 3 : 1,
        ),
      ),
      child: SizedBox.square(dimension: size),
    );
  }
}

String _toHex(Color color) {
  final value = color
      .toARGB32()
      .toRadixString(16)
      .padLeft(8, '0')
      .toUpperCase();
  return '#${value.substring(2)}';
}