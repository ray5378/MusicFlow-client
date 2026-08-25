import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/music_flow_design.dart';

enum MusicFlowDrawerConnectionState { connected, failed, unknown, disconnected }

class MusicFlowDrawerFrame extends StatelessWidget {
  const MusicFlowDrawerFrame({super.key, required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final sceneRadius = context.musicFlowRadii.scene;
    final availableWidth = math.max(
      0.0,
      MediaQuery.sizeOf(context).width - spacing.lg,
    );
    final preferredWidth = context.musicFlowWindowClass == MusicFlowWindowClass.compact
        ? 240.0
        : 267.0;
    final width = math.min(preferredWidth, availableWidth);

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: Semantics(
          container: true,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: '应用菜单',
          child: MusicFlowSurface(
            borderRadius: BorderRadiusDirectional.only(
              topEnd: sceneRadius.topRight,
              bottomEnd: sceneRadius.bottomRight,
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              right: false,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    header,
                    const MusicFlowDivider(),
                    Expanded(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MusicFlowDrawerIdentityHeader extends StatelessWidget {
  const MusicFlowDrawerIdentityHeader({
    super.key,
    required this.username,
    required this.libraryName,
    required this.addressLabel,
    required this.connectionState,
    required this.showingLibraries,
    required this.onToggleLibraries,
    this.avatarUrl,
  });

  final String username;
  final String libraryName;
  final String addressLabel;
  final MusicFlowDrawerConnectionState connectionState;
  final bool showingLibraries;
  final VoidCallback onToggleLibraries;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final status = _connectionPresentation(context, connectionState);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '当前账户 $username，音乐库 $libraryName，${status.label}，$addressLabel',
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          spacing.md,
          spacing.md,
          spacing.xs,
          spacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ExcludeSemantics(child: _Avatar(avatarUrl: avatarUrl)),
            SizedBox(width: spacing.sm),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(username, style: context.musicFlowTypography.title),
                    SizedBox(height: spacing.xxs),
                    Text(
                      libraryName,
                      style: context.musicFlowTypography.body.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                    SizedBox(height: spacing.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            status.icon,
                            size: 18,
                            color: status.color,
                          ),
                        ),
                        SizedBox(width: spacing.xs),
                        Expanded(
                          child: Text(
                            '${status.label} · $addressLabel',
                            style: context.musicFlowTypography.metadata.copyWith(
                              color: status.color,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: spacing.xs),
            MusicFlowIconButton(
              icon: showingLibraries
                  ? AppIcons.chevronUp
                  : AppIcons.chevronDown,
              label: showingLibraries ? '返回应用功能菜单' : '查看音乐库',
              selected: showingLibraries,
              onPressed: onToggleLibraries,
            ),
          ],
        ),
      ),
    );
  }
}

class MusicFlowDrawerLibraryRow extends StatelessWidget {
  const MusicFlowDrawerLibraryRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onSelected,
    required this.onEdit,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final motion = context.musicFlowMotion;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing.xs),
      child: AnimatedContainer(
        duration: motion.resolve(context, motion.state),
        curve: motion.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: context.musicFlowRadii.control,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: MusicFlowPressable(
                semanticLabel: <String>[
                  title,
                  subtitle,
                  if (selected) '当前音乐库',
                ].join('，'),
                selected: selected,
                onPressed: onSelected,
                minimumSize: const Size(double.infinity, 72),
                borderRadius: context.musicFlowRadii.control,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: spacing.xs,
                    vertical: spacing.xs,
                  ),
                  child: Row(
                    children: <Widget>[
                      SizedBox.square(
                        dimension: context.musicFlowInteraction.minimumTouchTarget,
                        child: Center(
                          child: Icon(
                            selected ? AppIcons.checkCircle : AppIcons.library,
                            size: context.musicFlowInteraction.smallIconSize,
                            color: selected ? colors.accent : colors.muted,
                          ),
                        ),
                      ),
                      SizedBox(width: spacing.xs),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(title, style: context.musicFlowTypography.title),
                            SizedBox(height: spacing.xxs),
                            Text(
                              subtitle,
                              style: context.musicFlowTypography.body.copyWith(
                                color: colors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(right: spacing.xs),
              child: MusicFlowIconButton(
                icon: AppIcons.edit,
                label: '编辑 $title',
                onPressed: onEdit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.avatarUrl});

  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Icon(AppIcons.profile, size: 28, color: context.musicFlowColors.accent),
    );

    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: context.musicFlowColors.raised,
        shape: BoxShape.circle,
        border: Border.all(color: context.musicFlowColors.controlBoundary),
      ),
      clipBehavior: Clip.antiAlias,
      child: avatarUrl == null
          ? fallback
          : Image.network(
              avatarUrl!,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
    );
  }
}

_ConnectionPresentation _connectionPresentation(
  BuildContext context,
  MusicFlowDrawerConnectionState state,
) {
  final colors = context.musicFlowColors;
  return switch (state) {
    MusicFlowDrawerConnectionState.connected => _ConnectionPresentation(
      icon: AppIcons.checkCircle,
      label: '连接正常',
      color: colors.accent,
    ),
    MusicFlowDrawerConnectionState.failed => _ConnectionPresentation(
      icon: AppIcons.error,
      label: '连接失败',
      color: colors.error,
    ),
    MusicFlowDrawerConnectionState.unknown => _ConnectionPresentation(
      icon: AppIcons.help,
      label: '等待检测',
      color: colors.muted,
    ),
    MusicFlowDrawerConnectionState.disconnected => _ConnectionPresentation(
      icon: AppIcons.cloudOff,
      label: '未连接',
      color: colors.muted,
    ),
  };
}

class _ConnectionPresentation {
  const _ConnectionPresentation({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;
}
