import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/services/app_update_installer.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/player/crossfade_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_dwell_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';
import 'package:musicflow_client/providers/ui/theme_provider.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/features/settings/pages/audio_quality_page.dart';
import 'package:musicflow_client/features/settings/pages/offline_cache_page.dart';
import 'package:musicflow_client/features/settings/pages/cover_providers_page.dart';
import 'package:musicflow_client/features/settings/pages/lyrics_providers_page.dart';
import 'package:musicflow_client/features/settings/pages/theme_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/language_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/log_viewer_page.dart';

/// 全屏设置页
class AppSettingsPage extends ConsumerStatefulWidget {
  const AppSettingsPage({super.key});

  @override
  ConsumerState<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends ConsumerState<AppSettingsPage> {
  bool _isCheckingUpdate = false;
  bool _autoPlayOnLaunch = false;
  bool _defaultControlCurrentClient = false;
  bool _loggingEnabled = false;

  /// 最近一次「发现新版本」的检测结果。
  ///
  /// 下载控制器里只有下载状态、没有 [ReleaseAsset] / 版本上下文，所以
  /// 「下载中」这一行没法自己把进度浮层重新弹出来。这里留一份结果，
  /// 用户再点一次时重走 [AppUpdateInstaller.install]（其内部同版本去重
  /// 分支会发现「正在下 / 已下好」并直接把浮层展示出来，不会重下）。
  UpdateCheckResult? _lastResult;

  @override
  void initState() {
    super.initState();
    LocalStorage.getAutoPlayOnLaunch().then((value) {
      if (mounted) setState(() => _autoPlayOnLaunch = value);
    });
    // 「默认控制当前客户端」开关（默认 false = 启动自动接管在播播放器）。
    LocalStorage.getDefaultControlCurrentClient().then((value) {
      if (mounted) setState(() => _defaultControlCurrentClient = value);
    });
    // 同步日志开关（默认关闭，需手动开启）到 Logger 全局状态。
    LocalStorage.getLoggingEnabled().then((value) {
      // [AS-D-063] 修复：Logger.setLoggingEnabled 一并纳入 mounted 保护，
      // 避免 dispose 后写全局日志状态。
      if (mounted) {
        setState(() => _loggingEnabled = value);
        Logger.setLoggingEnabled(value);
      }
    });
  }

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingUpdate = true);

