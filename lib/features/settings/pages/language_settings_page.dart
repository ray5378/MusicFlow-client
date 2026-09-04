import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/locale_provider.dart';
import '../widgets/music_flow_settings_components.dart';

/// 界面语言设置页：跟随系统 / 中文 / English 单选。
class LanguageSettingsPage extends ConsumerWidget {
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(appLanguageProvider);
    final notifier = ref.read(appLanguageProvider.notifier);
    final loc = AppLocalizations.of(context);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: loc.settings_language),
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
                title: loc.settings_language,
                description: loc.settings_language_caption,
                children: <Widget>[
                  MusicFlowChoiceRow(
                    title: loc.language_follow_system,
                    description: loc.language_follow_system_desc,
                    selected: preferences.preference == AppLanguagePreference.system,
                    onPressed: () => notifier.setPreference(AppLanguagePreference.system),
                    icon: AppIcons.settings,
                  ),
                  MusicFlowChoiceRow(
                    title: loc.language_zh,
                    description: loc.language_zh_desc,
                    selected: preferences.preference == AppLanguagePreference.zh,
                    onPressed: () => notifier.setPreference(AppLanguagePreference.zh),
                    icon: AppIcons.settings,
                  ),
                  MusicFlowChoiceRow(
                    title: loc.language_en,
                    description: loc.language_en_desc,
                    selected: preferences.preference == AppLanguagePreference.en,
                    onPressed: () => notifier.setPreference(AppLanguagePreference.en),
                    icon: AppIcons.settings,
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