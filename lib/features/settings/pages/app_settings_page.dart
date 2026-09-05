import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/services/update_checker.dart';
import '../../../core/utils/logger.dart';
import '../../../data/models/music_library.dart';
import '../../../data/models/server_address.dart';
import '../../../data/sources/local_storage.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/crossfade_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/lyrics_dwell_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/status_lyrics_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../providers/locale_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../widgets/windows_title_bar.dart';
import '../widgets/music_flow_settings_components.dart';
import 'audio_quality_page.dart';
import 'offline_cache_page.dart';
import 'cover_providers_page.dart';
import 'lyrics_providers_page.dart';
import 'theme_settings_page.dart';
import 'language_settings_page.dart';
import 'log_viewer_page.dart';

/// 全屏设置页
class AppSettingsPage extends ConsumerStatefulWidget {
  const AppSettingsPage({super.key});

  @override
  ConsumerState<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends ConsumerState<AppSettingsPage> {
  bool _isCheckingUpdate = false;
  bool _autoPlayOnLaunch = false;
  bool _loggingEnabled = false;

  @override
  void initState() {
    super.initState();
    LocalStorage.getAutoPlayOnLaunch().then((value) {
      if (mounted) setState(() => _autoPlayOnLaunch = value);
    });
    // 同步日志开关（默认关闭，需手动开启）到 Logger 全局状态。
    LocalStorage.getLoggingEnabled().then((value) {
      if (mounted) setState(() => _loggingEnabled = value);
      Logger.setLoggingEnabled(value);
    });
  }

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingUpdate = true);