    try {
      final result = await UpdateChecker.check();
      if (!mounted) return;

      if (result.hasUpdate) {
        _lastResult = result;
        _showUpdateDialog(result);
      } else {
        final loc = AppLocalizations.of(context);
        _showMessage(
          loc.settings_update_latest(result.currentVersion),
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (error, st) {
      // [AS-D-062] 修复：异常原文不进 UI 文案 —— 按错误类型映射稳定文案，
      // 原文只进 Logger。
      Logger.error('update check failed', error, st);
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      _showMessage(
        error is TimeoutException
            ? loc.discover_error_desc_check_route
            : loc.settings_update_check_failed_generic,
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
        _SettingsInfoLine(
          label: loc.settings_current_version,
          value: result.currentVersion,
        ),
        _SettingsInfoLine(
          label: loc.settings_latest_version,
          value: result.latestVersion,
        ),
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
                // 直接跳转下载，不再二次确认:用户在上一步已明确点选文件，
                // 再弹一层「确定要下载吗」只增加一次无意义的点击。
                //
                // Android 上的 apk 改走内置更新（直下 + 唤装）；其它文件
                // （如 Windows 的 setup.exe）仍然交给浏览器。
                onPressed: () {
                  if (_canInstallBuiltIn(asset)) {
                    unawaited(_startBuiltInUpdate(result));
                    return;
                  }
                  _openDownload(asset.name, asset.downloadUrl);
                },
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
            if (result.releaseUrl != null || _pickPlatformAsset(result) != null)
              MusicFlowButton.primary(
                label: loc.settings_download,
                leadingIcon: AppIcons.download,
                onPressed: () {
                  final asset = _pickPlatformAsset(result);
                  Navigator.of(ctx).pop();
                  // Android：内置更新（直下 apk → 校验 → 唤装），不跳浏览器。
                  if (_canInstallBuiltIn(asset)) {
                    unawaited(_startBuiltInUpdate(result));
                    return;
                  }
                  if (asset != null) {
                    _openDownload(asset.name, asset.downloadUrl);
                  } else if (result.releaseUrl != null) {
                    _openDownload(
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

  /// 挑选适合当前平台的下载文件。
  ///
  /// 交付物自 v4.3.41 起只有两个：`-android.apk` 与 `-windows-setup.exe`
  /// （绿色版 portable zip 已停止产出）。因此这里统一委托
  /// [pickPlatformUpdateAsset]，避免两处挑选逻辑漂移——本页此前硬编码
  /// 「非 Android 优先 .zip」，在 zip 下线后会挑不中首选而落到
  /// `assets.first`（列表首个恰为 apk），表现为 Windows 上给用户推 apk。
  ReleaseAsset? _pickPlatformAsset(UpdateCheckResult result) =>
      pickPlatformUpdateAsset(result);

  /// 是否是「内置更新」的目标平台（直下 apk + 唤装）。
  ///
  /// 只有 Android 为真 —— 其它平台（尤其 Windows）保持原样跳浏览器，
  /// 行为一个字节都不变。
  bool get _useBuiltInUpdate =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 这次的资产能不能走内置更新：平台对 + 挑中的**确实是 apk**。
  ///
  /// 第二个条件不能省：发布页可能只发了 zip/exe（例如这一版只有 Linux/Windows
  /// 包），此时根本没有能装的东西，必须老老实实跳浏览器 —— 否则用户点了
  /// 「下载」会看到一个挑不出安装包的内部错误，而拿不到本该给他的文件。
  bool _canInstallBuiltIn(ReleaseAsset? asset) {
    if (!_useBuiltInUpdate) return false;
    if (asset == null) return false;
    return asset.name.toLowerCase().endsWith('.apk');
  }

  /// 启动内置更新流程（Android）。
  ///
  /// 挑不到 apk 资产时 [AppUpdateInstaller] 会自己回退到浏览器，所以这里
  /// 不需要再判断一次 —— 判断逻辑只留一份，避免两处漂移。
  Future<void> _startBuiltInUpdate(UpdateCheckResult result) async {
    Logger.infoWithTag(
      'UPDATE',
      'built-in update: ${result.currentVersion} → ${result.latestVersion}',
    );
    await AppUpdateInstaller.install(context, result);
  }

  /// 直接跳转浏览器下载，由用户自行完成安装。
  ///
  /// 不再弹二次确认框（2026-09-10 起）：用户在「发现新版本」框里点
  /// 「前往下载」或点选某个下载文件时，意图已经明确，多一层确认只会
  /// 打断流程、制造一次无谓点击。关闭更新框与打开链接由调用方顺序完成。
  Future<void> _openDownload(String label, String url) async {
    Logger.infoWithTag('UPDATE', 'open download url: $label → $url');
    await _openUrl(url);
  }

  Future<void> _openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        // [AS-D-060] 修复：canLaunchUrl false 不再静默，给用户稳定提示。
        _showOpenLinkFailed();
      }
    } catch (e, st) {
      // [AS-D-061] 修复：链接解析/跳转异常不再外漏为 unhandled async error，
      // 失败给稳定提示、原文进 Logger。
      Logger.error('open url failed: $url', e, st);
      _showOpenLinkFailed();
    }
  }

  void _showOpenLinkFailed() {
    if (!mounted) return;
    _showMessage(
      AppLocalizations.of(context).settings_open_link_failed,
      kind: MusicFlowMessageKind.error,
    );
  }

  void _showMessage(
    String message, {
    MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  }) {
    if (!mounted) return;
    showMusicFlowMessage(context, message, kind: kind);
  }

  /// 「下载中」这一行被点：把进度浮层重新弹出来。
  ///
  /// 控制器不持有 [ReleaseAsset]，没法直接弹浮层，所以借上次的检测结果重走
  /// [AppUpdateInstaller.install]：它内部会先问控制器，同版本「正在下」或
  /// 「已下好」都直接展示浮层，**不会重下几十 MB**。
  ///
  /// 没有历史结果（例如本次启动由「启动结算」直接灌进 completed 态）时，
  /// 退回重新检查一次更新，让用户拿到完整的更新对话框。
  void _reopenProgressSheet() {
    final result = _lastResult;
    if (result == null) {
      unawaited(_checkForUpdates());
      return;
    }
    unawaited(_startBuiltInUpdate(result));
  }

  /// 「已就绪」这一行被点：唤起系统安装器。
  ///
  /// [UpdateDownloadController.installNow] 返回 false 说明安装器没被拉起
  /// （缺「安装未知应用」授权、包被系统清理等），给一条稳定提示，
  /// 原文已经进 Logger 了。
  Future<void> _installReadyUpdate() async {
    // 先取好本地化再 await：避免 await 之后碰 BuildContext。
    final loc = AppLocalizations.of(context);
    final opened = await ref
        .read(updateDownloadControllerProvider.notifier)
        .installNow();
    if (opened) return;
    // mounted 由 _showMessage 内部兜住。
    _showMessage(
      loc.settings_update_install_open_failed,
      kind: MusicFlowMessageKind.error,
    );
  }

  /// 失败原因只给一句能看懂的：原始 message 已进日志，超长则截断。
  String _shortReason(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    if (raw.length <= 160) return raw;
    return '${raw.substring(0, 157)}…';
  }

  /// 字节数 → 人类可读（与下载浮层同一口径，避免两处显示差一位小数）。
  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final digits = value >= 100 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
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
              context.musicFlowSpacing.xxl +
                  context.musicFlowShellBottomObstruction,
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
                  // 「添加新音乐库」：复用既有登录页路由 —— `/login?add=true`
                  // 会让路由 redirect 放行（否则已认证用户会被弹回 /home），
                  // 连接成功后 AuthRepository 走 addLibrary 落库
                  // （见 auth_provider.dart 的 authenticated 分支）。
                  // 抽屉里的同款入口见 app_drawer.dart，语义与文案完全一致；
                  // 此处只是把入口也暴露到设置页，避免用户必须回抽屉才能加库。
                  MusicFlowSettingRow(
                    icon: AppIcons.add,
                    title: loc.widgets_drawer_add_new_library,
                    description: loc.widgets_drawer_add_new_library_subtitle,
                    trailing: Icon(
                      AppIcons.chevronRight,
                      size: 20,
                      color: context.musicFlowColors.muted,
                    ),
                    onPressed: () => context.push('/login?add=true'),
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
                    onPressed: () => _showLyricsDwellSheet(lyricsDwellSeconds),
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
                  // 「默认控制当前客户端」开关 —— 功能注释：
                  //  * 打开 = 启动后始终控制**当前客户端**；
                  //  * 关闭（默认）= 启动后自动接管**正在播放中**的播放器。
                  // 生效点只有一处：CastPeerController._maybeAutoSelectPlayingTarget
                  // 在首次拉到播放端列表时先查本开关（开启则直接保持本机）。
                  // 仅影响**启动时**的控制目标选择；运行中手动切换目标不受影响。
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.speaker,
                    title: loc.settings_default_control_current_client,
                    description:
                        loc.settings_default_control_current_client_desc,
                    value: _defaultControlCurrentClient,
                    onChanged: (value) async {
                      setState(() => _defaultControlCurrentClient = value);
                      await LocalStorage.setDefaultControlCurrentClient(value);
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
                  // 更新行四态（只在 Android 内置更新下生效）：
                  //   空闲/失败 → 「检查更新」
                  //   下载中   → 「正在下载」+ 百分比（点开会重新弹进度浮层）
                  //   已就绪   → 「已下载完成」+ 版本（点开唤起系统安装器）
                  // 非 Android（Windows / Web）退化成改动前那一行，逐字一致。
                  Consumer(
                    builder: (rowContext, rowRef, _) {
                      final rowLoc = AppLocalizations.of(rowContext);
                      final downloadState = rowRef.watch(
                        updateDownloadControllerProvider,
                      );
                      if (_useBuiltInUpdate) {
                        switch (downloadState.stage) {
                          case UpdateDownloadStage.downloading:
                            return MusicFlowSettingRow(
                              icon: AppIcons.download,
                              title: rowLoc.settings_update_downloading,
                              description: rowLoc
                                  .settings_update_download_progress(
                                    '${downloadState.percent}',
                                    _formatBytes(
                                      downloadState.progress?.received ?? 0,
                                    ),
                                    _formatBytes(
                                      downloadState.progress?.total ?? 0,
                                    ),
                                  ),
                              trailing: Text(
                                '${downloadState.percent}%',
                                style: rowContext.musicFlowTypography.body
                                    .copyWith(
                                      color: rowContext.musicFlowColors.muted,
                                      fontSize: 12,
                                    ),
                              ),
                              onPressed: _reopenProgressSheet,
                            );
                          case UpdateDownloadStage.completed:
                            // 不变式由控制器保证：completed 一定带非空 apkPath
                            // （结算回来却没扫到包时它自己回落 idle），所以这里
                            // 不必再判空，避免同一约束在 UI 层重复一份、日后漂移。
                            final readyVersion = downloadState.version;
                            return MusicFlowSettingRow(
                              icon: AppIcons.download,
                              title: rowLoc.settings_update_download_ready,
                              description: readyVersion == null
                                  ? ''
                                  : rowLoc.settings_update_found_version(
                                      readyVersion,
                                    ),
                              trailing: Icon(
                                AppIcons.chevronRight,
                                size: 20,
                                color: rowContext.musicFlowColors.muted,
                              ),
                              onPressed: () => unawaited(_installReadyUpdate()),
                            );
                          case UpdateDownloadStage.idle:
                          case UpdateDownloadStage.failed:
                            break;
                        }
                      }
                      // 空闲 / 失败（以及检查更新的全平台通用形态）。
                      // 失败态描述换成「下载失败 + 一句话原因」，
                      // 点击仍走检查更新：重新检测会拿到新的 result。
                      final downloadFailed =
                          _useBuiltInUpdate &&
                          downloadState.stage == UpdateDownloadStage.failed;
                      return MusicFlowSettingRow(
                        icon: AppIcons.refresh,
                        title: rowLoc.settings_check_update,
                        description: downloadFailed
                            ? rowLoc.settings_update_download_failed(
                                _shortReason(downloadState.errorMessage),
                              )
                            : rowLoc.settings_check_update_desc,
                        semanticLabel: _isCheckingUpdate
                            ? rowLoc.settings_check_update_checking_semantics
                            : null,
                        trailing: _isCheckingUpdate
                            ? const MusicFlowSkeleton.circle(size: 20)
                            : null,
                        onPressed: _isCheckingUpdate ? null : _checkForUpdates,
                      );
                    },
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
    Navigator.of(context).push(
      MusicFlowPageRoute<void>(context: context, builder: (context) => page),
    );
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
                  description:
                      library.addresses.firstOrNull?.url ??
                      loc.settings_server_unconfigured,
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
    } catch (error, st) {
      // [AS-D-062] 修复：异常原文不进 UI 文案 —— 稳定文案 + 原文进 Logger。
      Logger.error('library switch failed', error, st);
      if (!mounted) return;
      _showMessage(
        AppLocalizations.of(context).settings_library_switch_failed_generic,
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
                      : loc.settings_crossfade_smooth(
                          _crossfadeLabel(loc, value),
                        ),
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
                      : loc.settings_lyrics_dwell_resume(
                          _lyricsDwellLabel(loc, value),
                        ),
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
                            style: sheetContext.musicFlowTypography.body
                                .copyWith(
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
                onPressed: () =>
                    _openUrl('https://github.com/ray5378/MusicFlow-client'),
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
      AppLanguagePreference.system => AppLocalizations.of(
        context,
      ).language_follow_system,
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
          _SettingsInfoLine(
            label: loc.settings_library_label,
            value: library?.name ?? loc.settings_not_selected,
          ),
          _SettingsInfoLine(
            label: loc.settings_current_connection,
            value: activeAddress?.label ?? loc.settings_not_connected,
          ),
          _SettingsInfoLine(
            label: loc.settings_server_address,
            value: activeAddress?.url ?? loc.settings_not_set,
          ),
          _SettingsInfoLine(
            label: loc.settings_username,
            value: library?.username ?? loc.settings_not_set,
          ),
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
  return loc.settings_crossfade_seconds(
    (milliseconds / 1000).toStringAsFixed(1),
  );
}

String _lyricsDwellLabel(AppLocalizations loc, int seconds) {
  return loc.settings_dwell_seconds('$seconds');
}
