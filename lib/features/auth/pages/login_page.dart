import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/server_url_security.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../providers/auth_provider.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _serverFormKey = GlobalKey<FormState>();
  final _authFormKey = GlobalKey<FormState>();
  final _serverUrlController = TextEditingController();
  final _libraryNameController = TextEditingController();
  final _addressLabelController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _apiKeyController = TextEditingController();

  int _currentStep = 0;
  ServerCapabilities? _serverCapabilities;
  bool _isDetecting = false;
  String? _confirmedInsecureHttpUrl;

  /// 来源级归一化：去掉用户输入的空白与尾部斜杠 / query / fragment，
  /// 从源头避免 `baseUrl + '/rest/...'` 拼接出双斜杠 URL（会导致封面/播放全部静默失败）。
  String get _normalizedServerUrl =>
      normalizeServerBaseUrl(_serverUrlController.text.trim());

  @override
  void dispose() {
    _serverUrlController.dispose();
    _libraryNameController.dispose();
    _addressLabelController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _detectServer() async {
    if (!(_serverFormKey.currentState?.validate() ?? false)) return;
    if (!await _confirmInsecureHttpIfNeeded()) return;

    setState(() => _isDetecting = true);
    try {
      final repository = ref.read(authRepositoryProvider);
      final capabilities = await repository.detectServerCapabilities(
        _normalizedServerUrl,
      );
      if (!mounted) return;
      setState(() {
        _serverCapabilities = capabilities;
        _isDetecting = false;
        _currentStep = 1;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDetecting = false);
      _showError('无法连接到服务器，请检查地址是否正确');
    }
  }

  Future<void> _login() async {
    if (!(_authFormKey.currentState?.validate() ?? false)) return;
    if (!await _confirmInsecureHttpIfNeeded()) return;

    final authNotifier = ref.read(authStateProvider.notifier);
    final serverUrl = _normalizedServerUrl;
    final username = _usernameController.text.trim();
    final libraryName = _libraryNameController.text.trim();
    final addressLabel = _addressLabelController.text.trim();

    final success =
        _serverCapabilities?.supportsApiKey == true &&
            _apiKeyController.text.isNotEmpty
        ? await authNotifier.loginWithApiKey(
            serverUrl: serverUrl,
            username: username,
            apiKey: _apiKeyController.text.trim(),
            libraryName: libraryName,
            addressLabel: addressLabel,
          )
        : await authNotifier.loginWithPassword(
            serverUrl: serverUrl,
            username: username,
            password: _passwordController.text,
            libraryName: libraryName,
            addressLabel: addressLabel,
          );

    if (success && mounted) context.go('/home');
  }

  Future<bool> _confirmInsecureHttpIfNeeded() async {
    final serverUrl = _normalizedServerUrl;
    if (!isInsecureHttpUrl(serverUrl)) return true;
    if (_confirmedInsecureHttpUrl == serverUrl) return true;

    final confirmed = await showEchoBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: 'HTTP 连接不安全',
        subtitle: serverUrl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'HTTP 不会加密传输。密码、API Key、令牌以及媒体请求都可能被同一网络中的其他人窃听或篡改。'
              '仅当你信任当前网络和该服务器时才继续。',
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
            SizedBox(height: context.musicFlowSpacing.lg),
            MusicFlowButton.destructive(
              label: '仍然继续',
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            SizedBox(height: context.musicFlowSpacing.xs),
            MusicFlowButton.ghost(
              label: '取消',
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) _confirmedInsecureHttpUrl = serverUrl;
    return confirmed == true;
  }

  void _showError(String message) {
    if (!mounted) return;
    showEchoMessage(context, message, kind: MusicFlowMessageKind.error);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final busy = authState.isLoading || _isDetecting;

    ref.listen<AuthState>(authStateProvider, (previous, next) {
      if (next.errorMessage == null) return;
      _showError(next.errorMessage!);
      ref.read(authStateProvider.notifier).clearError();
    });

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar(
        title: '连接到服务器',
        subtitle: _currentStep == 0 ? '先确认服务器地址' : '输入认证信息',
        leading: context.canPop()
            ? MusicFlowIconButton(
                icon: AppIcons.back,
                label: '返回',
                onPressed: context.pop,
              )
            : null,
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                context.musicFlowPageHorizontalPadding,
                context.musicFlowSpacing.sm,
                context.musicFlowPageHorizontalPadding,
                MediaQuery.viewInsetsOf(context).bottom +
                    context.musicFlowSpacing.xxl,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _LoginStepIndicator(currentStep: _currentStep),
                      SizedBox(height: context.musicFlowSpacing.xl),
                      if (_currentStep == 0)
                        _buildServerStep()
                      else
                        _buildAuthenticationStep(),
                      SizedBox(height: context.musicFlowSpacing.lg),
                      MusicFlowButton.primary(
                        label: _isDetecting
                            ? '正在检测…'
                            : authState.isLoading
                            ? '正在登录…'
                            : _currentStep == 0
                            ? '下一步'
                            : '登录',
                        leadingIcon: _currentStep == 0
                            ? AppIcons.route
                            : AppIcons.key,
                        expand: true,
                        onPressed: busy
                            ? null
                            : _currentStep == 0
                            ? _detectServer
                            : _login,
                      ),
                      if (_currentStep > 0) ...<Widget>[
                        SizedBox(height: context.musicFlowSpacing.xs),
                        MusicFlowButton.ghost(
                          label: '上一步',
                          leadingIcon: AppIcons.back,
                          expand: true,
                          onPressed: busy
                              ? null
                              : () => setState(() => _currentStep = 0),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildServerStep() {
    return Form(
      key: _serverFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const MusicFlowSectionHeader(
            title: '服务器',
            description: 'MusicFlow 会先探测服务器能力，再决定可用的认证方式。',
          ),
          SizedBox(height: context.musicFlowSpacing.md),
          MusicFlowTextField(
            controller: _serverUrlController,
            label: '服务器地址',
            hintText: 'https://your-server.com',
            helperText: '优先使用 HTTPS。只有在可信局域网中才建议使用 HTTP。',
            leadingIcon: AppIcons.router,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '请输入服务器地址';
              }
              if (!isSupportedServerUrl(value)) {
                return '请输入完整的 URL（包括 http:// 或 https://）';
              }
              return null;
            },
          ),
          SizedBox(height: context.musicFlowSpacing.md),
          MusicFlowTextField(
            controller: _libraryNameController,
            label: '音乐库名称（可选）',
            hintText: '例如：家庭 NAS',
            helperText: '不填写则自动使用服务器类型。',
            leadingIcon: AppIcons.library,
            textInputAction: TextInputAction.next,
          ),
          SizedBox(height: context.musicFlowSpacing.md),
          MusicFlowTextField(
            controller: _addressLabelController,
            label: '线路名称（可选）',
            hintText: '例如：主线路 / 家里',
            helperText: '不填写则默认使用 Primary。',
            leadingIcon: AppIcons.route,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _detectServer(),
          ),
          if (_isDetecting) ...<Widget>[
            SizedBox(height: context.musicFlowSpacing.md),
            const _LoginBusyStatus(label: '正在检测服务器能力', icon: AppIcons.route),
          ],
        ],
      ),
    );
  }

  Widget _buildAuthenticationStep() {
    final capabilities = _serverCapabilities;
    final supportsApiKey = capabilities?.supportsApiKey == true;

    return Form(
      key: _authFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const MusicFlowSectionHeader(
            title: '认证信息',
            description: '认证信息只用于连接你的音乐服务器。',
          ),
          if (capabilities?.isOpenSubsonic == true) ...<Widget>[
            SizedBox(height: context.musicFlowSpacing.md),
            MusicFlowSurface(
              level: MusicFlowSurfaceLevel.raised,
              borderColor: context.musicFlowColors.controlBoundary,
              padding: EdgeInsets.all(context.musicFlowSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox.square(
                    dimension: context.musicFlowInteraction.minimumTouchTarget,
                    child: Center(
                      child: Icon(
                        AppIcons.checkCircle,
                        color: context.musicFlowColors.accent,
                      ),
                    ),
                  ),
                  SizedBox(width: context.musicFlowSpacing.xs),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '已检测到 OpenSubsonic',
                          style: context.musicFlowTypography.title,
                        ),
                        SizedBox(height: context.musicFlowSpacing.xxs),
                        Text(
                          capabilities?.serverType ?? '未知服务器类型',
                          style: context.musicFlowTypography.body.copyWith(
                            color: context.musicFlowColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: context.musicFlowSpacing.md),
          MusicFlowTextField(
            controller: _usernameController,
            label: '用户名',
            leadingIcon: AppIcons.profile,
            textInputAction: TextInputAction.next,
            validator: (value) {
              if (value == null || value.trim().isEmpty) return '请输入用户名';
              return null;
            },
          ),
          if (supportsApiKey) ...<Widget>[
            SizedBox(height: context.musicFlowSpacing.md),
            MusicFlowTextField(
              controller: _apiKeyController,
              label: 'API Key（推荐）',
              helperText: '填写 API Key 后将优先使用 API Key 认证。',
              leadingIcon: AppIcons.key,
              obscureText: true,
              textInputAction: TextInputAction.next,
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.md),
              child: Row(
                children: <Widget>[
                  const Expanded(child: MusicFlowDivider()),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.musicFlowSpacing.sm,
                    ),
                    child: Text(
                      '或使用密码',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ),
                  const Expanded(child: MusicFlowDivider()),
                ],
              ),
            ),
          ] else
            SizedBox(height: context.musicFlowSpacing.md),
          MusicFlowTextField(
            controller: _passwordController,
            label: '密码',
            leadingIcon: AppIcons.shield,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            validator: (value) {
              if (supportsApiKey && _apiKeyController.text.isNotEmpty) {
                return null;
              }
              if (value == null || value.isEmpty) return '请输入密码';
              return null;
            },
          ),
          if (ref.watch(authStateProvider).isLoading) ...<Widget>[
            SizedBox(height: context.musicFlowSpacing.md),
            const _LoginBusyStatus(label: '正在验证认证信息', icon: AppIcons.key),
          ],
        ],
      ),
    );
  }
}

class _LoginStepIndicator extends StatelessWidget {
  const _LoginStepIndicator({required this.currentStep});

  final int currentStep;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '登录进度，第 ${currentStep + 1} 步，共 2 步',
      child: ExcludeSemantics(
        child: Row(
          children: <Widget>[
            Expanded(
              child: _LoginStep(
                number: 1,
                label: '服务器',
                active: currentStep == 0,
                complete: currentStep > 0,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.musicFlowSpacing.xs),
              child: SizedBox(
                width: 32,
                child: MusicFlowDivider(
                  color: currentStep > 0
                      ? context.musicFlowColors.accent
                      : context.musicFlowColors.divider,
                ),
              ),
            ),
            Expanded(
              child: _LoginStep(
                number: 2,
                label: '认证',
                active: currentStep == 1,
                complete: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoginStep extends StatelessWidget {
  const _LoginStep({
    required this.number,
    required this.label,
    required this.active,
    required this.complete,
  });

  final int number;
  final String label;
  final bool active;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final highlighted = active || complete;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: highlighted
                ? colors.accent.withValues(alpha: 0.14)
                : colors.raised,
            borderRadius: context.musicFlowRadii.pill,
            border: Border.all(
              color: highlighted ? colors.accent : colors.controlBoundary,
            ),
          ),
          child: SizedBox.square(
            dimension: 36,
            child: Center(
              child: complete
                  ? Icon(AppIcons.check, size: 18, color: colors.accent)
                  : Text(
                      '$number',
                      style: context.musicFlowTypography.label.copyWith(
                        color: highlighted ? colors.accent : colors.muted,
                      ),
                    ),
            ),
          ),
        ),
        SizedBox(width: context.musicFlowSpacing.xs),
        Flexible(
          child: Text(
            label,
            style: context.musicFlowTypography.label.copyWith(
              color: highlighted ? colors.ink : colors.muted,
            ),
          ),
        ),
      ],
    );
  }
}

class _LoginBusyStatus extends StatelessWidget {
  const _LoginBusyStatus({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: Center(
                child: Icon(icon, size: 20, color: context.musicFlowColors.accent),
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(label, style: context.musicFlowTypography.body),
                  SizedBox(height: context.musicFlowSpacing.xs),
                  const MusicFlowSkeleton.line(height: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