    try {
      final result = await UpdateChecker.check();
      if (!mounted) return;

      if (result.hasUpdate) {
        _showUpdateDialog(result);
      } else {
        final loc = AppLocalizations.of(context);
        _showMessage(
          loc.settings_update_latest(result.currentVersion),
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (error) {
      _showMessage(
        AppLocalizations.of(context).settings_update_check_failed('$error'),
        kind: MusicFlowMessageKind.error,
      );
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    final ctx = context;
    final loc = AppLocalizations.of(ctx);
    final subtitle = loc.settings_update_found;
    final title = '${result.currentVersion} → ${result.latestVersion}';

    if (isWindowsDesktop) {
      // Windows 用「窗户」样式对话框,与安卓底部抽屉区分。
      showMusicFlowDesktopDialog<void>(
        context: ctx,
        useRootNavigator: true,
        builder: (dialogContext) => MusicFlowDesktopDialog(
          icon: AppIcons.download,
          title: subtitle,
          subtitle: title,
          child: _buildUpdateContent(dialogContext, result),
        ),
      );
    } else {
      showMusicFlowBottomSheet<void>(
        context: ctx,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (sheetContext) => MusicFlowBottomSheet(
          title: subtitle,
          subtitle: title,
          constrainToAvailableHeight: true,
          child: SingleChildScrollView(
            child: _buildUpdateContent(sheetContext, result),
          ),
        ),
      );
    }
  }

  Widget _buildUpdateContent(BuildContext ctx, UpdateCheckResult result) {
    final loc = AppLocalizations.of(ctx);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
          _SettingsInfoLine(label: loc.settings_current_version, value: result.currentVersion),
          _SettingsInfoLine(label: loc.settings_latest_version, value: result.latestVersion),
          if (result.releaseNotes != null &&
              result.releaseNotes!.isNotEmpty) ...<Widget>[
            SizedBox(height: ctx.musicFlowSpacing.sm),
            const MusicFlowDivider(),
            SizedBox(height: ctx.musicFlowSpacing.md),
            MusicFlowSectionHeader(title: loc.settings_update_notes),
            SizedBox(height: ctx.musicFlowSpacing.xs),
            Text(
              result.releaseNotes!,
              style: ctx.musicFlowTypography.body.copyWith(
                color: ctx.musicFlowColors.muted,
              ),
            ),
          ],
          if (result.assets.isNotEmpty) ...<Widget>[
            SizedBox(height: ctx.musicFlowSpacing.sm),
            const MusicFlowDivider(),
            SizedBox(height: ctx.musicFlowSpacing.md),
            MusicFlowSectionHeader(
              title: loc.settings_update_assets,
              description: loc.settings_update_assets_desc,
            ),
            SizedBox(height: ctx.musicFlowSpacing.xs),
            for (final asset in result.assets)
              Padding(
                padding: EdgeInsets.only(bottom: ctx.musicFlowSpacing.xs),
                child: MusicFlowActionRow(
                  icon: AppIcons.download,
                  title: asset.name,
                  subtitle:
                      '${(asset.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                  trailing: Icon(
                    AppIcons.chevronRight,
                    size: 20,
                    color: ctx.musicFlowColors.muted,
                  ),
                  onPressed: () =>
                      _confirmOpenDownload(asset.name, asset.downloadUrl),
                ),
              ),
          ],
          SizedBox(height: ctx.musicFlowSpacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: ctx.musicFlowSpacing.xs,
            runSpacing: ctx.musicFlowSpacing.xs,
            children: <Widget>[
              MusicFlowButton.ghost(
                label: loc.settings_later,
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              if (result.releaseUrl != null ||
                  _pickPlatformAsset(result) != null)
                MusicFlowButton.primary(
                  label: loc.settings_download,
                  leadingIcon: AppIcons.download,
                  onPressed: () {
                    final asset = _pickPlatformAsset(result);
                    Navigator.of(ctx).pop();
                    if (asset != null) {
                      _confirmOpenDownload(asset.name, asset.downloadUrl);
                    } else if (result.releaseUrl != null) {
                      _confirmOpenDownload(
                        loc.settings_update_package(result.latestVersion),
                        result.releaseUrl!,
                      );
                    }
                  },
                ),
            ],
          ),
        ],
    );
  }

  /// 挑选适合当前平台的下载文件：Android 优先 apk，其余平台优先 zip（windows）。
  ReleaseAsset? _pickPlatformAsset(UpdateCheckResult result) {
    if (result.assets.isEmpty) return null;
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final preferred = isAndroid ? '.apk' : '.zip';
    for (final asset in result.assets) {
      if (asset.name.toLowerCase().contains(preferred)) return asset;
    }
    return result.assets.first;
  }

  /// 弹出确认后跳转浏览器下载，由用户自行解压/安装完成更新。
  /// Windows 用「窗户」样式对话框,安卓保持底部抽屉。
  Future<void> _confirmOpenDownload(String label, String url) async {
    final ctx = context;
    final loc = AppLocalizations.of(ctx);
    final bool confirmed;
    if (isWindowsDesktop) {
      confirmed = (await showMusicFlowDesktopDialog<bool>(
        context: ctx,
        useRootNavigator: true,
        builder: (dialogContext) => MusicFlowDesktopDialog(
          icon: AppIcons.download,
          title: loc.settings_download,
          subtitle: label,
          child: _buildConfirmContent(dialogContext),
        ),
      )) ??
          false;
    } else {
      confirmed = (await showMusicFlowBottomSheet<bool>(
        context: ctx,
        useRootNavigator: true,
        builder: (sheetContext) => MusicFlowBottomSheet(
          title: loc.settings_download,
          subtitle: label,
          child: _buildConfirmContent(sheetContext),
        ),
      )) ??
          false;
    }
    if (confirmed) {
      await _openUrl(url);
    }
  }

  Widget _buildConfirmContent(BuildContext ctx) {
    final loc = AppLocalizations.of(ctx);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          loc.settings_download_confirm_body,
          style: ctx.musicFlowTypography.body.copyWith(
            color: ctx.musicFlowColors.muted,
          ),
        ),
        SizedBox(height: ctx.musicFlowSpacing.lg),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: ctx.musicFlowSpacing.xs,
          runSpacing: ctx.musicFlowSpacing.xs,
          children: <Widget>[
            MusicFlowButton.ghost(
              label: loc.settings_cancel,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            MusicFlowButton.primary(
              label: loc.settings_download,
              leadingIcon: AppIcons.download,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showMessage(
    String message, {
    MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  }) {
    if (!mounted) return;
    showMusicFlowMessage(context, message, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final library = authState.currentLibrary;
    final librariesAsync = ref.watch(librariesProvider);
    final activeAddress = ref.watch(activeAddressProvider);
    final autoFallback = ref.watch(autoFallbackProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final languageSettings = ref.watch(appLanguageProvider);
    final crossfadeMs = ref.watch(crossfadeDurationMsProvider);
    final lyricsDwellSeconds = ref.watch(lyricsScrollDwellProvider);
    final statusLyricsEnabled = ref.watch(statusLyricsEnabledProvider);
    final availableLibraries = librariesAsync.valueOrNull;
    final loc = AppLocalizations.of(context);
    final switchDescription = librariesAsync.when(
      data: (libraries) => libraries.length > 1
          ? loc.settings_library_count_saved(libraries.length)
          : libraries.isEmpty
          ? loc.settings_library_empty
          : loc.settings_library_single,
      loading: () => loc.settings_library_loading,
      error: (error, stackTrace) => loc.settings_library_load_failed,
    );

    final VoidCallback? switchLibraryAction;
    if (availableLibraries != null && availableLibraries.isNotEmpty) {
      switchLibraryAction = () =>
          _showLibrarySheet(availableLibraries, library);
    } else if (librariesAsync.hasError) {
      switchLibraryAction = () => ref.invalidate(librariesProvider);
    } else {
      switchLibraryAction = null;
    }

    final Widget switchLibraryTrailing;
    if (librariesAsync.isLoading) {
      switchLibraryTrailing = const MusicFlowSkeleton.circle(size: 20);
    } else if (librariesAsync.hasError) {
      switchLibraryTrailing = Icon(
        AppIcons.refresh,
        size: 20,
        color: context.musicFlowColors.error,
      );
    } else {
      switchLibraryTrailing = Icon(
        AppIcons.chevronDown,
        size: 20,
        color: context.musicFlowColors.muted,
      );
    }

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: loc.settings_title),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.sm,
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
            ),
            children: <Widget>[
              MusicFlowSettingsSection(
                title: loc.settings_library_section,
                description: loc.settings_library_section_desc,
                children: <Widget>[
                  _ServerSummary(
                    library: library,
                    activeAddress: activeAddress,
                  ),
                  SizedBox(height: context.musicFlowSpacing.sm),
                  MusicFlowSettingRow(
                    icon: AppIcons.library,
                    title: loc.settings_switch_library,
                    value: library?.name ?? loc.settings_not_selected,
                    description: switchDescription,
                    trailing: switchLibraryTrailing,
                    onPressed: switchLibraryAction,
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.edit,
                    title: loc.settings_edit_library,
                    value: library?.name ?? loc.settings_not_selected,
                    description: library == null
                        ? loc.settings_edit_library_empty_desc
                        : loc.settings_edit_library_desc,
                    onPressed: library == null
                        ? null
                        : () => context.push('/library/edit/${library.id}'),
                  ),
                ],
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: loc.settings_playback_section,
                description: loc.settings_playback_section_desc,
                children: <Widget>[
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.route,
                    title: loc.settings_route_auto_fallback,
                    description: loc.settings_route_auto_fallback_desc,
                    value: autoFallback,
                    onChanged: (value) async {
                      ref.read(autoFallbackProvider.notifier).state = value;
                      ref.read(addressPoolProvider).autoFallback = value;
                      await LocalStorage.setAutoFallback(value);
                    },
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.palette,
                    title: loc.settings_theme,
                    value:
                        '${_themeModeText(themeSettings.mode)} · ${_colorHex(themeSettings.seedColor)}',
                    description: loc.settings_theme_desc,
                    onPressed: () => _pushPage(const ThemeSettingsPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.settings,
                    title: loc.settings_language,
                    value: _languageLabel(languageSettings.preference),
                    description: loc.settings_language_caption,
                    onPressed: () => _pushPage(const LanguageSettingsPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.quality,
                    title: loc.settings_audio_quality,
                    description: loc.settings_audio_quality_desc,
                    onPressed: () => _pushPage(const AudioQualityPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.cloudOff,
                    title: loc.offline_cache_title,
                    description: loc.offline_cache_settings_desc,
                    onPressed: () => _pushPage(const OfflineCachePage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.timer,
                    title: loc.settings_crossfade,
                    value: _crossfadeLabel(loc, crossfadeMs),
                    description: loc.settings_crossfade_desc,
                    onPressed: () => _showCrossfadeSheet(crossfadeMs),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.lyrics,
                    title: loc.settings_lyrics_dwell,
                    value: _lyricsDwellLabel(loc, lyricsDwellSeconds),
                    description: loc.settings_lyrics_dwell_desc,
                    onPressed: () =>
                        _showLyricsDwellSheet(lyricsDwellSeconds),
                  ),
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.play,
                    title: loc.settings_autoplay,
                    description: loc.settings_autoplay_desc,
                    value: _autoPlayOnLaunch,
                    onChanged: (value) async {
                      setState(() => _autoPlayOnLaunch = value);
                      await LocalStorage.setAutoPlayOnLaunch(value);
                    },
                  ),
                  if (isWindowsDesktop)
                    MusicFlowToggleSettingRow(
                      icon: AppIcons.lyrics,
                      title: loc.settings_desktop_lyrics,
                      description: loc.settings_desktop_lyrics_desc,
                      value: statusLyricsEnabled,
                      onChanged: (_) =>
                          ref.read(statusLyricsControllerProvider).toggle(),
                    ),
                  MusicFlowSettingRow(
                    icon: AppIcons.lyrics,
                    title: loc.settings_lyrics_provider,
                    description: loc.settings_lyrics_provider_desc,
                    onPressed: () => _pushPage(const LyricsProvidersPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.image,
                    title: loc.settings_cover_provider,
                    description: loc.settings_cover_provider_desc,
                    onPressed: () => _pushPage(const CoverProvidersPage()),
                  ),
                ],
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: loc.settings_diagnostics_section,
                description: loc.settings_diagnostics_section_desc,
                children: <Widget>[
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.fileText,
                    title: loc.settings_logging,
                    description: loc.settings_logging_desc,
                    value: _loggingEnabled,
                    onChanged: (value) async {
                      setState(() => _loggingEnabled = value);
                      Logger.setLoggingEnabled(value);
                      await LocalStorage.setLoggingEnabled(value);
                    },
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.fileText,
                    title: loc.settings_view_logs,
                    description: loc.settings_view_logs_desc,
                    trailing: Icon(
                      AppIcons.chevronRight,
                      size: 20,
                      color: context.musicFlowColors.muted,
                    ),
                    onPressed: () => _pushPage(const LogViewerPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.refresh,
                    title: loc.settings_check_update,
                    description: loc.settings_check_update_desc,
                    semanticLabel: _isCheckingUpdate
                        ? loc.settings_check_update_checking_semantics
                        : null,
                    trailing: _isCheckingUpdate
                        ? const MusicFlowSkeleton.circle(size: 20)
                        : null,
                    onPressed: _isCheckingUpdate ? null : _checkForUpdates,
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.info,
                    title: loc.settings_about,
                    description: loc.settings_about_desc,
                    onPressed: _showAboutSheet,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _pushPage(Widget page) {
    Navigator.of(
      context,
    ).push(MusicFlowPageRoute<void>(context: context, builder: (context) => page));
  }

  Future<void> _showLibrarySheet(
    List<MusicLibrary> libraries,
    MusicLibrary? currentLibrary,
  ) async {
    final loc = AppLocalizations.of(context);
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.settings_switch_library,
        subtitle: loc.settings_library_switch_subtitle,
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final library in libraries)
                MusicFlowChoiceRow(
                  title: library.name,
                  description: library.addresses.firstOrNull?.url ?? loc.settings_server_unconfigured,
                  selected: library.id == currentLibrary?.id,
                  icon: AppIcons.library,
                  onPressed: () {
                    final alreadySelected = library.id == currentLibrary?.id;
                    Navigator.of(sheetContext).pop();
                    if (!alreadySelected) _switchLibrary(library);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _switchLibrary(MusicLibrary library) async {
    try {
      final repository = ref.read(libraryRepositoryProvider);
      await repository.setActiveLibrary(library.id);
      ref.read(authStateProvider.notifier).switchLibrary(library);
      ref.invalidate(playerProvider);
      ref.invalidate(randomSongsProvider);
      // 广播变更信号,让随机歌曲区块按需重拉新库内容。
      notifyRandomSongsChanged();
      ref.invalidate(recentAlbumsProvider);
      ref.invalidate(frequentAlbumsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(starredProvider);
      _showMessage(
        AppLocalizations.of(context).settings_library_switched(library.name),
        kind: MusicFlowMessageKind.success,
      );
    } catch (error) {
      _showMessage(
        AppLocalizations.of(context).settings_library_switch_failed('$error'),
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _showCrossfadeSheet(int currentValue) async {
    const values = <int>[0, 500, 1000, 1500, 2000, 2500, 3000];
    final loc = AppLocalizations.of(context);
    final selected = await showMusicFlowBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.settings_crossfade,
        subtitle: loc.settings_crossfade_subtitle,
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final value in values)
                MusicFlowChoiceRow(
                  title: _crossfadeLabel(loc, value),
                  description: value == 0
                      ? loc.settings_crossfade_off_value
                      : loc.settings_crossfade_smooth(_crossfadeLabel(loc, value)),
                  selected: value == currentValue,
                  icon: AppIcons.timer,
                  onPressed: () => Navigator.of(sheetContext).pop(value),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    ref.read(crossfadeDurationMsProvider.notifier).setDuration(selected);
  }

  Future<void> _showLyricsDwellSheet(int currentValue) async {
    const values = <int>[1, 2, 3, 4, 5, 8, 10];
    final loc = AppLocalizations.of(context);
    final selected = await showMusicFlowBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.settings_lyrics_dwell,
        subtitle: loc.settings_lyrics_dwell_subtitle,
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final value in values)
                MusicFlowChoiceRow(
                  title: _lyricsDwellLabel(loc, value),
                  description: value == 3
                      ? loc.settings_lyrics_dwell_default
                      : loc.settings_lyrics_dwell_resume(_lyricsDwellLabel(loc, value)),
                  selected: value == currentValue,
                  icon: AppIcons.lyrics,
                  onPressed: () => Navigator.of(sheetContext).pop(value),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    ref.read(lyricsScrollDwellProvider.notifier).setDwell(selected);
  }

  void _showAboutSheet() {
    final loc = AppLocalizations.of(context);
    showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.settings_about_title,
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              MusicFlowSurface(
                level: MusicFlowSurfaceLevel.raised,
                borderColor: sheetContext.musicFlowColors.controlBoundary,
                padding: EdgeInsets.all(sheetContext.musicFlowSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox.square(
                      dimension:
                          sheetContext.musicFlowInteraction.minimumTouchTarget,
                      child: Center(
                        child: Icon(
                          AppIcons.musicFilled,
                          size: 28,
                          color: sheetContext.musicFlowColors.accent,
                        ),
                      ),
                    ),
                    SizedBox(width: sheetContext.musicFlowSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'MusicFlow',
                            style: sheetContext.musicFlowTypography.headline,
                          ),
                          SizedBox(height: sheetContext.musicFlowSpacing.xxs),
                          Text(
                            loc.settings_about_subtitle,
                            style: sheetContext.musicFlowTypography.body.copyWith(
                              color: sheetContext.musicFlowColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: sheetContext.musicFlowSpacing.md),
              MusicFlowActionRow(
                icon: AppIcons.externalLink,
                title: loc.settings_project_home,
                subtitle: 'github.com/ray5378/MusicFlow-client',
                trailing: Icon(
                  AppIcons.chevronRight,
                  size: 20,
                  color: sheetContext.musicFlowColors.muted,
                ),
                onPressed: () => _openUrl(
                  'https://github.com/ray5378/MusicFlow-client',
                ),
              ),
              SizedBox(height: sheetContext.musicFlowSpacing.sm),
              Text(
                '© 2026 MusicFlow',
                style: sheetContext.musicFlowTypography.metadata.copyWith(
                  color: sheetContext.musicFlowColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _languageLabel(AppLanguagePreference pref) {
    return switch (pref) {
      AppLanguagePreference.system => AppLocalizations.of(context).language_follow_system,
      AppLanguagePreference.zh => AppLocalizations.of(context).language_zh,
      AppLanguagePreference.en => AppLocalizations.of(context).language_en,
    };
  }

  String _themeModeText(ThemeMode mode) {
    final loc = AppLocalizations.of(context);
    switch (mode) {
      case ThemeMode.system:
        return loc.settings_theme_mode_system;
      case ThemeMode.light:
        return loc.settings_theme_mode_light;
      case ThemeMode.dark:
        return loc.settings_theme_mode_dark;
    }
  }

  String _colorHex(Color color) {
    final value = color
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .toUpperCase();
    return '#${value.substring(2)}';
  }
}

class _ServerSummary extends StatelessWidget {
  const _ServerSummary({required this.library, required this.activeAddress});

  final MusicLibrary? library;
  final ServerAddress? activeAddress;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowSurface(
      level: MusicFlowSurfaceLevel.raised,
      borderColor: context.musicFlowColors.controlBoundary,
      padding: EdgeInsets.all(context.musicFlowSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SettingsInfoLine(label: loc.settings_library_label, value: library?.name ?? loc.settings_not_selected),
          _SettingsInfoLine(
            label: loc.settings_current_connection,
            value: activeAddress?.label ?? loc.settings_not_connected,
          ),
          _SettingsInfoLine(label: loc.settings_server_address, value: activeAddress?.url ?? loc.settings_not_set),
          _SettingsInfoLine(label: loc.settings_username, value: library?.username ?? loc.settings_not_set),
          _SettingsInfoLine(
            label: loc.settings_auth_type,
            value: library?.authType == MusicLibraryAuthType.apiKey
                ? 'API Key'
                : loc.settings_auth_password,
            showBottomSpacing: false,
          ),
        ],
      ),
    );
  }
}

class _SettingsInfoLine extends StatelessWidget {
  const _SettingsInfoLine({
    required this.label,
    required this.value,
    this.showBottomSpacing = true,
  });

  final String label;
  final String value;
  final bool showBottomSpacing;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: loc.settings_info_line_semantics(label, value),
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: showBottomSpacing ? context.musicFlowSpacing.sm : 0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: context.musicFlowTypography.metadata.copyWith(
                  color: context.musicFlowColors.muted,
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.xxs),
              SelectableText(value, style: context.musicFlowTypography.body),
            ],
          ),
        ),
      ),
    );
  }
}

String _crossfadeLabel(AppLocalizations loc, int milliseconds) {
  if (milliseconds <= 0) return loc.settings_crossfade_off;
  return loc.settings_crossfade_seconds((milliseconds / 1000).toStringAsFixed(1));
}

String _lyricsDwellLabel(AppLocalizations loc, int seconds) {
  return loc.settings_dwell_seconds('$seconds');
}