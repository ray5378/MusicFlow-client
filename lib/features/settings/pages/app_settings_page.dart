import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
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
import '../../../widgets/windows_title_bar.dart';
import '../widgets/music_flow_settings_components.dart';
import 'audio_quality_page.dart';
import 'cover_providers_page.dart';
import 'lyrics_providers_page.dart';
import 'theme_settings_page.dart';
import 'log_viewer_page.dart';

/// 全屏设置页
class AppSettingsPage extends ConsumerStatefulWidget {
  const AppSettingsPage({super.key});

  @override
  ConsumerState<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends ConsumerState<AppSettingsPage> {
  bool _isExportingLogs = false;
  bool _isCheckingUpdate = false;
  bool _autoPlayOnLaunch = false;

  @override
  void initState() {
    super.initState();
    LocalStorage.getAutoPlayOnLaunch().then((value) {
      if (mounted) setState(() => _autoPlayOnLaunch = value);
    });
  }

  Future<void> _exportLogs() async {
    setState(() => _isExportingLogs = true);

    try {
      final logContent = Logger.exportLogs();
      if (logContent.isEmpty) {
        _showMessage('暂无日志可导出');
        return;
      }

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      await Share.shareXFiles([
        XFile.fromData(
          utf8.encode(logContent),
          mimeType: 'text/plain',
          name: 'musicflow_log_$timestamp.txt',
        ),
      ], subject: 'MusicFlow 日志导出 $timestamp');

      Logger.infoWithTag(
        'LOG_EXPORT',
        'exported ${Logger.bufferedLineCount} lines to share payload'
            '${kIsWeb ? " (web)" : ""}',
      );
    } catch (error) {
      Logger.errorWithTag('LOG_EXPORT', 'export failed', error);
      _showMessage('日志导出失败: $error', kind: MusicFlowMessageKind.error);
    } finally {
      if (mounted) setState(() => _isExportingLogs = false);
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingUpdate = true);

    try {
      final result = await UpdateChecker.check();
      if (!mounted) return;

      if (result.hasUpdate) {
        _showUpdateDialog(result);
      } else {
        _showMessage(
          '当前已是最新版本 (${result.currentVersion})',
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (error) {
      _showMessage('检查更新失败: $error', kind: MusicFlowMessageKind.error);
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    final ctx = context;
    const subtitle = '发现新版本';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
          _SettingsInfoLine(label: '当前版本', value: result.currentVersion),
          _SettingsInfoLine(label: '最新版本', value: result.latestVersion),
          if (result.releaseNotes != null &&
              result.releaseNotes!.isNotEmpty) ...<Widget>[
            SizedBox(height: ctx.musicFlowSpacing.sm),
            const MusicFlowDivider(),
            SizedBox(height: ctx.musicFlowSpacing.md),
            const MusicFlowSectionHeader(title: '更新说明'),
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
            const MusicFlowSectionHeader(
              title: '下载文件',
              description: '选择适合当前设备的安装文件。',
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
                label: '稍后再说',
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              if (result.releaseUrl != null ||
                  _pickPlatformAsset(result) != null)
                MusicFlowButton.primary(
                  label: '前往下载',
                  leadingIcon: AppIcons.download,
                  onPressed: () {
                    final asset = _pickPlatformAsset(result);
                    Navigator.of(ctx).pop();
                    if (asset != null) {
                      _confirmOpenDownload(asset.name, asset.downloadUrl);
                    } else if (result.releaseUrl != null) {
                      _confirmOpenDownload(
                        '更新包 ${result.latestVersion}',
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
    final bool confirmed;
    if (isWindowsDesktop) {
      confirmed = (await showMusicFlowDesktopDialog<bool>(
        context: ctx,
        useRootNavigator: true,
        builder: (dialogContext) => MusicFlowDesktopDialog(
          icon: AppIcons.download,
          title: '前往下载',
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
          title: '前往下载',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '将跳转到浏览器开始下载。下载完成后请自行完成更新安装：'
          'Windows 请解压 zip 覆盖到安装目录，Android 请安装下载的 apk。',
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
              label: '取消',
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            MusicFlowButton.primary(
              label: '前往下载',
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
    final crossfadeMs = ref.watch(crossfadeDurationMsProvider);
    final lyricsDwellSeconds = ref.watch(lyricsScrollDwellProvider);
    final statusLyricsEnabled = ref.watch(statusLyricsEnabledProvider);
    final availableLibraries = librariesAsync.valueOrNull;
    final switchDescription = librariesAsync.when(
      data: (libraries) => libraries.length > 1
          ? '已保存 ${libraries.length} 个音乐库'
          : libraries.isEmpty
          ? '当前没有可切换的音乐库'
          : '当前仅有一个音乐库',
      loading: () => '正在读取音乐库列表',
      error: (error, stackTrace) => '音乐库列表读取失败，点击重试',
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
      topBar: MusicFlowTopBar.back(context: context, title: '设置'),
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
                title: '音乐库与服务器',
                description: '查看当前连接，也可以切换或编辑已经保存的音乐库。',
                children: <Widget>[
                  _ServerSummary(
                    library: library,
                    activeAddress: activeAddress,
                  ),
                  SizedBox(height: context.musicFlowSpacing.sm),
                  MusicFlowSettingRow(
                    icon: AppIcons.library,
                    title: '切换音乐库',
                    value: library?.name ?? '未选择',
                    description: switchDescription,
                    trailing: switchLibraryTrailing,
                    onPressed: switchLibraryAction,
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.edit,
                    title: '编辑当前音乐库',
                    value: library?.name ?? '未选择',
                    description: library == null
                        ? '选择音乐库后可编辑服务器与认证信息。'
                        : '管理服务器地址、认证方式与音乐库能力。',
                    onPressed: library == null
                        ? null
                        : () => context.push('/library/edit/${library.id}'),
                  ),
                ],
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: '播放与外观',
                description: '这些选择会立即应用到当前设备。',
                children: <Widget>[
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.route,
                    title: '线路自动回退',
                    description: '手动线路不可用时，自动切换到其他可用线路。',
                    value: autoFallback,
                    onChanged: (value) async {
                      ref.read(autoFallbackProvider.notifier).state = value;
                      ref.read(addressPoolProvider).autoFallback = value;
                      await LocalStorage.setAutoFallback(value);
                    },
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.palette,
                    title: '主题设置',
                    value:
                        '${_themeModeText(themeSettings.mode)} · ${_colorHex(themeSettings.seedColor)}',
                    description: '明暗模式与主题色',
                    onPressed: () => _pushPage(const ThemeSettingsPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.quality,
                    title: '音质设置',
                    description: '按网络选择播放码率',
                    onPressed: () => _pushPage(const AudioQualityPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.timer,
                    title: '切歌淡入淡出',
                    value: _crossfadeLabel(crossfadeMs),
                    description: '设置相邻曲目之间的交叉衰减时长。',
                    onPressed: () => _showCrossfadeSheet(crossfadeMs),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.lyrics,
                    title: '歌词跟随停靠时长',
                    value: _lyricsDwellLabel(lyricsDwellSeconds),
                    description: '手动滚动歌词后，过多久恢复自动跟随当前歌词。',
                    onPressed: () =>
                        _showLyricsDwellSheet(lyricsDwellSeconds),
                  ),
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.play,
                    title: '打开时自动播放',
                    description: '启动后恢复上次本机播放队列与进度，并自动续播。',
                    value: _autoPlayOnLaunch,
                    onChanged: (value) async {
                      setState(() => _autoPlayOnLaunch = value);
                      await LocalStorage.setAutoPlayOnLaunch(value);
                    },
                  ),
                  if (isWindowsDesktop)
                    MusicFlowToggleSettingRow(
                      icon: AppIcons.lyrics,
                      title: '任务栏歌词',
                      description: '开启后，系统托盘图标旁显示当前播放歌词。',
                      value: statusLyricsEnabled,
                      onChanged: (_) =>
                          ref.read(statusLyricsControllerProvider).toggle(),
                    ),
                  MusicFlowSettingRow(
                    icon: AppIcons.lyrics,
                    title: '歌词提供商',
                    description: '调整获取顺序与启用状态',
                    onPressed: () => _pushPage(const LyricsProvidersPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.image,
                    title: '封面提供商',
                    description: '调整获取顺序并配置 Fanart.tv',
                    onPressed: () => _pushPage(const CoverProvidersPage()),
                  ),
                ],
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: '诊断与更新',
                description: '导出本机诊断日志，或检查 GitHub Releases。',
                children: <Widget>[
                  MusicFlowSettingRow(
                    icon: AppIcons.fileText,
                    title: '查看日志',
                    description: '应用内直接查看并复制诊断日志（可筛选 DLNA）',
                    trailing: Icon(
                      AppIcons.chevronRight,
                      size: 20,
                      color: context.musicFlowColors.muted,
                    ),
                    onPressed: () => _pushPage(const LogViewerPage()),
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.fileText,
                    title: '导出日志',
                    description: '共缓存 ${Logger.bufferedLineCount} 条日志',
                    semanticLabel: _isExportingLogs ? '导出日志，正在准备分享文件' : null,
                    trailing: _isExportingLogs
                        ? const MusicFlowSkeleton.circle(size: 20)
                        : null,
                    onPressed: _isExportingLogs ? null : _exportLogs,
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.refresh,
                    title: '检查更新',
                    description: '从 GitHub Releases 检查最新版本',
                    semanticLabel: _isCheckingUpdate
                        ? '检查更新，正在连接 GitHub Releases'
                        : null,
                    trailing: _isCheckingUpdate
                        ? const MusicFlowSkeleton.circle(size: 20)
                        : null,
                    onPressed: _isCheckingUpdate ? null : _checkForUpdates,
                  ),
                  MusicFlowSettingRow(
                    icon: AppIcons.info,
                    title: '关于',
                    description: 'MusicFlow · 基于 Subsonic API',
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
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: '切换音乐库',
        subtitle: '选择后会刷新当前音乐库的内容与播放状态。',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final library in libraries)
                MusicFlowChoiceRow(
                  title: library.name,
                  description: library.addresses.firstOrNull?.url ?? '未配置服务器地址',
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
      _showMessage('已切换到“${library.name}”', kind: MusicFlowMessageKind.success);
    } catch (error) {
      _showMessage('切换音乐库失败: $error', kind: MusicFlowMessageKind.error);
    }
  }

  Future<void> _showCrossfadeSheet(int currentValue) async {
    const values = <int>[0, 500, 1000, 1500, 2000, 2500, 3000];
    final selected = await showMusicFlowBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: '切歌淡入淡出',
        subtitle: '选择相邻曲目同时播放的交叉衰减时长。',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final value in values)
                MusicFlowChoiceRow(
                  title: _crossfadeLabel(value),
                  description: value == 0
                      ? '关闭交叉衰减'
                      : '用 ${_crossfadeLabel(value)} 平滑衔接相邻曲目',
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
    final selected = await showMusicFlowBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: '歌词跟随停靠时长',
        subtitle: '手动滚动并停下后，等待该时长再恢复「跟随当前歌词」自动滚动。',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final value in values)
                MusicFlowChoiceRow(
                  title: _lyricsDwellLabel(value),
                  description: value == 3
                      ? '默认：停下 3 秒后恢复跟随'
                      : '停下 ${_lyricsDwellLabel(value)} 后恢复跟随',
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
    showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: '关于 MusicFlow',
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
                            '基于 Subsonic API 的音乐客户端。',
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
                title: '项目主页',
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

  String _themeModeText(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '白色';
      case ThemeMode.dark:
        return '黑色';
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
    return MusicFlowSurface(
      level: MusicFlowSurfaceLevel.raised,
      borderColor: context.musicFlowColors.controlBoundary,
      padding: EdgeInsets.all(context.musicFlowSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SettingsInfoLine(label: '音乐库', value: library?.name ?? '未选择'),
          _SettingsInfoLine(
            label: '当前连接',
            value: activeAddress?.label ?? '未连接',
          ),
          _SettingsInfoLine(label: '服务器地址', value: activeAddress?.url ?? '未设置'),
          _SettingsInfoLine(label: '用户名', value: library?.username ?? '未设置'),
          _SettingsInfoLine(
            label: '认证方式',
            value: library?.authType == MusicLibraryAuthType.apiKey
                ? 'API Key'
                : '密码',
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
    return Semantics(
      container: true,
      label: '$label，$value',
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

String _crossfadeLabel(int milliseconds) {
  if (milliseconds <= 0) return '关闭';
  return '${(milliseconds / 1000).toStringAsFixed(1)} 秒';
}

String _lyricsDwellLabel(int seconds) {
  return '$seconds 秒';
}
